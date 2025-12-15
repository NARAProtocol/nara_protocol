// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Base.sol";
import "./NaraTiers.sol";

/// --------------------------------------------------------------------------
/// NARAToken v2 - Enhanced Tier System
/// --------------------------------------------------------------------------
contract NARAToken is Ownable, NaraTiers {
    string public constant name = "Not A Real Asset";
    string public constant symbol = "NARA";
    uint8  public constant decimals = 18;

    uint256 public immutable totalSupply;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) public allowance;

    function balanceOf(address account) public view virtual returns (uint256) {
        return _balances[account];
    }

    function _balanceOf(address account) internal view override returns (uint256) {
        return _balances[account];
    }

    uint256 public transferFeeBps = 10; // 0.1%
    address public feeRecipient;

    bool public tokenParamsLocked;
    error TokenParamsLocked();

    // ═══════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event TransferFeeUpdated(uint256 newBps);
    event FeeRecipientUpdated(address indexed newRecipient);
    event TokenParamsLockedEvent();

    modifier onlyOwnerWhenTokenUnlocked() {
        if (owner() != _msgSender()) revert OwnableUnauthorizedAccount(_msgSender());
        if (tokenParamsLocked) revert TokenParamsLocked();
        _;
    }

    constructor(address initialHolder) Ownable(msg.sender) {
        require(initialHolder != address(0), "NARA: zero initial holder");
        uint256 _max = 3_333_333 * 10**uint256(decimals);
        totalSupply = _max;
        _balances[initialHolder] = _max;

        // Tier initialization removed to prevent "insider tier" narrative.
        // Deployer starts with 0 tiers. Tiers are updated only upon transfer.

        emit Transfer(address(0), initialHolder, _max);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "NARA: allowance");
        if (a != type(uint256).max) {
            allowance[from][msg.sender] = a - amount;
            emit Approval(from, msg.sender, allowance[from][msg.sender]);
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "NARA: zero to");
        uint256 bal = _balances[from];
        require(bal >= amount, "NARA: balance");

        uint256 fee = 0;
        if (transferFeeBps > 0) {
             // Only charge fee if at least one recipient is set
             if (feeRecipient != address(0) || treasury != address(0)) {
                fee = (amount * transferFeeBps) / 10000;
             }
        }

        uint256 sendAmount = amount - fee;

        unchecked { _balances[from] = bal - amount; }
        _balances[to] += sendAmount;
        emit Transfer(from, to, sendAmount);

        // Fee Splitting Logic
        if (fee > 0) {
            uint256 treasuryFee = 0;
            if (treasury != address(0)) {
                treasuryFee = fee / 2;
            }
            uint256 jackpotFee = fee - treasuryFee;

            if (treasuryFee > 0) {
                _balances[treasury] += treasuryFee;
                emit Transfer(from, treasury, treasuryFee);
            }

            if (jackpotFee > 0 && feeRecipient != address(0)) {
                _balances[feeRecipient] += jackpotFee;
                emit Transfer(from, feeRecipient, jackpotFee);

                if (feeRecipient.code.length > 0) {
                    try INaraJackpotReceiver(feeRecipient).onNaraFeeReceived(from, jackpotFee) {} catch {}
                }
            }
        }

        // Update tiers for all affected addresses
        if (from != address(0)) _updateTiers(from, _balances[from]);
        if (to != address(0)) _updateTiers(to, _balances[to]);
        
        // Update tiers for fee recipients
        if (fee > 0) {
             if (treasury != address(0)) _updateTiers(treasury, _balances[treasury]);
             if (feeRecipient != address(0)) _updateTiers(feeRecipient, _balances[feeRecipient]);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    function lockTokenParams() external onlyOwnerWhenTokenUnlocked {
        tokenParamsLocked = true;
        emit TokenParamsLockedEvent();
    }

    function setTransferFeeBps(uint256 bps) external onlyOwnerWhenTokenUnlocked {
        require(bps <= 100, "fee too high");
        transferFeeBps = bps;
        emit TransferFeeUpdated(bps);
    }

    function setFeeRecipient(address recipient) external onlyOwnerWhenTokenUnlocked {
        feeRecipient = recipient;
        emit FeeRecipientUpdated(recipient);
    }

    address public treasury;
    event TreasuryUpdated(address indexed newTreasury);

    function setTreasury(address newTreasury) external onlyOwnerWhenTokenUnlocked {
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    function setMiningHoldDuration(uint256 seconds_) external onlyOwnerWhenTokenUnlocked {
        require(seconds_ <= 30 days, "Duration too long");
        miningHoldDurationSeconds = seconds_;
        emit MiningHoldDurationUpdated(seconds_);
    }
}
