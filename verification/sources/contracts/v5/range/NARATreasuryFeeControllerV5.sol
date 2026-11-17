// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPoolManager} from "@uniswap/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {NARAFeeVaultV5} from "../fee-vault/NARAFeeVaultV5.sol";
import {RewardAsset} from "../interfaces/NARAAccountingTypesV5.sol";

/// @title NARATreasuryFeeControllerV5
/// @notice Zero-lock fee controller for NARAFeeVaultV5.
/// @dev Replaces permanent POL lockup with immediate (0-second delay) fee redemption and withdrawal
///      to Treasury Safe or an operator/governor-specified recipient.
contract NARATreasuryFeeControllerV5 is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using TransientStateLibrary for IPoolManager;

    uint256 public constant SCHEMA_VERSION = 1;

    NARAFeeVaultV5 public immutable feeVault;
    IPoolManager public immutable poolManager;
    address public immutable nara;
    address public immutable usdc;
    address public immutable governor;
    address public operator;

    error Unauthorized();
    error InvalidBinding();
    error InvalidRecipient();
    error InvalidAmount();
    error ManagerUnlocked();

    event OperatorUpdated(address indexed previousOperator, address indexed newOperator);
    event FeesWithdrawn(RewardAsset indexed asset, address indexed recipient, uint256 claimsRedeemed, uint256 amountWithdrawn);

    constructor(NARAFeeVaultV5 vault_, address operator_) {
        if (address(vault_).code.length == 0 || operator_ == address(0)) revert InvalidBinding();
        IPoolManager pm = vault_.poolManager();
        address n = vault_.nara();
        address u = vault_.usdc();
        address g = vault_.governor();
        if (
            address(pm).code.length == 0 || n.code.length == 0 || u.code.length == 0 || g.code.length == 0
                || operator_ == address(vault_) || operator_ == address(pm) || operator_ == n || operator_ == u
        ) revert InvalidBinding();

        feeVault = vault_;
        poolManager = pm;
        nara = n;
        usdc = u;
        governor = g;
        operator = operator_;
        emit OperatorUpdated(address(0), operator_);
    }

    modifier onlyAuthorized() {
        if (msg.sender != governor && msg.sender != operator) revert Unauthorized();
        _;
    }

    modifier managerLocked() {
        if (poolManager.isUnlocked()) revert ManagerUnlocked();
        _;
    }

    /// @notice Required by NARAFeeVaultV5._validateController / executeController.
    /// @dev Always true because this controller holds no locked LP positions or pending obligations.
    function canRetire() external view returns (bool) {
        if (poolManager.isUnlocked()) revert ManagerUnlocked();
        return true;
    }

    /// @notice Governor (Treasury Safe) can update the EOA operator with 0-second delay.
    function setOperator(address newOperator) external nonReentrant managerLocked {
        if (msg.sender != governor) revert Unauthorized();
        if (
            newOperator == address(0) || newOperator == address(this) || newOperator == address(feeVault)
                || newOperator == address(poolManager) || newOperator == nara || newOperator == usdc
        ) revert InvalidBinding();
        address prev = operator;
        operator = newOperator;
        emit OperatorUpdated(prev, newOperator);
    }

    /// @notice Preview total immediately withdrawable fees (booked claims + booked raw) in NARAFeeVaultV5.
    function withdrawable(RewardAsset asset) external view returns (uint256 claims, uint256 raw, uint256 total) {
        NARAFeeVaultV5.Inventory memory inv = feeVault.inventory(asset);
        claims = inv.booked.polClaims;
        raw = inv.booked.polRaw;
        total = claims + raw;
    }

    /// @notice Sweep 100% of available USDC and NARA fees from NARAFeeVaultV5 straight to Treasury Safe (0-second delay).
    function sweepToSafe() external nonReentrant managerLocked returns (uint256 usdcOut, uint256 naraOut) {
        usdcOut = _withdrawAllAsset(RewardAsset.USDC, governor);
        naraOut = _withdrawAllAsset(RewardAsset.NARA, governor);
    }

    /// @notice Withdraw 100% of available USDC and NARA fees from NARAFeeVaultV5 to any specified recipient (0-second delay).
    function withdrawAllTo(address recipient)
        external
        nonReentrant
        managerLocked
        onlyAuthorized
        returns (uint256 usdcOut, uint256 naraOut)
    {
        _validateRecipient(recipient);
        usdcOut = _withdrawAllAsset(RewardAsset.USDC, recipient);
        naraOut = _withdrawAllAsset(RewardAsset.NARA, recipient);
    }

    /// @notice Withdraw an exact amount of USDC or NARA fees from NARAFeeVaultV5 to any specified recipient (0-second delay).
    function withdrawTo(RewardAsset asset, uint256 amount, address recipient)
        external
        nonReentrant
        managerLocked
        onlyAuthorized
        returns (uint256 redeemedClaims)
    {
        if (asset == RewardAsset.ETH || amount == 0) revert InvalidAmount();
        _validateRecipient(recipient);

        NARAFeeVaultV5.Inventory memory inv = feeVault.inventory(asset);
        uint256 availableClaims = inv.booked.polClaims;
        uint256 availableRaw = inv.booked.polRaw;
        if (amount > availableClaims + availableRaw) revert InvalidAmount();

        if (amount > availableRaw) {
            redeemedClaims = amount - availableRaw;
            feeVault.redeem(asset, 0, redeemedClaims);
        }

        feeVault.takePOL(asset, amount);
        IERC20(asset == RewardAsset.NARA ? nara : usdc).safeTransfer(recipient, amount);
        emit FeesWithdrawn(asset, recipient, redeemedClaims, amount);
    }

    /// @notice Rescue any token accidentally sent directly to this controller.
    function rescueToken(address token, address recipient, uint256 amount)
        external
        nonReentrant
        managerLocked
        onlyAuthorized
    {
        if (token == address(0) || amount == 0) revert InvalidAmount();
        _validateRecipient(recipient);
        IERC20(token).safeTransfer(recipient, amount);
    }

    function _withdrawAllAsset(RewardAsset asset, address recipient) private returns (uint256 totalOut) {
        NARAFeeVaultV5.Inventory memory inv = feeVault.inventory(asset);
        uint256 claims = inv.booked.polClaims;
        uint256 raw = inv.booked.polRaw;
        totalOut = claims + raw;
        if (totalOut == 0) return 0;

        if (claims != 0) {
            feeVault.redeem(asset, 0, claims);
        }
        feeVault.takePOL(asset, totalOut);
        IERC20(asset == RewardAsset.NARA ? nara : usdc).safeTransfer(recipient, totalOut);
        emit FeesWithdrawn(asset, recipient, claims, totalOut);
    }

    function _validateRecipient(address recipient) private view {
        if (
            recipient == address(0) || recipient == address(this) || recipient == address(feeVault)
                || recipient == address(poolManager) || recipient == nara || recipient == usdc
        ) revert InvalidRecipient();
    }
}
