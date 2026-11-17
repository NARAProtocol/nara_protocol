// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {NARARewardLedgerV5} from "./NARARewardLedgerV5.sol";
import {NARAPrincipalLedgerV5} from "./NARAPrincipalLedgerV5.sol";
import {RewardAsset} from "../interfaces/NARAAccountingTypesV5.sol";

/// @notice Receive-only royalty/donation inventory, permissionlessly forwarded
/// to the three approved reward assets. No principal or claimant authority.
/// @dev Receipt here is unallocated inventory. Only successful admission into
/// RewardLedger creates its dated pulse bucket; backlog/asset failure leaves
/// inventory here for a later attempt. No automatic token registration or swaps.
contract NARARewardIngressV5 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant SCHEMA_VERSION = 1;
    address public immutable rewards;
    address public immutable nara;
    address public immutable usdc;

    error InvalidBinding();
    error InvalidAmount();
    error InvalidForward();
    error UnexpectedAllowance();

    event NativeReceived(address indexed sender, uint256 amount);
    event RewardsForwarded(RewardAsset indexed asset, address indexed caller, uint256 amount);

    constructor(address rewards_) {
        if (rewards_.code.length == 0 || rewards_ == address(this)) revert InvalidBinding();
        NARARewardLedgerV5 r = NARARewardLedgerV5(rewards_);
        address principal = r.principal();
        if (r.SCHEMA_VERSION() != 2 || principal.code.length == 0) revert InvalidBinding();
        NARAPrincipalLedgerV5 p = NARAPrincipalLedgerV5(principal);
        address n = r.nara(); address u = r.usdc();
        if (p.rewards() != rewards_ || p.engine() != r.engine() || p.nara() != n
            || p.reserve() != r.reserve() || n.code.length == 0 || u.code.length == 0
            || n == u || n == address(this) || u == address(this)) revert InvalidBinding();
        rewards = rewards_; nara = n; usdc = u;
    }

    /// @dev No external call or state write: ordinary marketplace ETH receipt is
    /// independent of settlement availability. Forced ETH may have no such log.
    receive() external payable { emit NativeReceived(msg.sender, msg.value); }

    /// @notice Actual unallocated inventory, in each asset's native base units.
    function pending(RewardAsset asset) external view returns (uint256) {
        return asset == RewardAsset.ETH ? address(this).balance : _token(asset).balanceOf(address(this));
    }

    /// @notice Forward any positive available portion to the fixed reward ledger.
    /// A caller chooses amount and asset, never a recipient or financial owner.
    function forward(RewardAsset asset, uint256 amount) external nonReentrant returns (uint256 received) {
        if (amount == 0) revert InvalidAmount();
        if (asset == RewardAsset.ETH) {
            uint256 beforeBalance = address(this).balance;
            if (amount > beforeBalance) revert InvalidAmount();
            NARARewardLedgerV5(rewards).donateETH{value: amount}();
            if (address(this).balance != beforeBalance - amount) revert InvalidForward();
            received = amount;
        } else {
            IERC20 token = _token(asset);
            uint256 beforeBalance = token.balanceOf(address(this));
            if (amount > beforeBalance) revert InvalidAmount();
            if (token.allowance(address(this), rewards) != 0) revert UnexpectedAllowance();
            token.forceApprove(rewards, amount);
            received = NARARewardLedgerV5(rewards).donateToken(asset, amount);
            token.forceApprove(rewards, 0);
            if (received != amount || token.balanceOf(address(this)) != beforeBalance - amount) revert InvalidForward();
            if (token.allowance(address(this), rewards) != 0) revert UnexpectedAllowance();
        }
        emit RewardsForwarded(asset, msg.sender, received);
    }

    function _token(RewardAsset asset) private view returns (IERC20) {
        // Enum ABI validation rejects indices outside NARA/ETH/USDC. Both callers
        // take the separate native branch for ETH before reaching this helper.
        return IERC20(asset == RewardAsset.NARA ? nara : usdc);
    }
}
