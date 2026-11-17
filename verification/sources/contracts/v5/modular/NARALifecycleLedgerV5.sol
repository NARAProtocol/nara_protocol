// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PositionState} from "../interfaces/NARAAccountingTypesV5.sol";
import {FrameAwardV5, GenerationLifecycleV5, AttemptInputsV5, FinalizeStatusV5, FusionInputTermsV5,
    INARAPrincipalLifecycleV5, INARADurationMultiplierV5, NO_OUTCOME} from "./NARAModuleInterfacesV5.sol";
import {NARARarityWeightV5} from "./NARARarityWeightV5.sol";

/// @notice Constructor-created lifecycle child of the Principal (LIFECYCLE_DESIGN.md §3.2): the award
/// record per frame, the per-generation lifecycle flags and the attempt registry. It holds no funds, no
/// lock and no policy.
/// @dev P2.2/P2.4/P2.6: the Forge writes the registry and the freeze (`registerAttempt`, with the owner,
/// current and withdrawn re-checks, AR2-07) and the timeout outcome (`failAttempt`, the Q8 option (a) shapes);
/// the Principal drives `finalize`, which runs the roll and five-input fusion branches under the Principal's
/// lock through its write primitives and is total (every input-state mismatch ends Void or Cancelled, never a
/// revert); the Principal's awarded recharge marks its new generation applied (`markApplied`).
contract NARALifecycleLedgerV5 {
    uint256 public constant SCHEMA_VERSION = 1;
    uint256 private constant WAD = 1e18;
    uint256 private constant MAX_DURATION_WAD = 4e18;
    uint8 private constant MAX_TIER = 5;
    uint8 private constant MAX_ROLL_TIER = 4;
    address public immutable principal;   // msg.sender at construction
    address public immutable forge;       // constructor argument (the precomputed Forge peer)

    mapping(uint256 frameId => FrameAwardV5) private _awards;
    mapping(uint256 id => mapping(uint64 generation => GenerationLifecycleV5)) private _lifecycle;
    mapping(uint256 outputId => uint256[5]) private _lineage;              // A8/ND-5: the five input IDs
    mapping(bytes32 attemptId => AttemptInputsV5) private _attempts;      // written once by the Forge at commit

    error Unauthorized();
    error AwardExists();
    error NoAward();
    error InvalidInputs();
    error AttemptPending();

    /// @dev AR-06: every award-record write revises the generation's termsHash; the status is the branch taken.
    event AwardRecorded(uint256 indexed frameId, uint64 indexed generation, bytes32 indexed attemptId,
        uint8 outcomeTier, FinalizeStatusV5 status, bytes32 termsHash);
    event AttemptReleased(bytes32 indexed attemptId, bool failed);
    event FusionCancelled(bytes32 indexed attemptId, uint256 input, uint8 reason);
    event GenerationConsumed(uint256 indexed positionId, uint64 indexed generation, uint256 indexed outputId, uint64 cutover);
    event FusionOpened(uint256 indexed outputId, address indexed owner, bytes32 indexed attemptId, uint8 tier, uint256 originalCap);

    constructor(address forge_) { principal = msg.sender; forge = forge_; }

    function award(uint256 frameId) external view returns (FrameAwardV5 memory) { return _awards[frameId]; }
    function awardTier(uint256 frameId) external view returns (uint8) { return _awards[frameId].tier; }
    function lifecycle(uint256 id, uint64 generation) external view returns (GenerationLifecycleV5 memory) {
        return _lifecycle[id][generation];
    }
    function pendingAttempt(uint256 id, uint64 generation) external view returns (bytes32) {
        return _lifecycle[id][generation].pendingAttempt;
    }
    function lineage(uint256 outputId) external view returns (uint256[5] memory) { return _lineage[outputId]; }
    function attemptInputs(bytes32 attemptId) external view returns (AttemptInputsV5 memory) { return _attempts[attemptId]; }

    /// @notice The applied tier of a generation, dated at the Principal's settled boundary (AR2-12):
    /// the frame's record tier when this generation carries the award, its weight is live at the opened
    /// epoch and no scheduled weight cutover is still ahead of that epoch; 0 otherwise.
    function rarityTier(uint256 id, uint64 generation) public view returns (uint8) {
        if (!_lifecycle[id][generation].rarityApplied) return 0;
        INARAPrincipalLifecycleV5 ledger = INARAPrincipalLifecycleV5(principal);
        (PositionState memory p,, uint64 cutover) = ledger.lifecyclePosition(id, generation);
        uint64 opened = ledger.openedEpoch();
        if (p.activation > opened || cutover > opened) return 0;
        return _awards[id].tier;
    }

    // ---- Forge-written entry points (§4.1) --------------------------------------------------------------

    /// @notice Freezes the committed generation(s) and stores the attempt inputs (the Forge, at commit).
    /// @dev AR2-07: the registry can only freeze a generation the committing owner holds, that is current and
    /// unwithdrawn, so a Forge defect cannot freeze another holder's receipt. A roll needs a frame with no
    /// record (Q3; a Failed record also refuses a roll). A fusion needs five strictly ascending unconsumed
    /// inputs whose fusion right is unspent. No weight, principal or credit effect.
    function registerAttempt(bytes32 attemptId, address owner, uint8 count, uint256[5] calldata ids,
        uint64[5] calldata generations, uint64 commitEpoch) external
    {
        if (msg.sender != forge) revert Unauthorized();
        if (attemptId == bytes32(0) || owner == address(0) || (count != 1 && count != 5)
            || _attempts[attemptId].count != 0) revert InvalidInputs();
        if (count == 1 && _awards[ids[0]].attemptId != bytes32(0)) revert AwardExists();
        INARAPrincipalLifecycleV5 ledger = INARAPrincipalLifecycleV5(principal);
        for (uint256 i; i < count; ++i) {
            if (i != 0 && ids[i] <= ids[i - 1]) revert InvalidInputs();
            (PositionState memory p, uint64 current,) = ledger.lifecyclePosition(ids[i], generations[i]);
            GenerationLifecycleV5 storage l = _lifecycle[ids[i]][generations[i]];
            if (generations[i] != current || p.generationOwner != owner || p.withdrawn || l.consumed
                || (count == 5 && l.fusionSpent)) revert InvalidInputs();
            if (l.pendingAttempt != bytes32(0)) revert AttemptPending();
            l.pendingAttempt = attemptId;
        }
        _attempts[attemptId] = AttemptInputsV5(owner, count, commitEpoch, ids, generations);
    }

    /// @notice The timeout path (the Forge, after the deadline): lifts the freeze and writes the Q8 option (a)
    /// outcome. A roll spends the frame's only roll (a Failed record, no cap, no tier, NO_OUTCOME); a fusion
    /// spends each input generation's fusion right. No currency requirement (AR-12).
    function failAttempt(bytes32 attemptId) external {
        if (msg.sender != forge) revert Unauthorized();
        AttemptInputsV5 storage a = _attempts[attemptId];
        if (a.count == 0) revert InvalidInputs();
        _release(a, attemptId);
        if (a.count == 1) {
            if (_awards[a.ids[0]].attemptId == bytes32(0))
                _writeAward(a.ids[0], FrameAwardV5(0, WAD, WAD, 0, NO_OUTCOME, 0, a.commitEpoch, 0, 0, attemptId));
        } else {
            for (uint256 i; i < 5; ++i) _lifecycle[a.ids[i]][a.generations[i]].fusionSpent = true;
        }
        emit AttemptReleased(attemptId, true);
    }

    // ---- Principal-written entry points ------------------------------------------------------------------

    /// @notice The awarded recharge (P2.4, design §4.1, §5.6): the Principal, inside rechargeAwarded under its own
    /// lock, marks the generation it has just opened as carrying the frame's award. The frame's record is never
    /// rewritten: only awardedGeneration rises to this generation (X5). Refuses a frame without an applied-tier
    /// award (NoAward: no record, a Common, void or Failed record) and a generation at or below its awardedGeneration.
    function markApplied(uint256 id, uint64 generation) external {
        if (msg.sender != principal) revert Unauthorized();
        _markApplied(id, generation);
    }

    // ---- Finalization (the Principal, under its own lock) -----------------------------------------------

    /// @notice Finalizes a delivered attempt. Dispatches on the registered input count: 1 is a roll; 5 is a
    /// fusion (P2.6); anything else was never registered and froze nothing.
    function finalize(bytes32 attemptId, uint8 outcomeTier, uint16 oddsVersion, uint256 requestId, uint64 wall)
        external returns (FinalizeStatusV5 status, uint256 outputId)
    {
        if (msg.sender != principal) revert Unauthorized();
        AttemptInputsV5 storage a = _attempts[attemptId];
        if (a.count == 1) return (_finalizeRoll(a, attemptId, outcomeTier, oddsVersion, requestId, wall), 0);
        if (a.count == 5) return _finalizeFusion(a, attemptId, outcomeTier, oddsVersion, requestId, wall);
        revert InvalidInputs();
    }

    /// @dev The roll branch (§4.1). The freeze is lifted first. A result the Forge can never produce (a tier
    /// above 4) or a frame that already carries a record ends Void with no write. Otherwise the record is
    /// written once (Q3: the frame's roll), the award is applied to a live generation through the Principal's
    /// weight replacement (cutover wall + 1, checkpoint before the delta writes), and a Common or void result
    /// only revises the termsHash (AR-06) so every pre-commit Sale listing fails InvalidBacking.
    function _finalizeRoll(AttemptInputsV5 storage a, bytes32 attemptId, uint8 tier, uint16 oddsVersion,
        uint256 requestId, uint64 wall) private returns (FinalizeStatusV5 status)
    {
        _release(a, attemptId);
        uint256 id = a.ids[0]; uint64 g = a.generations[0];
        if (tier > MAX_ROLL_TIER || _awards[id].attemptId != bytes32(0)) return FinalizeStatusV5.Void;
        INARAPrincipalLifecycleV5 ledger = INARAPrincipalLifecycleV5(principal);
        (PositionState memory p, uint64 current,) = ledger.lifecyclePosition(id, g);
        uint256 d = INARADurationMultiplierV5(ledger.admissionHelper()).durationMultiplier(p.duration);
        // Live: still the frame's current generation, unwithdrawn, activated, and not in its last epoch (the
        // cutover wall + 1 must precede effectiveEnd); the same conditions the weight replacement enforces.
        bool live = g == current && !p.withdrawn && p.activation <= wall && wall + 1 < p.effectiveEnd;
        bool applied = live && tier != 0;
        uint8 appliedTier = applied ? tier : 0;
        uint256 multiplier = NARARarityWeightV5.multiplierWad(appliedTier);
        _writeAward(id, FrameAwardV5(p.principal, multiplier, d, appliedTier, tier, oddsVersion, wall,
            applied ? g : 0, requestId, attemptId));
        bytes32 termsHash;
        if (applied) {
            termsHash = ledger.applyWeightFor(id, g, NARARarityWeightV5.weight(p.principal, p.principal, multiplier, d, d));
            status = FinalizeStatusV5.Applied;
        } else {
            termsHash = ledger.reviseTermsFor(id, g, attemptId, tier);
            status = live ? FinalizeStatusV5.RecordedCommon : FinalizeStatusV5.Void;
        }
        emit AwardRecorded(id, g, attemptId, tier, status, termsHash);
    }

    /// @dev The five-input fusion branch (§4.1, §5.5, P2.6). Re-checks all five inputs against the settled
    /// Principal state, checkpoints rewards, ends the five input generations at cutover = wall + 1, marks them
    /// consumed, constructs the output generation and award record via the admission child, opens the
    /// reclassified output generation on the Principal without touching principalInventory, and retires the
    /// five active input NFTs without minting dormant receipts.
    function _finalizeFusion(AttemptInputsV5 storage a, bytes32 attemptId, uint8 outcomeTier,
        uint16 oddsVersion, uint256 requestId, uint64 wall)
        private returns (FinalizeStatusV5 status, uint256 outputId)
    {
        (uint256 cancelInput, uint8 reason, FusionInputTermsV5[5] memory terms) = _checkFusionInputs(a, outcomeTier);
        if (reason != 0) return _cancel(a, attemptId, cancelInput, reason);
        INARAPrincipalLifecycleV5 ledger = INARAPrincipalLifecycleV5(principal);
        for (uint256 i; i < 5; ++i) ledger.checkpointFor(a.ids[i], a.generations[i]);
        outputId = ledger.nextPositionId();
        uint64 k = wall + 1;
        for (uint256 i; i < 5; ++i) {
            uint256 id = a.ids[i]; uint64 g = a.generations[i];
            ledger.endGenerationAt(id, g, k);
            GenerationLifecycleV5 storage l = _lifecycle[id][g];
            l.consumed = true; l.fusedInto = outputId;
            emit GenerationConsumed(id, g, outputId, k);
        }
        _release(a, attemptId);
        address owner = a.owner;
        (PositionState memory s, FrameAwardV5 memory out) = INARADurationMultiplierV5(ledger.admissionHelper())
            .quoteFusionOutput(owner, outputId, k, terms, outcomeTier, oddsVersion, requestId, attemptId);
        _writeAward(outputId, out);
        _lineage[outputId] = a.ids;
        ledger.openReclassified(outputId, s);
        for (uint256 i; i < 5; ++i) ledger.retireActiveFor(a.ids[i], a.generations[i]);
        emit FusionOpened(outputId, owner, attemptId, outcomeTier, out.originalCap);
        return (FinalizeStatusV5.Applied, outputId);
    }

    function _checkFusionInputs(AttemptInputsV5 storage a, uint8 outcomeTier)
        private view returns (uint256 cancelInput, uint8 reason, FusionInputTermsV5[5] memory terms)
    {
        INARAPrincipalLifecycleV5 ledger = INARAPrincipalLifecycleV5(principal);
        INARADurationMultiplierV5 ad = INARADurationMultiplierV5(ledger.admissionHelper());
        address owner = a.owner;
        uint8 tier;
        for (uint256 i; i < 5; ++i) {
            uint256 id = a.ids[i]; uint64 g = a.generations[i];
            (PositionState memory p, uint64 current,) = ledger.lifecyclePosition(id, g);
            if (g != current || p.generationOwner != owner) return (id, 1, terms);
            if (p.withdrawn) return (id, 2, terms);
            uint8 t = rarityTier(id, g);
            if (i == 0) tier = t;
            else if (t != tier) return (id, 3, terms);
            FrameAwardV5 memory rec = _awards[id];
            bool awarded = rec.attemptId != bytes32(0) && rec.outcomeTier != NO_OUTCOME;
            if (awarded && rec.tier != t) return (id, 4, terms);
            terms[i] = FusionInputTermsV5(p.principal, awarded ? rec.originalCap : p.principal,
                awarded ? rec.awardedDurationWad : ad.durationMultiplier(p.duration), p.maturity);
        }
        if (tier > MAX_ROLL_TIER || outcomeTier < tier || outcomeTier > MAX_TIER
            || (outcomeTier == MAX_TIER && tier != MAX_ROLL_TIER)) return (0, 5, terms);
    }

    function _cancel(AttemptInputsV5 storage a, bytes32 attemptId, uint256 input, uint8 reason)
        private returns (FinalizeStatusV5, uint256)
    {
        _release(a, attemptId);
        emit FusionCancelled(attemptId, input, reason);
        return (FinalizeStatusV5.Cancelled, 0);
    }

    /// @dev Clears only the freeze flags that name this attempt; never reverts.
    function _release(AttemptInputsV5 storage a, bytes32 attemptId) private {
        for (uint256 i; i < a.count; ++i) {
            GenerationLifecycleV5 storage l = _lifecycle[a.ids[i]][a.generations[i]];
            if (l.pendingAttempt == attemptId) l.pendingAttempt = bytes32(0);
        }
    }

    /// @dev The ONE function that writes a frame's award record (M-1b, X5). A record is written once;
    /// its shape is checked here so no caller can store a tier/multiplier pair the weight library would
    /// not produce, an applied tier without its generation, or a Failed record with a cap or a tier.
    function _writeAward(uint256 frameId, FrameAwardV5 memory a) internal {
        if (_awards[frameId].attemptId != bytes32(0)) revert AwardExists();
        bool failed = a.outcomeTier == NO_OUTCOME;
        if (a.attemptId == bytes32(0) || a.tier > MAX_TIER || (!failed && a.outcomeTier > MAX_TIER)
            || a.multiplierWad != NARARarityWeightV5.multiplierWad(a.tier)
            || a.awardedDurationWad < WAD || a.awardedDurationWad > MAX_DURATION_WAD
            || (failed ? (a.tier != 0 || a.originalCap != 0) : a.originalCap == 0)
            || (a.tier != 0) != (a.awardedGeneration != 0)
            || (a.tier != 0 && a.tier != a.outcomeTier)) revert InvalidInputs();
        _awards[frameId] = a;
        if (a.awardedGeneration != 0) _lifecycle[frameId][a.awardedGeneration].rarityApplied = true;
    }

    /// @dev Marks a later generation of an awarded frame as carrying the award (the awarded recharge through
    /// markApplied, P2.4; the harness seam). awardedGeneration only increases (X5).
    function _markApplied(uint256 id, uint64 generation) internal {
        FrameAwardV5 storage a = _awards[id];
        if (a.attemptId == bytes32(0) || a.tier == 0) revert NoAward();
        if (generation <= a.awardedGeneration) revert InvalidInputs();
        _lifecycle[id][generation].rarityApplied = true;
        a.awardedGeneration = generation;
    }
}
