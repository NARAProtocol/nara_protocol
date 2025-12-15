// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { OFT } from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import "./NaraTiers.sol";

interface INaraJackpotReceiver {
    function onNaraFeeReceived(address from, uint256 amount) external;
}

/// @title NARATokenOFT - Omnichain Version of NARA
/// @notice Implements LayerZero OFT standard for native cross-chain transfers
/// @dev Maintains all original NARA logic (Tiers, Fees, Fixed Supply)
contract NARATokenOFT is OFT, NaraTiers {
    function _balanceOf(address account) internal view override returns (uint256) {
        return balanceOf(account);
    }
    // ========================================================================
    // NARA Core Logic (Ported from NARAToken.sol)
    // ========================================================================
    
    uint256 public constant MAX_SUPPLY = 3_333_333 * 1e18;
    
    // Fee Logic
    uint256 public transferFeeBps = 10; // 0.1%
    address public feeRecipient;
    address public treasury; // Added treasury address
    
    // Events
    event TransferFeeUpdated(uint256 newBps);
    event FeeRecipientUpdated(address indexed newRecipient);
    event TreasuryUpdated(address indexed newTreasury); // Added TreasuryUpdated event
    
    error FeeTooHigh();
    error DurationTooLong();
    error TransferFromZeroAddress();
    error TransferToZeroAddress();

    /// @notice The chain where tokens are initially minted (Base mainnet = 8453)
    uint256 public immutable mainChainId;

    /// @notice Constructor
    /// @param _lzEndpoint LayerZero Endpoint address for the chain
    /// @param _delegate Owner/Delegate address
    /// @param _mainChainId The chain ID where tokens should be minted (e.g., 8453 for Base)
    constructor(
        address _lzEndpoint,
        address _delegate,
        uint256 _mainChainId
    ) OFT("Not A Real Asset", "NARA", _lzEndpoint, _delegate) Ownable(_delegate) {
        mainChainId = _mainChainId;
        
        // Only mint on the designated main chain
        if (block.chainid == _mainChainId) {
            _mint(_delegate, MAX_SUPPLY);
            // Tier initialization removed to prevent "insider tier" narrative.
            // Deployer starts with 0 tiers. Tiers are updated only upon transfer.
        }
    }

    // ========================================================================
    // OFT Overrides (The Magic)
    // ========================================================================

    /// @dev Override _debit to handle fees BEFORE burning
    function _debit(
        address _from,
        uint256 _amountLD,
        uint256 _minAmountLD,
        uint32 _dstEid
    ) internal virtual override returns (uint256 amountSentLD, uint256 amountReceivedLD) {
        // 1. Calculate Fee
        uint256 fee = 0;
        if (transferFeeBps > 0) {
             // Only charge fee if at least one recipient is set
             if (feeRecipient != address(0) || treasury != address(0)) {
                fee = (_amountLD * transferFeeBps) / 10000;
             }
        }
        
        uint256 amountAfterFee = _amountLD - fee;

        // 2. Pay Fee (Transfer to recipient)
        if (fee > 0) {
            uint256 treasuryFee = 0;
            if (treasury != address(0)) {
                treasuryFee = fee / 2;
            }
            uint256 jackpotFee = fee - treasuryFee;

            if (treasuryFee > 0) {
                super._transfer(_from, treasury, treasuryFee);
                _updateTiers(treasury, balanceOf(treasury));
            }

            if (jackpotFee > 0 && feeRecipient != address(0)) {
                super._transfer(_from, feeRecipient, jackpotFee);
                _updateTiers(feeRecipient, balanceOf(feeRecipient));
                
                // Notify recipient
                if (feeRecipient.code.length > 0) {
                    try INaraJackpotReceiver(feeRecipient).onNaraFeeReceived(_from, jackpotFee) {} catch {}
                }
            }
        }

        // 3. Burn the rest (Bridge it)
        // Adjust minAmountLD proportionally to fees to avoid unexpected slippage reverts
        uint256 minAmountAfterFee = (_minAmountLD * amountAfterFee) / _amountLD;
        (amountSentLD, amountReceivedLD) = super._debit(_from, amountAfterFee, minAmountAfterFee, _dstEid);
        
        // Update tiers for sender (balance decreased)
        _updateTiers(_from, balanceOf(_from));
        
        return (amountSentLD, amountReceivedLD);
    }

    /// @dev Override _credit to update tiers AFTER minting
    function _credit(
        address _to,
        uint256 _amountLD,
        uint32 _srcEid
    ) internal virtual override returns (uint256 amountReceivedLD) {
        amountReceivedLD = super._credit(_to, _amountLD, _srcEid);
        
        // Update tiers for receiver (balance increased)
        _updateTiers(_to, balanceOf(_to));
        
        return amountReceivedLD;
    }

    // ========================================================================
    // Standard ERC20 Overrides for Tiers & Fees
    // ========================================================================

    /// @dev Override transfer to include Fee and Tier logic
    function transfer(address to, uint256 value) public virtual override returns (bool) {
        address owner = _msgSender();
        _transferWithFee(owner, to, value);
        return true;
    }

    /// @dev Override transferFrom to include Fee and Tier logic
    function transferFrom(address from, address to, uint256 value) public virtual override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        _transferWithFee(from, to, value);
        return true;
    }

    /// @dev Custom transfer logic with fees
    function _transferWithFee(address from, address to, uint256 amount) internal {
        if (from == address(0)) revert TransferFromZeroAddress();
        if (to == address(0)) revert TransferToZeroAddress();

        uint256 fee = 0;
        if (transferFeeBps > 0) {
             // Only charge fee if at least one recipient is set
             if (feeRecipient != address(0) || treasury != address(0)) {
                fee = (amount * transferFeeBps) / 10000;
             }
        }
        uint256 sendAmount = amount - fee;

        // Perform transfers using super._transfer (which is raw ERC20 transfer)
        super._transfer(from, to, sendAmount);
        
        if (fee > 0) {
            uint256 treasuryFee = 0;
            if (treasury != address(0)) {
                treasuryFee = fee / 2;
            }
            uint256 jackpotFee = fee - treasuryFee;

            if (treasuryFee > 0) {
                super._transfer(from, treasury, treasuryFee);
                _updateTiers(treasury, balanceOf(treasury));
            }

            if (jackpotFee > 0 && feeRecipient != address(0)) {
                super._transfer(from, feeRecipient, jackpotFee);
                _updateTiers(feeRecipient, balanceOf(feeRecipient));

                if (feeRecipient.code.length > 0) {
                    try INaraJackpotReceiver(feeRecipient).onNaraFeeReceived(from, jackpotFee) {} catch {}
                }
            }
        }

        // Update tiers
        _updateTiers(from, balanceOf(from));
        _updateTiers(to, balanceOf(to));
    }

    bool public tokenParamsLocked;
    error TokenParamsLocked();
    event TokenParamsLockedEvent();

    modifier onlyOwnerWhenTokenUnlocked() {
        if (owner() != _msgSender()) revert OwnableUnauthorizedAccount(_msgSender());
        if (tokenParamsLocked) revert TokenParamsLocked();
        _;
    }

    // ========================================================================
    // Admin Functions
    // ========================================================================

    function lockTokenParams() external onlyOwnerWhenTokenUnlocked {
        tokenParamsLocked = true;
        emit TokenParamsLockedEvent();
    }

    function setTransferFeeBps(uint256 bps) external onlyOwnerWhenTokenUnlocked {
        if (bps > 100) revert FeeTooHigh(); // max 1%
        transferFeeBps = bps;
        emit TransferFeeUpdated(bps);
    }

    function setFeeRecipient(address recipient) external onlyOwnerWhenTokenUnlocked {
        feeRecipient = recipient;
        emit FeeRecipientUpdated(recipient);
    }

    function setMiningHoldDuration(uint256 seconds_) external onlyOwnerWhenTokenUnlocked {
        if (seconds_ > 30 days) revert DurationTooLong();
        miningHoldDurationSeconds = seconds_;
        emit MiningHoldDurationUpdated(seconds_);
    }

    function setTreasury(address newTreasury) external onlyOwnerWhenTokenUnlocked {
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }
}
