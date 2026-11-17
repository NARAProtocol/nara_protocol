// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {NARAPrincipalLedgerV5} from "./NARAPrincipalLedgerV5.sol";
import {NARALifecycleLedgerV5} from "./NARALifecycleLedgerV5.sol";
import {NARARarityWeightV5} from "./NARARarityWeightV5.sol";
import {NARAPrincipalPreviewV5, CommonRechargeBlockerV5} from "./NARAPrincipalPreviewV5.sol";
import {INARAEpochCoordinatorV5, INARADurationMultiplierV5, GenerationLifecycleV5, FrameAwardV5} from "./NARAModuleInterfacesV5.sol";
import {PositionState, EpochClock} from "../interfaces/NARAAccountingTypesV5.sol";
import {AttemptKindV5, RollBlockerV5, RollQuoteV5, RechargeQuoteV5, INARAEntropyAdapterV5, INARAForgeAdapterViewV5, INARAEmissionReferenceV5} from "./NARAForgeTypesV5.sol";

/// @notice Stateless quote child. Quotes do not authorize a lifecycle transition.
contract NARAForgeQuoteV5 {
    uint256 public constant MIN_FEE = 1e18;
    uint256 public constant ROLL_BASE_FEE = 5e17;
    uint256 public constant MIN_ROLL_PRINCIPAL = 10e18;
    uint64 public constant INDEX_WINDOW = 2_880;
    uint16 public constant ODDS_VERSION = 1;
    uint64 public constant YEAR_EPOCHS = 35_040;
    uint32 public constant TICKETS = 100_000;
    uint256 private constant WAD = 1e18;
    uint256 private constant SUPPLY = 1e24;
    address public immutable forge;
    address public immutable principal;
    address public immutable lifecycleLedger;
    address public immutable admissionHelper;
    address public immutable engine;
    address public immutable nara;
    uint64 public immutable timeoutEpochs;
    error InvalidTerms();

    constructor(address principal_, address lifecycle_, address admission_, address engine_, address nara_, uint64 timeout_) {
        forge = msg.sender; principal = principal_; lifecycleLedger = lifecycle_; admissionHelper = admission_;
        engine = engine_; nara = nara_; timeoutEpochs = timeout_;
    }
    function rollTickets(uint8 tier) public pure returns (uint256) {
        if (tier == 0) return 51_000; if (tier == 1) return 25_000; if (tier == 2) return 15_000;
        if (tier == 3) return 8_000; if (tier == 4) return 1_000; revert InvalidTerms();
    }
    function stepTickets(uint8 step) public pure returns (uint256) {
        if (step == 0) return 98_889; if (step == 1) return 1_000; if (step == 2) return 100;
        if (step == 3) return 10; if (step == 4) return 1; revert InvalidTerms();
    }
    function recipeTickets(uint8 outcome) public pure returns (uint256) {
        if (outcome == 0) return 75_000; if (outcome == 1) return 25_000; revert InvalidTerms();
    }
    function outcomeOf(uint256 word, AttemptKindV5 kind, uint8 inputTier) external pure returns (uint8) {
        uint256 ticket = word % TICKETS;
        if (kind == AttemptKindV5.Roll) {
            uint256 cumulative;
            for (uint8 i; i < 5; ++i) { cumulative += rollTickets(i); if (ticket < cumulative) return i; }
        } else {
            if (inputTier > 4) revert InvalidTerms();
            if (inputTier == 4) return ticket < recipeTickets(0) ? 5 : 4;
            uint256 cumulative;
            for (uint8 i; i < 5; ++i) { cumulative += stepTickets(i); if (ticket < cumulative) return uint8(Math.min(inputTier + i, 4)); }
        }
        revert InvalidTerms();
    }
    function multiplierWad(uint8 tier) public pure returns (uint256) { return NARARarityWeightV5.multiplierWad(tier); }
    function weight(uint256 p, uint256 c, uint256 a, uint256 d, uint256 daw) public pure returns (uint256) {
        return NARARarityWeightV5.weight(p, c, a, d, daw);
    }
    function valueFee(uint256 numerator, uint256 total, uint256 emission) public pure returns (uint256) {
        if (total == 0 || total > 400 * SUPPLY || emission > SUPPLY) revert InvalidTerms();
        return Math.max(MIN_FEE, Math.mulDiv(emission * YEAR_EPOCHS, numerator, 10 * TICKETS * total, Math.Rounding.Ceil));
    }
    function rollFee(uint256 p, uint256 d, uint256 own, uint256 total, uint256 emission)
        public pure returns (uint256 value, uint256 fixedFee)
    {
        if (own != Math.mulDiv(p, d, WAD) || total < own || own == 0) revert InvalidTerms();
        uint256 numerator;
        for (uint8 t = 1; t <= 4; ++t) {
            uint256 next = weight(p, p, multiplierWad(t), d, d);
            numerator += rollTickets(t) * (Math.mulDiv(next, total, total - own + next) - own);
        }
        return (valueFee(numerator, total, emission), ROLL_BASE_FEE);
    }
    /// @dev Prices the retained award at Daw even when the output duration is shorter.
    function priceWeight(uint256 p, uint256 c, uint256 a, uint256 d, uint256 daw) public pure returns (uint256) {
        if (p > SUPPLY || c == 0 || d < WAD || d > 4 * WAD || daw < WAD || daw > 4 * WAD
            || a < WAD || a > 100 * WAD) revert InvalidTerms();
        return (d * p * WAD + Math.min(p, c) * (a - WAD) * daw) / WAD ** 2;
    }
    function fusionFee(uint256 p, uint256 c, uint256 inputCapacity, uint256 own, uint8 tier, uint256 d, uint256 daw,
        uint256 total, uint256 emission) external pure returns (uint256)
    {
        if (p == 0 || inputCapacity == 0 || inputCapacity > Math.min(p, c) || tier > 4 || total < own) revert InvalidTerms();
        uint256 outside = total - own;
        uint256 a = multiplierWad(tier);
        uint256 moved = priceWeight(p, c, a, d, daw);
        uint256 kept = priceWeight(p, inputCapacity, a, d, daw);
        uint256 moveNumerator = TICKETS * (Math.mulDiv(moved, total, outside + moved) - Math.mulDiv(kept, total, outside + kept));
        uint256 effective = Math.min(SUPPLY, Math.max(p, c));
        uint256 u = _upgradeNumerator(effective, c, outside, tier, d, daw, total);
        if (effective != p) u = Math.max(u, _upgradeNumerator(p, c, outside, tier, d, daw, total));
        return valueFee(moveNumerator + u, total, emission);
    }
    function _upgradeNumerator(uint256 pTerm, uint256 c, uint256 outside, uint8 tier, uint256 d, uint256 daw, uint256 total)
        private pure returns (uint256 numerator)
    {
        uint256 base = priceWeight(pTerm, c, multiplierWad(tier), d, daw);
        uint256 baseShare = Math.mulDiv(base, total, outside + base);
        for (uint8 step = 1; step <= 4; ++step) {
            uint8 outcome = tier == 4 ? 5 : uint8(Math.min(tier + step, 4));
            uint256 next = priceWeight(pTerm, c, multiplierWad(outcome), d, daw);
            numerator += (tier == 4 ? recipeTickets(0) : stepTickets(step)) *
                (Math.mulDiv(next, total, outside + next) - baseShare);
            if (tier == 4) break;
        }
    }
    function rentRaw(uint256 p, uint256 c, uint256 a, uint256 d, uint256 daw, uint256 epochs,
        uint256 total, uint256 emission) public pure returns (uint256)
    {
        if (total > 400 * SUPPLY || epochs > YEAR_EPOCHS || emission > SUPPLY) revert InvalidTerms();
        uint256 rare = weight(p, c, a, d, daw);
        uint256 common = Math.mulDiv(p, d, WAD);
        // With no outside weight both shares are one and the incremental reward is zero.
        if (total == 0) return 0;
        uint256 gain = Math.mulDiv(rare, total, total + rare) - Math.mulDiv(common, total, total + common);
        return Math.mulDiv(emission * epochs, gain, 20 * total, Math.Rounding.Ceil);
    }
    function rent(uint256 p, uint256 c, uint256 a, uint256 d, uint256 daw, uint256 epochs,
        uint256 total, uint256 emission) public pure returns (uint256)
    { return Math.max(MIN_FEE, rentRaw(p, c, a, d, daw, epochs, total, emission)); }

    function reads() public view returns (RollBlockerV5 blocker, uint64 wall, uint256 total, uint256 emission) {
        if (IERC20(nara).totalSupply() != SUPPLY) return (RollBlockerV5.FlashActive, 0, 0, 0);
        EpochClock memory c = INARAEpochCoordinatorV5(engine).clock(); wall = c.wallEpoch;
        if (!c.started || c.backlog != 0) return (RollBlockerV5.NotCurrent, wall, 0, 0);
        uint64 samples; (emission, samples) = INARAEmissionReferenceV5(engine).emissionReference();
        if (samples < INDEX_WINDOW) return (RollBlockerV5.RollsNotOpen, wall, 0, emission);
        total = NARAPrincipalLedgerV5(principal).principalAccounting().activeRewardWeight;
    }
    function eligibility(address caller, uint256 id, uint64 g, bytes32 expectedTermsHash, uint64 wall, bool roll)
        public view returns (RollBlockerV5 blocker, PositionState memory p)
    {
        NARAPrincipalLedgerV5 pl = NARAPrincipalLedgerV5(principal);
        p = pl.position(id, g);
        if (p.generationOwner != caller) return (RollBlockerV5.NotOwner, p);
        if (pl.positionHead(id).generation != g) return (RollBlockerV5.NotCurrentGeneration, p);
        if (p.withdrawn) return (RollBlockerV5.Withdrawn, p);
        if (p.activation > wall) return (RollBlockerV5.NotActivated, p);
        if (p.effectiveEnd != p.maturity) return (RollBlockerV5.Ended, p);
        if (p.termsHash != expectedTermsHash) return (RollBlockerV5.TermsChanged, p);
        if (uint256(p.maturity) <= uint256(wall) + timeoutEpochs + 3) return (RollBlockerV5.InsufficientRemaining, p);
        if (pl.rewardWeightState(id, g).cutover > wall) return (RollBlockerV5.TransitionPending, p);
        NARALifecycleLedgerV5 ll = NARALifecycleLedgerV5(lifecycleLedger);
        GenerationLifecycleV5 memory l = ll.lifecycle(id, g);
        if (l.consumed) return (RollBlockerV5.Consumed, p);
        if (l.pendingAttempt != bytes32(0)) return (RollBlockerV5.AttemptPending, p);
        if (roll) {
            if (p.principal < MIN_ROLL_PRINCIPAL) return (RollBlockerV5.BelowMinimumPrincipal, p);
            if (ll.award(id).attemptId != bytes32(0)) return (RollBlockerV5.AwardExists, p);
        } else if (l.fusionSpent) return (RollBlockerV5.FusionSpent, p);
    }
    function quoteRoll(uint256 id, uint64 g) external view returns (RollQuoteV5 memory q) {
        uint256 total; uint256 emission;
        (q.blocker, q.wallEpoch, total, emission) = reads(); q.oddsVersion = ODDS_VERSION;
        if (q.blocker != RollBlockerV5.None) return q;
        PositionState memory p = NARAPrincipalLedgerV5(principal).position(id, g);
        (q.blocker, p) = eligibility(p.generationOwner, id, g, p.termsHash, q.wallEpoch, true);
        if (q.blocker != RollBlockerV5.None) return q;
        (q.valueFee, q.fixedFee) = rollFee(p.principal, INARADurationMultiplierV5(admissionHelper).durationMultiplier(p.duration), p.rewardWeight, total, emission);
        q.deadlineEpoch = q.wallEpoch + timeoutEpochs + 1;
        q.oracleFee = INARAEntropyAdapterV5(INARAForgeAdapterViewV5(forge).adapter()).quote();
    }
    function quoteRecharge(uint256 id, uint32 duration, uint256 amount) external view returns (RechargeQuoteV5 memory q) {
        uint64 wall; uint256 total; uint256 emission;
        (q.blocker, wall, total, emission) = reads(); if (q.blocker != RollBlockerV5.None) return q;
        NARAPrincipalLedgerV5 pl = NARAPrincipalLedgerV5(principal);
        PositionState memory p = pl.positionHead(id);
        NARALifecycleLedgerV5 ll = NARALifecycleLedgerV5(lifecycleLedger);
        GenerationLifecycleV5 memory l = ll.lifecycle(id, p.generation);
        if (l.pendingAttempt != bytes32(0)) { q.blocker = RollBlockerV5.AttemptPending; return q; }
        if (l.consumed) { q.blocker = RollBlockerV5.Consumed; return q; }
        if (l.rarityApplied) p.rewardWeight = p.modelWeight;
        if (NARAPrincipalPreviewV5.rechargeGeneration(p, p.generation, wall) != CommonRechargeBlockerV5.None) {
            q.blocker = RollBlockerV5.RechargeBlocked; return q;
        }
        FrameAwardV5 memory a = ll.award(id); q.tier = a.tier; q.originalCap = a.originalCap;
        if (a.tier == 0) { q.blocker = RollBlockerV5.NoAward; return q; }
        uint256 d = INARADurationMultiplierV5(admissionHelper).durationMultiplier(duration);
        q.rewardWeight = weight(amount, a.originalCap, a.multiplierWad, d, a.awardedDurationWad);
        q.modelWeight = Math.mulDiv(amount, d, WAD);
        q.rent = rent(amount, a.originalCap, a.multiplierWad, d, a.awardedDurationWad, duration, total, emission);
    }
}
