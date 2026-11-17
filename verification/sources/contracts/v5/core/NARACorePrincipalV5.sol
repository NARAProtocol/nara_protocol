// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {NARACoreFundingV5, FundingClose} from "./NARACoreFundingV5.sol";
import {AccountingPolicy, DurationCurve, CoreBindings, EpochClock, PositionState,
    CreateRequest, CreatePreview, ExitPreview, ActionBlocker, AdvanceResult, ReserveDelivery}
    from "../interfaces/NARAAccountingTypesV5.sol";

/// @dev Candidate mint boundary only; the full thin NFT remains a separate stage.
interface IPrincipalPositionNFT {
    function core() external view returns (address);
    function mint(address owner, uint256 positionId) external;
}

struct PrincipalAccounting {
    bool initialized;
    uint64 openedEpoch;
    uint256 principalInventory;
    uint256 principalSnapshot;
    uint256 activeModelWeight;
    uint256 activeRewardWeight;
    int256 pendingPrincipalDelta;
    uint256 positionCount;
}

struct PrincipalEpochChanges {
    int256 principalDelta;
    int256 modelWeightDelta;
    int256 rewardWeightDelta;
}

/// @notice Abstract principal kernel. Reward settlement and the full NFT are not implemented.
/// @dev Common alloy, generation one, ordinary maturity only. No early-exit rights
///      are granted by this slice. The inherited guard and cursor are authoritative.
abstract contract NARACorePrincipalV5 is NARACoreFundingV5 {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 private constant NARA_FIXED_SUPPLY = 1_000_000 ether;
    uint256 private constant WAD = 1e18;
    uint256 private constant RAY = 1e27;
    bytes32 private constant POLICY_DOMAIN = keccak256("NARA_V5_PRINCIPAL_POLICY_V1");
    bytes32 private constant TERMS_DOMAIN = keccak256("NARA_V5_PRINCIPAL_TERMS_V1");

    AccountingPolicy private _policy;
    PrincipalAccounting private _principal;
    mapping(uint64 epoch => PrincipalEpochChanges changes) private _changes;
    mapping(uint256 id => mapping(uint64 generation => PositionState state)) private _positions;

    error InvalidPolicy();
    error InvalidTerms();
    error CreateBlocked(ActionBlocker blocker);
    error InvalidPrincipalReceipt();
    error InvalidPrincipalPayment();
    error UnknownGeneration();
    error InvalidRecipient();

    event PositionCreated(uint256 indexed positionId, uint64 indexed generation, address indexed owner, PositionState position);
    event PrincipalWithdrawn(uint256 indexed positionId, uint64 indexed generation, address indexed recipient, uint256 amount);

    constructor(address authority, address nara, address reserve, address model, uint256 genesisFunding,
        AccountingPolicy memory initialPolicy)
        NARACoreFundingV5(authority, nara, reserve, model, genesisFunding)
    {
        // A zero input hash has one canonical encoding; never accept a supplied
        // hash that purports to authenticate different constructor fields.
        if (initialPolicy.policyHash != bytes32(0) || initialPolicy.version != 1
            || initialPolicy.epochSeconds != 900 || initialPolicy.rewardIndexScale != RAY
            || initialPolicy.activationDelay == 0 || initialPolicy.activationDelay >= 35_040
            || initialPolicy.minDuration != 96 || initialPolicy.maxDuration != 35_040
            || initialPolicy.earlyExitEnabled || initialPolicy.earlyExitBps != 0
            || initialPolicy.minimumPrincipal == 0 || initialPolicy.minimumPrincipal > NARA_FIXED_SUPPLY
            || initialPolicy.maxAdvance == 0 || initialPolicy.maxAdvance > 96
            || initialPolicy.rewardAdmissionCap == 0 || initialPolicy.rewardAdmissionCap > type(uint256).max / RAY) {
            revert InvalidPolicy();
        }
        // Candidate identity for this AccountingPolicy tuple, not a hash of the
        // still-unimplemented emission/reward configuration or final Core graph.
        initialPolicy.policyHash = keccak256(abi.encode(POLICY_DOMAIN, block.chainid, address(this), initialPolicy));
        _policy = initialPolicy;
    }

    function policy() public view override returns (AccountingPolicy memory) { return _policy; }

    function principalAccounting() external view coherentFundingRead returns (PrincipalAccounting memory) {
        return _principal;
    }

    /// @notice Principal schedules only. No fabricated reward/funding fields.
    function principalChangesAt(uint64 epoch) external view coherentFundingRead returns (PrincipalEpochChanges memory) {
        if (epoch < clock().nextEpochToClose) revert InvalidEpoch();
        return _changes[epoch];
    }

    function position(uint256 id, uint64 generation) external view coherentFundingRead returns (PositionState memory) {
        return _positionView(id, generation);
    }

    function previewCreate(address caller, CreateRequest calldata request)
        external view coherentFundingRead returns (CreatePreview memory)
    { return _previewCreate(caller, request); }

    function previewWithdraw(address caller, uint256 id, uint64 generation)
        external view coherentFundingRead returns (ExitPreview memory p)
    {
        PositionState storage s = _positions[id][generation];
        if (s.generationOwner == address(0)) { p.blocker = ActionBlocker.UnknownGeneration; return p; }
        p.effectiveEnd = s.effectiveEnd;
        if (caller != s.generationOwner) p.blocker = ActionBlocker.NotOwner;
        else if (s.withdrawn) p.blocker = ActionBlocker.AlreadyWithdrawn;
        else if (!clock().started) p.blocker = ActionBlocker.NotStarted;
        else if (clock().wallEpoch < s.maturity) p.blocker = ActionBlocker.NotMature;
        else if (clock().wallEpoch == type(uint64).max) p.blocker = ActionBlocker.InvalidTerms;
        else p.principalOut = s.principal;
    }

    function create(CreateRequest calldata request) external nonReentrant returns (uint256 id, uint64 generation) {
        CreatePreview memory p = _previewCreate(msg.sender, request);
        if (p.blocker != ActionBlocker.None) revert CreateBlocked(p.blocker);
        IERC20 token = IERC20(bindings().nara);
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), request.amount);
        uint256 afterBalance = token.balanceOf(address(this));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != request.amount) revert InvalidPrincipalReceipt();
        if (token.totalSupply() != NARA_FIXED_SUPPLY) revert FlashActive();

        uint64 createdEpoch = clock().wallEpoch;
        id = ++_principal.positionCount;
        generation = 1;
        PositionState memory s;
        s.generationOwner = msg.sender; s.generation = generation; s.createdEpoch = createdEpoch;
        s.activation = p.activation; s.maturity = p.maturity; s.effectiveEnd = p.maturity;
        s.duration = request.duration; s.principal = request.amount;
        s.modelWeight = p.modelWeight; s.rewardWeight = p.rewardWeight;
        // Hash the full initial record with a canonical zero termsHash. It stays
        // immutable when the live withdrawn flag changes; hash the original record.
        s.termsHash = keccak256(abi.encode(TERMS_DOMAIN, block.chainid, address(this), _policy.policyHash, id, s));
        _positions[id][generation] = s;
        _principal.principalInventory += request.amount;
        _schedulePrincipal(createdEpoch + 1, request.amount.toInt256());
        _scheduleWeight(p.activation, p.modelWeight.toInt256());
        _scheduleWeight(p.maturity, -p.modelWeight.toInt256());
        _assertPrincipalBounds();
        // The mint must use this exact id/owner under the same financial guard.
        // Rejected or reentrant receiver calls revert token receipt and all effects.
        IPrincipalPositionNFT(bindings().positionNFT).mint(msg.sender, id);
        emit PositionCreated(id, generation, msg.sender, s);
    }

    function withdrawPrincipal(uint256 id, uint64 generation, address recipient)
        external nonReentrant returns (uint256 paid)
    {
        PositionState storage s = _positions[id][generation];
        if (s.generationOwner == address(0)) revert UnknownGeneration();
        if (s.generationOwner != msg.sender) revert Unauthorized();
        CoreBindings memory b = bindings();
        if (recipient == address(0) || recipient == address(this) || recipient == b.reserve) revert InvalidRecipient();
        EpochClock memory c = clock();
        if (!c.started || c.wallEpoch < s.maturity || s.withdrawn) revert InvalidState();
        if (c.wallEpoch == type(uint64).max) revert InvalidEpoch();
        paid = s.principal;
        s.withdrawn = true;
        _principal.principalInventory -= paid;
        _schedulePrincipal(c.wallEpoch + 1, -paid.toInt256());
        _assertPrincipalBounds();
        // Only the bound NARA token is consulted: no reward, NFT, model, Reserve
        // or settled-supply dependency can block an otherwise earned principal exit.
        IERC20 token = IERC20(b.nara);
        uint256 beforeBalance = token.balanceOf(address(this));
        uint256 beforeRecipient = token.balanceOf(recipient);
        token.safeTransfer(recipient, paid);
        uint256 afterBalance = token.balanceOf(address(this));
        uint256 afterRecipient = token.balanceOf(recipient);
        if (afterBalance > beforeBalance || beforeBalance - afterBalance != paid
            || afterRecipient < beforeRecipient || afterRecipient - beforeRecipient != paid) revert InvalidPrincipalPayment();
        emit PrincipalWithdrawn(id, generation, recipient, paid);
    }

    function advance(uint32 maxEpochs) external nonReentrant returns (AdvanceResult memory r) {
        if (maxEpochs == 0 || maxEpochs > _policy.maxAdvance) revert InvalidTerms();
        EpochClock memory c = clock();
        if (!c.started) revert InvalidState();
        // Even an empty advance cannot disguise an active flash context as success.
        if (IERC20(bindings().nara).totalSupply() != NARA_FIXED_SUPPLY) revert FlashActive();
        r.fromEpoch = c.nextEpochToClose;
        while (r.closedCount < maxEpochs && clock().nextEpochToClose < c.wallEpoch) {
            FundingClose memory closed = _closeFundingEpoch();
            if (closed.status == ReserveDelivery.Failed) ++r.failedReserveCalls;
            ++r.closedCount;
        }
        r.nextEpochToClose = clock().nextEpochToClose;
        r.remainingBacklog = c.wallEpoch - r.nextEpochToClose;
    }

    function _previewCreate(address caller, CreateRequest calldata request) private view returns (CreatePreview memory p) {
        p.policyHash = _policy.policyHash;
        CoreBindings memory b = bindings(); EpochClock memory c = clock();
        if (!b.bindingsSealed) { p.blocker = ActionBlocker.NotSealed; return p; }
        if (!c.started) { p.blocker = ActionBlocker.NotStarted; return p; }
        if (c.backlog != 0) { p.blocker = ActionBlocker.CoreStale; return p; }
        if (caller == address(0) || caller == address(this) || caller == b.reserve
            || request.expectedPolicyHash != _policy.policyHash || block.timestamp > request.deadline
            || request.amount < _policy.minimumPrincipal || request.amount > NARA_FIXED_SUPPLY
            || request.duration < _policy.minDuration || request.duration > _policy.maxDuration
            || request.amount > NARA_FIXED_SUPPLY - _principal.principalInventory) {
            p.blocker = ActionBlocker.InvalidTerms; return p;
        }
        uint256 activation = uint256(c.wallEpoch) + _policy.activationDelay;
        uint256 maturity = activation + request.duration;
        if (maturity > type(uint64).max) { p.blocker = ActionBlocker.InvalidTerms; return p; }
        IERC20 token = IERC20(b.nara);
        if (token.totalSupply() != NARA_FIXED_SUPPLY) { p.blocker = ActionBlocker.FlashActive; return p; }
        if (token.balanceOf(caller) < request.amount) { p.blocker = ActionBlocker.InsufficientBalance; return p; }
        if (token.allowance(caller, address(this)) < request.amount) { p.blocker = ActionBlocker.InsufficientAllowance; return p; }
        p.activation = uint64(activation); p.maturity = uint64(maturity);
        uint256 multiplier;
        if (_policy.durationCurve == DurationCurve.Linear) {
            multiplier = WAD + 3 * WAD * (request.duration - 96) / 34_944;
        } else {
            uint256 ratio = uint256(request.duration) * WAD / 35_040;
            multiplier = WAD + (WAD / 2) * ratio / WAD + (5 * WAD / 2) * (ratio * ratio / WAD) / WAD;
        }
        // principal <= supply, multiplier <= 4 WAD, so these direct products fit.
        p.modelWeight = request.amount * multiplier / WAD;
        p.rewardWeight = p.modelWeight;
    }

    function _validatePositionNFT(address nft) internal view override {
        if (IPrincipalPositionNFT(nft).core() != address(this)) revert InvalidState();
        _validatePrincipalNFT(nft);
    }

    /// @dev Non-virtual template: reward integration cannot forget principal opening.
    function _openFundingEpoch(uint64 epoch) internal override {
        if (!_reentrancyGuardEntered() || epoch != clock().nextEpochToClose) revert InvalidState();
        if (_principal.initialized ? epoch != _principal.openedEpoch + 1 : epoch != 0) revert InvalidEpoch();
        _principal.initialized = true; _principal.openedEpoch = epoch;
        PrincipalEpochChanges memory delta = _changes[epoch]; delete _changes[epoch];
        _principal.principalSnapshot = _applyDelta(_principal.principalSnapshot, delta.principalDelta);
        _principal.pendingPrincipalDelta -= delta.principalDelta;
        _principal.activeModelWeight = _applyDelta(_principal.activeModelWeight, delta.modelWeightDelta);
        _principal.activeRewardWeight = _applyDelta(_principal.activeRewardWeight, delta.rewardWeightDelta);
        _assertPrincipalBounds();
        _afterPrincipalOpen(epoch);
    }

    function _schedulePrincipal(uint64 epoch, int256 delta) private {
        _changes[epoch].principalDelta += delta;
        _principal.pendingPrincipalDelta += delta;
    }

    function _scheduleWeight(uint64 epoch, int256 delta) private {
        _changes[epoch].modelWeightDelta += delta;
        _changes[epoch].rewardWeightDelta += delta;
    }

    function _applyDelta(uint256 value, int256 delta) private pure returns (uint256) {
        return delta >= 0 ? value + uint256(delta) : value - uint256(-delta);
    }

    function _assertPrincipalBounds() private view {
        if (_principal.principalInventory > NARA_FIXED_SUPPLY || _principal.principalSnapshot > NARA_FIXED_SUPPLY
            || _principal.activeModelWeight > 4 * NARA_FIXED_SUPPLY || _principal.activeRewardWeight != _principal.activeModelWeight
            || _principal.principalSnapshot.toInt256() + _principal.pendingPrincipalDelta != _principal.principalInventory.toInt256()) {
            revert InvalidState();
        }
    }

    function _principalView() internal view returns (PrincipalAccounting memory) { return _principal; }
    function _positionView(uint256 id, uint64 generation) internal view returns (PositionState memory s) {
        s = _positions[id][generation];
        if (s.generationOwner == address(0)) revert UnknownGeneration();
    }

    /// @dev Reward/checkpoint opening remains mandatory, unimplemented in this slice.
    function _afterPrincipalOpen(uint64 epoch) internal virtual;
    /// @dev Final NFT schema/lifecycle validation must be consciously implemented by
    ///      each concrete Core; reciprocal getters alone are not mint authentication.
    function _validatePrincipalNFT(address nft) internal view virtual;
}
