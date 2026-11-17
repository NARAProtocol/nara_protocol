// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {NARATokenV5} from "../NARATokenV5.sol";
import {NARAEmissionModelV5} from "../engine/NARAEmissionModelV5.sol";
import {EmissionConfig, EmissionState, EmissionInputs, EmissionQuote} from "../engine/NARAEmissionTypesV5.sol";
import {INARAEmissionReserveV5} from "../interfaces/INARAEmissionReserveV5.sol";
import {AccountingPolicy, CoreBindings, DurationCurve, EpochClock, ReserveState, ReserveDelivery, AdvanceResult}
    from "../interfaces/NARAAccountingTypesV5.sol";
import {NARAPrincipalLedgerV5} from "./NARAPrincipalLedgerV5.sol";
import {NARARewardLedgerV5} from "./NARARewardLedgerV5.sol";
import {NARARewardCreditLedgerV5} from "./NARARewardCreditLedgerV5.sol";
import {NARAForgeV5} from "./NARAForgeV5.sol";
import {NARAPositionNFTV5} from "./NARAPositionNFTV5.sol";
import {NARAPositionRendererV5} from "./NARAPositionRendererV5.sol";
import {INARAPositionIdentityV5, INARAForgeIdentityV5, PrincipalLedgerStateV5, RewardLedgerStateV5} from "./NARAModuleInterfacesV5.sol";

struct EpochFundingStateV5 {
    bool initialFundingRecognized;
    uint256 eligibleReserve;
    uint256 futureReserve;
    uint256 lastFundingSequence;
    uint256 cumulativeRecognized;
    uint256 cumulativeReleased;
    uint32 releaseGasLimit;
    uint32 minimumGasBeforeRelease;
}

struct EpochSettlementV5 {
    uint256 principalSnapshot;
    uint256 protectedRewardSnapshot;
    uint256 reserveSnapshot;
    uint256 modelFloat;
    uint256 modelWeight;
    uint256 rewardWeight;
    uint256 requested;
    uint256 delivered;
    ReserveDelivery status;
    EmissionState nextModelState;
}

/// @notice Bias-corrected exponentially weighted mean of NARA delivered per close, over closes with reward weight
/// (LIFECYCLE_DESIGN §5.4, P2.10). One packed slot: `sum` and `weight` are bounded by one close's largest delivery
/// (at most maxBaseEmission × dripSplit / 1e18 ≤ 4.99e18 by G5) and by 1e18, so both fit `uint96`.
struct EmissionReferenceV5 {
    uint96 sum;
    uint96 weight;
    uint64 samples;
}

/// @notice Sole epoch cursor, adaptive model state and Reserve eligibility journal.
/// @dev No principal or persistent reward custody. The fixed Reserve still sends
/// to this Engine; its exact fresh receipt is forwarded to Rewards atomically.
/// Funding-call provenance: NARACoreFundingV5 reference, with the same bounded
/// gas/return-data behavior and a cross-module financial lock.
contract NARAEpochEngineV5 {
    using SafeERC20 for IERC20;
    uint256 private constant SUPPLY = 1_000_000 ether;
    /// @notice T of the reserve-scaled release (B3): 4 years of 900-second epochs. A compile-time constant,
    /// not a packet argument (A2-16); G8 (3 ≤ T ≤ 5 years) is a test of this value, not a runtime check.
    uint256 public constant RELEASE_HORIZON_EPOCHS = 140_160;
    /// @dev Time constant of the emission reference, in sampled closes (30 days of closes; §5.4).
    uint256 private constant REFERENCE_WINDOW = 2_880;
    uint32 private constant RELEASE_GAS = 400_000;
    // The old funding-only guard left too little gas for three-asset settlement
    // and both opening acknowledgements after a hostile Reserve spends 400k.
    uint32 private constant RELEASE_MINIMUM_GAS = 1_000_000;

    NARATokenV5 private immutable _nara;
    INARAEmissionReserveV5 private immutable _reserve;
    NARAEmissionModelV5 private immutable _model;
    uint256 private immutable _genesisFunding;
    /// @dev R_ref of the reserve-scaled release (B3): RELEASE_HORIZON_EPOCHS × floor(maxBaseEmission × dripSplit / 1e18),
    /// the Reserve that funds the largest possible target for exactly T epochs (595,680 NARA for B8).
    uint256 private immutable _referenceRelease;
    bytes32 public immutable emissionConfigurationHash;
    address private _bootstrap;
    NARAPrincipalLedgerV5 private _principal;
    NARARewardLedgerV5 private _rewards;
    address private _nft;
    bool private _sealed;
    bool private _activated;
    uint64 private _genesis;
    uint64 private _cursor;
    bytes32 public principalBindingHash;
    bytes32 public rewardBindingHash;
    bytes32 public graphHash;
    AccountingPolicy private _policy;
    EmissionConfig private _config;
    EmissionState private _emission;
    EpochFundingStateV5 private _funding;
    mapping(uint64 epoch => uint256 amount) private _fundingAt;
    EmissionReferenceV5 private _reference;
    bool transient private _localBusy;
    bool transient private _releasing;
    uint64 transient private _releaseEpoch;
    uint256 transient private _releaseMaximum;

    error Unauthorized();
    error InvalidState();
    error InvalidPolicy();
    error InvalidEpoch();
    error InvalidFundingSequence();
    error AccountingInProgress();
    error FlashActive();
    error InvalidReserveDelivery();
    error InvalidRewardForward();
    error InsufficientReleaseGas();
    error InvalidTerms();
    error InvalidModel();
    error InvalidEmissionEnvelope();

    event FinancialModulesBound(address indexed principal, address indexed rewards, address indexed nft);
    event CoreBindingsSealed(bytes32 indexed graphHash, bytes32 principalBindingHash, bytes32 rewardBindingHash);
    event CoreActivated(uint64 genesisTimestamp);
    event ReserveFundingRecorded(uint256 indexed sequence, uint64 indexed eligibleEpoch, uint256 amount);
    event EmissionConfigurationBound(bytes32 indexed configurationHash, EmissionConfig config, EmissionState initialState);
    /// @dev These exact historical inputs plus the versioned pure model/config
    /// reconstruct every quote output. Rewards emits its own exact allocations.
    event EpochSettled(uint64 indexed epoch, bytes32 indexed graphHash, EpochSettlementV5 settlement);

    constructor(address authority, address nara, address reserve, address model, uint256 genesisFunding,
        AccountingPolicy memory p, EmissionConfig memory config, EmissionState memory initialState)
    {
        if (authority == address(0) || nara.code.length == 0 || reserve.code.length == 0 || model.code.length == 0
            || nara == reserve || nara == model || reserve == model || genesisFunding == 0 || genesisFunding > SUPPLY) revert InvalidState();
        // ACC-E02: the model is authenticated by its exact runtime bytes before any getter is read.
        // The model holds no immutables, so this is its deployed code; the deployed model must come
        // from the same compilation job as this Engine or construction fails here.
        if (model.codehash != keccak256(type(NARAEmissionModelV5).runtimeCode)) revert InvalidModel();
        _nara = NARATokenV5(nara); _reserve = INARAEmissionReserveV5(reserve); _model = NARAEmissionModelV5(model);
        _bootstrap = authority; _genesisFunding = genesisFunding;
        if (_nara.MAX_SUPPLY() != SUPPLY || _nara.FLASH_FEE_SINK() != reserve || _model.MODEL_VERSION() != 1
            || _model.FIXED_SUPPLY() != SUPPLY) revert InvalidState();
        _requireSettledSupply();
        ReserveState memory s = _reserve.state();
        if (s.schemaVersion != 1 || s.nara != nara || s.core != address(0) || s.bootstrapAuthority != authority
            || s.bindingsSealed || s.initialFundingRecognized || s.genesisFunding != genesisFunding
            || s.fundingSequence != 0 || s.cumulativeRecognized != 0 || s.cumulativeReleased != 0) revert InvalidState();
        // P2.9 policy pins (B2, B8, DOS-002): the V4Quadratic curve, which the deployed Reserve does not check;
        // minimumPrincipal at most the float outside the Reserve; and exactly the one cap that never binds.
        if (p.policyHash != bytes32(0) || p.version != 1 || p.epochSeconds != 900 || p.rewardIndexScale != 1e27
            || p.activationDelay == 0 || p.activationDelay >= 35_040 || p.minDuration != 96 || p.maxDuration != 35_040
            || p.durationCurve != DurationCurve.V4Quadratic || p.earlyExitEnabled || p.earlyExitBps != 0
            || p.minimumPrincipal == 0 || p.minimumPrincipal > SUPPLY - genesisFunding
            || p.maxAdvance == 0 || p.maxAdvance > 96 || p.rewardAdmissionCap != type(uint256).max / 1e27) revert InvalidPolicy();
        p.policyHash = keccak256(abi.encode(keccak256("NARA_V5_MODULAR_POLICY_V1"), block.chainid, address(this), p));
        _policy = p;
        _model.calculateNext(config, initialState, EmissionInputs(SUPPLY - genesisFunding, 0));
        _requireEmissionEnvelope(config, initialState);
        _config = config; _emission = initialState;
        // P2.10 (B3): R_ref from the compile-time T (A2-16, conflict 17); the floor-first order is the P1.5 model's.
        _referenceRelease = RELEASE_HORIZON_EPOCHS * (config.maxBaseEmission * config.dripSplitWad / 1e18);
        emissionConfigurationHash = keccak256(abi.encode(keccak256("NARA_V5_EMISSION_CONFIGURATION_V2"),
            block.chainid, address(this), model, config, initialState, RELEASE_HORIZON_EPOCHS));
        _funding.releaseGasLimit = RELEASE_GAS; _funding.minimumGasBeforeRelease = RELEASE_MINIMUM_GAS;
        emit EmissionConfigurationBound(emissionConfigurationHash, config, initialState);
    }

    /// @dev G1–G7 of ECONOMIC_DESIGN_REVIEW §2.7 (LIFECYCLE_DESIGN §5.7, P2.9), constructor-only. Runs after the
    /// model's own domain checks on the same config and state, so every product here is bounded (eMax and
    /// maxBaseEmission at most SUPPLY; the WAD coefficients at most 10e18). G8 is RELEASE_HORIZON_EPOCHS.
    function _requireEmissionEnvelope(EmissionConfig memory c, EmissionState memory s) private pure {
        if (c.eMax * 1e18 < SUPPLY * (c.beta0Wad + c.mWad) // G1 no strand: the horizon covers the supply
            || c.bWad >= 1e18 // G2 no strand at low participation
            || c.warmupRateWad == 0 || c.dripSplitWad == 0 || c.minBaseEmission == 0 // G3 no strand
            || (s.bootstrapWeight != 0 && c.bootstrapDecayWad > 0.99976e18) // G4 bootstrap half-life ≤ about 30 days
            || c.maxBaseEmission * c.dripSplitWad / 1e18 > 4.99e18 // G5 no fast drain: genesis over 4 years per epoch
            || c.growthFactorWad > 1.001e18 || c.warmupRateWad > 0.01e18 // G6 ramps
            || s.baseEmission < c.minBaseEmission || s.baseEmission > c.maxBaseEmission || s.warmupFactorWad != 0) // G7 initial state
            revert InvalidEmissionEnvelope();
    }

    modifier onlyBootstrap() { if (msg.sender != _bootstrap) revert Unauthorized(); _; }
    modifier financialAction() {
        NARAPrincipalLedgerV5 locked = _beginAction();
        _;
        _endAction(locked);
    }
    // One implementation of the graph-lock protocol for every financial entry.
    // Capture the pre-action peer: first binding starts before Principal is set.
    function _beginAction() private returns (NARAPrincipalLedgerV5 locked) {
        if (_localBusy) revert AccountingInProgress();
        _localBusy = true;
        locked = _principal;
        if (address(locked) != address(0)) locked.beginModuleAction();
    }
    function _endAction(NARAPrincipalLedgerV5 locked) private {
        if (address(locked) != address(0)) locked.endModuleAction();
        _localBusy = false;
    }
    modifier coherentRead() { if (accountingInProgress()) revert AccountingInProgress(); _; }

    function bindFinancialModules(address principal, address rewards) external onlyBootstrap financialAction {
        if (address(_principal) != address(0) || !_validPeer(principal) || !_validPeer(rewards) || principal == rewards) revert InvalidState();
        NARAPrincipalLedgerV5 p = NARAPrincipalLedgerV5(principal); NARARewardLedgerV5 r = NARARewardLedgerV5(rewards);
        address nft = p.positionNFT();
        if (p.engine() != address(this) || p.nara() != address(_nara) || p.reserve() != address(_reserve)
            || p.rewards() != rewards || p.bindingsSealed() || p.SCHEMA_VERSION() != 3
            || r.engine() != address(this) || r.principal() != principal || r.nara() != address(_nara)
            || r.reserve() != address(_reserve) || r.initialized() || r.SCHEMA_VERSION() != 2 || r.RARITY_SHARE_BPS() != 2_000
            || !_validPeer(nft) || nft == principal || nft == rewards
            || INARAPositionIdentityV5(nft).core() != principal || INARAPositionIdentityV5(nft).financialSchemaVersion() != 2) revert InvalidState();
        // P2.2 / P2.12 (§2.2, §4.5): the Forge peer is a code-bearing, distinct address whose principal() is this
        // Principal, and it enters expectedPrincipal (binding V3); its adapter state is checked at bind and seal.
        address forge = p.forge();
        if (!_validPeer(forge) || forge == principal || forge == rewards || forge == nft
            || INARAForgeIdentityV5(forge).principal() != principal) revert InvalidState();
        _validForgeAdapter(forge, principal, rewards, nft);
        bytes32 expectedPrincipal = keccak256(abi.encode(keccak256("NARA_V5_PRINCIPAL_BINDING_V3"), block.chainid,
            address(this), principal, address(_nara), address(_reserve), rewards, nft, forge, _policy.policyHash));
        NARARewardCreditLedgerV5 credit = r.creditLedger();
        if (!_validPeer(address(credit)) || credit.rewards() != rewards) revert InvalidState();
        bytes32 expectedReward = keccak256(abi.encode(keccak256("NARA_V5_REWARD_BINDING_V3"), block.chainid,
            address(this), principal, rewards, expectedPrincipal, address(_nara), address(_reserve), r.usdc(), uint8(6),
            _policy.rewardAdmissionCap, address(credit), uint256(2_000), uint256(2)));
        if (p.bindingHash() != expectedPrincipal || r.bindingHash() != expectedReward) revert InvalidState();
        _principal = p; _rewards = r; _nft = nft;
        emit FinancialModulesBound(principal, rewards, nft);
    }
    function sealBindings() external onlyBootstrap financialAction {
        if (address(_principal) == address(0) || _sealed) revert InvalidState();
        _requireSettledSupply(); ReserveState memory s = _reserve.state(); _validateReserve(s);
        if (s.bindingsSealed || s.bootstrapAuthority != _bootstrap || s.initialFundingRecognized
            || s.fundingSequence != 0 || s.cumulativeRecognized != 0 || s.cumulativeReleased != 0) revert InvalidState();
        // Constructor-fixed peer identities were fully checked during bind. The
        // final deployment gate must also authenticate their actual bytecode and re-check the adapter state (AR-07, P2.12).
        address forge = _principal.forge();
        address initialAdapter = _validForgeAdapter(forge, address(_principal), address(_rewards), _nft);
        NARAPositionRendererV5 renderer = NARAPositionRendererV5(NARAPositionNFTV5(_nft).renderer());
        principalBindingHash = _principal.bindingHash(); rewardBindingHash = _rewards.bindingHash();
        graphHash = keccak256(abi.encode(
            keccak256("NARA_V5_FINANCIAL_GRAPH_V2"),
            block.chainid,
            address(this),
            address(_nara),
            address(_reserve),
            address(_model),
            address(_principal),
            address(_rewards),
            _nft,
            _policy.policyHash,
            emissionConfigurationHash,
            principalBindingHash,
            rewardBindingHash,
            address(_principal).codehash,
            address(_rewards).codehash,
            _nft.codehash,
            _principal.admissionHelper().codehash,
            _principal.lifecycleLedger().codehash,
            address(_rewards.creditLedger()).codehash,
            forge,
            forge.codehash,
            INARAForgeIdentityV5(forge).quote().codehash,
            initialAdapter,
            initialAdapter.codehash,
            address(renderer).codehash,
            address(renderer.art()).codehash,
            address(renderer.statsReader()).codehash
        ));
        _sealed = true; _bootstrap = address(0);
        emit CoreBindingsSealed(graphHash, principalBindingHash, rewardBindingHash);
    }
    function activate() external financialAction {
        if (!_sealed || _activated || !_funding.initialFundingRecognized) revert InvalidState();
        _requireSettledSupply(); ReserveState memory s = _reserve.state(); _validateReserve(s);
        if (!s.bindingsSealed || s.bootstrapAuthority != address(0) || !s.initialFundingRecognized
            || s.fundingSequence != 1 || _funding.lastFundingSequence != 1 || s.cumulativeRecognized != _genesisFunding
            || s.cumulativeReleased != 0 || _nara.balanceOf(address(_reserve)) < _genesisFunding) revert InvalidState();
        uint256 genesis = (block.timestamp / 900 + 1) * 900;
        if (genesis > type(uint64).max) revert InvalidEpoch();
        _genesis = uint64(genesis); _activated = true;
        _principal.initialize(_genesis); _rewards.initialize(_genesis); _assertBoundary();
        emit CoreActivated(_genesis);
    }

    function bindings() external view returns (CoreBindings memory) {
        return CoreBindings(1, address(_nara), address(_reserve), address(_model), _nft, _bootstrap, _sealed, _activated, _genesisFunding);
    }
    function financialModules() external view returns (address principal, address rewards) { return (address(_principal), address(_rewards)); }
    function principalEpoch() external view returns (uint64 genesis, uint64 nextEpochToClose) { return (_genesis, _cursor); }
    function policy() external view returns (AccountingPolicy memory) { return _policy; }
    function emissionConfig() external view returns (EmissionConfig memory) { return _config; }
    function emissionState() external view coherentRead returns (EmissionState memory) { return _emission; }
    function fundingState() external view coherentRead returns (EpochFundingStateV5 memory) { return _funding; }
    /// @notice ε of LIFECYCLE_DESIGN §5.4: floor(sum × 1e18 / weight) wei of NARA delivered per close (0 while nothing
    /// is sampled) and the number of sampled closes; rolls, fusions and awarded recharges open at 2,880 samples.
    function emissionReference() external view coherentRead returns (uint256 naraPerEpoch, uint64 samples) {
        EmissionReferenceV5 memory e = _reference;
        return (e.weight == 0 ? 0 : uint256(e.sum) * 1e18 / e.weight, e.samples);
    }
    function reserveFundingAt(uint64 epoch) external view coherentRead returns (uint256) {
        if (epoch < _cursor) revert InvalidEpoch(); return _fundingAt[epoch];
    }
    function clock() public view returns (EpochClock memory c) {
        if (!_activated) return c;
        c.genesisTimestamp = _genesis;
        if (block.timestamp < _genesis) { c.nextBoundaryTimestamp = _genesis; return c; }
        uint256 wall = (block.timestamp - _genesis) / 900;
        if (wall > type(uint64).max) revert InvalidEpoch();
        c.started = true; c.wallEpoch = uint64(wall); c.nextEpochToClose = _cursor; c.backlog = c.wallEpoch - _cursor;
        c.nextBoundaryTimestamp = uint256(_genesis) + (wall + 1) * 900;
    }
    function accountingInProgress() public view returns (bool) {
        return _localBusy || (address(_principal) != address(0) && _principal.moduleLockHolder() != address(0));
    }
    function reserveReleaseContext() external view returns (bool active, uint64 epoch, uint256 maximum) {
        if (msg.sender != address(_reserve)) revert Unauthorized(); return (_releasing, _releaseEpoch, _releaseMaximum);
    }

    function recordInitialReserveFunding(uint256 sequence, uint256 amount) external financialAction {
        if (msg.sender != address(_reserve)) revert Unauthorized();
        if (!_sealed || _activated || _funding.initialFundingRecognized) revert InvalidState();
        if (sequence != 1 || _funding.lastFundingSequence != 0 || amount != _genesisFunding) revert InvalidFundingSequence();
        _requireSettledSupply(); _funding.initialFundingRecognized = true;
        _funding.eligibleReserve = amount; _funding.cumulativeRecognized = amount; _funding.lastFundingSequence = sequence;
        emit ReserveFundingRecorded(sequence, 0, amount);
    }
    function recordReserveFunding(uint256 sequence, uint64 epoch, uint256 amount) external financialAction {
        if (msg.sender != address(_reserve)) revert Unauthorized();
        EpochClock memory c = clock();
        if (!c.started || c.wallEpoch == type(uint64).max) revert InvalidEpoch();
        if (!_funding.initialFundingRecognized || amount == 0 || sequence != _funding.lastFundingSequence + 1) revert InvalidFundingSequence();
        if (epoch != c.wallEpoch + 1) revert InvalidEpoch();
        _requireSettledSupply(); _fundingAt[epoch] += amount; _funding.futureReserve += amount;
        _funding.cumulativeRecognized += amount; _funding.lastFundingSequence = sequence;
        emit ReserveFundingRecorded(sequence, epoch, amount);
    }
    function advance(uint32 maxEpochs) external financialAction returns (AdvanceResult memory r) {
        if (maxEpochs == 0 || maxEpochs > _policy.maxAdvance) revert InvalidTerms();
        EpochClock memory c = clock(); if (!c.started) revert InvalidState(); _requireSettledSupply();
        r.fromEpoch = _cursor;
        while (r.closedCount < maxEpochs && _cursor < c.wallEpoch) {
            if (_closeEpoch() == ReserveDelivery.Failed) ++r.failedReserveCalls;
            ++r.closedCount;
        }
        r.nextEpochToClose = _cursor; r.remainingBacklog = c.wallEpoch - _cursor;
    }

    function _closeEpoch() private returns (ReserveDelivery status) {
        uint64 epoch = _cursor;
        PrincipalLedgerStateV5 memory p = _principal.settlementState();
        RewardLedgerStateV5 memory r = _rewards.prepareEpoch(epoch);
        if (!p.initialized || p.openedEpoch != epoch || !r.initialized || r.openedEpoch != epoch || r.nextCheckpoint != epoch) revert InvalidEpoch();
        EpochSettlementV5 memory out;
        out.principalSnapshot = p.principalSnapshot; out.protectedRewardSnapshot = r.protectedNaraSnapshot;
        out.reserveSnapshot = _funding.eligibleReserve;
        out.modelFloat = SUPPLY - p.principalSnapshot - r.protectedNaraSnapshot - out.reserveSnapshot;
        out.modelWeight = p.activeModelWeight; out.rewardWeight = p.activeRewardWeight;
        EmissionQuote memory q = _model.calculateNext(_config, _emission, EmissionInputs(out.modelFloat, p.activeModelWeight));
        uint256 maximum = r.naraAdmissionHeadroom < out.reserveSnapshot ? r.naraAdmissionHeadroom : out.reserveSnapshot;
        if (p.activeRewardWeight != 0) {
            // P2.10 (B3, EC-3, MEV-NFT-01): requested = min(target × min(eligible, R_ref) / R_ref, eligible / T, headroom).
            // Identical to today's min(target, headroom, eligible) while eligible ≥ R_ref; the model is untouched.
            uint256 scaled = out.reserveSnapshot < _referenceRelease
                ? q.targetNara * out.reserveSnapshot / _referenceRelease : q.targetNara;
            uint256 tail = out.reserveSnapshot / RELEASE_HORIZON_EPOCHS;
            if (scaled > tail) scaled = tail;
            out.requested = scaled < maximum ? scaled : maximum;
        }
        uint256 beforeEngine = _nara.balanceOf(address(this));
        if (out.requested != 0) (out.delivered, out.status) = _receiveReserve(epoch, out.requested, maximum, beforeEngine);
        if (out.delivered != 0) IERC20(address(_nara)).safeTransfer(address(_rewards), out.delivered);
        if (_nara.balanceOf(address(this)) != beforeEngine) revert InvalidRewardForward();
        // Rewards checks its own pre-delivery baseline and direct authoritative
        // Principal weight. A failed forward/close/open reverts the Reserve call too.
        _rewards.closeEpoch(epoch, out.delivered);
        if (p.activeRewardWeight != 0) {
            // P2.10 (§5.4, A2-05 / AR2-03): sampled only at closes with reward weight, the request condition above;
            // a delivery of 0 at such a close is a genuine zero sample. One packed write per sampled close.
            EmissionReferenceV5 memory e = _reference;
            _reference = EmissionReferenceV5(
                uint96(((REFERENCE_WINDOW - 1) * e.sum + out.delivered) / REFERENCE_WINDOW),
                uint96(((REFERENCE_WINDOW - 1) * e.weight + 1e18) / REFERENCE_WINDOW), e.samples + 1);
        }
        _funding.eligibleReserve -= out.delivered; _funding.cumulativeReleased += out.delivered;
        _emission = q.nextState; out.nextModelState = q.nextState;
        _cursor = epoch + 1;
        uint256 promoted = _fundingAt[_cursor]; delete _fundingAt[_cursor];
        _funding.futureReserve -= promoted; _funding.eligibleReserve += promoted;
        _principal.openBoundary(_cursor); _rewards.openBoundary(_cursor); _assertBoundary();
        emit EpochSettled(epoch, graphHash, out); return out.status;
    }
    function _receiveReserve(uint64 epoch, uint256 requested, uint256 maximum, uint256 beforeBalance)
        private returns (uint256 delivered, ReserveDelivery status)
    {
        _releasing = true; _releaseEpoch = epoch; _releaseMaximum = maximum;
        bytes memory payload = abi.encodeCall(INARAEmissionReserveV5.releaseForEpoch, (epoch, requested));
        address reserve = address(_reserve); uint256 limit = RELEASE_GAS;
        if (gasleft() < RELEASE_MINIMUM_GAS) revert InsufficientReleaseGas();
        bool success; uint256 size;
        assembly ("memory-safe") {
            let output := mload(0x40)
            mstore(output, 0)
            success := call(limit, reserve, 0, add(payload, 32), mload(payload), output, 32)
            size := returndatasize()
            delivered := mload(output)
        }
        _releasing = false; _releaseEpoch = 0; _releaseMaximum = 0;
        uint256 afterBalance = _nara.balanceOf(address(this));
        if (!success) {
            if (afterBalance != beforeBalance) revert InvalidReserveDelivery(); return (0, ReserveDelivery.Failed);
        }
        if (size != 32 || delivered > requested || afterBalance < beforeBalance
            || afterBalance - beforeBalance != delivered) revert InvalidReserveDelivery();
        return (delivered, ReserveDelivery.Succeeded);
    }
    function _assertBoundary() private view {
        PrincipalLedgerStateV5 memory p = _principal.settlementState(); RewardLedgerStateV5 memory r = _rewards.settlementState();
        if (!p.initialized || !r.initialized || p.openedEpoch != _cursor || r.openedEpoch != _cursor
            || r.nextCheckpoint != _cursor || r.receiptPrepared || _releasing
            || _funding.cumulativeRecognized != _funding.eligibleReserve + _funding.futureReserve + _funding.cumulativeReleased
            || p.principalSnapshot + r.protectedNaraSnapshot + _funding.eligibleReserve > SUPPLY) revert InvalidState();
    }
    function _requireSettledSupply() private view { if (_nara.totalSupply() != SUPPLY) revert FlashActive(); }
    function _validateReserve(ReserveState memory s) private view {
        if (s.schemaVersion != 1 || s.nara != address(_nara) || s.core != address(this) || s.genesisFunding != _genesisFunding) revert InvalidState();
    }
    function _validForgeAdapter(address forge, address principal, address rewards, address nft) private view returns (address initialAdapter) {
        (address current, address pending, uint256 nonce) = NARAForgeV5(forge).adapterState();
        initialAdapter = NARAForgeV5(forge).initialAdapter();
        if (INARAForgeIdentityV5(forge).SCHEMA_VERSION() != 1 || current != initialAdapter || pending != address(0) || nonce != 0
            || !_validPeer(initialAdapter) || initialAdapter == principal || initialAdapter == rewards
            || initialAdapter == nft || initialAdapter == forge) revert InvalidState();
    }
    function _validPeer(address peer) private view returns (bool) {
        return peer.code.length != 0 && !(peer.code.length >= 3 && bytes3(peer.code) == 0xef0100)
            && peer != address(this) && peer != address(_nara) && peer != address(_reserve) && peer != address(_model);
    }
}
