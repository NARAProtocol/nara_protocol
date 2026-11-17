// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NARAPrincipalLedgerV5} from "./NARAPrincipalLedgerV5.sol";
import {NARARewardLedgerV5} from "./NARARewardLedgerV5.sol";
import {RewardCreditStateV5} from "./NARARewardCreditLedgerV5.sol";
import {RewardLedgerStateV5, RewardWeightStateV5} from "./NARAModuleInterfacesV5.sol";
import {NARARewardMathV5} from "./NARARewardMathV5.sol";
import {RewardAsset, RewardCredit, PositionState} from "../interfaces/NARAAccountingTypesV5.sol";

/// @notice Exact derived reward credit for display and guarded NFT acquisition.
/// @dev Principal exits and reward payouts remain independent of this read helper.
contract NARARewardLensV5 {
    function credit(NARARewardLedgerV5 rewards, uint256 id, uint64 generation, RewardAsset asset)
        external view returns (RewardCredit memory c)
    {
        RewardLedgerStateV5 memory state = rewards.rewardState();
        PositionState memory p = NARAPrincipalLedgerV5(rewards.principal()).position(id, generation);
        RewardWeightStateV5 memory w = NARAPrincipalLedgerV5(rewards.principal()).rewardWeightState(id, generation);
        RewardCreditStateV5 memory saved = rewards.claimCredit(id, generation, asset);
        uint64 genesis = rewards.genesisTimestamp();
        if (!state.initialized || block.timestamp < genesis) revert NARARewardLedgerV5.InvalidState();
        uint256 value = (block.timestamp - genesis) / 900;
        if (value > type(uint64).max) revert NARARewardLedgerV5.InvalidEpoch();
        uint64 wall = uint64(value);
        uint64 start = saved.through > p.activation ? saved.through : p.activation;
        uint64 end = state.nextCheckpoint < p.effectiveEnd ? state.nextCheckpoint : p.effectiveEnd;
        uint256 total = saved.unpaidScaled; c.accruedThrough = start;
        if (end > start) {
            total = _interval(rewards, asset, start, end, p.modelWeight, total, true);
            if (w.cutover == 0 || end <= w.cutover) {
                total = _interval(rewards, asset, start, end, w.previousWeight, total, false);
            } else {
                if (start < w.cutover) {
                    total = _interval(rewards, asset, start, w.cutover, w.previousWeight, total, false);
                    start = w.cutover;
                }
                total = _interval(rewards, asset, start, end, w.nextWeight, total, false);
            }
            c.accruedThrough = end;
        }
        c.generationOwner = p.generationOwner; c.generation = generation; c.closedCreditScaled = total;
        c.claimable = total / 1e27; c.fractionScaled = total % 1e27; c.cumulativePaid = saved.paid;
        c.pendingThrough = wall < p.effectiveEnd ? wall : p.effectiveEnd;
        uint64 from = p.activation > state.nextCheckpoint ? p.activation : state.nextCheckpoint;
        c.pendingFrom = from < c.pendingThrough ? from : c.pendingThrough;
        c.hasUnsettledEpochs = c.pendingFrom < c.pendingThrough;
        c.openEpochEligible = p.activation <= wall && wall < p.effectiveEnd;
    }

    function _interval(NARARewardLedgerV5 rewards, RewardAsset asset, uint64 start, uint64 end,
        uint256 weight, uint256 carried, bool base) private view returns (uint256)
    {
        (bool hasStart, uint256 baseStart, uint256 rarityStart) = rewards.indicesAt(asset, start);
        (bool hasEnd, uint256 baseEnd, uint256 rarityEnd) = rewards.indicesAt(asset, end);
        if (!hasStart || !hasEnd) revert NARARewardLedgerV5.InvalidState();
        return NARARewardMathV5.scaledCredit(weight, base ? baseStart : rarityStart, base ? baseEnd : rarityEnd, carried);
    }
}
