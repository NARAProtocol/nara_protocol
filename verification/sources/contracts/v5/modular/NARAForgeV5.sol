// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {NARAPrincipalLedgerV5} from "./NARAPrincipalLedgerV5.sol";
import {NARALifecycleLedgerV5} from "./NARALifecycleLedgerV5.sol";
import {NARAForgeQuoteV5} from "./NARAForgeQuoteV5.sol";
import {FinalizeStatusV5, FrameAwardV5, INARADurationMultiplierV5} from "./NARAModuleInterfacesV5.sol";
import {PositionState} from "../interfaces/NARAAccountingTypesV5.sol";
import {AttemptKindV5, AttemptStateV5, AttemptV5, RollBlockerV5, RollRequestV5, FusionRequestV5,
    INARAEntropyAdapterV5, INARAForgeAdapterViewV5, RechargeAwardedRequestV5, INARAForgeRechargePrincipalV5} from "./NARAForgeTypesV5.sol";

/// @notice Paid, single-attempt lifecycle orchestration. Custody and weights stay in Principal.
/// @dev No administrator can mutate an existing attempt's adapter, inputs, fee, or deadline.
contract NARAForgeV5 is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    uint256 public constant SCHEMA_VERSION = 1;
    uint16 public constant ODDS_VERSION = 1;
    uint256 public constant READ_STIPEND = 50_000;
    // More than 2 * READ_STIPEND * 64 / 63, cold accesses and terminal bookkeeping.
    uint256 public constant GAS_FLOOR = 400_000;
    address public immutable principal;
    address public immutable engine;
    address public immutable nara;
    address public immutable reserve;
    address public immutable rewards;
    address public immutable positionNFT;
    address public immutable admissionHelper;
    address public immutable lifecycleLedger;
    address public immutable quote;
    address public immutable governor;
    address public immutable guardian;
    address public immutable initialAdapter;
    uint64 public immutable TIMEOUT_EPOCHS;
    bool public commitsPaused;
    address public adapter;
    address public pendingAdapter;
    uint256 public adapterReadyAt;
    uint256 public pendingProposal;
    uint256 public proposalCount;
    uint256 public adapterNonce;
    mapping(uint256 => address) public adapterHistory;
    mapping(address => bool) public wasAdapter;
    uint256 private _attemptNonce;
    mapping(bytes32 => AttemptV5) private _attempts;
    mapping(address => uint256) public ethRefund;
    mapping(address => uint256) public naraRefund;
    uint256 public escrowedNara;
    uint256 public ethRefundTotal;
    uint256 public naraRefundTotal;
    uint256 public pendingTotal;

    error Unauthorized(); error NotGuardian(); error InvalidState(); error InvalidAdapter(); error NotSealed();
    error ProposalPending(); error ProposalNotReady(); error Expired(); error Ineligible(RollBlockerV5 blocker);
    error FlashActive(); error FeeAboveMax(); error OracleFeeAboveMax(); error InsufficientPayment();
    error InvalidFeeReceipt(); error InvalidInputs(); error AttemptNotPending(); error InsufficientGas();
    error NotDelivered(); error AlreadyDelivered(); error NotTimedOut(); error InvalidRecipient();
    error NothingToWithdraw(); error RefundFailed();
    error RentAboveMax();

    event RollCommitted(bytes32 indexed attemptId, uint256 indexed positionId, uint64 indexed generation,
        address payer, address adapter, uint256 requestId, uint256 valueFee, uint256 fixedFee, uint256 oracleFee,
        uint256 excess, bytes32 commitment, uint64 commitEpoch, uint64 deadlineEpoch);
    event FusionCommitted(bytes32 indexed attemptId, address indexed payer, address adapter, uint256 requestId,
        uint256[5] positionIds, uint64[5] generations, uint8 inputTier, uint256 protocolFee, uint256 extensionRent,
        uint256 oracleFee, uint256 excess, bytes32 commitment, uint64 commitEpoch, uint64 deadlineEpoch);
    event AttemptFinalized(bytes32 indexed attemptId, uint256 word, uint8 outcomeTier, uint8 status, uint256 feeToReserve, uint256 outputId);
    event AttemptFailed(bytes32 indexed attemptId, address indexed payer, uint256 feeRefunded, uint64 deadlineEpoch);
    event RefundWithdrawn(address indexed payer, address indexed recipient, uint256 eth, uint256 nara);
    event AdapterProposed(address indexed next, uint256 indexed proposalId, uint256 readyAt, bytes32 codehash);
    event AdapterProposalCancelled(uint256 indexed proposalId);
    event AdapterReplaced(address indexed previous, address indexed next, uint256 indexed nonce, uint256 proposalId);
    event CommitsPaused(address indexed by);
    event CommitsUnpaused(address indexed by);
    event RentPaid(uint256 indexed frameId, uint64 indexed generation, address indexed payer, uint256 rent, uint256 rewardWeight, uint256 modelWeight);

    constructor(address principal_, address adapter_, address governor_, address guardian_, uint64 timeout_) {
        if (!_contractPeer(principal_) || !_contractPeer(governor_) || !_contractPeer(guardian_)
            || governor_ == guardian_ || timeout_ < 4 || timeout_ > 96) revert InvalidState();
        NARAPrincipalLedgerV5 p = NARAPrincipalLedgerV5(principal_);
        // P2.11 (A3-07(a)): Principal is schema 3.
        if (p.forge() != address(this) || p.SCHEMA_VERSION() != 3 || p.bindingsSealed()
            || NARALifecycleLedgerV5(p.lifecycleLedger()).forge() != address(this)) revert InvalidState();
        principal = principal_; engine = p.engine(); nara = p.nara(); reserve = p.reserve();
        rewards = p.rewards(); positionNFT = p.positionNFT(); admissionHelper = p.admissionHelper();
        lifecycleLedger = p.lifecycleLedger(); governor = governor_; guardian = guardian_; TIMEOUT_EPOCHS = timeout_;
        _validateAdapter(adapter_); initialAdapter = adapter_; adapter = adapter_; wasAdapter[adapter_] = true;
        quote = address(new NARAForgeQuoteV5(principal_, lifecycleLedger, admissionHelper, engine, nara, timeout_));
    }
    function attempt(bytes32 id) external view returns (AttemptV5 memory) { return _attempts[id]; }
    function adapterState() external view returns (address current, address pending, uint256 nonce) { return (adapter, pendingAdapter, adapterNonce); }
    function isAdapterOrFormer(address a) external view returns (bool) { return wasAdapter[a]; }
    function pauseCommits() external nonReentrant { if (msg.sender != guardian) revert NotGuardian(); commitsPaused = true; emit CommitsPaused(msg.sender); }
    function unpauseCommits() external nonReentrant { if (msg.sender != guardian) revert NotGuardian(); commitsPaused = false; emit CommitsUnpaused(msg.sender); }

    function commitRoll(RollRequestV5 calldata r) external payable nonReentrant returns (bytes32 id, uint256 requestId) {
        _commitChecks(r.deadline);
        NARAForgeQuoteV5 q = NARAForgeQuoteV5(quote);
        (RollBlockerV5 blocker, uint64 wall, uint256 total, uint256 emission) = q.reads(); _eligible(blocker);
        PositionState memory p;
        (blocker, p) = q.eligibility(msg.sender, r.positionId, r.generation, r.expectedTermsHash, wall, true); _eligible(blocker);
        (uint256 value, uint256 fixedFee) = q.rollFee(p.principal,
            INARADurationMultiplierV5(admissionHelper).durationMultiplier(p.duration), p.rewardWeight, total, emission);
        if (value + fixedFee > r.maxFee) revert FeeAboveMax();
        uint256[5] memory ids; ids[0] = r.positionId; uint64[5] memory generations; generations[0] = r.generation;
        (id, requestId) = _commit(AttemptKindV5.Roll, 0, ids, generations, value + fixedFee, r.maxOracleFee, wall);
        bytes32[5] memory terms; terms[0] = r.expectedTermsHash;
        AttemptV5 storage a = _attempts[id];
        emit RollCommitted(id, r.positionId, r.generation, msg.sender, a.adapter, requestId, value, fixedFee,
            a.oracleFee, msg.value - a.oracleFee, keccak256(abi.encode(ids, generations, terms, msg.sender, wall)), wall, a.deadlineEpoch);
    }
    function commitFusion(FusionRequestV5 calldata r) external payable nonReentrant returns (bytes32 id, uint256 requestId) {
        _commitChecks(r.deadline);
        NARAForgeQuoteV5 q = NARAForgeQuoteV5(quote);
        (RollBlockerV5 blocker, uint64 wall, uint256 total, uint256 emission) = q.reads(); _eligible(blocker);
        PositionState[5] memory ps; uint256[5] memory caps; uint256 daw = 4e18; uint8 tier;
        uint256 sumP; uint256 sumC; uint256 inputCapacity; uint256 own; uint64 maturity = wall + 97;
        for (uint256 i; i < 5; ++i) {
            if (i > 0 && r.positionIds[i] <= r.positionIds[i - 1]) revert InvalidInputs();
            (blocker, ps[i]) = q.eligibility(msg.sender, r.positionIds[i], r.generations[i], r.expectedTermsHashes[i], wall, false); _eligible(blocker);
            uint8 t = NARAPrincipalLedgerV5(principal).rarityTier(r.positionIds[i], r.generations[i]);
            if (i == 0) tier = t; if (t != tier || t > 4) revert InvalidInputs();
            FrameAwardV5 memory a = NARALifecycleLedgerV5(lifecycleLedger).award(r.positionIds[i]);
            bool awarded = a.attemptId != bytes32(0) && a.outcomeTier != 255;
            if (awarded && a.tier != t) revert InvalidInputs();
            caps[i] = awarded ? a.originalCap : ps[i].principal;
            uint256 inputDaw = awarded ? a.awardedDurationWad : INARADurationMultiplierV5(admissionHelper).durationMultiplier(ps[i].duration);
            daw = Math.min(daw, inputDaw); sumP += ps[i].principal; sumC += caps[i];
            inputCapacity += Math.min(ps[i].principal, caps[i]); own += ps[i].rewardWeight;
            if (ps[i].maturity > maturity) maturity = ps[i].maturity;
        }
        uint256 d = INARADurationMultiplierV5(admissionHelper).durationMultiplier(uint32(maturity - wall - 1));
        uint256 fee = q.fusionFee(sumP, sumC, inputCapacity, own, tier, d, daw, total, emission);
        uint256 extension;
        if (tier != 0) {
            bool extended;
            for (uint256 i; i < 5; ++i) if (ps[i].maturity < maturity) {
                extended = true;
                extension += q.rentRaw(ps[i].principal, caps[i], q.multiplierWad(tier), Math.min(d, daw), daw, maturity - ps[i].maturity, total, emission);
            }
            if (extended) extension = Math.max(q.MIN_FEE(), extension);
        }
        fee += extension; if (fee > r.maxFee) revert FeeAboveMax();
        (id, requestId) = _commit(AttemptKindV5.Fusion, tier, r.positionIds, r.generations, fee, r.maxOracleFee, wall);
        AttemptV5 storage a = _attempts[id];
        emit FusionCommitted(id, msg.sender, a.adapter, requestId, r.positionIds, r.generations, tier, fee, extension,
            a.oracleFee, msg.value - a.oracleFee, keccak256(abi.encode(r.positionIds, r.generations, r.expectedTermsHashes, msg.sender, wall)), wall, a.deadlineEpoch);
    }
    function _commitChecks(uint64 deadline) private view {
        _settledSupply(); if (commitsPaused) revert INARAForgeAdapterViewV5.CommitsPaused(); if (block.timestamp > deadline) revert Expired();
    }
    function _eligible(RollBlockerV5 blocker) private pure { if (blocker != RollBlockerV5.None) revert Ineligible(blocker); }
    function _settledSupply() private view { if (IERC20(nara).totalSupply() != 1e24) revert FlashActive(); }
    function _commit(AttemptKindV5 kind, uint8 tier, uint256[5] memory ids, uint64[5] memory generations,
        uint256 fee, uint256 maxOracleFee, uint64 wall) private returns (bytes32 id, uint256 requestId)
    {
        address selected = adapter; uint256 oracleFee = INARAEntropyAdapterV5(selected).quote();
        if (oracleFee > maxOracleFee) revert OracleFeeAboveMax(); if (msg.value < oracleFee) revert InsufficientPayment();
        id = keccak256(abi.encode(keccak256("NARA_V5_FORGE_ATTEMPT_V1"), block.chainid, address(this), kind, ++_attemptNonce));
        uint256 excess = msg.value - oracleFee; ethRefund[msg.sender] += excess; ethRefundTotal += excess;
        uint256 beforeBalance = IERC20(nara).balanceOf(address(this)); IERC20(nara).safeTransferFrom(msg.sender, address(this), fee);
        if (IERC20(nara).balanceOf(address(this)) != beforeBalance + fee) revert InvalidFeeReceipt(); escrowedNara += fee;
        NARALifecycleLedgerV5(lifecycleLedger).registerAttempt(id, msg.sender, kind == AttemptKindV5.Roll ? 1 : 5, ids, generations, wall);
        _attempts[id] = AttemptV5(kind, AttemptStateV5.Committed, msg.sender, selected, wall, wall + TIMEOUT_EPOCHS + 1, ODDS_VERSION, tier, 0, fee, oracleFee, 0, 0);
        ++pendingTotal;
        requestId = INARAEntropyAdapterV5(selected).request{value: oracleFee}(id);
        if (requestId == 0) revert InvalidInputs(); _attempts[id].requestId = requestId;
    }
    function finalize(bytes32 id) external nonReentrant returns (uint8 outcomeTier, FinalizeStatusV5 status) {
        // AR32-06: the shared on-time read runs from the same prior state as in fail; settled supply is checked after it.
        AttemptV5 storage a = _pending(id); (bool onTime, uint256 word) = _onTimeWord(id, a);
        _settledSupply(); if (!onTime) revert NotDelivered();
        outcomeTier = NARAForgeQuoteV5(quote).outcomeOf(word, a.kind, a.inputTier);
        a.word = word; a.outcomeTier = outcomeTier; a.state = AttemptStateV5.Finalized;
        uint256 output; (status, output) = NARAPrincipalLedgerV5(principal).finalizeAttempt(id, outcomeTier, a.oddsVersion, a.requestId);
        if (status == FinalizeStatusV5.Void || status == FinalizeStatusV5.Cancelled) a.state = AttemptStateV5.Voided;
        --pendingTotal; escrowedNara -= a.protocolFee; IERC20(nara).safeTransfer(reserve, a.protocolFee);
        emit AttemptFinalized(id, word, outcomeTier, uint8(status), a.protocolFee, output);
    }
    function fail(bytes32 id) external nonReentrant {
        AttemptV5 storage a = _pending(id); (bool onTime,) = _onTimeWord(id, a);
        if (onTime) revert AlreadyDelivered(); if (block.timestamp < _deadline(a)) revert NotTimedOut();
        a.state = AttemptStateV5.Failed; --pendingTotal;
        NARALifecycleLedgerV5(lifecycleLedger).failAttempt(id);
        escrowedNara -= a.protocolFee; naraRefund[a.payer] += a.protocolFee; naraRefundTotal += a.protocolFee;
        emit AttemptFailed(id, a.payer, a.protocolFee, a.deadlineEpoch);
    }
    function _pending(bytes32 id) private view returns (AttemptV5 storage a) {
        a = _attempts[id]; if (a.state != AttemptStateV5.Committed) revert AttemptNotPending();
    }
    function _deadline(AttemptV5 storage a) private view returns (uint256) {
        return uint256(NARAPrincipalLedgerV5(principal).genesisTimestamp()) + uint256(a.deadlineEpoch) * 900;
    }
    /// @dev Both terminal branches use these same fixed-gas, fixed-size reads. Oversized returndata is never copied.
    function _onTimeWord(bytes32 id, AttemptV5 storage a) private view returns (bool onTime, uint256 word) {
        if (gasleft() < GAS_FLOOR) revert InsufficientGas();
        address selected = a.adapter;
        bytes memory input = abi.encodeCall(INARAEntropyAdapterV5.result, (a.requestId));
        uint256[4] memory output; bool ok;
        assembly ("memory-safe") {
            ok := staticcall(READ_STIPEND, selected, add(input, 32), mload(input), 0, 0)
            ok := and(ok, eq(returndatasize(), 128))
            if ok { returndatacopy(output, 0, 128) }
        }
        input = abi.encodeCall(INARAEntropyAdapterV5.requestOf, (id)); bool matched; uint256 returnedId;
        assembly ("memory-safe") {
            matched := staticcall(READ_STIPEND, selected, add(input, 32), mload(input), 0, 0)
            matched := and(matched, eq(returndatasize(), 32))
            if matched { returndatacopy(add(input, 32), 0, 32) returnedId := mload(add(input, 32)) }
        }
        onTime = ok && output[0] == 1 && output[1] <= type(uint64).max && output[2] <= type(uint64).max
            && output[1] < _deadline(a) && matched && returnedId == a.requestId;
        word = output[3];
    }
    function withdrawRefund(address recipient) external nonReentrant returns (uint256 eth, uint256 naraAmount) {
        if (NARAPrincipalLedgerV5(principal).isProtocolSink(recipient)) revert InvalidRecipient();
        eth = ethRefund[msg.sender]; naraAmount = naraRefund[msg.sender]; if (eth == 0 && naraAmount == 0) revert NothingToWithdraw();
        ethRefund[msg.sender] = 0; naraRefund[msg.sender] = 0; ethRefundTotal -= eth; naraRefundTotal -= naraAmount;
        if (naraAmount != 0) {
            uint256 beforeBalance = IERC20(nara).balanceOf(recipient); IERC20(nara).safeTransfer(recipient, naraAmount);
            if (IERC20(nara).balanceOf(recipient) != beforeBalance + naraAmount) revert InvalidFeeReceipt();
        }
        if (eth != 0) { (bool ok,) = recipient.call{value: eth}(""); if (!ok) revert RefundFailed(); }
        emit RefundWithdrawn(msg.sender, recipient, eth, naraAmount);
    }
    /// @dev Principal's authenticated awarded-recharge implementation lands in P2.4. This entry point never
    /// changes caller identity, never reads adapter governance, and moves rent only after Principal succeeds.
    function rechargeAwarded(RechargeAwardedRequestV5 calldata r) external nonReentrant returns (uint64 generation) {
        _settledSupply();
        NARAForgeQuoteV5 q = NARAForgeQuoteV5(quote);
        (RollBlockerV5 blocker,, uint256 total, uint256 emission) = q.reads(); _eligible(blocker);
        FrameAwardV5 memory a = NARALifecycleLedgerV5(lifecycleLedger).award(r.recharge.positionId);
        if (a.tier == 0) revert Ineligible(RollBlockerV5.NoAward);
        uint256 d = INARADurationMultiplierV5(admissionHelper).durationMultiplier(r.recharge.funding.duration);
        uint256 rent = q.rent(r.recharge.funding.amount, a.originalCap, a.multiplierWad, d, a.awardedDurationWad,
            r.recharge.funding.duration, total, emission);
        if (rent > r.maxRent) revert RentAboveMax();
        uint256 rewardWeight; uint256 modelWeight;
        (generation, rewardWeight, modelWeight) = INARAForgeRechargePrincipalV5(principal).rechargeAwarded(msg.sender, r.recharge);
        uint256 beforeBalance = IERC20(nara).balanceOf(reserve); IERC20(nara).safeTransferFrom(msg.sender, reserve, rent);
        if (IERC20(nara).balanceOf(reserve) != beforeBalance + rent) revert InvalidFeeReceipt();
        emit RentPaid(r.recharge.positionId, generation, msg.sender, rent, rewardWeight, modelWeight);
    }
    function proposeAdapter(address next) external nonReentrant {
        if (msg.sender != governor) revert Unauthorized(); if (!NARAPrincipalLedgerV5(principal).bindingsSealed()) revert NotSealed();
        if (pendingAdapter != address(0)) revert ProposalPending(); _validateAdapter(next); if (next == adapter) revert InvalidAdapter();
        pendingAdapter = next; pendingProposal = ++proposalCount; adapterReadyAt = block.timestamp + 7 days;
        emit AdapterProposed(next, pendingProposal, adapterReadyAt, next.codehash);
    }
    function cancelAdapterProposal(uint256 proposalId) external nonReentrant {
        if (msg.sender != governor) revert Unauthorized(); if (proposalId == 0 || proposalId != pendingProposal) revert InvalidState();
        _clearProposal(); emit AdapterProposalCancelled(proposalId);
    }
    function finalizeAdapter(address next, uint256 proposalId) external nonReentrant {
        if (next == address(0) || next != pendingAdapter || proposalId != pendingProposal) revert InvalidState();
        if (block.timestamp < adapterReadyAt) revert ProposalNotReady(); _validateAdapter(next);
        address previous = adapter; uint256 nonce = ++adapterNonce; adapterHistory[nonce] = previous;
        wasAdapter[next] = true; adapter = next; _clearProposal(); emit AdapterReplaced(previous, next, nonce, proposalId);
    }
    function _clearProposal() private { pendingAdapter = address(0); adapterReadyAt = 0; pendingProposal = 0; }
    function _validateAdapter(address a) private view {
        if (!_contractPeer(a) || INARAEntropyAdapterV5(a).forge() != address(this) || INARAEntropyAdapterV5(a).SCHEMA_VERSION() != 1) revert InvalidAdapter();
    }
    function _contractPeer(address a) private view returns (bool) {
        if (a.code.length == 0) return false;
        bytes3 prefix; assembly ("memory-safe") { let ptr := mload(0x40) extcodecopy(a, ptr, 0, 3) prefix := mload(ptr) }
        return prefix != bytes3(0xef0100);
    }
}
