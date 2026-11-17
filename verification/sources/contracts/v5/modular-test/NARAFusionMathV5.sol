// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NARARarityMathV5} from "./NARARarityMathV5.sol";

/// @notice Unauthenticated prospective five-Common fusion comparison.
/// @dev Both cap choices and reward archival are unselected proposal inputs.
/// This pure helper cannot authenticate ownership, closed intervals, deposited
/// principal, original caps or a rarity award. It neither consumes frames nor
/// implements custody, entropy, activation, recovery or a duration curve.
contract NARAFusionMathV5 {
    enum CapRule { FreshAwardOnMergedPrincipal, SumInputCapacities }
    enum RewardTreatment { ArchiveToInputOwner }

    struct Input {
        uint256 frameId;
        uint64 generation;
        address owner;
        uint256 principal;
        uint256 originalPrincipalCap;
        uint8 tier;
        uint256 durationWad;
        uint64 maturity;
        uint64 creditThrough;
        bool withdrawn;
        bool pending;
        bool consumed;
        uint256[3] unpaidScaled;
        uint256[3] paid;
    }

    struct Terms {
        address owner;
        uint256 newFrameId;
        uint64 cutoverEpoch;
        uint64 outputMaturity;
        uint8 outputTier;
        uint256 outputDurationWad;
        CapRule capRule;
        RewardTreatment rewardTreatment;
    }

    struct ArchivedInput {
        uint256 frameId;
        uint64 generation;
        address owner;
        uint256[3] unpaidScaled;
        uint256[3] paid;
    }

    struct Quote {
        uint256 principal;
        uint256 outputCap;
        uint64 outputMaturity;
        ArchivedInput[5] archived;
        /// @dev Diagnostic totals only. Fractions remain separate input rights;
        /// summing them does not authorize a merged claim or a new payout.
        uint256[3] archivedUnpaidScaled;
        uint256[3] paidHistory;
        uint256[3] outputOpeningCreditScaled;
        /// @dev Compose with NARARarityMathV5.quote for single-floor weight.
        /// These terms select neither an award nor adaptive emission demand.
        NARARarityMathV5.Terms rarityTerms;
    }

    uint256 public constant SCHEMA_VERSION = 1;
    uint256 private constant WAD = 1e18;
    uint256 private constant RAY = 1e27;
    uint256 private constant MAX_PRINCIPAL = 1_000_000e18;
    uint256 private constant MAX_PAID = type(uint256).max / RAY;

    error InvalidOwner();
    error InvalidFrame(uint256 frameId);
    error InvalidGeneration(uint256 frameId);
    error InvalidInputState(uint256 frameId);
    error InvalidInputTier(uint256 frameId);
    error InvalidPrincipal(uint256 principal);
    error InvalidOriginalPrincipalCap(uint256 cap);
    error InvalidDurationMultiplier(uint256 durationWad);
    error InvalidMaturity();
    error InvalidCreditThrough(uint256 frameId, uint64 expected, uint64 actual);
    error InvalidAssetHistory(uint8 asset);
    error InvalidOutputTier(uint8 tier);
    error InvalidRewardTreatment();

    /// @notice Check supplied comparison terms and preserve every old fraction.
    /// @dev Fixed cardinality bounds all work. Solidity rejects unknown enum
    /// values during ABI decoding. The supported duration/multiplier envelopes
    /// mirror the reference model, not a selected launch calibration. A stated
    /// creditThrough value is compared for consistency, never verified onchain.
    function quote(Input[5] calldata inputs, Terms calldata terms) external pure returns (Quote memory q) {
        if (terms.owner == address(0)) revert InvalidOwner();
        if (terms.newFrameId == 0) revert InvalidFrame(0);
        if (terms.cutoverEpoch == 0) revert InvalidMaturity();
        if (terms.outputTier == 0 || terms.outputTier > 4) revert InvalidOutputTier(terms.outputTier);
        if (terms.rewardTreatment != RewardTreatment.ArchiveToInputOwner) revert InvalidRewardTreatment();
        _validateDuration(terms.outputDurationWad);

        uint256 inputCapacity;
        uint64 latestMaturity;
        for (uint256 i; i < 5; ++i) {
            Input calldata p = inputs[i];
            if (p.frameId == 0 || p.frameId == terms.newFrameId) revert InvalidFrame(p.frameId);
            for (uint256 j; j < i; ++j) {
                if (inputs[j].frameId == p.frameId) revert InvalidFrame(p.frameId);
            }
            if (p.generation == 0) revert InvalidGeneration(p.frameId);
            if (p.owner != terms.owner) revert InvalidOwner();
            if (p.withdrawn || p.pending || p.consumed) revert InvalidInputState(p.frameId);
            if (p.tier != 0) revert InvalidInputTier(p.frameId);
            if (p.principal == 0 || p.principal > MAX_PRINCIPAL) revert InvalidPrincipal(p.principal);
            if (p.originalPrincipalCap == 0 || p.originalPrincipalCap > MAX_PRINCIPAL) {
                revert InvalidOriginalPrincipalCap(p.originalPrincipalCap);
            }
            _validateDuration(p.durationWad);
            if (p.maturity == 0) revert InvalidMaturity();
            uint64 through = p.maturity < terms.cutoverEpoch ? p.maturity : terms.cutoverEpoch;
            if (p.creditThrough != through) revert InvalidCreditThrough(p.frameId, through, p.creditThrough);

            // Five individually bounded principals/capacities sum to <= 5e24.
            q.principal += p.principal;
            inputCapacity += p.originalPrincipalCap;
            if (p.maturity > latestMaturity) latestMaturity = p.maturity;
            q.archived[i] = ArchivedInput(p.frameId, p.generation, p.owner, p.unpaidScaled, p.paid);
            for (uint8 asset; asset < 3; ++asset) {
                // Reject before addition/multiplication can overflow. Total
                // unpaid + paid * RAY must fit the reference admission envelope.
                if (p.unpaidScaled[asset] > type(uint256).max - q.archivedUnpaidScaled[asset]
                    || p.paid[asset] > MAX_PAID - q.paidHistory[asset]) revert InvalidAssetHistory(asset);
                q.archivedUnpaidScaled[asset] += p.unpaidScaled[asset];
                q.paidHistory[asset] += p.paid[asset];
                if (q.archivedUnpaidScaled[asset] > type(uint256).max - q.paidHistory[asset] * RAY) {
                    revert InvalidAssetHistory(asset);
                }
            }
        }
        if (q.principal > MAX_PRINCIPAL) revert InvalidPrincipal(q.principal);
        if (terms.outputMaturity < latestMaturity || terms.outputMaturity <= terms.cutoverEpoch) {
            revert InvalidMaturity();
        }
        uint64 remaining = terms.outputMaturity - terms.cutoverEpoch;
        if (remaining < 96 || remaining > 35_040) revert InvalidMaturity();

        q.outputCap = terms.capRule == CapRule.FreshAwardOnMergedPrincipal
            ? q.principal : (inputCapacity < q.principal ? inputCapacity : q.principal);
        q.outputMaturity = terms.outputMaturity;
        // Candidate tier multipliers only; a supplied tier proves no entropy.
        uint256[4] memory upgradedMultipliers = [uint256(3e18), 10e18, 25e18, 50e18];
        q.rarityTerms = NARARarityMathV5.Terms(
            q.principal, q.outputCap, upgradedMultipliers[terms.outputTier - 1], terms.outputDurationWad
        );
        // outputOpeningCreditScaled stays zero. Paid history is provenance;
        // unpaid fractions remain attributed to each input owner above.
    }

    function _validateDuration(uint256 durationWad) private pure {
        if (durationWad < WAD || durationWad > 4 * WAD) revert InvalidDurationMultiplier(durationWad);
    }
}
