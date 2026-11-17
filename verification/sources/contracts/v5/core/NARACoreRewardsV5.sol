// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {NARACorePrincipalV5, PrincipalAccounting} from "./NARACorePrincipalV5.sol";
import {CoreFundingState} from "./NARACoreFundingV5.sol";
import {NARAEmissionModelV5} from "../engine/NARAEmissionModelV5.sol";
import {EmissionConfig, EmissionState, EmissionInputs, EmissionQuote} from "../engine/NARAEmissionTypesV5.sol";
import {AccountingPolicy, RewardAsset, RewardAccounting, RewardCredit, PositionState,
    EpochClock, CoreAccounting, EpochOutcome, ReserveDelivery} from "../interfaces/NARAAccountingTypesV5.sol";

struct StoredRewardCredit {
    uint64 through;
    uint256 fractionScaled;
    uint256 paid;
}

/// @notice Three-asset reward kernel over the existing common-alloy principal kernel.
/// @dev Candidate economics, ordinary maturity only. Full NFT validation remains
/// abstract. One inherited guard/cursor/custody owner; no external reward manager.
abstract contract NARACoreRewardsV5 is NARACorePrincipalV5 {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 private constant SCALE = 1e27;
    uint256 private constant SETTLED_SUPPLY = 1_000_000 ether;
    /// @notice Authenticates reward semantics, asset identities, initial model
    /// state/config and the separately scoped principal policy. No NFT binding
    /// or final deployment-graph approval is implied by this constructor hash.
    bytes32 public immutable rewardConfigurationHash;
    EmissionConfig private _config;
    EmissionState private _emission;
    RewardAccounting[3] private _rewards;
    mapping(uint8 asset => mapping(uint64 epoch => uint256 amount)) private _buckets;
    mapping(uint8 asset => mapping(uint64 boundary => uint256 index)) private _indices;
    mapping(uint256 id => mapping(uint64 generation => mapping(uint8 asset => StoredRewardCredit))) private _credits;
    mapping(uint64 epoch => int256 delta) private _rewardChanges;
    uint256 private _protectedRewardSnapshot;
    int256 private _pendingRewardDelta;
    bool private _rewardInitialized;

    error UnsupportedAsset();
    error AdmissionCapacityExceeded();
    error InvalidRewardReceipt();
    error InvalidRewardPayment();
    error RewardCustodyDeficit(RewardAsset asset);

    event RewardConfigurationBound(bytes32 indexed configurationHash, address indexed usdc,
        EmissionConfig config, EmissionState initialState);
    event RewardReceived(RewardAsset indexed asset, address indexed payer, uint64 indexed epoch, uint256 amount);
    event RewardClaimed(uint256 indexed positionId, uint64 indexed generation, RewardAsset indexed asset,
        address recipient, uint256 amount);
    /// @dev policyHash retains its existing principal-policy meaning. The immutable
    /// RewardConfigurationBound event supplies the additional reward identity.
    event EpochClosed(uint64 indexed epoch, bytes32 indexed policyHash, EpochOutcome outcome);

    constructor(address authority, address nara, address reserve, address model, uint256 genesisFunding,
        AccountingPolicy memory principalPolicy, address usdc, EmissionConfig memory config,
        EmissionState memory initialState)
        NARACorePrincipalV5(authority, nara, reserve, model, genesisFunding, principalPolicy)
    {
        if (usdc.code.length == 0 || usdc == nara || usdc == reserve || usdc == model
            || usdc == address(this) || IERC20Metadata(usdc).decimals() != 6) revert InvalidState();
        // Validates the entire coefficient/state envelope without selecting defaults.
        NARAEmissionModelV5(model).calculateNext(config, initialState,
            EmissionInputs(SETTLED_SUPPLY - genesisFunding, 0));
        _config = config;
        _emission = initialState;
        _rewards[0].token = nara; _rewards[0].decimals = 18;
        _rewards[1].token = address(0); _rewards[1].decimals = 18;
        _rewards[2].token = usdc; _rewards[2].decimals = 6;
        for (uint256 i; i < 3; ++i) _rewards[i].receiptsEnabled = true;
        rewardConfigurationHash = keccak256(abi.encode(keccak256("NARA_V5_REWARD_POLICY_V1"),
            block.chainid, address(this), policy().policyHash, nara, reserve, model, usdc, config, initialState));
        emit RewardConfigurationBound(rewardConfigurationHash, usdc, config, initialState);
    }

    function emissionConfig() external view returns (EmissionConfig memory) { return _config; }
    function emissionState() external view coherentFundingRead returns (EmissionState memory) { return _emission; }
    function accounting() external view coherentFundingRead returns (CoreAccounting memory) {
        PrincipalAccounting memory p = _principalView(); CoreFundingState memory f = _fundingView();
        return CoreAccounting(p.principalInventory, p.principalSnapshot, _protectedRewardSnapshot,
            f.eligibleReserve, f.futureReserve, f.lastFundingSequence, p.activeModelWeight,
            p.activeRewardWeight, p.pendingPrincipalDelta, _pendingRewardDelta, false);
    }
    function rewardAccounting(RewardAsset asset) external view coherentFundingRead returns (RewardAccounting memory) {
        return _rewards[uint8(asset)];
    }
    function rewardChangesAt(uint64 epoch) external view coherentFundingRead returns (int256) {
        if (epoch < clock().nextEpochToClose) revert InvalidEpoch();
        return _rewardChanges[epoch];
    }
    function rewardBucket(RewardAsset asset, uint64 epoch) external view coherentFundingRead returns (uint256) {
        if (epoch < clock().nextEpochToClose) revert InvalidEpoch();
        return _buckets[uint8(asset)][epoch];
    }
    function indexAt(RewardAsset asset, uint64 boundary)
        external view coherentFundingRead returns (bool exists, uint256 index)
    {
        exists = _rewardInitialized && boundary <= clock().nextEpochToClose;
        if (exists) index = _indices[uint8(asset)][boundary];
    }
    function credit(uint256 id, uint64 generation, RewardAsset asset)
        external view coherentFundingRead returns (RewardCredit memory)
    { return _creditView(id, generation, asset); }

    /// @dev Explicit receipt only. Forced ETH remains surplus and cannot enter an index.
    function donateETH() external payable nonReentrant {
        EpochClock memory c = _admissionClock(msg.value, RewardAsset.ETH);
        if (address(this).balance - msg.value < _rewards[1].recordedCustody) revert RewardCustodyDeficit(RewardAsset.ETH);
        _admitExternal(RewardAsset.ETH, msg.value, c.wallEpoch);
    }
    function donateToken(RewardAsset asset, uint256 amount) external nonReentrant returns (uint256 received) {
        if (asset == RewardAsset.ETH) revert UnsupportedAsset();
        EpochClock memory c = _admissionClock(amount, asset);
        _requireHealthy(asset);
        IERC20 token = IERC20(_rewards[uint8(asset)].token);
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 afterBalance = token.balanceOf(address(this));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) revert InvalidRewardReceipt();
        // Reject a callback which tries to leave an unsettled NARA flash context.
        if (IERC20(bindings().nara).totalSupply() != SETTLED_SUPPLY) revert FlashActive();
        received = afterBalance - beforeBalance;
        _admitExternal(asset, received, c.wallEpoch);
    }
    function claim(uint256 id, uint64 generation, RewardAsset asset, address recipient)
        external nonReentrant returns (uint256 paid)
    {
        RewardCredit memory c = _creditView(id, generation, asset);
        if (c.generationOwner != msg.sender) revert Unauthorized();
        if (recipient == address(0) || recipient == address(this) || recipient == bindings().reserve) revert InvalidRecipient();
        paid = c.claimable;
        // A zero payout preserves the fraction and advances the owner's anchor
        // without consulting a potentially unavailable external asset.
        if (paid != 0) _requireHealthy(asset);
        StoredRewardCredit storage saved = _credits[id][generation][uint8(asset)];
        saved.through = c.accruedThrough;
        saved.fractionScaled = c.fractionScaled;
        saved.paid += paid;
        RewardAccounting storage l = _rewards[uint8(asset)];
        l.owedScaled -= paid * SCALE;
        l.recordedCustody -= paid;
        l.cumulativePaid += paid;
        if (asset == RewardAsset.NARA && paid != 0) {
            uint64 wall = clock().wallEpoch;
            if (wall == type(uint64).max) revert InvalidEpoch();
            _scheduleReward(wall + 1, -paid.toInt256());
        }
        _assertLedger(asset);
        if (paid != 0) _pay(asset, recipient, paid);
        emit RewardClaimed(id, generation, asset, recipient, paid);
    }

    function _admissionClock(uint256 amount, RewardAsset asset) private view returns (EpochClock memory c) {
        c = clock();
        if (!c.started || c.backlog != 0) revert InvalidState();
        if (c.wallEpoch == type(uint64).max) revert InvalidEpoch();
        if (amount == 0) revert InvalidTerms();
        if (amount > policy().rewardAdmissionCap - _rewards[uint8(asset)].cumulativeAdmitted) revert AdmissionCapacityExceeded();
        if (IERC20(bindings().nara).totalSupply() != SETTLED_SUPPLY) revert FlashActive();
    }
    function _admitExternal(RewardAsset asset, uint256 amount, uint64 epoch) private {
        RewardAccounting storage l = _rewards[uint8(asset)];
        l.recordedCustody += amount; l.pendingTotal += amount;
        l.cumulativeAdmitted += amount; l.cumulativeExternal += amount;
        _buckets[uint8(asset)][epoch] += amount;
        if (asset == RewardAsset.NARA) _scheduleReward(epoch + 1, amount.toInt256());
        _assertLedger(asset);
        emit RewardReceived(asset, msg.sender, epoch, amount);
    }
    function _creditView(uint256 id, uint64 generation, RewardAsset asset) private view returns (RewardCredit memory c) {
        PositionState memory p = _positionView(id, generation);
        StoredRewardCredit storage saved = _credits[id][generation][uint8(asset)];
        EpochClock memory t = clock();
        uint64 start = saved.through > p.activation ? saved.through : p.activation;
        uint64 end = t.nextEpochToClose < p.effectiveEnd ? t.nextEpochToClose : p.effectiveEnd;
        uint256 total = saved.fractionScaled;
        c.accruedThrough = start;
        if (end > start) {
            if (!_rewardInitialized) revert InvalidState();
            // Difference first: absolute index * a new position's weight may overflow.
            total += p.rewardWeight * (_indices[uint8(asset)][end] - _indices[uint8(asset)][start]);
            c.accruedThrough = end;
        }
        c.generationOwner = p.generationOwner; c.generation = generation;
        c.closedCreditScaled = total; c.claimable = total / SCALE; c.fractionScaled = total % SCALE;
        c.cumulativePaid = saved.paid;
        c.pendingThrough = t.wallEpoch < p.effectiveEnd ? t.wallEpoch : p.effectiveEnd;
        uint64 from = p.activation > t.nextEpochToClose ? p.activation : t.nextEpochToClose;
        c.pendingFrom = from < c.pendingThrough ? from : c.pendingThrough;
        c.hasUnsettledEpochs = c.pendingFrom < c.pendingThrough;
        c.openEpochEligible = p.activation <= t.wallEpoch && t.wallEpoch < p.effectiveEnd;
    }
    function _fundingDemand(uint64) internal view override returns (uint256 target, uint256 headroom) {
        EmissionQuote memory q = _quote(_fundingView().eligibleReserve);
        headroom = policy().rewardAdmissionCap - _rewards[0].cumulativeAdmitted;
        if (_principalView().activeRewardWeight != 0) target = q.targetNara;
    }
    function _settleFundingEpoch(uint64 epoch, uint256 eligibleBefore, uint256 requested,
        uint256 delivered, ReserveDelivery status) internal override
    {
        PrincipalAccounting memory p = _principalView();
        EmissionQuote memory q = _quote(eligibleBefore);
        EpochOutcome memory out;
        out.principalSnapshot = p.principalSnapshot; out.protectedRewardSnapshot = _protectedRewardSnapshot;
        out.reserveSnapshot = eligibleBefore; out.modelFloat = _modelFloat(eligibleBefore);
        out.modelWeight = p.activeModelWeight; out.rewardWeight = p.activeRewardWeight;
        out.quote = q; out.reserveRequested = requested; out.reserveDelivered = delivered; out.deliveryStatus = status;
        RewardAccounting storage n = _rewards[0];
        if (delivered > policy().rewardAdmissionCap - n.cumulativeAdmitted) revert AdmissionCapacityExceeded();
        n.recordedCustody += delivered; n.cumulativeAdmitted += delivered; n.cumulativeEmissions += delivered;
        // Internal Reserve-to-reward movement preserves historical combined exclusion.
        _protectedRewardSnapshot += delivered;
        _emission = q.nextState;
        for (uint8 i; i < 3; ++i) {
            RewardAccounting storage l = _rewards[i];
            uint256 bucket = _buckets[i][epoch]; delete _buckets[i][epoch];
            l.pendingTotal -= bucket;
            uint256 distribution = bucket + l.banked + (i == 0 ? delivered : 0);
            if (p.activeRewardWeight == 0) l.banked = distribution;
            else {
                uint256 scaled = distribution * SCALE;
                uint256 increment = scaled / p.activeRewardWeight;
                uint256 assigned = increment * p.activeRewardWeight;
                l.index += increment; l.owedScaled += assigned;
                l.quarantinedScaled += scaled - assigned; l.banked = 0;
                out.grossAllocation[i] = distribution; out.indexDelta[i] = increment;
            }
            _indices[i][epoch + 1] = l.index;
            _assertLedger(RewardAsset(i));
        }
        emit EpochClosed(epoch, policy().policyHash, out);
    }
    function _afterPrincipalOpen(uint64 epoch) internal override {
        if (!_rewardInitialized) {
            if (epoch != 0) revert InvalidEpoch();
            _rewardInitialized = true;
        }
        int256 delta = _rewardChanges[epoch]; delete _rewardChanges[epoch];
        _protectedRewardSnapshot = delta >= 0 ? _protectedRewardSnapshot + uint256(delta)
            : _protectedRewardSnapshot - uint256(-delta);
        _pendingRewardDelta -= delta;
        _assertNaraSnapshot();
    }
    function _quote(uint256 eligible) private view returns (EmissionQuote memory) {
        return NARAEmissionModelV5(bindings().emissionModel).calculateNext(_config, _emission,
            EmissionInputs(_modelFloat(eligible), _principalView().activeModelWeight));
    }
    function _modelFloat(uint256 eligible) private view returns (uint256) {
        return SETTLED_SUPPLY - _principalView().principalSnapshot - eligible - _protectedRewardSnapshot;
    }
    function _scheduleReward(uint64 epoch, int256 delta) private {
        _rewardChanges[epoch] += delta; _pendingRewardDelta += delta;
        _assertNaraSnapshot();
    }
    function _assertNaraSnapshot() private view {
        if (_protectedRewardSnapshot > SETTLED_SUPPLY || _rewards[0].recordedCustody > SETTLED_SUPPLY
            || _protectedRewardSnapshot.toInt256() + _pendingRewardDelta != _rewards[0].recordedCustody.toInt256()) revert InvalidState();
    }
    function _assertLedger(RewardAsset asset) private view {
        RewardAccounting storage l = _rewards[uint8(asset)];
        if (l.cumulativeAdmitted > policy().rewardAdmissionCap
            || l.cumulativeAdmitted != l.recordedCustody + l.cumulativePaid
            || l.cumulativeAdmitted != l.cumulativeExternal + l.cumulativeEmissions
            || l.recordedCustody * SCALE != (l.pendingTotal + l.banked) * SCALE + l.owedScaled + l.quarantinedScaled) revert InvalidState();
        if (asset == RewardAsset.NARA) _assertNaraSnapshot();
    }
    function _requireHealthy(RewardAsset asset) private view {
        RewardAccounting storage l = _rewards[uint8(asset)];
        uint256 protected = l.recordedCustody;
        if (asset == RewardAsset.NARA) protected += _principalView().principalInventory;
        uint256 observed = asset == RewardAsset.ETH ? address(this).balance : IERC20(l.token).balanceOf(address(this));
        if (observed < protected) revert RewardCustodyDeficit(asset);
    }
    function _pay(RewardAsset asset, address recipient, uint256 amount) private {
        if (asset == RewardAsset.ETH) {
            (bool success,) = payable(recipient).call{value: amount}("");
            if (!success) revert InvalidRewardPayment();
        } else {
            IERC20 token = IERC20(_rewards[uint8(asset)].token);
            uint256 beforeCore = token.balanceOf(address(this)); uint256 beforeRecipient = token.balanceOf(recipient);
            token.safeTransfer(recipient, amount);
            uint256 afterCore = token.balanceOf(address(this)); uint256 afterRecipient = token.balanceOf(recipient);
            if (afterCore > beforeCore || beforeCore - afterCore != amount
                || afterRecipient < beforeRecipient || afterRecipient - beforeRecipient != amount) revert InvalidRewardPayment();
        }
    }
}
