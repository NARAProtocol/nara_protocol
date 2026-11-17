// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {INARARewardCreditIndicesV5, RewardTermsV5} from "./NARAModuleInterfacesV5.sol";
import {RewardAsset} from "../interfaces/NARAAccountingTypesV5.sol";

struct RewardCreditStateV5 {
    uint64 through;
    uint256 unpaidScaled;
    uint256 paid;
}

/// @notice Fixed, non-custodial per-generation reward credit storage.
/// @dev Only the creating Rewards ledger may read or mutate financial state.
/// A checkpoint preserves whole unpaid units as well as fractions. This does
/// not authorize changing a position's weight for an unsettled epoch.
contract NARARewardCreditLedgerV5 {
    uint256 private constant SCALE = 1e27;
    address public immutable rewards;
    mapping(uint256 id => mapping(uint64 generation => mapping(uint8 asset => RewardCreditStateV5))) private _credits;

    error Unauthorized();

    constructor() { rewards = msg.sender; }

    modifier onlyRewards() {
        if (msg.sender != rewards) revert Unauthorized();
        _;
    }

    function credit(uint256 id, uint64 generation, RewardAsset asset)
        external view onlyRewards returns (RewardCreditStateV5 memory)
    {
        return _credits[id][generation][uint8(asset)];
    }

    function checkpoint(uint256 id, uint64 generation, RewardAsset asset, RewardTermsV5 calldata terms, uint64 nextCheckpoint)
        external onlyRewards
    {
        _accrue(id, generation, asset, terms, nextCheckpoint);
    }

    function consumeClaim(uint256 id, uint64 generation, RewardAsset asset, RewardTermsV5 calldata terms, uint64 nextCheckpoint)
        external onlyRewards returns (uint256 paid)
    {
        RewardCreditStateV5 storage saved = _accrue(id, generation, asset, terms, nextCheckpoint);
        paid = saved.unpaidScaled / SCALE;
        saved.unpaidScaled %= SCALE;
        saved.paid += paid;
    }

    function _accrue(uint256 id, uint64 generation, RewardAsset asset, RewardTermsV5 calldata terms, uint64 nextCheckpoint)
        private returns (RewardCreditStateV5 storage saved)
    {
        saved = _credits[id][generation][uint8(asset)];
        uint64 start = saved.through > terms.activation ? saved.through : terms.activation;
        uint64 end = nextCheckpoint < terms.effectiveEnd ? nextCheckpoint : terms.effectiveEnd;
        if (end > start) {
            // A single carry owns both tranches: combine before the payout floor.
            saved.unpaidScaled += _interval(asset, start, end, terms.baseWeight, true);
            uint64 split = terms.cutover;
            if (split == 0 || end <= split) {
                saved.unpaidScaled += _interval(asset, start, end, terms.weight, false);
            } else {
                if (start < split) {
                    saved.unpaidScaled += _interval(asset, start, split, terms.weight, false);
                    start = split;
                }
                saved.unpaidScaled += _interval(asset, start, end, terms.nextWeight, false);
            }
            start = end;
        }
        saved.through = start;
    }

    function _interval(RewardAsset asset, uint64 start, uint64 end, uint256 weight, bool base) private view returns (uint256) {
        (uint256 baseFrom, uint256 baseTo, uint256 rarityFrom, uint256 rarityTo) =
            INARARewardCreditIndicesV5(rewards).creditIndices(asset, start, end);
        // Subtract first: large historical indices must not inflate the product.
        return weight * (base ? baseTo - baseFrom : rarityTo - rarityFrom);
    }
}
