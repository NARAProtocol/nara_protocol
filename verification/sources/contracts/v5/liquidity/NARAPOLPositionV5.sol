// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IAllowanceTransfer} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-periphery/lib/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/TickMath.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {NARAFeeVaultV5} from "../fee-vault/NARAFeeVaultV5.sol";
import {RewardAsset} from "../interfaces/NARAAccountingTypesV5.sol";

interface IPOLHookV5 {
    function poolRegistered() external view returns (bool);
    function poolKey() external view returns (PoolKey memory);
}
interface IPOLCapitalPolicyV5 {
    function polPosition() external view returns (address);
    function feeVault() external view returns (address);
    function hasPendingCapitalOperations() external view returns (bool);
}
interface IPOLPositionManagerV5 {
    function poolManager() external view returns (address);
    function permit2() external view returns (address);
    function nextTokenId() external view returns (uint256);
    function ownerOf(uint256 id) external view returns (address);
    function getPositionLiquidity(uint256 id) external view returns (uint128);
    function getPoolAndPositionInfo(uint256 id) external view returns (PoolKey memory, PositionInfo);
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
}

/// @notice Single registered POL LP custody; all unspent capital remains in the Fee Vault.
/// @dev Capital allocation belongs to a separate, immutable policy. Its on-chain limits,
/// oracle, matched sizing and delayed governance are mandatory before deployment acceptance.
/// This executor never swaps, approves an NFT, signs a permit, or chooses an arbitrary recipient.
contract NARAPOLPositionV5 is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    struct Add {
        uint128 liquidity;
        uint128 maxNara;
        uint128 maxUsdc;
        uint160 minSqrtPriceX96;
        uint160 maxSqrtPriceX96;
        uint48 deadline;
    }
    struct Remove {
        uint128 liquidity;
        uint128 minNara;
        uint128 minUsdc;
        uint48 deadline;
    }
    struct Totals {
        uint256 naraAdded;
        uint256 usdcAdded;
        uint256 naraRemoved;
        uint256 usdcRemoved;
        uint256 naraFees;
        uint256 usdcFees;
    }

    uint256 public constant SCHEMA_VERSION = 1;
    uint256 public constant COLLECTION_INTERVAL = 900;
    NARAFeeVaultV5 public immutable feeVault;
    IPoolManager public immutable poolManager;
    IPOLPositionManagerV5 public immutable positionManager;
    IAllowanceTransfer public immutable permit2;
    address public immutable nara;
    address public immutable usdc;
    address public initializer;
    address public capitalPolicy;
    uint256 public positionTokenId;
    uint256 public nextCollectionAt;
    int24 public tickLower;
    int24 public tickUpper;
    PoolKey private _key;
    Totals private _totals;

    error Unauthorized();
    error InvalidBinding();
    error InvalidState();
    error InvalidAmount();
    error InvalidReceipt();
    error InvalidPrice();
    error Expired();
    error ManagerUnlocked();
    error NoCollectibleFees();
    error CollectionTooSoon();
    event Sealed(address indexed policy, bytes32 indexed poolId);
    event LPFees(uint256 indexed tokenId, uint256 naraAmount, uint256 usdcAmount);
    event CapitalAdded(uint256 indexed tokenId, uint128 liquidity, uint256 naraAmount, uint256 usdcAmount);
    event CapitalRemoved(uint256 indexed tokenId, uint128 liquidity, uint256 naraAmount, uint256 usdcAmount, bool closed);
    event SurplusDonated(uint256 naraAmount, uint256 usdcAmount, uint256 ethAmount);

    constructor(NARAFeeVaultV5 vault, IPOLPositionManagerV5 pm) {
        if (address(vault).code.length == 0 || address(pm).code.length == 0) revert InvalidBinding();
        feeVault = vault; positionManager = pm;
        poolManager = vault.poolManager(); nara = vault.nara(); usdc = vault.usdc();
        address p = pm.permit2();
        if (address(pm.poolManager()) != address(poolManager) || p.code.length == 0
            || address(pm) == address(vault) || p == address(pm) || p == address(vault)
            || (!vault.bindingsSealed() && vault.initializer() != msg.sender)) revert InvalidBinding();
        // A replacement can be prepared after launch, but only the fixed governor
        // can bind it. Construction never makes this the active spending controller.
        permit2 = IAllowanceTransfer(p); initializer = vault.bindingsSealed() ? vault.governor() : msg.sender;
    }

    modifier locked() { _requireLocked(); _; }
    modifier ready() { _requireReady(); _; }
    modifier capitalAccess() { _requireCapitalAccess(); _; }

    function seal(address policy) external nonReentrant locked {
        if (msg.sender != initializer || initializer == address(0)) revert Unauthorized();
        if (!feeVault.bindingsSealed()
            || policy.code.length == 0 || policy == address(this) || policy == address(feeVault)
            || !IPOLHookV5(feeVault.hook()).poolRegistered()) revert InvalidBinding();
        IPOLCapitalPolicyV5 p = IPOLCapitalPolicyV5(policy);
        if (p.polPosition() != address(this) || p.feeVault() != address(feeVault)) revert InvalidBinding();
        PoolKey memory k = IPOLHookV5(feeVault.hook()).poolKey();
        if (Currency.unwrap(k.currency0) != (nara < usdc ? nara : usdc)
            || Currency.unwrap(k.currency1) != (nara < usdc ? usdc : nara)
            || address(k.hooks) != feeVault.hook() || k.fee != 3000 || k.tickSpacing != 60) revert InvalidBinding();
        _key = k; capitalPolicy = policy; initializer = address(0);
        emit Sealed(policy, keccak256(abi.encode(k)));
    }

    function poolKey() external view returns (PoolKey memory) { _coherent(); return _key; }
    function totals() external view returns (Totals memory) { _coherent(); return _totals; }
    function liquidity() public view returns (uint128) {
        _coherent(); return positionTokenId == 0 ? 0 : positionManager.getPositionLiquidity(positionTokenId);
    }

    /// @dev No recorded buffers or jobs live here. Unsolicited assets cannot veto retirement:
    /// sweepSurplus remains usable after replacement and always donates to this same Vault.
    function canRetire() external view returns (bool) {
        _coherent();
        return initializer == address(0) && capitalPolicy != address(0) && positionTokenId == 0
            && !IPOLCapitalPolicyV5(capitalPolicy).hasPendingCapitalOperations();
    }

    function add(int24 lower, int24 upper, Add calldata a)
        external nonReentrant locked capitalAccess
    {
        bool minting = positionTokenId == 0;
        if (minting) {
            if (lower >= upper || lower < TickMath.MIN_TICK || upper > TickMath.MAX_TICK
                || lower % _key.tickSpacing != 0 || upper % _key.tickSpacing != 0) revert InvalidState();
            tickLower = lower; tickUpper = upper;
        } else {
            if (lower != tickLower || upper != tickUpper) revert InvalidState();
            _checkAdd(a);
            _collect(a.deadline); // Increases realize fees too; never net holder fees against new principal.
        }
        _add(a, minting);
    }
    function collect() external nonReentrant locked ready {
        _requirePosition();
        if (block.timestamp < nextCollectionAt) revert CollectionTooSoon();
        if (!_collect(uint48(block.timestamp))) revert NoCollectibleFees();
    }
    function remove(Remove calldata r, bool closePosition) external nonReentrant locked capitalAccess {
        _remove(r, closePosition);
    }

    /// @notice Direct unrequested NARA/USDC/forced ETH are donations, not earned LP fees.
    /// Other tokens/NFTs are not registered or silently assigned financial rights.
    function sweepSurplus() external nonReentrant locked {
        (uint256 n, uint256 u) = _balances();
        uint256 e = address(this).balance;
        _vaultPayment(nara, RewardAsset.NARA, n, feeVault.fundPOL); _vaultPayment(usdc, RewardAsset.USDC, u, feeVault.fundPOL);
        if (e != 0) feeVault.fundPOL{value: e}(RewardAsset.ETH, e);
        emit SurplusDonated(n, u, e);
    }

    function _add(Add calldata a, bool minting) private {
        _checkAdd(a);
        (uint256 n0, uint256 u0) = _balances();
        if (a.maxNara != 0) feeVault.takePOL(RewardAsset.NARA, a.maxNara);
        if (a.maxUsdc != 0) feeVault.takePOL(RewardAsset.USDC, a.maxUsdc);
        _allow(nara, a.maxNara, a.deadline); _allow(usdc, a.maxUsdc, a.deadline);
        uint128 beforeL;
        uint256 id = positionTokenId;
        bytes[] memory p = new bytes[](2);
        (uint128 m0, uint128 m1) = nara < usdc ? (a.maxNara, a.maxUsdc) : (a.maxUsdc, a.maxNara);
        if (minting) {
            id = positionManager.nextTokenId();
            p[0] = abi.encode(_key, tickLower, tickUpper, uint256(a.liquidity), m0, m1, address(this), bytes(""));
        } else {
            beforeL = positionManager.getPositionLiquidity(id);
            p[0] = abi.encode(id, uint256(a.liquidity), m0, m1, bytes(""));
        }
        p[1] = abi.encode(_key.currency0, _key.currency1);
        positionManager.modifyLiquidities(abi.encode(minting ? hex"020d" : hex"000d", p), a.deadline);
        _allow(nara, 0, 0); _allow(usdc, 0, 0);
        if (positionManager.ownerOf(id) != address(this)
            || positionManager.getPositionLiquidity(id) != uint256(beforeL) + a.liquidity) revert InvalidReceipt();
        (PoolKey memory actual, PositionInfo info) = positionManager.getPoolAndPositionInfo(id);
        if (keccak256(abi.encode(actual)) != keccak256(abi.encode(_key))
            || info.tickLower() != tickLower || info.tickUpper() != tickUpper || info.hasSubscriber()) revert InvalidReceipt();
        (uint256 n1, uint256 u1) = _balances();
        if (n1 < n0 || n1 > n0 + a.maxNara || u1 < u0 || u1 > u0 + a.maxUsdc) revert InvalidReceipt();
        uint256 nUsed = n0 + a.maxNara - n1; uint256 uUsed = u0 + a.maxUsdc - u1;
        if (nUsed == 0 && uUsed == 0) revert InvalidReceipt();
        positionTokenId = id;
        _vaultPayment(nara, RewardAsset.NARA, a.maxNara - nUsed, feeVault.returnPOL);
        _vaultPayment(usdc, RewardAsset.USDC, a.maxUsdc - uUsed, feeVault.returnPOL);
        _totals.naraAdded += nUsed; _totals.usdcAdded += uUsed;
        emit CapitalAdded(id, a.liquidity, nUsed, uUsed);
    }

    function _remove(Remove calldata r, bool closing) private {
        _requirePosition(); _deadline(r.deadline);
        uint256 id = positionTokenId;
        uint128 oldL = positionManager.getPositionLiquidity(id);
        if (r.liquidity == 0 || r.liquidity > oldL || (closing ? r.liquidity != oldL : r.liquidity == oldL)) revert InvalidAmount();
        _collect(r.deadline); // All subsequent positive receipts are principal, not LP revenue.
        (uint256 n0, uint256 u0) = _balances();
        bytes[] memory p = new bytes[](2);
        (uint128 m0, uint128 m1) = nara < usdc ? (r.minNara, r.minUsdc) : (r.minUsdc, r.minNara);
        p[0] = closing ? abi.encode(id, m0, m1, bytes("")) : abi.encode(id, uint256(r.liquidity), m0, m1, bytes(""));
        p[1] = abi.encode(_key.currency0, _key.currency1, address(this));
        positionManager.modifyLiquidities(abi.encode(closing ? hex"0311" : hex"0111", p), r.deadline);
        if (!closing && positionManager.getPositionLiquidity(id) != oldL - r.liquidity) revert InvalidReceipt();
        (uint256 n, uint256 u) = _balances(); n -= n0; u -= u0;
        if (n < r.minNara || u < r.minUsdc) revert InvalidReceipt();
        if (closing) { positionTokenId = 0; tickLower = 0; tickUpper = 0; }
        _vaultPayment(nara, RewardAsset.NARA, n, feeVault.returnPOL); _vaultPayment(usdc, RewardAsset.USDC, u, feeVault.returnPOL);
        _totals.naraRemoved += n; _totals.usdcRemoved += u;
        emit CapitalRemoved(id, r.liquidity, n, u, closing);
    }
    function _collect(uint48 deadline) private returns (bool received) {
        (uint256 n0, uint256 u0) = _balances();
        bytes[] memory p = new bytes[](2);
        p[0] = abi.encode(positionTokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        p[1] = abi.encode(_key.currency0, _key.currency1, address(this));
        positionManager.modifyLiquidities(abi.encode(hex"0111", p), deadline);
        (uint256 n, uint256 u) = _balances(); n -= n0; u -= u0;
        _vaultPayment(nara, RewardAsset.NARA, n, feeVault.receiveLPFees); _vaultPayment(usdc, RewardAsset.USDC, u, feeVault.receiveLPFees);
        _totals.naraFees += n; _totals.usdcFees += u;
        emit LPFees(positionTokenId, n, u);
        received = n != 0 || u != 0;
        if (received) nextCollectionAt = block.timestamp + COLLECTION_INTERVAL;
    }
    function _balances() private view returns (uint256, uint256) {
        return (IERC20(nara).balanceOf(address(this)), IERC20(usdc).balanceOf(address(this)));
    }
    function _vaultPayment(address token, RewardAsset asset, uint256 amount, function(RewardAsset, uint256) external payable pay) private {
        if (amount == 0) return;
        IERC20 t = IERC20(token); uint256 beforeBalance = t.balanceOf(address(this));
        t.forceApprove(address(feeVault), amount);
        pay(asset, amount);
        t.forceApprove(address(feeVault), 0);
        if (t.balanceOf(address(this)) != beforeBalance - amount) revert InvalidReceipt();
    }
    function _allow(address token, uint160 amount, uint48 expiration) private {
        IERC20(token).forceApprove(address(permit2), amount);
        permit2.approve(token, address(positionManager), amount, expiration);
    }
    function _checkAdd(Add calldata a) private view {
        _deadline(a.deadline);
        if (a.liquidity == 0 || (a.maxNara == 0 && a.maxUsdc == 0)) revert InvalidAmount();
        (uint160 price,,,) = poolManager.getSlot0(_key.toId());
        if (a.minSqrtPriceX96 < TickMath.MIN_SQRT_PRICE || a.maxSqrtPriceX96 >= TickMath.MAX_SQRT_PRICE
            || a.minSqrtPriceX96 > a.maxSqrtPriceX96 || price < a.minSqrtPriceX96 || price > a.maxSqrtPriceX96) revert InvalidPrice();
    }
    function _requireLocked() private view { if (poolManager.isUnlocked()) revert ManagerUnlocked(); }
    function _requireReady() private view {
        if (capitalPolicy == address(0) || feeVault.polController() != address(this)) revert InvalidState();
    }
    function _requireCapitalAccess() private view {
        _requireReady();
        if (msg.sender != capitalPolicy) revert Unauthorized();
        if (feeVault.polPaused()) revert InvalidState();
    }
    function _deadline(uint48 d) private view { if (d < block.timestamp) revert Expired(); }
    function _requirePosition() private view { if (positionTokenId == 0) revert InvalidState(); }
    function _coherent() private view {
        if (_reentrancyGuardEntered()) revert InvalidState();
        _requireLocked();
    }
}
