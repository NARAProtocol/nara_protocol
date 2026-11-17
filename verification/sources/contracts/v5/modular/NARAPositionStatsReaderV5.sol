// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {NARAPositionDisplayV5} from "./NARAPositionDisplayV5.sol";
import {NARAPrincipalLedgerV5} from "./NARAPrincipalLedgerV5.sol";
import {NARALifecycleLedgerV5} from "./NARALifecycleLedgerV5.sol";

import {PositionViewV5, PositionStatusV5, INARAPositionViewIdentityV5, INARAPositionStatsProviderV5} from "./NARAPositionViewTypesV5.sol";

/// @notice Fixed statistics decoder, validator and formatter for one Renderer/NFT pair.
/// @dev Created by the exact fixed Renderer. Holds no financial state or roles;
/// neither identity can be changed. Typed checks do not authenticate consistent
/// provider lies. All provider/decode/validation/format failures remain inside the
/// Renderer-caught call and cannot select the original image or change finance.
contract NARAPositionStatsReaderV5 {
    using Strings for uint256;
    uint256 public constant MAX_ATTRIBUTES_BYTES = 4_096;
    uint256 public constant MAX_FACTS_BYTES = 3_072;
    uint256 public constant SCHEMA_VERSION = 2;
    uint256 public constant SNAPSHOT_BYTES = 107 * 32;
    address public immutable renderer;
    address public immutable positionNFT;
    error Unauthorized();
    error StatisticsUnavailable();

    constructor(address positionNFT_) {
        // The creating NFT and Renderer are still under construction: bind the
        // identities directly without calling them or requiring deployed code.
        renderer = msg.sender;
        positionNFT = positionNFT_;
    }
    /// @dev Fixed-renderer-only external exception boundary. The outer try catches ABI
    /// decoder errors too, including invalid enum/bool/narrow-integer encodings.
    /// Zero output memory and exact width checks precede every returndata copy.
    function readValidatedSnapshot(uint256 tokenId, address provider)
        external view returns (PositionViewV5 memory v)
    {
        if (msg.sender != renderer) revert Unauthorized();
        return _readSnapshot(tokenId, provider);
    }

    function _readSnapshot(uint256 tokenId, address provider) private view returns (PositionViewV5 memory v) {
        bytes memory input = abi.encodeCall(INARAPositionStatsProviderV5.snapshot, (positionNFT, tokenId));
        bool ok; uint256 size;
        assembly ("memory-safe") {
            ok := staticcall(gas(), provider, add(input, 32), mload(input), 0, 0)
            size := returndatasize()
        }
        if (!ok || size != SNAPSHOT_BYTES) revert StatisticsUnavailable();
        bytes memory result = new bytes(SNAPSHOT_BYTES);
        assembly ("memory-safe") { returndatacopy(add(result, 32), 0, size) }
        v = abi.decode(result, (PositionViewV5));
        _validate(v, tokenId, result);
    }

    function _validate(PositionViewV5 memory v, uint256 tokenId, bytes memory raw) private view {
        INARAPositionViewIdentityV5 identity = INARAPositionViewIdentityV5(positionNFT);
        (uint256 positionId, uint64 generation, uint8 kind) = identity.receiptInfo(tokenId);
        address owner = identity.ownerOf(tokenId);
        NARAPrincipalLedgerV5 core = NARAPrincipalLedgerV5(identity.core());
        uint256 expectedShare = v.totalRewardWeight == 0 || v.totalModelWeight == 0
            || v.eligibleRewardWeight > v.totalRewardWeight || v.eligibleModelWeight > v.totalModelWeight ? 0
            : _trancheShare(v.eligibleModelWeight, v.totalModelWeight, 8e17)
                + _trancheShare(v.eligibleRewardWeight, v.totalRewardWeight, 2e17);
        if (v.schemaVersion != 2 || v.tokenId != tokenId || v.positionId != positionId || v.generation != generation
            || v.receiptKind != kind || kind > 1 || v.nftOwner != owner || v.rarityTier > 5
            || v.rarityTier != (kind == 1 ? v.award.tier : core.rarityTier(positionId, generation))
            || !_matchCanonical(address(core), core.lifecycleLedger(), positionId, generation, raw)
            || v.financial.generation != generation || v.financial.generationOwner == address(0)
            || v.asOfBlock != block.number || v.asOfTimestamp != block.timestamp
            || v.eligibleRewardWeight > v.totalRewardWeight || v.eligibleModelWeight > v.totalModelWeight
            || (v.totalRewardWeight == 0) != (v.totalModelWeight == 0) || v.rewardShareWad != expectedShare
            || v.weightEpoch > v.wallEpoch || v.weightSnapshotCurrent != (v.weightEpoch == v.wallEpoch)
            || v.award.tier > 5 || (v.award.outcomeTier > 5 && v.award.outcomeTier != 255)
            || (v.lifecycle.pendingAttempt != bytes32(0) && v.transferable)
            || (v.lifecycle.consumed && v.transferable)) {
            revert StatisticsUnavailable();
        }
        bool detached = v.status == PositionStatusV5.Withdrawn || v.status == PositionStatusV5.Dormant || v.lifecycle.consumed;
        if (kind == 1) {
            if (v.status != PositionStatusV5.Dormant || !v.financial.withdrawn) revert StatisticsUnavailable();
        } else if (v.status == PositionStatusV5.Dormant || v.financial.generationOwner != owner
            || v.financial.withdrawn != (v.status == PositionStatusV5.Withdrawn)
            || (v.financial.withdrawn && v.transferable)) revert StatisticsUnavailable();
        if (v.status == PositionStatusV5.Pending || v.status == PositionStatusV5.Active) {
            if (v.unlockTimestamp < v.asOfTimestamp) revert StatisticsUnavailable();
        }
        if (detached) {
            if (v.attachedPrincipal != 0 || v.eligibleRewardWeight != 0 || v.eligibleModelWeight != 0 || v.rewardShareWad != 0
                || v.currentPulseEligible) revert StatisticsUnavailable();
        } else if (v.attachedPrincipal != v.financial.principal) revert StatisticsUnavailable();
        for (uint8 i; i < 3; ++i) {
            if (!v.rewardReadSuccess[i]) {
                if (v.attachedClaimable[i] != 0 || v.archivedClaimable[i] != 0) revert StatisticsUnavailable();
            } else if (detached) {
                if (v.attachedClaimable[i] != 0 || v.archivedClaimable[i] != v.rewards[i].claimable) revert StatisticsUnavailable();
            } else if (v.attachedClaimable[i] != v.rewards[i].claimable || v.archivedClaimable[i] != 0) {
                revert StatisticsUnavailable();
            }
            if (v.rewardReadSuccess[i] && (v.rewards[i].generation != generation
                || v.rewards[i].generationOwner != v.financial.generationOwner
                || v.positionRewardsEarned[i] != v.rewards[i].cumulativePaid + v.rewards[i].claimable)) {
                revert StatisticsUnavailable();
            }
        }
        if ((!v.rewardReadSuccess[0] && (v.historicalNaraRateAvailable || v.observedClosedPulses != 0
            || v.naraRewardRatioWad != 0 || v.historicalNaraRateWad != 0))
            || (!v.historicalNaraRateAvailable && v.historicalNaraRateWad != 0)) {
            revert StatisticsUnavailable();
        }
    }

    function _matchCanonical(address core, address ll, uint256 id, uint64 gen, bytes memory raw)
        private view returns (bool ok)
    {
        bytes4 sPos = NARAPrincipalLedgerV5.position.selector;
        bytes4 sAwd = NARALifecycleLedgerV5.award.selector;
        bytes4 sLc = NARALifecycleLedgerV5.lifecycle.selector;
        bytes4 sLin = NARALifecycleLedgerV5.lineage.selector;
        assembly ("memory-safe") {
            function eqCall(t, sel, i, g, inSz, rPtr, outSz) -> r {
                let p := mload(64)
                mstore(p, sel) mstore(add(p, 4), i) mstore(add(p, 36), g)
                if staticcall(gas(), t, p, inSz, p, outSz) {
                    if eq(returndatasize(), outSz) { r := eq(keccak256(p, outSz), keccak256(rPtr, outSz)) }
                }
            }
            ok := eqCall(core, sPos, id, gen, 68, add(raw, 480), 512)
            if ok { ok := eqCall(ll, sAwd, id, 0, 36, add(raw, 2656), 320) }
            if ok { ok := eqCall(ll, sLc, id, gen, 68, add(raw, 2976), 160) }
            if ok { ok := eqCall(ll, sLin, id, 0, 36, add(raw, 3136), 160) }
        }
    }

    /// @notice Only this fixed code emits attribute keys/labels/JSON fragments.
    /// Providers supply the static typed snapshot, never a string or fragment.
    /// Read, decoding and all statistics formatting share the caught gas budget.
    function readMetadata(uint256 tokenId, address provider) external view returns (string memory attrs, string memory facts) {
        if (msg.sender != renderer) revert Unauthorized();
        PositionViewV5 memory v = _readSnapshot(tokenId, provider);
        attrs = _attributes(v);
        facts = _financialMetadata(v);
        // Seventeen statistics attributes with fixed labels and bounded values
        // fit below 4096 bytes. Facts contain fixed keys and uint256 strings
        // of at most 78 digits (or null), below 3072 bytes. The resource gate
        // must preserve these bounds across future fixed-schema changes.
        if (bytes(attrs).length > MAX_ATTRIBUTES_BYTES || bytes(facts).length > MAX_FACTS_BYTES) revert StatisticsUnavailable();
    }
    function _attributes(PositionViewV5 memory v) private pure returns (string memory) {
        (string memory tier,) = NARAPositionDisplayV5.tierStyle(v.rarityTier);
        string memory attrs = string.concat(
            '{"trait_type":"Rarity","value":"', tier,
            '"},{"trait_type":"Status","value":"', NARAPositionDisplayV5._status(v.status),
            '"},{"trait_type":"NARA principal","value":"', NARAPositionDisplayV5.formatUnits(v.attachedPrincipal, 18),
            '"},{"trait_type":"Withdrawal","value":"', NARAPositionDisplayV5._withdrawal(v), '"}');
        for (uint8 i; i < 3; ++i) {
            attrs = string.concat(attrs, ',{"trait_type":"Claimable ', NARAPositionDisplayV5._asset(i), '","value":"', NARAPositionDisplayV5._reward(v, i), '"}');
        }
        attrs = string.concat(attrs,
            ',{"trait_type":"Model weight","value":"', NARAPositionDisplayV5.formatUnits(v.eligibleModelWeight, 18),
            '"},{"trait_type":"Total model weight","value":"', NARAPositionDisplayV5.formatUnits(v.totalModelWeight, 18),
            '"},{"trait_type":"Reward weight","value":"', NARAPositionDisplayV5.formatUnits(v.eligibleRewardWeight, 18),
            '"},{"trait_type":"Total reward weight","value":"', NARAPositionDisplayV5.formatUnits(v.totalRewardWeight, 18),
            '"},{"trait_type":"Reward pool share","value":"', NARAPositionDisplayV5._share(v), '"}');
        return string.concat(attrs,
            ',{"trait_type":"Weight snapshot","value":"', v.weightSnapshotCurrent ? "Current pulse" : "Earlier pulse - settlement pending",
            '"},{"trait_type":"Earning this pulse","value":"', v.currentPulseEligible ? "Yes" : "No",
            '"},{"trait_type":"Observed closed pulses","value":"', v.rewardReadSuccess[0] ? uint256(v.observedClosedPulses).toString() : "Unavailable",
            '"},{"trait_type":"Award cap NARA","value":"', NARAPositionDisplayV5.formatUnits(v.award.originalCap, 18),
            '"},{"trait_type":"Pending attempt","value":"', v.lifecycle.pendingAttempt == bytes32(0) ? "None" : "Yes", '"}');
    }

    /// @dev Keep financial formatting separate from identity/image composition
    /// so the fixed-schema serializer stays within the compiler stack budget.
    function _financialMetadata(PositionViewV5 memory v) private pure returns (string memory) {
        string memory current = string.concat(
            '","principal_wei":"', v.attachedPrincipal.toString(), '","unlock_timestamp":"', v.unlockTimestamp.toString(),
            '","as_of_block":"', v.asOfBlock.toString(), '","as_of_timestamp":"', v.asOfTimestamp.toString(), '",',
            '"weight_epoch":"', uint256(v.weightEpoch).toString(), '","eligible_model_weight":"', v.eligibleModelWeight.toString(),
            '","total_model_weight":"', v.totalModelWeight.toString(), '","eligible_reward_weight":"', v.eligibleRewardWeight.toString(),
            '","total_reward_weight":"', v.totalRewardWeight.toString(), '","reward_share_wad":"', v.rewardShareWad.toString(), '",');
        string memory rates = string.concat(
            '"historical_nara_rate_wad":', _optUint(v.historicalNaraRateAvailable, v.historicalNaraRateWad),
            ',"nara_reward_ratio_wad":', _optUint(v.rewardReadSuccess[0], v.naraRewardRatioWad),
            ',"observed_closed_pulses":', _optUint(v.rewardReadSuccess[0], v.observedClosedPulses),
            ',"history_scope":"generation_all_owners",');
        string memory earned = string.concat(
            '"position_earned_nara_wei":', _optUint(v.rewardReadSuccess[0], v.positionRewardsEarned[0]),
            ',"position_earned_eth_wei":', _optUint(v.rewardReadSuccess[1], v.positionRewardsEarned[1]),
            ',"position_earned_usdc_units":', _optUint(v.rewardReadSuccess[2], v.positionRewardsEarned[2]),
            ',"archived_claimable_nara_wei":', _optUint(v.rewardReadSuccess[0], v.archivedClaimable[0]),
            ',"archived_claimable_eth_wei":', _optUint(v.rewardReadSuccess[1], v.archivedClaimable[1]),
            ',"archived_claimable_usdc_units":', _optUint(v.rewardReadSuccess[2], v.archivedClaimable[2]), ',');
        return string.concat(current, rates, earned, _lifecycleMetadata(v));
    }

    function _lifecycleMetadata(PositionViewV5 memory v) private pure returns (string memory) {
        string memory award = string.concat(
            '"award_tier":"', uint256(v.award.tier).toString(), '","award_outcome_tier":"', uint256(v.award.outcomeTier).toString(),
            '","award_odds_version":"', uint256(v.award.oddsVersion).toString(), '","award_cap_wei":"', v.award.originalCap.toString(),
            '","award_multiplier_wad":"', v.award.multiplierWad.toString(), '","award_duration_wad":"', v.award.awardedDurationWad.toString(),
            '","award_epoch":"', uint256(v.award.awardEpoch).toString(), '","awarded_generation":"', uint256(v.award.awardedGeneration).toString(),
            '","award_request_id":"', v.award.requestId.toString(), '","award_attempt_id":"', uint256(v.award.attemptId).toHexString(32), '",');
        string memory state = string.concat(
            '"pending_attempt":"', uint256(v.lifecycle.pendingAttempt).toHexString(32), '","rarity_applied":', _bool(v.lifecycle.rarityApplied),
            ',"consumed":', _bool(v.lifecycle.consumed), ',"fusion_spent":', _bool(v.lifecycle.fusionSpent),
            ',"fused_into":"', v.lifecycle.fusedInto.toString(), '","lineage":["', v.lineage[0].toString(), '","', v.lineage[1].toString(),
            '","', v.lineage[2].toString(), '","', v.lineage[3].toString(), '","', v.lineage[4].toString(), '"],');
        return string.concat(award, state);
    }

    function _trancheShare(uint256 w, uint256 tot, uint256 scale) private pure returns (uint256) {
        return w == tot ? scale : (w * scale) / tot;
    }

    function _bool(bool ok) private pure returns (string memory) {
        return ok ? "true" : "false";
    }

    function _optUint(bool ok, uint256 value) private pure returns (string memory) {
        return ok ? string.concat('"', value.toString(), '"') : "null";
    }
}
