// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {NARAPrincipalLedgerV5} from "./NARAPrincipalLedgerV5.sol";
import {INARAEpochCoordinatorV5, PrincipalLedgerStateV5, RewardLedgerStateV5, RewardTermsV5,
    RewardAccountingV5} from "./NARAModuleInterfacesV5.sol";
import {RewardAsset} from "../interfaces/NARAAccountingTypesV5.sol";
import {NARARewardCreditLedgerV5, RewardCreditStateV5} from "./NARARewardCreditLedgerV5.sol";

struct RewardAnchorV5 {
    uint64 through;
    uint256 fractionScaled;
    uint256 paid;
}

/// @notice Separate, fixed-asset reward custody and archived-generation claims.
/// @dev Candidate ordinary-maturity semantics. Engine alone orchestrates pulses;
/// Principal supplies positions/weights and the transaction-wide financial lock.
contract NARARewardLedgerV5 {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    uint256 private constant SCALE = 1e27;
    uint256 private constant SUPPLY = 1_000_000 ether;
    uint256 public constant SCHEMA_VERSION = 2;
    uint256 public constant RARITY_SHARE_BPS = 2_000;
    address public immutable engine;
    address public immutable principal;
    address public immutable nara;
    address public immutable usdc;
    address public immutable reserve;
    NARARewardCreditLedgerV5 public immutable creditLedger;
    uint256 public immutable admissionCap;
    bytes32 public immutable bindingHash;
    uint64 public genesisTimestamp;
    bool public initialized;
    uint64 private _openedEpoch;
    uint64 private _nextCheckpoint;
    uint256 private _protectedNaraSnapshot;
    int256 private _pendingNaraDelta;
    bool transient private _receiptPrepared;
    uint256 transient private _receiptBefore;

    RewardAccountingV5[3] private _rewards;
    mapping(uint8 asset => mapping(uint64 epoch => uint256 amount)) private _buckets;
    mapping(uint8 asset => mapping(uint64 boundary => uint256 index)) private _baseIndices;
    mapping(uint8 asset => mapping(uint64 boundary => uint256 index)) private _rarityIndices;
    mapping(uint64 epoch => int256 delta) private _changes;

    error Unauthorized();
    error InvalidState();
    error InvalidEpoch();
    error InvalidTerms();
    error InvalidRecipient();
    error AccountingInProgress();
    error UnsupportedAsset();
    error AdmissionCapacityExceeded();
    error InvalidRewardReceipt();
    error InvalidRewardPayment();
    error FlashActive();
    error RewardCustodyDeficit(RewardAsset asset);

    event Initialized(uint64 genesisTimestamp, bytes32 indexed bindingHash);
    event RewardReceived(RewardAsset indexed asset, address indexed payer, uint64 indexed epoch, uint256 amount);
    event RewardClaimed(uint256 indexed positionId, uint64 indexed generation, RewardAsset indexed asset, address recipient, uint256 amount);
    event PositionCreditCheckpointed(uint256 indexed positionId, uint64 indexed generation, uint64 through);
    event RewardPulseClosed(uint64 indexed epoch, uint256 delivered, uint256 baseWeight, uint256 rarityWeight,
        uint256[3] allocation, uint256[3] baseIndexDelta, uint256[3] rarityIndexDelta);

    constructor(address engine_, address principal_, address usdc_) {
        if (engine_.code.length == 0 || principal_.code.length == 0 || usdc_.code.length == 0
            || engine_ == principal_ || usdc_ == engine_ || usdc_ == principal_ || usdc_ == address(this)) revert InvalidState();
        NARAPrincipalLedgerV5 p = NARAPrincipalLedgerV5(principal_);
        if (p.SCHEMA_VERSION() != 3 || p.engine() != engine_ || p.rewards() != address(this) || p.bindingsSealed()
            || usdc_ == p.nara() || usdc_ == p.reserve() || usdc_ == p.positionNFT()
            || IERC20Metadata(usdc_).decimals() != 6) revert InvalidState();
        engine = engine_; principal = principal_; usdc = usdc_; nara = p.nara(); reserve = p.reserve();
        admissionCap = p.policy().rewardAdmissionCap;
        creditLedger = new NARARewardCreditLedgerV5();
        _rewards[0].token = p.nara(); _rewards[0].decimals = 18;
        _rewards[1].token = address(0); _rewards[1].decimals = 18;
        _rewards[2].token = usdc_; _rewards[2].decimals = 6;
        for (uint8 i; i < 3; ++i) _rewards[i].receiptsEnabled = true;
        bindingHash = keccak256(abi.encode(keccak256("NARA_V5_REWARD_BINDING_V3"), block.chainid,
            engine_, principal_, address(this), p.bindingHash(), p.nara(), p.reserve(), usdc_, uint8(6), admissionCap,
            address(creditLedger), RARITY_SHARE_BPS, SCHEMA_VERSION));
    }

    modifier financialAction() {
        _beginAction();
        _;
        _endAction();
    }
    function _beginAction() private { NARAPrincipalLedgerV5(principal).beginModuleAction(); }
    function _endAction() private { NARAPrincipalLedgerV5(principal).endModuleAction(); }
    modifier coherentRead() {
        _requireCoherent();
        _;
    }
    function _requireCoherent() private view {
        if (NARAPrincipalLedgerV5(principal).moduleLockHolder() != address(0)) revert AccountingInProgress();
    }
    modifier engineCommand() {
        if (msg.sender != engine || NARAPrincipalLedgerV5(principal).moduleLockHolder() != engine) revert Unauthorized();
        _;
    }

    function initialize(uint64 genesis) external engineCommand {
        INARAEpochCoordinatorV5 e = INARAEpochCoordinatorV5(engine);
        (uint64 g, uint64 cursor) = e.principalEpoch();
        NARAPrincipalLedgerV5 p = NARAPrincipalLedgerV5(principal);
        if (initialized || genesis <= block.timestamp || genesis % 900 != 0 || g != genesis || cursor != 0
            || e.rewardBindingHash() != bindingHash || !p.bindingsSealed() || p.genesisTimestamp() != genesis) revert InvalidState();
        initialized = true; genesisTimestamp = genesis;
        emit Initialized(genesis, bindingHash);
    }

    function rewardState() external view coherentRead returns (RewardLedgerStateV5 memory) { return _state(); }
    function settlementState() external view engineCommand returns (RewardLedgerStateV5 memory) { return _state(); }
    function rewardAccounting(RewardAsset asset) external view coherentRead returns (RewardAccountingV5 memory) { return _rewards[uint8(asset)]; }
    function rewardChangesAt(uint64 epoch) external view coherentRead returns (int256) {
        if (epoch < _openedEpoch) revert InvalidEpoch(); return _changes[epoch];
    }
    function rewardBucket(RewardAsset asset, uint64 epoch) external view coherentRead returns (uint256) {
        if (epoch < _nextCheckpoint) revert InvalidEpoch(); return _buckets[uint8(asset)][epoch];
    }
    function indicesAt(RewardAsset asset, uint64 boundary) external view coherentRead
        returns (bool exists, uint256 baseIndex, uint256 rarityIndex) {
        exists = initialized && boundary <= _nextCheckpoint;
        if (exists) {
            baseIndex = _baseIndices[uint8(asset)][boundary];
            rarityIndex = _rarityIndices[uint8(asset)][boundary];
        }
    }
    function claimCredit(uint256 id, uint64 generation, RewardAsset asset) public view coherentRead returns (RewardCreditStateV5 memory) {
        // Validate existence; unknown generations must not masquerade as zero credit.
        NARAPrincipalLedgerV5(principal).rewardTerms(id, generation);
        return creditLedger.credit(id, generation, asset);
    }
    /// @notice Legacy fraction/paid projection. Use claimCredit for full unpaid credit.
    function claimAnchor(uint256 id, uint64 generation, RewardAsset asset) external view returns (RewardAnchorV5 memory) {
        RewardCreditStateV5 memory saved = claimCredit(id, generation, asset);
        return RewardAnchorV5(saved.through, saved.unpaidScaled % SCALE, saved.paid);
    }
    /// @dev Narrow internal graph read: only the immutable credit child, settled indices only.
    function creditIndices(RewardAsset asset, uint64 start, uint64 end) external view
        returns (uint256 baseFrom, uint256 baseTo, uint256 rarityFrom, uint256 rarityTo) {
        if (msg.sender != address(creditLedger)) revert Unauthorized();
        if (!initialized || start > end || end > _nextCheckpoint) revert InvalidEpoch();
        return (_baseIndices[uint8(asset)][start], _baseIndices[uint8(asset)][end],
            _rarityIndices[uint8(asset)][start], _rarityIndices[uint8(asset)][end]);
    }
    /// @notice Materialize all settled credit using Principal's unchanged canonical terms.
    /// @dev No custody, payout or global-liability changes. Future weight transitions must
    /// separately preserve the old weight for any interval not yet settled here.
    function checkpointPosition(uint256 id, uint64 generation) external {
        if (msg.sender != principal || NARAPrincipalLedgerV5(principal).moduleLockHolder() != principal) revert Unauthorized();
        if (_receiptPrepared || _openedEpoch != _nextCheckpoint || _nextCheckpoint != _wall()) revert InvalidState();
        RewardTermsV5 memory terms = NARAPrincipalLedgerV5(principal).rewardTerms(id, generation);
        for (uint8 i; i < 3; ++i) creditLedger.checkpoint(id, generation, RewardAsset(i), terms, _nextCheckpoint);
        emit PositionCreditCheckpointed(id, generation, _nextCheckpoint);
    }

    /// @dev Prepare before Reserve delivery. The later receipt acknowledgement
    /// measures this contract's own exact delta, excluding unsolicited old surplus.
    function prepareEpoch(uint64 epoch) external engineCommand returns (RewardLedgerStateV5 memory) {
        _requireClosingEpoch(epoch);
        if (_receiptPrepared) revert InvalidState();
        _receiptBefore = IERC20(nara).balanceOf(address(this));
        _receiptPrepared = true;
        return _state();
    }
    function closeEpoch(uint64 epoch, uint256 delivered) external engineCommand returns (
        uint256[3] memory allocation, uint256[3] memory baseIndexDelta, uint256[3] memory rarityIndexDelta
    ) {
        _requireClosingEpoch(epoch);
        if (!_receiptPrepared) revert InvalidState();
        uint256 balance = IERC20(nara).balanceOf(address(this));
        if (balance < _receiptBefore || balance - _receiptBefore != delivered) revert InvalidRewardReceipt();
        PrincipalLedgerStateV5 memory p = NARAPrincipalLedgerV5(principal).settlementState();
        if (!p.initialized || p.openedEpoch != epoch) revert InvalidEpoch();
        if ((p.activeModelWeight == 0) != (p.activeRewardWeight == 0)) revert InvalidState();
        RewardAccountingV5 storage n = _rewards[0];
        if (delivered > admissionCap - n.cumulativeAdmitted) revert AdmissionCapacityExceeded();
        n.recordedCustody += delivered; n.cumulativeAdmitted += delivered; n.cumulativeEmissions += delivered;
        _protectedNaraSnapshot += delivered;
        for (uint8 i; i < 3; ++i) {
            RewardAccountingV5 storage l = _rewards[i];
            uint256 bucket = _buckets[i][epoch]; delete _buckets[i][epoch]; l.pendingTotal -= bucket;
            uint256 distribution = bucket + l.banked + (i == 0 ? delivered : 0);
            if (p.activeRewardWeight == 0) l.banked = distribution;
            else {
                uint256 scaled = distribution * SCALE;
                // Aggregate receipts first. Round the rarity tranche down and
                // retain the native-unit remainder in the protected base tranche.
                uint256 rarityAmount = distribution * RARITY_SHARE_BPS / 10_000;
                uint256 baseIncrement = (distribution - rarityAmount) * SCALE / p.activeModelWeight;
                uint256 rarityIncrement = rarityAmount * SCALE / p.activeRewardWeight;
                uint256 assigned = baseIncrement * p.activeModelWeight + rarityIncrement * p.activeRewardWeight;
                l.baseIndex += baseIncrement; l.rarityIndex += rarityIncrement;
                l.owedScaled += assigned; l.quarantinedScaled += scaled - assigned; l.banked = 0;
                allocation[i] = distribution; baseIndexDelta[i] = baseIncrement; rarityIndexDelta[i] = rarityIncrement;
            }
            _baseIndices[i][epoch + 1] = l.baseIndex;
            _rarityIndices[i][epoch + 1] = l.rarityIndex;
            _assertLedger(RewardAsset(i));
        }
        _nextCheckpoint = epoch + 1;
        _receiptPrepared = false; _receiptBefore = 0;
        emit RewardPulseClosed(epoch, delivered, p.activeModelWeight, p.activeRewardWeight,
            allocation, baseIndexDelta, rarityIndexDelta);
    }
    function openBoundary(uint64 epoch) external engineCommand {
        (uint64 g, uint64 cursor) = INARAEpochCoordinatorV5(engine).principalEpoch();
        if (!initialized || _receiptPrepared || epoch != _openedEpoch + 1 || epoch != _nextCheckpoint
            || cursor != epoch || g != genesisTimestamp || epoch > _wall()) revert InvalidEpoch();
        int256 delta = _changes[epoch]; delete _changes[epoch];
        _protectedNaraSnapshot = delta >= 0 ? _protectedNaraSnapshot + uint256(delta) : _protectedNaraSnapshot - uint256(-delta);
        _pendingNaraDelta -= delta; _openedEpoch = epoch; _assertNaraSnapshot();
    }

    function donateETH() external payable financialAction {
        uint64 wall = _admission(msg.value, RewardAsset.ETH);
        if (address(this).balance - msg.value < _rewards[1].recordedCustody) revert RewardCustodyDeficit(RewardAsset.ETH);
        _admit(RewardAsset.ETH, msg.value, wall);
    }
    function donateToken(RewardAsset asset, uint256 amount) external financialAction returns (uint256 received) {
        if (asset == RewardAsset.ETH) revert UnsupportedAsset();
        uint64 wall = _admission(amount, asset); _requireHealthy(asset);
        IERC20 token = IERC20(_rewards[uint8(asset)].token);
        uint256 beforeBalance = token.balanceOf(address(this)); token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 balance = token.balanceOf(address(this));
        if (balance < beforeBalance || balance - beforeBalance != amount) revert InvalidRewardReceipt();
        if (IERC20(nara).totalSupply() != SUPPLY) revert FlashActive();
        received = amount; _admit(asset, amount, wall);
    }
    function claim(uint256 id, uint64 generation, RewardAsset asset, address recipient) external financialAction returns (uint256 paid) {
        if (!initialized) revert InvalidState();
        RewardTermsV5 memory p = NARAPrincipalLedgerV5(principal).rewardTerms(id, generation);
        if (p.owner != msg.sender) revert Unauthorized();
        if (NARAPrincipalLedgerV5(principal).isProtocolSink(recipient)) revert InvalidRecipient();
        paid = creditLedger.consumeClaim(id, generation, asset, p, _nextCheckpoint);
        if (paid != 0) _requireHealthy(asset);
        RewardAccountingV5 storage l = _rewards[uint8(asset)];
        l.owedScaled -= paid * SCALE; l.recordedCustody -= paid; l.cumulativePaid += paid;
        if (asset == RewardAsset.NARA && paid != 0) {
            uint64 wall = _wall(); if (wall == type(uint64).max) revert InvalidEpoch();
            _schedule(wall + 1, -paid.toInt256());
        }
        _assertLedger(asset);
        if (paid != 0) _pay(asset, recipient, paid);
        emit RewardClaimed(id, generation, asset, recipient, paid);
    }

    function _admission(uint256 amount, RewardAsset asset) private view returns (uint64 wall) {
        wall = _wall();
        if (_openedEpoch != wall || _nextCheckpoint != wall) revert InvalidState();
        if (wall == type(uint64).max) revert InvalidEpoch();
        if (amount == 0) revert InvalidTerms();
        if (amount > admissionCap - _rewards[uint8(asset)].cumulativeAdmitted) revert AdmissionCapacityExceeded();
        if (IERC20(nara).totalSupply() != SUPPLY) revert FlashActive();
    }
    function _admit(RewardAsset asset, uint256 amount, uint64 epoch) private {
        RewardAccountingV5 storage l = _rewards[uint8(asset)];
        l.recordedCustody += amount; l.pendingTotal += amount; l.cumulativeAdmitted += amount; l.cumulativeExternal += amount;
        _buckets[uint8(asset)][epoch] += amount;
        if (asset == RewardAsset.NARA) _schedule(epoch + 1, amount.toInt256());
        _assertLedger(asset); emit RewardReceived(asset, msg.sender, epoch, amount);
    }
    function _requireClosingEpoch(uint64 epoch) private view {
        (uint64 g, uint64 cursor) = INARAEpochCoordinatorV5(engine).principalEpoch();
        if (g != genesisTimestamp || epoch != cursor || epoch != _openedEpoch || epoch != _nextCheckpoint || epoch >= _wall()) revert InvalidEpoch();
    }
    function _state() private view returns (RewardLedgerStateV5 memory) {
        return RewardLedgerStateV5(initialized, _openedEpoch, _nextCheckpoint, _protectedNaraSnapshot,
            _pendingNaraDelta, admissionCap - _rewards[0].cumulativeAdmitted, _receiptPrepared);
    }
    function _wall() private view returns (uint64) {
        if (!initialized || block.timestamp < genesisTimestamp) revert InvalidState();
        uint256 value = (block.timestamp - genesisTimestamp) / 900;
        if (value > type(uint64).max) revert InvalidEpoch(); return uint64(value);
    }
    function _schedule(uint64 epoch, int256 delta) private {
        _changes[epoch] += delta; _pendingNaraDelta += delta; _assertNaraSnapshot();
    }
    function _assertNaraSnapshot() private view {
        if (_protectedNaraSnapshot > SUPPLY || _rewards[0].recordedCustody > SUPPLY
            || _protectedNaraSnapshot.toInt256() + _pendingNaraDelta != _rewards[0].recordedCustody.toInt256()) revert InvalidState();
    }
    function _assertLedger(RewardAsset asset) private view {
        RewardAccountingV5 storage l = _rewards[uint8(asset)];
        if (l.cumulativeAdmitted > admissionCap || l.cumulativeAdmitted != l.recordedCustody + l.cumulativePaid
            || l.cumulativeAdmitted != l.cumulativeExternal + l.cumulativeEmissions
            || l.recordedCustody * SCALE != (l.pendingTotal + l.banked) * SCALE + l.owedScaled + l.quarantinedScaled) revert InvalidState();
        if (asset == RewardAsset.NARA) _assertNaraSnapshot();
    }
    function _requireHealthy(RewardAsset asset) private view {
        RewardAccountingV5 storage l = _rewards[uint8(asset)];
        uint256 observed = asset == RewardAsset.ETH ? address(this).balance : IERC20(l.token).balanceOf(address(this));
        if (observed < l.recordedCustody) revert RewardCustodyDeficit(asset);
    }
    function _pay(RewardAsset asset, address recipient, uint256 amount) private {
        if (asset == RewardAsset.ETH) {
            (bool success,) = payable(recipient).call{value: amount}(""); if (!success) revert InvalidRewardPayment();
        } else {
            IERC20 token = IERC20(_rewards[uint8(asset)].token);
            uint256 beforeSource = token.balanceOf(address(this)); uint256 beforeRecipient = token.balanceOf(recipient);
            token.safeTransfer(recipient, amount);
            uint256 afterSource = token.balanceOf(address(this)); uint256 afterRecipient = token.balanceOf(recipient);
            if (afterSource > beforeSource || beforeSource - afterSource != amount
                || afterRecipient < beforeRecipient || afterRecipient - beforeRecipient != amount) revert InvalidRewardPayment();
        }
    }
}
