// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {AccountingPolicy, CoreBindings, DurationCurve, PositionState,
    CreateRequest, CreatePreview, ActionBlocker} from "../interfaces/NARAAccountingTypesV5.sol";
import {INARAEpochCoordinatorV5, INARARewardLedgerIdentityV5, INARAPositionIdentityV5, INARARewardCheckpointV5,
    INARAForgeIdentityV5, FinalizeStatusV5, PrincipalLedgerStateV5, PrincipalLedgerChangesV5, RewardTermsV5,
    RewardWeightStateV5, FrameAwardV5, GenerationLifecycleV5} from "./NARAModuleInterfacesV5.sol";
import {NARAPrincipalAdmissionV5, PrincipalAdmissionSnapshotV5} from "./NARAPrincipalAdmissionV5.sol";
import {NARAPrincipalPreviewV5, CommonRechargeRequestV5, CommonRechargeBlockerV5} from "./NARAPrincipalPreviewV5.sol";
import {NARALifecycleLedgerV5} from "./NARALifecycleLedgerV5.sol";

/// @notice Separate principal custody and sole archived position authority.
/// @dev Candidate common-alloy/ordinary-maturity slice. No early exit, financial
/// rarity. Common recharge opens a fresh immutable generation after withdrawal
/// and settlement; fee/award policy and full NFT acceptance remain open.
/// Accounting provenance: the NARACorePrincipalV5 reference kernel; chronology is
/// now commanded by a separately deployed Engine, never inherited into this runtime.
contract NARAPrincipalLedgerV5 {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 private constant SUPPLY = 1_000_000 ether;
    uint256 private constant RAY = 1e27;
    uint256 public constant SCHEMA_VERSION = 3;
    address public immutable nara;
    address public immutable engine;
    address public immutable reserve;
    address public immutable rewards;
    address public immutable positionNFT;
    /// @notice Constructor-created admission code with immutable graph/policy context.
    address public immutable admissionHelper;
    /// @notice Constructor-created lifecycle child (LL): the award record per frame, the per-generation
    /// lifecycle flags and the attempt registry. Public-readable, no lock; it writes this ledger only through
    /// the two lifecycleCommand primitives below, under this ledger's own lock.
    address public immutable lifecycleLedger;
    /// @notice The Forge peer (precomputed, in bindingHash): the only caller of finalizeAttempt and, through the
    /// lifecycle child, the only writer of the attempt registry and the transfer freeze.
    address public immutable forge;
    bool public bindingsSealed;
    uint64 public genesisTimestamp;
    // Cancun/EIP-1153: even a defective peer omitting cleanup cannot persist the
    // lock into another transaction. Explicit release still enables composition.
    address transient public moduleLockHolder;
    bytes32 public immutable bindingHash;

    AccountingPolicy private _policy;
    PrincipalLedgerStateV5 private _state;
    mapping(uint64 epoch => PrincipalLedgerChangesV5) private _changes;
    mapping(uint256 id => mapping(uint64 generation => PositionState)) private _positions;
    mapping(uint256 id => uint64 generation) private _currentGeneration;
    struct RewardWeightTransition {
        uint64 cutover;
        uint256 previousWeight;
    }
    mapping(uint256 id => mapping(uint64 generation => RewardWeightTransition)) private _rewardTransitions;
    // Fixed deny-list peers (design §4.1, AR2-01): the Rewards-side pair is set once at initialize from the sealed
    // peers; the emission model is read once from the Engine's bindings at construction (§4.7). The quote child
    // joins in P2.3. No exit, claim or transfer path makes an external call for any of them.
    address private _usdc;
    address private _creditLedger;
    address private immutable _model;
    address private _quote;

    error Unauthorized();
    error InvalidState();
    error InvalidPolicy();
    error InvalidEpoch();
    error AccountingInProgress();
    error InvalidLockRelease();
    error UnknownGeneration();
    error InvalidRecipient();
    error InvalidPrincipalReceipt();
    error InvalidPrincipalPayment();
    error PrincipalCustodyDeficit();
    error FlashActive();
    error AttemptPending();
    error GenerationConsumed();
    error NoAward();
    error CreateBlocked(ActionBlocker blocker);
    error RechargeBlocked(CommonRechargeBlockerV5 blocker);

    event BindingsSealed(address indexed engine, address indexed rewards, address indexed nft);
    event Initialized(uint64 genesisTimestamp);
    event BoundaryOpened(uint64 indexed epoch, PrincipalLedgerStateV5 state);
    event PositionCreated(uint256 indexed positionId, uint64 indexed generation, address indexed owner, PositionState position);
    event PrincipalWithdrawn(uint256 indexed positionId, uint64 indexed generation, address indexed recipient, uint256 amount);
    event PositionOwnerTransferred(uint256 indexed positionId, uint64 indexed generation, address indexed from, address to);
    event RewardWeightScheduled(uint256 indexed positionId, uint64 indexed generation, uint64 indexed cutover,
        uint256 previousWeight, uint256 nextWeight, bytes32 termsHash);
    event AwardedGenerationOpened(uint256 indexed frameId, uint64 indexed generation, uint256 rewardWeight, uint256 modelWeight);
    event GenerationEnded(uint256 indexed positionId, uint64 indexed generation, uint64 indexed cutover);

    constructor(address authority, address nara_, address engine_, address rewards_, address nft_, address forge_) {
        if (authority == address(0) || nara_.code.length == 0 || engine_.code.length == 0
            || nara_ == engine_ || rewards_ == address(0) || nft_ == address(0)
            || rewards_ == nft_ || rewards_ == nara_ || rewards_ == engine_ || rewards_ == address(this)
            || nft_ == nara_ || nft_ == engine_ || nft_ == address(this)
            || forge_ == address(0) || forge_ == nara_ || forge_ == engine_ || forge_ == rewards_ || forge_ == nft_
            || forge_ == address(this)) revert InvalidState();
        INARAEpochCoordinatorV5 coordinator = INARAEpochCoordinatorV5(engine_);
        CoreBindings memory b = coordinator.bindings();
        if (b.schemaVersion != 1 || b.nara != nara_ || b.reserve.code.length == 0
            || b.reserve == nara_ || b.reserve == engine_ || b.bindingsSealed || b.activated
            || b.bootstrapAuthority != authority || b.reserve == rewards_ || b.reserve == nft_ || b.reserve == forge_
            || b.expectedGenesisFunding == 0 || b.expectedGenesisFunding > SUPPLY) revert InvalidState();
        AccountingPolicy memory p = coordinator.policy();
        // P2.9 mirror of the Engine's policy pins (E:115-119): V4Quadratic, minimumPrincipal at most the float
        // outside the Reserve, and exactly the one admission cap that never binds (DOS-002).
        if (p.policyHash == bytes32(0) || p.version != 1 || p.epochSeconds != 900
            || p.rewardIndexScale != RAY || p.activationDelay == 0 || p.activationDelay >= 35_040
            || p.minDuration != 96 || p.maxDuration != 35_040 || p.durationCurve != DurationCurve.V4Quadratic
            || p.earlyExitEnabled || p.earlyExitBps != 0
            || p.minimumPrincipal == 0 || p.minimumPrincipal > SUPPLY - b.expectedGenesisFunding
            || p.maxAdvance == 0 || p.maxAdvance > 96 || p.rewardAdmissionCap != type(uint256).max / RAY) revert InvalidPolicy();
        if (IERC20(nara_).totalSupply() != SUPPLY) revert FlashActive();
        nara = nara_; engine = engine_; reserve = b.reserve; forge = forge_; _model = b.emissionModel;
        rewards = rewards_; positionNFT = nft_; _policy = p;
        admissionHelper = address(new NARAPrincipalAdmissionV5(p, nara_, engine_, b.reserve, rewards_));
        lifecycleLedger = _createLifecycleLedger(forge_);
        // Peers may be deployed next at precomputed addresses. No deposit or
        // initialization can succeed until code/reciprocity and the sealed graph
        // are checked. There are no mutable bind/rebind/admin methods on this ledger.
        bindingHash = keccak256(abi.encode(keccak256("NARA_V5_PRINCIPAL_BINDING_V3"), block.chainid,
            engine_, address(this), nara_, b.reserve, rewards_, nft_, forge_, p.policyHash));
    }

    /// @dev The lifecycle-child factory (A2-04 test seam): the production child here, a test subclass in the
    /// harness. Measured at 0 bytes against a direct creation; no production path overrides it.
    function _createLifecycleLedger(address forge_) internal virtual returns (address) {
        return address(new NARALifecycleLedgerV5(forge_));
    }

    modifier financialAction() {
        _acquire(address(this));
        _;
        _release(address(this));
    }
    modifier coherentRead() {
        if (moduleLockHolder != address(0)) revert AccountingInProgress();
        _;
    }
    modifier engineCommand() {
        if (msg.sender != engine || moduleLockHolder != engine) revert Unauthorized();
        _;
    }
    /// @dev The lifecycle child's write primitives: callable by it only, while this ledger holds its own lock
    /// (that is, from inside finalizeAttempt). Never from the Forge, the Engine or an external caller.
    modifier lifecycleCommand() {
        if (msg.sender != lifecycleLedger || moduleLockHolder != address(this)) revert Unauthorized();
        _;
    }

    // Lock access is limited to fixed code-verified peers. Their complete actions
    // must acquire/release within one transaction; there is no public executor.
    function beginModuleAction() external {
        if (msg.sender != engine && (msg.sender != rewards || rewards.code.length == 0)) revert Unauthorized();
        _acquire(msg.sender);
    }
    function endModuleAction() external {
        if (msg.sender != engine && msg.sender != rewards) revert Unauthorized();
        _release(msg.sender);
    }
    function _acquire(address holder) private {
        if (moduleLockHolder != address(0)) revert AccountingInProgress();
        moduleLockHolder = holder;
    }
    function _release(address holder) private {
        if (moduleLockHolder != holder) revert InvalidLockRelease();
        moduleLockHolder = address(0);
    }

    function initialize(uint64 genesis) external engineCommand {
        INARAEpochCoordinatorV5 coordinator = INARAEpochCoordinatorV5(engine);
        (uint64 engineGenesis, uint64 cursor) = coordinator.principalEpoch();
        if (_state.initialized || genesis <= block.timestamp || genesis % 900 != 0
            || engineGenesis != genesis || coordinator.principalBindingHash() != bindingHash
            || rewards.code.length == 0 || positionNFT.code.length == 0) revert InvalidState();
        INARARewardLedgerIdentityV5 peer = INARARewardLedgerIdentityV5(rewards);
        if (peer.engine() != engine || peer.principal() != address(this) || peer.nara() != nara) revert InvalidState();
        _validateNFT(positionNFT);
        // Forge reciprocity (m-8; the Engine's bind-time check is the canonical one) and the deny-list pair,
        // read once here and never again on an exit, claim or transfer path (§4.7).
        if (forge.code.length == 0 || INARAForgeIdentityV5(forge).principal() != address(this)) revert InvalidState();
        _usdc = peer.usdc(); _creditLedger = peer.creditLedger();
        _quote = INARAForgeIdentityV5(forge).quote();
        genesisTimestamp = genesis;
        _state.initialized = true; bindingsSealed = true;
        if (cursor != 0) revert InvalidEpoch();
        emit BindingsSealed(engine, rewards, positionNFT);
        emit Initialized(genesis);
        emit BoundaryOpened(0, _state);
    }

    function openBoundary(uint64 epoch) external engineCommand {
        (uint64 engineGenesis, uint64 cursor) = INARAEpochCoordinatorV5(engine).principalEpoch();
        (bool started, uint64 wall) = _wall();
        if (!started || epoch > wall || engineGenesis != genesisTimestamp
            || epoch != _state.openedEpoch + 1 || epoch != cursor) revert InvalidEpoch();
        PrincipalLedgerChangesV5 memory delta = _changes[epoch]; delete _changes[epoch];
        _state.openedEpoch = epoch;
        _state.principalSnapshot = _apply(_state.principalSnapshot, delta.principalDelta);
        _state.pendingPrincipalDelta -= delta.principalDelta;
        _state.activeModelWeight = _apply(_state.activeModelWeight, delta.modelWeightDelta);
        _state.activeRewardWeight = _apply(_state.activeRewardWeight, delta.rewardWeightDelta);
        _assertBounds();
        emit BoundaryOpened(epoch, _state);
    }

    function policy() external view returns (AccountingPolicy memory) { return _policy; }
    function principalAccounting() external view coherentRead returns (PrincipalLedgerStateV5 memory) { return _state; }
    /// @dev Rewards reads the authoritative weight directly while Engine holds
    /// the graph lock; neither Engine nor an external caller supplies that weight.
    function settlementState() external view returns (PrincipalLedgerStateV5 memory) {
        if (moduleLockHolder != engine || (msg.sender != engine && msg.sender != rewards)) revert Unauthorized();
        return _state;
    }
    function principalChangesAt(uint64 epoch) external view coherentRead returns (PrincipalLedgerChangesV5 memory) {
        if (epoch < _state.openedEpoch) revert InvalidEpoch();
        return _changes[epoch];
    }
    function position(uint256 id, uint64 generation) external view coherentRead returns (PositionState memory) {
        return _position(id, generation);
    }
    function positionHead(uint256 id) external view coherentRead returns (PositionState memory) {
        return _position(id, _currentGeneration[id]);
    }
    /// @notice Retained reward intervals, including a scheduled future target.
    /// Unlike position(), this does not project at the currently opened epoch.
    function rewardWeightState(uint256 id, uint64 generation) external view coherentRead returns (RewardWeightStateV5 memory) {
        PositionState storage p = _positions[id][generation];
        if (p.generationOwner == address(0)) revert UnknownGeneration();
        RewardWeightTransition storage t = _rewardTransitions[id][generation];
        return RewardWeightStateV5(t.cutover, t.cutover == 0 ? p.rewardWeight : t.previousWeight, p.rewardWeight);
    }
    /// @notice The applied financial tier of a generation: the lifecycle child's record tier once the
    /// award is applied and live at the settled boundary (AR2-12), else 0. Renderers and token IDs
    /// cannot assign financial rarity; the only writer is a Forge-authenticated finalization.
    function rarityTier(uint256 id, uint64 generation) external view coherentRead returns (uint8) {
        _position(id, generation);
        return NARALifecycleLedgerV5(lifecycleLedger).rarityTier(id, generation);
    }
    /// @dev The lifecycle child's own read of a stored generation (AR2-08): callable by it only, no lock
    /// requirement, not boundary-projected. The child serves rarityTier and the attempt registry from it.
    function lifecyclePosition(uint256 id, uint64 generation) external view
        returns (PositionState memory p, uint64 currentGeneration, uint64 transitionCutover)
    {
        if (msg.sender != lifecycleLedger) revert Unauthorized();
        p = _positions[id][generation];
        if (p.generationOwner == address(0)) revert UnknownGeneration();
        return (p, _currentGeneration[id], _rewardTransitions[id][generation].cutover);
    }
    /// @notice The settled boundary (the last opened epoch); readable without the coherent guard so the
    /// lifecycle child can date its reads while this ledger holds its own lock.
    function openedEpoch() external view returns (uint64) { return _state.openedEpoch; }
    function nextPositionId() external view returns (uint256) { return _state.positionCount + 1; }
    /// @notice Fixed recipient deny-list (design §4.1, AR2-01): immutables and initialize-time peers only,
    /// no external call and no governance-writable storage. Shared by transferPosition, withdrawPrincipal,
    /// Rewards.claim, NFT._validateRecipient and Forge.withdrawRefund (P2.12).
    function isProtocolSink(address a) public view returns (bool) {
        return a == address(0) || a == address(this) || a == positionNFT || a == engine || a == rewards
            || a == reserve || a == nara || a == admissionHelper || a == lifecycleLedger || a == forge
            || a == _usdc || a == _creditLedger || a == _model || a == _quote;
    }
    /// @notice A live receipt carries principal and every unpaid reward right.
    /// NFT ownership changes first; this call commits financial ownership before
    /// any ERC721 receiver callback. No index, weight, credit or funding changes.
    /// A generation frozen by a pending Forge attempt (R12) cannot move until the attempt is terminal.
    function transferPosition(uint256 id, uint64 generation, address from, address to) external financialAction {
        if (msg.sender != positionNFT) revert Unauthorized();
        PositionState storage s = _positions[id][generation];
        if (s.generationOwner == address(0)) revert UnknownGeneration();
        if (!bindingsSealed || generation != _currentGeneration[id] || s.withdrawn
            || s.effectiveEnd != s.maturity) revert InvalidState();
        if (NARALifecycleLedgerV5(lifecycleLedger).pendingAttempt(id, generation) != bytes32(0)) revert AttemptPending();
        if (s.generationOwner != from) revert Unauthorized();
        if (isProtocolSink(to)) revert InvalidRecipient();
        if (INARAPositionIdentityV5(positionNFT).activeOwnerOf(id, generation) != to) revert InvalidState();
        s.generationOwner = to;
        emit PositionOwnerTransferred(id, generation, from, to);
    }
    /// @dev Rewards reads fixed financial terms and the current rights owner while it holds the graph
    /// lock, during Principal's credit checkpoint, or during a coherent read.
    /// It never supplies or overwrites those terms.
    function rewardTerms(uint256 id, uint64 generation) external view returns (RewardTermsV5 memory) {
        if (msg.sender != rewards || (moduleLockHolder != address(0) && moduleLockHolder != rewards
            && moduleLockHolder != address(this))) revert Unauthorized();
        PositionState storage p = _positions[id][generation];
        if (p.generationOwner == address(0)) revert UnknownGeneration();
        RewardWeightTransition storage t = _rewardTransitions[id][generation];
        return RewardTermsV5(p.generationOwner, p.activation, p.effectiveEnd,
            t.cutover == 0 ? p.rewardWeight : t.previousWeight, t.cutover, p.rewardWeight, p.modelWeight);
    }

    // ---- Forge-authenticated award (design §4.1; P2.2) ------------------------------------------------------

    /// @notice Finalizes a delivered attempt: the Forge's only write entry. This ledger takes its own lock and
    /// hands the orchestration to the lifecycle child, which calls back the two primitives below; the Forge is
    /// trusted for the drawn tier (§9 conflict 11) and the child enforces the tier envelope and totality.
    /// Currency (cursor, openedEpoch and wall equal) is the one state revert; anyone's advance clears it.
    function finalizeAttempt(bytes32 attemptId, uint8 outcomeTier, uint16 oddsVersion, uint256 requestId)
        external financialAction returns (FinalizeStatusV5 status, uint256 outputId)
    {
        if (msg.sender != forge) revert Unauthorized();
        uint64 wall = _currentWall();
        return NARALifecycleLedgerV5(lifecycleLedger).finalize(attemptId, outcomeTier, oddsVersion, requestId, wall);
    }
    /// @dev Applies an award's weight to a live generation: the child's primitive over _replaceRewardWeight,
    /// which reads the current owner and termsHash (never a request-time value) and checkpoints all three
    /// assets under the old terms before the delta writes. Returns the revised termsHash.
    function applyWeightFor(uint256 id, uint64 generation, uint256 newWeight) external lifecycleCommand returns (bytes32) {
        PositionState storage p = _positions[id][generation];
        _replaceRewardWeight(id, generation, p.generationOwner, p.termsHash, newWeight);
        return p.termsHash;
    }
    /// @dev AR-06, M-1b: every award-record write revises the generation's termsHash, including a Common or
    /// void result that changes no weight, so a Sale listing made before the commit fails InvalidBacking.
    function reviseTermsFor(uint256 id, uint64 generation, bytes32 attemptId, uint8 outcomeTier)
        external lifecycleCommand returns (bytes32)
    {
        PositionState storage p = _positions[id][generation];
        if (p.generationOwner == address(0)) revert UnknownGeneration();
        p.termsHash = keccak256(abi.encode(keccak256("NARA_V5_AWARD_RECORDED_REVISION_V1"), block.chainid,
            address(this), id, generation, p.termsHash, attemptId, outcomeTier));
        return p.termsHash;
    }
    /// @dev Fusion primitives (design §4.1, P2.6): callable only by the lifecycle child under this ledger's lock.
    function checkpointFor(uint256 id, uint64 generation) external lifecycleCommand {
        INARARewardCheckpointV5(rewards).checkpointPosition(id, generation);
    }
    function endGenerationAt(uint256 id, uint64 generation, uint64 k) external lifecycleCommand {
        PositionState storage p = _positions[id][generation];
        if (p.generationOwner == address(0)) revert UnknownGeneration();
        if (p.withdrawn || p.effectiveEnd != p.maturity || generation != _currentGeneration[id]
            || _rewardTransitions[id][generation].cutover > k - 1) revert InvalidState();
        if (p.maturity > k) {
            int256 mw = p.modelWeight.toInt256();
            int256 rw = p.rewardWeight.toInt256();
            _scheduleWeights(p.maturity, mw, rw);
            _scheduleWeights(k, -mw, -rw);
            p.effectiveEnd = k;
        }
        emit GenerationEnded(id, generation, k);
    }
    function openReclassified(uint256 outputId, PositionState calldata s) external lifecycleCommand {
        if (outputId != _state.positionCount + 1 || s.generation != 1) revert InvalidState();
        _state.positionCount = outputId;
        _openGeneration(outputId, s, true);
    }
    function retireActiveFor(uint256 id, uint64 generation) external lifecycleCommand {
        INARAPositionIdentityV5(positionNFT).retireActive(id, generation);
    }
    /// @dev Currency: sealed, started, Engine cursor == openedEpoch == wall, same genesis (LC-INV-SC).
    function _currentWall() private view returns (uint64 wall) {
        bool started; (started, wall) = _wall();
        (uint64 engineGenesis, uint64 cursor) = INARAEpochCoordinatorV5(engine).principalEpoch();
        if (!bindingsSealed || !started || wall != _state.openedEpoch || cursor != wall
            || engineGenesis != genesisTimestamp || wall == type(uint64).max) revert InvalidEpoch();
    }

    /// @dev Chronology primitive: reached only through applyWeightFor, from the lifecycle child's roll
    /// finalization, which derives the exact weight from canonical duration, original-principal cap and the
    /// applied tier. The 400P check is an arithmetic envelope, NOT per-position rarity policy.
    /// All earlier intervals are materialized before replacing the bounded pair;
    /// the current open epoch keeps its previous weight until the next boundary.
    function _replaceRewardWeight(uint256 id, uint64 generation, address expectedOwner,
        bytes32 expectedTermsHash, uint256 newWeight) internal
    {
        if (moduleLockHolder != address(this)) revert Unauthorized();
        PositionState storage p = _positions[id][generation];
        if (p.generationOwner == address(0)) revert UnknownGeneration();
        if (p.generationOwner != expectedOwner) revert Unauthorized();
        uint64 wall = _currentWall();
        uint64 cutover = wall + 1;
        RewardWeightTransition storage t = _rewardTransitions[id][generation];
        if (generation != _currentGeneration[id] || p.withdrawn || p.activation > wall
            || p.effectiveEnd != p.maturity || cutover >= p.effectiveEnd
            || p.termsHash != expectedTermsHash || t.cutover > wall
            || newWeight == 0 || newWeight > 400 * p.principal || newWeight == p.rewardWeight) revert InvalidState();
        // Under the Principal-held graph lock, Rewards authenticates this caller
        // and reads the OLD canonical pair; no caller-supplied financial terms.
        INARARewardCheckpointV5(rewards).checkpointPosition(id, generation);
        uint256 oldWeight = p.rewardWeight;
        int256 delta = newWeight.toInt256() - oldWeight.toInt256();
        _changes[cutover].rewardWeightDelta += delta;
        _changes[p.effectiveEnd].rewardWeightDelta -= delta;
        t.cutover = cutover; t.previousWeight = oldWeight; p.rewardWeight = newWeight;
        // This is a revision of the current economic commitment, not an immutable
        // opening-struct hash. It invalidates old Sale listings immediately.
        p.termsHash = keccak256(abi.encode(keccak256("NARA_V5_REWARD_TERMS_REVISION_V1"), block.chainid,
            address(this), id, generation, p.termsHash, cutover, oldWeight, newWeight));
        emit RewardWeightScheduled(id, generation, cutover, oldWeight, newWeight, p.termsHash);
    }

    function create(CreateRequest calldata request) external financialAction returns (uint256 id, uint64 generation) {
        id = _state.positionCount + 1; generation = 1;
        PositionState memory s = _prepareGeneration(msg.sender, id, generation, request);
        _receivePrincipal(msg.sender, request.amount);
        _state.positionCount = id;
        _openGeneration(id, s, false);
    }

    /// @notice Common recharge from an exact owned dormant receipt: free (A9), and permitted on a frame that holds an
    /// award (R1), where it opens a Common generation and leaves the award on the frame for a later awarded recharge.
    /// @dev Fresh received principal funds a new immutable generation. Old owner,
    /// terms, claim anchors and fractions are preserved without any reward payout.
    /// The award-preserving route is rechargeAwarded, reached only through the Forge, which charges the rent.
    function rechargeCommon(CommonRechargeRequestV5 calldata request)
        external financialAction returns (uint64 generation)
    {
        (generation,,) = _recharge(msg.sender, request, false);
    }

    /// @notice Award-preserving capped recharge (design §4.1, §5.6; A9, Q4): the Forge only. The Forge has quoted the
    /// rent and moves it to the Reserve after this returns. The new generation's reward weight carries the frame's
    /// award on exactly min(P, C), with the frame's immutable cap C, multiplier A and awarded duration Daw from the
    /// lifecycle child's record, and its own duration multiplier D.
    /// @dev `owner` is the Forge's authenticated caller. The NFT re-checks after funding that `owner` holds the exact
    /// dormant receipt (consumeDormant), so a supplied owner who does not hold it reverts there (M-10).
    function rechargeAwarded(address owner, CommonRechargeRequestV5 calldata request)
        external financialAction returns (uint64 generation, uint256 rewardWeight, uint256 modelWeight)
    {
        if (msg.sender != forge) revert Unauthorized();
        return _recharge(owner, request, true);
    }

    /// @dev The one recharge body (design §4.1). Order: the transfer freeze (A5, R12) and consumption on the old
    /// generation; the dormant path (PV:54-66, its equal-weight rule relaxed for an old generation that carried the
    /// applied award); for the awarded path the frame's record (tier 0, a Common, void or Failed record: NoAward);
    /// the admission quote (proves sealed, started and Engine cursor == openedEpoch == wall; with the settled old
    /// interval and this held lock all three old indices are closed); principal received from `owner`; the NFT's
    /// dormant owner and nonce re-check after any token callback; the opening (mint last); then the award is marked
    /// applied on the new generation (X5: awardedGeneration only increases).
    function _recharge(address owner, CommonRechargeRequestV5 calldata request, bool awarded)
        private returns (uint64 generation, uint256 rewardWeight, uint256 modelWeight)
    {
        uint256 id = request.positionId;
        PositionState memory old = _positions[id][_currentGeneration[id]];
        NARALifecycleLedgerV5 ll = NARALifecycleLedgerV5(lifecycleLedger);
        GenerationLifecycleV5 memory l = ll.lifecycle(id, old.generation);
        if (l.pendingAttempt != bytes32(0)) revert AttemptPending();
        if (l.consumed) revert GenerationConsumed();
        if (l.rarityApplied) old.rewardWeight = old.modelWeight;
        CommonRechargeBlockerV5 blocker = NARAPrincipalPreviewV5.rechargeGeneration(
            old, request.expectedGeneration, _state.openedEpoch);
        if (blocker != CommonRechargeBlockerV5.None) revert RechargeBlocked(blocker);
        generation = old.generation + 1;
        PositionState memory s;
        if (awarded) {
            FrameAwardV5 memory a = ll.award(id);
            if (a.tier == 0) revert NoAward();
            CreatePreview memory p;
            (p, s) = NARAPrincipalAdmissionV5(admissionHelper).quoteAwardedGeneration(owner, id, generation,
                _admissionSnapshot(), request.funding, a);
            if (p.blocker != ActionBlocker.None) revert CreateBlocked(p.blocker);
        } else {
            s = _prepareGeneration(owner, id, generation, request.funding);
        }
        _receivePrincipal(owner, request.funding.amount);
        INARAPositionIdentityV5(positionNFT).consumeDormant(owner, id, old.generation,
            request.dormantTokenId, request.expectedTransferNonce);
        _openGeneration(id, s, false);
        if (awarded) {
            ll.markApplied(id, generation);
            emit AwardedGenerationOpened(id, generation, s.rewardWeight, s.modelWeight);
        }
        return (generation, s.rewardWeight, s.modelWeight);
    }

    function _receivePrincipal(address payer, uint256 amount) internal {
        IERC20 token = IERC20(nara);
        uint256 beforeBalance = token.balanceOf(address(this));
        if (beforeBalance < _state.principalInventory) revert PrincipalCustodyDeficit();
        token.safeTransferFrom(payer, address(this), amount);
        uint256 afterBalance = token.balanceOf(address(this));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) revert InvalidPrincipalReceipt();
        if (token.totalSupply() != SUPPLY) revert FlashActive();
    }

    /// @dev Shared exact opening template. It only writes the fresh (id,g)
    /// entry; every old generation and RewardLedger anchor remains immutable.
    /// Per-generation bounds at every opening (A2-17): a violation surfaces here, never as a later
    /// openBoundary halt; paired with the 400P check of _replaceRewardWeight and the aggregate
    /// bounds of _assertBounds (ARI-03). Model and reward schedules are written separately.
    /// When `reclassified` is true (P2.6 fusion output), principal already sits inside principalInventory
    /// and principalSnapshot from the five consumed inputs, so neither inventory nor the principal schedule moves.
    function _openGeneration(uint256 id, PositionState memory s, bool reclassified) internal
    {
        uint64 generation = s.generation;
        if (_positions[id][generation].generationOwner != address(0)) revert InvalidState();
        if (s.rewardWeight > 400 * s.principal || s.modelWeight > 4 * s.principal) revert InvalidState();
        _positions[id][generation] = s;
        _currentGeneration[id] = generation;
        if (!reclassified) {
            _state.principalInventory += s.principal;
            _schedulePrincipal(s.createdEpoch + 1, s.principal.toInt256());
        }
        int256 mw = s.modelWeight.toInt256();
        int256 rw = s.rewardWeight.toInt256();
        _scheduleWeights(s.activation, mw, rw);
        _scheduleWeights(s.maturity, -mw, -rw);
        _assertBounds();
        INARAPositionIdentityV5(positionNFT).mint(s.generationOwner, id, generation);
        emit PositionCreated(id, generation, s.generationOwner, s);
    }

    /// @notice Local archived terms and NARA alone authorize mature return.
    /// Consumed generations (P2.6) were reclassified into their fusion output and cannot withdraw.
    function withdrawPrincipal(uint256 id, uint64 generation, address recipient)
        external financialAction returns (uint256 paid)
    {
        PositionState storage s = _positions[id][generation];
        if (s.generationOwner == address(0)) revert UnknownGeneration();
        if (s.generationOwner != msg.sender) revert Unauthorized();
        if (isProtocolSink(recipient)) revert InvalidRecipient();
        (bool started, uint64 wall) = _wall();
        if (!started || wall < s.maturity || s.withdrawn) revert InvalidState();
        if (NARALifecycleLedgerV5(lifecycleLedger).lifecycle(id, generation).consumed) revert GenerationConsumed();
        if (wall == type(uint64).max) revert InvalidEpoch();
        IERC20 token = IERC20(nara);
        uint256 beforeBalance = token.balanceOf(address(this));
        if (beforeBalance < _state.principalInventory) revert PrincipalCustodyDeficit();
        uint256 beforeRecipient = token.balanceOf(recipient);
        paid = s.principal; s.withdrawn = true;
        _state.principalInventory -= paid;
        _schedulePrincipal(wall + 1, -paid.toInt256());
        _assertBounds();
        token.safeTransfer(recipient, paid);
        uint256 afterBalance = token.balanceOf(address(this));
        uint256 afterRecipient = token.balanceOf(recipient);
        if (afterBalance > beforeBalance || beforeBalance - afterBalance != paid
            || afterRecipient < beforeRecipient || afterRecipient - beforeRecipient != paid) revert InvalidPrincipalPayment();
        emit PrincipalWithdrawn(id, generation, recipient, paid);
    }

    function _prepareGeneration(address caller, uint256 id, uint64 generation, CreateRequest memory request)
        private view returns (PositionState memory s)
    {
        // Only this ledger constructs an executable snapshot, from local state.
        // The fixed helper calculates weights under the validated policy. It
        // has no mutable authority or ability to write financial state.
        CreatePreview memory p;
        (p, s) = NARAPrincipalAdmissionV5(admissionHelper).quoteGeneration(caller, id, generation,
            _admissionSnapshot(), request);
        if (p.blocker != ActionBlocker.None) revert CreateBlocked(p.blocker);
    }
    function _admissionSnapshot() private view returns (PrincipalAdmissionSnapshotV5 memory) {
        return PrincipalAdmissionSnapshotV5(_state.initialized, bindingsSealed, genesisTimestamp,
            _state.openedEpoch, _state.principalInventory);
    }
    function _wall() private view returns (bool started, uint64 wall) {
        if (!_state.initialized || block.timestamp < genesisTimestamp) return (false, 0);
        uint256 value = (block.timestamp - genesisTimestamp) / 900;
        if (value > type(uint64).max) revert InvalidEpoch();
        return (true, uint64(value));
    }
    function _position(uint256 id, uint64 generation) private view returns (PositionState memory s) {
        s = _positions[id][generation];
        if (s.generationOwner == address(0)) revert UnknownGeneration();
        RewardWeightTransition storage t = _rewardTransitions[id][generation];
        // Settlement can lag wall time. Use the denominator's actual epoch.
        if (t.cutover > _state.openedEpoch) s.rewardWeight = t.previousWeight;
    }
    function _validateNFT(address candidate) private view {
        if (INARAPositionIdentityV5(candidate).core() != address(this)
            || INARAPositionIdentityV5(candidate).financialSchemaVersion() != 2) revert InvalidState();
    }
    function _schedulePrincipal(uint64 epoch, int256 delta) private {
        _changes[epoch].principalDelta += delta; _state.pendingPrincipalDelta += delta;
    }
    function _scheduleWeights(uint64 epoch, int256 modelDelta, int256 rewardDelta) private {
        PrincipalLedgerChangesV5 storage c = _changes[epoch];
        c.modelWeightDelta += modelDelta; c.rewardWeightDelta += rewardDelta;
    }
    function _apply(uint256 value, int256 delta) private pure returns (uint256) {
        return delta >= 0 ? value + uint256(delta) : value - uint256(-delta);
    }
    function _assertBounds() private view {
        if (_state.principalInventory > SUPPLY || _state.principalSnapshot > SUPPLY
            || _state.activeModelWeight > 4 * SUPPLY || _state.activeRewardWeight > 400 * SUPPLY
            || _state.principalSnapshot.toInt256() + _state.pendingPrincipalDelta != _state.principalInventory.toInt256()) revert InvalidState();
    }
}
