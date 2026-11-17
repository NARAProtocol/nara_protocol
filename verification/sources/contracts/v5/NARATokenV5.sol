// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20FlashMint} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20FlashMint.sol";
import {ERC1363} from "@openzeppelin/contracts/token/ERC20/extensions/ERC1363.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";

/// @title NARA Token
/// @notice NARA for Base: 1,000,000 settled supply; bounded atomic flash minting; no admin or pause.
/// @custom:website https://naraprotocol.io
/// @custom:twitter https://x.com/NARA_protocol
/// @custom:telegram https://t.me/naraprotocol
/// @dev Feature matrix:
///  - ERC20Permit (EIP-2612 gasless approvals, domain validated via EIP-712)
///  - ERC20FlashMint (ERC-3156 flash loans; fee = 10 bps, routed to FLASH_FEE_SINK, hard-capped)
///  - ERC1363 (transferAndCall / approveAndCall for single-tx dApp flows)
///  - Multicall (batch calls; protocol permit wrappers are preferred for permit + lock flows)
///
/// Immutability guarantees:
///  - MAX_SUPPLY is minted once in constructor; flash mints are bounded and repaid in the same transaction.
///  - FLASH_FEE_SINK is immutable; bind the reviewed protocol reserve at deployment.
///  - No owner, no pause, no blacklist, no upgrade path, no admin setter.
contract NARATokenV5 is ERC20, ERC20Permit, ERC20FlashMint, ERC1363, Multicall {
    bytes32 private constant FLASH_CALLBACK_SUCCESS =
        keccak256("ERC3156FlashBorrower.onFlashLoan");

    /// @notice Settled supply: 1,000,000 NARA, initially minted to `treasury_`.
    /// @dev During callbacks totalSupply = MAX_SUPPLY + outstanding flash principal.
    uint256 public constant MAX_SUPPLY = 1_000_000 ether;

    /// @notice Maximum same-transaction flash-minted supply. 10% of MAX_SUPPLY.
    uint256 public constant MAX_FLASH_LOAN = 100_000 ether;

    /// @notice Flash loan fee in basis points (0.10%).
    /// @dev Hardcoded. Cannot be changed. Rationale: predictable economics, no admin key.
    uint16 public constant FLASH_FEE_BPS = 10;

    /// @notice Immutable recipient of NARA flash fees; no callback is invoked on receipt.
    /// @dev The protocol reserve must recognize direct transfers once through its funding ledger.
    /// Deployment must validate the fresh recipient and its permissionless sync path.
    address public immutable FLASH_FEE_SINK;
    uint256 private _outstandingFlashPrincipal;

    error ZeroAddress();
    error EmptyMetadata();

    constructor(
        address treasury_,
        address flashFeeSink_,
        string memory name_,
        string memory symbol_
    )
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        if (treasury_ == address(0) || flashFeeSink_ == address(0)) revert ZeroAddress();
        if (bytes(name_).length == 0 || bytes(symbol_).length == 0) revert EmptyMetadata();
        FLASH_FEE_SINK = flashFeeSink_;
        _mint(treasury_, MAX_SUPPLY);
    }

    // ============================================================
    // Flash mint fee logic
    // ============================================================

    /// @dev Fee = floor(amount * 10 / 10_000) in token base units; zero and sub-1,000-wei loans cost zero.
    function _flashFee(address /*token*/, uint256 value) internal pure override returns (uint256) {
        return (value * FLASH_FEE_BPS) / 10_000;
    }

    /// @notice Returns the fee for a supported flash loan amount.
    function flashFee(address token, uint256 value) public view override returns (uint256) {
        if (token != address(this)) revert ERC3156UnsupportedToken(token);
        if (value > MAX_FLASH_LOAN) revert ERC3156ExceededMaxLoan(MAX_FLASH_LOAN);
        return _flashFee(token, value);
    }

    /// @dev Fee is routed to the immutable deployment-bound sink.
    function _flashFeeReceiver() internal view override returns (address) {
        return FLASH_FEE_SINK;
    }

    /// @notice Bound flash-minted supply to the protocol cap.
    function maxFlashLoan(address token) public view override returns (uint256) {
        if (token != address(this)) return 0;
        return MAX_FLASH_LOAN - _outstandingFlashPrincipal;
    }

    /// @notice Flash mint with one aggregate cap shared by every recursive loan.
    /// @dev Reentry is intentional: reserve capacity before calling the borrower;
    /// restore it only after principal burn and fee transfer. Any failure rolls back
    /// the entire loan. Integrators must not treat callback balances as settled funds.
    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 value,
        bytes calldata data
    ) public override returns (bool) {
        uint256 maxLoan = maxFlashLoan(token);
        if (value > maxLoan) revert ERC3156ExceededMaxLoan(maxLoan);

        uint256 fee = flashFee(token, value);
        _outstandingFlashPrincipal += value;
        _mint(address(receiver), value);

        if (
            receiver.onFlashLoan(_msgSender(), token, value, fee, data) !=
            FLASH_CALLBACK_SUCCESS
        ) {
            revert ERC3156InvalidReceiver(address(receiver));
        }

        address feeReceiver = _flashFeeReceiver();
        _spendAllowance(address(receiver), address(this), value + fee);
        if (fee == 0 || feeReceiver == address(0)) {
            _burn(address(receiver), value + fee);
        } else {
            _burn(address(receiver), value);
            _transfer(address(receiver), feeReceiver, fee);
        }
        _outstandingFlashPrincipal -= value;
        return true;
    }

    /// @dev Add IERC3156FlashLender to the list of supported interfaces.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1363)
        returns (bool)
    {
        return
            interfaceId == type(IERC3156FlashLender).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
