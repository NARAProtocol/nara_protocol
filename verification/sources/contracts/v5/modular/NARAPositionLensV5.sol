// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NARAPrincipalLedgerV5} from "./NARAPrincipalLedgerV5.sol";
import {NARALifecycleLedgerV5} from "./NARALifecycleLedgerV5.sol";
import {NARARewardLedgerV5} from "./NARARewardLedgerV5.sol";
import {NARARewardLensV5} from "./NARARewardLensV5.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PrincipalLedgerStateV5, RewardWeightStateV5} from "./NARAModuleInterfacesV5.sol";
import {RewardAsset, RewardCredit, PositionState} from "../interfaces/NARAAccountingTypesV5.sol";
import {PositionViewV5, PositionStatusV5, INARAPositionViewIdentityV5} from "./NARAPositionViewTypesV5.sol";

/// @notice Authoritative financial/identity composition, independent of artwork.
/// @dev Primary-state failures revert. Each optional reward read has an explicit
/// success flag; zero-filled failure data must never be presented as zero earned.
contract NARAPositionLensV5 {
    uint256 public constant SCHEMA_VERSION = 2;
    uint256 public constant REWARD_READ_GAS = 200_000;
    uint256 public constant PULSES_PER_YEAR = 35_040;
    // Presentation floor only; no change to eligibility, claims or settlement.
    uint256 public constant MIN_RATE_PULSES = 96;
    bytes32 public immutable EXPECTED_REWARD_LENS_CODEHASH = keccak256(type(NARARewardLensV5).runtimeCode);
    address public immutable rewardLens;
    error InvalidBinding();
    error InvalidState();

    constructor(address rewardLens_) {
        if (rewardLens_.code.length == 0 || rewardLens_.codehash != EXPECTED_REWARD_LENS_CODEHASH) revert InvalidBinding();
        rewardLens = rewardLens_;
    }

    function snapshot(address nftAddress, uint256 tokenId) external view returns (PositionViewV5 memory v) {
        INARAPositionViewIdentityV5 nft = INARAPositionViewIdentityV5(nftAddress);
        if (nftAddress.code.length == 0 || nft.financialSchemaVersion() != 2) revert InvalidBinding();
        NARAPrincipalLedgerV5 principal = NARAPrincipalLedgerV5(nft.core());
        address rewards = nft.rewards();
        if (principal.positionNFT() != nftAddress || principal.rewards() != rewards) revert InvalidBinding();
        v.schemaVersion = 2; v.tokenId = tokenId;
        (v.positionId, v.generation, v.receiptKind) = nft.receiptInfo(tokenId);
        if (v.receiptKind > 1) revert InvalidState();
        v.nftOwner = nft.ownerOf(tokenId);
        v.financial = principal.position(v.positionId, v.generation);
        PositionState memory head = principal.positionHead(v.positionId);
        NARALifecycleLedgerV5 ll = NARALifecycleLedgerV5(principal.lifecycleLedger());
        v.award = ll.award(v.positionId);
        v.lifecycle = ll.lifecycle(v.positionId, v.generation);
        v.lineage = ll.lineage(v.positionId);
        v.rarityTier = v.receiptKind == 1 ? v.award.tier : principal.rarityTier(v.positionId, v.generation);
        uint64 genesis = principal.genesisTimestamp();
        if (genesis == 0 || block.timestamp < genesis) revert InvalidState();
        uint256 wall = (block.timestamp - genesis) / 900;
        if (wall > type(uint64).max) revert InvalidState();
        v.wallEpoch = uint64(wall); v.asOfBlock = block.number; v.asOfTimestamp = block.timestamp;
        v.unlockTimestamp = uint256(genesis) + uint256(v.financial.maturity) * 900;
        if (v.receiptKind == 1) {
            if (!v.financial.withdrawn) revert InvalidState();
            v.status = PositionStatusV5.Dormant;
            v.transferable = head.generation == v.generation && head.withdrawn
                && v.lifecycle.pendingAttempt == bytes32(0) && !v.lifecycle.consumed;
        } else {
            if (v.nftOwner != v.financial.generationOwner) revert InvalidState();
            v.status = v.financial.withdrawn ? PositionStatusV5.Withdrawn
                : wall < v.financial.activation ? PositionStatusV5.Pending
                : wall >= v.financial.maturity ? PositionStatusV5.Matured : PositionStatusV5.Active;
            v.transferable = !v.financial.withdrawn && !v.lifecycle.consumed
                && v.lifecycle.pendingAttempt == bytes32(0) && head.generation == v.generation
                && v.financial.effectiveEnd == v.financial.maturity;
            if (!v.financial.withdrawn && !v.lifecycle.consumed) v.attachedPrincipal = v.financial.principal;
        }
        for (uint8 i; i < 3; ++i) {
            try NARARewardLensV5(rewardLens).credit{gas: REWARD_READ_GAS}(
                NARARewardLedgerV5(rewards), v.positionId, v.generation, RewardAsset(i)) returns (RewardCredit memory c) {
                if (c.generationOwner != v.financial.generationOwner || c.generation != v.generation) revert InvalidState();
                v.rewardReadSuccess[i] = true; v.rewards[i] = c;
                v.positionRewardsEarned[i] = c.cumulativePaid + c.claimable;
                if (v.receiptKind == 0 && !v.financial.withdrawn && !v.lifecycle.consumed) {
                    v.attachedClaimable[i] = c.claimable;
                } else {
                    v.archivedClaimable[i] = c.claimable;
                }
            } catch { /* Preserve the per-asset unavailable flag. */ }
        }
        PrincipalLedgerStateV5 memory accounting = principal.principalAccounting();
        if (!accounting.initialized || accounting.openedEpoch > v.wallEpoch) revert InvalidState();
        v.weightEpoch = accounting.openedEpoch;
        v.weightSnapshotCurrent = accounting.openedEpoch == v.wallEpoch;
        v.totalRewardWeight = accounting.activeRewardWeight;
        v.totalModelWeight = accounting.activeModelWeight;
        bool attached = v.receiptKind == 0 && !v.financial.withdrawn && !v.lifecycle.consumed && head.generation == v.generation;
        v.currentPulseEligible = attached && v.financial.activation <= v.wallEpoch
            && v.wallEpoch < v.financial.effectiveEnd;
        if (attached && v.financial.activation <= v.weightEpoch && v.weightEpoch < v.financial.effectiveEnd) {
            RewardWeightStateV5 memory weights = principal.rewardWeightState(v.positionId, v.generation);
            v.eligibleRewardWeight = weights.cutover == 0 || v.weightEpoch < weights.cutover
                ? weights.previousWeight : weights.nextWeight;
            v.eligibleModelWeight = v.financial.modelWeight;
        }
        if (v.eligibleRewardWeight > v.totalRewardWeight || v.eligibleModelWeight > v.totalModelWeight
            || (v.totalRewardWeight == 0) != (v.totalModelWeight == 0)) revert InvalidState();
        // Ideal current share, not a promise of future receipts or exact dust payout.
        // Schema v2 exposes both model weight (80% base tranche) and rarity weight (20% tranche).
        if (v.totalRewardWeight != 0) v.rewardShareWad = Math.mulDiv(v.eligibleModelWeight, 8e17, v.totalModelWeight)
            + Math.mulDiv(v.eligibleRewardWeight, 2e17, v.totalRewardWeight);
        if (v.rewardReadSuccess[0]) {
            uint64 through = v.rewards[0].accruedThrough;
            if (through > v.financial.effectiveEnd) revert InvalidState();
            if (through > v.financial.activation) v.observedClosedPulses = through - v.financial.activation;
            v.naraRewardRatioWad = Math.mulDiv(v.positionRewardsEarned[0], 1e18, v.financial.principal);
            if (v.observedClosedPulses >= MIN_RATE_PULSES) {
                v.historicalNaraRateAvailable = true;
                // Admission cap <= MAX / RAY, principal <= fixed supply and
                // duration <= 35,040 bound this ratio and its denominator.
                v.historicalNaraRateWad = Math.mulDiv(v.positionRewardsEarned[0], PULSES_PER_YEAR * 1e18,
                    v.financial.principal * v.observedClosedPulses);
            }
        }
    }
}
