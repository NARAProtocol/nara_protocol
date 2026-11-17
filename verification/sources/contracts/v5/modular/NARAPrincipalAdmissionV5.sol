// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccountingPolicy, CreateRequest, CreatePreview, ActionBlocker, PositionState} from "../interfaces/NARAAccountingTypesV5.sol";
import {INARAEpochCoordinatorV5, FrameAwardV5, FusionInputTermsV5} from "./NARAModuleInterfacesV5.sol";
import {NARAPrincipalPreviewV5, PrincipalPreviewContextV5} from "./NARAPrincipalPreviewV5.sol";
import {NARARarityWeightV5} from "./NARARarityWeightV5.sol";

/// @dev The Principal supplies these fields from its canonical local state while
/// holding its financial lock. Lens captures them through a coherent public read.
struct PrincipalAdmissionSnapshotV5 {
    bool initialized;
    bool bindingsSealed;
    uint64 genesisTimestamp;
    uint64 openedEpoch;
    uint256 principalInventory;
}

/// @notice Fixed-context admission calculator shared by Principal and its Lens.
/// @dev Created only as the bound Principal's constructor child in the supported
/// graph. The parent validates the complete policy before copying it here.
/// No roles, setters, custody, lifecycle writes or caller-selected dependencies.
/// A direct quote accepts an UNTRUSTED synthetic snapshot: it neither certifies
/// canonical Principal state nor authorizes a deposit, generation or reward.
contract NARAPrincipalAdmissionV5 {
    uint256 public constant SCHEMA_VERSION = 1;
    uint256 private constant SUPPLY = 1_000_000 ether;
    uint256 private constant WAD = 1e18;
    uint256 private constant MAX_DURATION_WAD = 4e18;
    uint8 private constant MAX_TIER = 5;
    address public immutable principal;
    address public immutable nara;
    address public immutable engine;
    address public immutable reserve;
    address public immutable rewards;
    bytes32 public immutable policyHash;
    AccountingPolicy private _policy;

    error InvalidBinding();
    // Keep selectors identical to the prior Principal admission errors.
    error InvalidState();
    error InvalidEpoch();
    error InvalidTerms();

    constructor(AccountingPolicy memory policy_, address nara_, address engine_, address reserve_, address rewards_) {
        // The Principal is under construction and Rewards is precomputed, so
        // neither may be required to have code here. Their graph is sealed later.
        if (policy_.policyHash == bytes32(0) || nara_.code.length == 0 || engine_.code.length == 0
            || reserve_.code.length == 0 || rewards_ == address(0) || rewards_ == msg.sender
            || rewards_ == address(this) || nara_ == engine_ || nara_ == reserve_ || engine_ == reserve_
            || rewards_ == nara_ || rewards_ == engine_ || rewards_ == reserve_) revert InvalidBinding();
        principal = msg.sender; nara = nara_; engine = engine_; reserve = reserve_; rewards = rewards_;
        policyHash = policy_.policyHash; _policy = policy_;
    }

    /// @notice Observed eligibility and funding checks for the supplied snapshot.
    /// @dev Only Principal execution or a coherent PrincipalLens call supplies
    /// canonical state. Public callers may simulate states that never existed.
    /// All token/Engine reads target constructor-fixed identities. Allowance is
    /// checked against the fixed Principal, never this helper or msg.sender.
    function quoteCreate(address caller, PrincipalAdmissionSnapshotV5 calldata snapshot, CreateRequest calldata request)
        external view returns (CreatePreview memory p)
    {
        return _quoteCreate(caller, snapshot, request);
    }

    /// @notice Build candidate Common generation terms using the same admission calculation.
    /// @dev Id, generation and snapshot are UNTRUSTED quote inputs. Only the
    /// bound Principal supplies its canonical values and commits the returned
    /// terms after exact funding. Calling this view creates no award or position.
    /// The hash domain remains the Principal, never this calculation helper.
    function quoteGeneration(address caller, uint256 id, uint64 generation,
        PrincipalAdmissionSnapshotV5 calldata snapshot, CreateRequest calldata request)
        external view returns (CreatePreview memory p, PositionState memory s)
    {
        (p, s) = _quoteGeneration(caller, generation, snapshot, request);
        if (p.blocker != ActionBlocker.None) return (p, s);
        s.termsHash = keccak256(abi.encode(keccak256("NARA_V5_MODULAR_PRINCIPAL_TERMS_V1"),
            block.chainid, principal, policyHash, id, s));
    }

    /// @notice Candidate generation terms that carry a frame's award (LIFECYCLE_DESIGN.md §4.1, P2.1):
    /// the same admission and token checks as quoteGeneration (principal is received), the Common model
    /// weight, and the duration-capped reward weight of the accepted rule on the UNTRUSTED award supplied.
    /// @dev Only the bound Principal supplies the canonical award (P2.4's awarded recharge); a direct call
    /// authorizes nothing. The terms hash carries the award's attempt id under its own domain.
    function quoteAwardedGeneration(address caller, uint256 id, uint64 generation,
        PrincipalAdmissionSnapshotV5 calldata snapshot, CreateRequest calldata request, FrameAwardV5 calldata award)
        external view returns (CreatePreview memory p, PositionState memory s)
    {
        (p, s) = _quoteGeneration(caller, generation, snapshot, request);
        if (p.blocker != ActionBlocker.None) return (p, s);
        p.rewardWeight = NARARarityWeightV5.weight(request.amount, award.originalCap, award.multiplierWad,
            NARAPrincipalPreviewV5.durationMultiplier(_policy.durationCurve, request.duration), award.awardedDurationWad);
        s.rewardWeight = p.rewardWeight;
        s.termsHash = keccak256(abi.encode(keccak256("NARA_V5_MODULAR_AWARDED_TERMS_V1"),
            block.chainid, principal, policyHash, id, s, award.attemptId));
    }

    /// @notice The policy's duration multiplier D (WAD) for a duration inside [minDuration, maxDuration].
    function durationMultiplier(uint32 duration) public view returns (uint256) {
        if (duration < _policy.minDuration || duration > _policy.maxDuration) revert InvalidTerms();
        return NARAPrincipalPreviewV5.durationMultiplier(_policy.durationCurve, duration);
    }

    /// @notice Pure output-generation and frame-award constructor for five-input fusion (LIFECYCLE_DESIGN.md §4.1, P2.6).
    /// @dev Inputs are UNTRUSTED quote inputs unless supplied by the lifecycle child during fusion finalization.
    function quoteFusionOutput(address owner, uint256 outputId, uint64 cutover,
        FusionInputTermsV5[5] calldata inputs, uint8 outcomeTier, uint16 oddsVersion,
        uint256 requestId, bytes32 attemptId)
        external view returns (PositionState memory s, FrameAwardV5 memory a)
    {
        if (owner == address(0) || outputId == 0 || cutover == 0 || attemptId == bytes32(0)
            || outcomeTier > MAX_TIER) revert InvalidTerms();
        uint256 sumP; uint256 sumC; uint64 latest; uint256 dawOut = MAX_DURATION_WAD;
        for (uint256 i; i < 5; ++i) {
            FusionInputTermsV5 calldata x = inputs[i];
            if (x.principal == 0 || x.cap == 0 || x.awardedDurationWad < WAD
                || x.awardedDurationWad > MAX_DURATION_WAD) revert InvalidTerms();
            sumP += x.principal; sumC += x.cap;
            if (x.maturity > latest) latest = x.maturity;
            if (x.awardedDurationWad < dawOut) dawOut = x.awardedDurationWad;
        }
        if (sumP > SUPPLY) revert InvalidTerms();
        uint64 minMaturity = cutover + _policy.minDuration;
        uint64 maturityOut = latest > minMaturity ? latest : minMaturity;
        uint64 span = maturityOut - cutover;
        if (span > _policy.maxDuration) revert InvalidTerms();
        uint32 duration = uint32(span);
        uint256 dOut = durationMultiplier(duration);
        uint256 multiplier = NARARarityWeightV5.multiplierWad(outcomeTier);
        s.generationOwner = owner; s.generation = 1; s.createdEpoch = cutover - 1;
        s.activation = cutover; s.maturity = maturityOut; s.effectiveEnd = maturityOut;
        s.duration = duration; s.principal = sumP;
        s.modelWeight = sumP * dOut / WAD;
        s.rewardWeight = NARARarityWeightV5.weight(sumP, sumC, multiplier, dOut, dawOut);
        s.termsHash = keccak256(abi.encode(keccak256("NARA_V5_MODULAR_FUSION_TERMS_V1"),
            block.chainid, principal, policyHash, outputId, s, attemptId));
        a = FrameAwardV5(sumC, multiplier, dawOut, outcomeTier, outcomeTier, oddsVersion,
            cutover - 1, outcomeTier != 0 ? 1 : 0, requestId, attemptId);
    }

    function _quoteGeneration(address caller, uint64 generation, PrincipalAdmissionSnapshotV5 calldata snapshot,
        CreateRequest calldata request) private view returns (CreatePreview memory p, PositionState memory s)
    {
        p = _quoteCreate(caller, snapshot, request);
        if (p.blocker != ActionBlocker.None) return (p, s);
        (, uint64 wall) = _wall(snapshot.initialized, snapshot.genesisTimestamp);
        s.generationOwner = caller; s.generation = generation; s.createdEpoch = wall;
        s.activation = p.activation; s.maturity = p.maturity; s.effectiveEnd = p.maturity;
        s.duration = request.duration; s.principal = request.amount;
        s.modelWeight = p.modelWeight; s.rewardWeight = p.rewardWeight;
    }

    function _quoteCreate(address caller, PrincipalAdmissionSnapshotV5 calldata snapshot, CreateRequest calldata request)
        private view returns (CreatePreview memory p)
    {
        p.policyHash = policyHash;
        if (!snapshot.bindingsSealed) { p.blocker = ActionBlocker.NotSealed; return p; }
        (bool started, uint64 wall) = _wall(snapshot.initialized, snapshot.genesisTimestamp);
        if (!started) { p.blocker = ActionBlocker.NotStarted; return p; }
        (uint64 engineGenesis, uint64 cursor) = INARAEpochCoordinatorV5(engine).principalEpoch();
        if (engineGenesis != snapshot.genesisTimestamp || cursor != snapshot.openedEpoch) revert InvalidState();
        p = NARAPrincipalPreviewV5.create(_policy, PrincipalPreviewContextV5(caller, principal, engine,
            reserve, rewards, snapshot.bindingsSealed, started, wall, cursor, snapshot.principalInventory, block.timestamp), request);
        if (p.blocker != ActionBlocker.None) return p;
        IERC20 token = IERC20(nara);
        if (token.totalSupply() != SUPPLY) { p.blocker = ActionBlocker.FlashActive; return p; }
        if (token.balanceOf(caller) < request.amount) { p.blocker = ActionBlocker.InsufficientBalance; return p; }
        if (token.allowance(caller, principal) < request.amount) { p.blocker = ActionBlocker.InsufficientAllowance; return p; }
    }

    function _wall(bool initialized, uint64 genesis) private view returns (bool started, uint64 wall) {
        if (!initialized || block.timestamp < genesis) return (false, 0);
        uint256 value = (block.timestamp - genesis) / 900;
        if (value > type(uint64).max) revert InvalidEpoch();
        return (true, uint64(value));
    }
}
