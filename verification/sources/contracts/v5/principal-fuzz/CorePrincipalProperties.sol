// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

// TEST-ONLY Echidna harness. Excluded from every production deployment inventory.

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {NARATokenV5} from "../NARATokenV5.sol";
import {NARAEmissionModelV5} from "../engine/NARAEmissionModelV5.sol";
import {NARAEmissionReserveV5} from "../reserve/NARAEmissionReserveV5.sol";
import {CorePrincipalHarness, CorePrincipalNFTStub} from "../principal-test/CorePrincipalTestHelpers.sol";
import {PrincipalAccounting} from "../core/NARACorePrincipalV5.sol";
import {
    AccountingPolicy,
    ActionBlocker,
    AdvanceResult,
    CreateRequest,
    DurationCurve,
    EpochClock,
    ExitPreview,
    PositionState
} from "../interfaces/NARAAccountingTypesV5.sol";

/// @notice Stateful principal lifecycle properties around the real Token, Reserve and Model.
/// @dev Funding demand stays zero. Reward allocation, the full NFT and the final Core graph are outside scope.
contract CorePrincipalProperties is IERC721Receiver {
    uint256 private constant SUPPLY = 1_000_000 ether;
    uint256 private constant INITIAL = 400_000 ether;
    uint256 private constant MAX_ACTION_AMOUNT = 10_000 ether;
    uint256 private constant MAX_TRACKED_POSITIONS = 64;
    uint32 private constant MIN_DURATION = 96;
    uint32 private constant MAX_DURATION = 35_040;
    uint256 private constant COVER_CREATE = 1 << 0;
    uint256 private constant COVER_ADVANCE = 1 << 1;
    uint256 private constant COVER_WITHDRAW = 1 << 2;
    uint256 private constant COVER_EARLY_REJECT = 1 << 3;

    NARAEmissionReserveV5 public immutable reserve;
    NARATokenV5 public immutable token;
    NARAEmissionModelV5 public immutable model;
    CorePrincipalHarness public immutable core;
    CorePrincipalNFTStub public immutable positionNFT;

    uint256[] private _positionIds;
    mapping(uint256 positionId => uint64 applyEpoch) private _withdrawApplyEpoch;
    uint256 private _expectedInventory;
    bool private _violation;
    bytes32 public lastViolation;
    uint256 public createSuccesses;
    uint256 public advanceSuccesses;
    uint256 public withdrawalSuccesses;
    uint256 public earlyWithdrawalRejections;
    uint256 public coverageMask;

    event CampaignCoverage(uint8 indexed action, uint64 wallEpoch, uint64 nextEpoch, uint256 value);

    constructor() {
        reserve = new NARAEmissionReserveV5(address(this), INITIAL);
        token = new NARATokenV5(address(this), address(reserve), "NARA", "NARA");
        reserve.bindToken(address(token));
        model = new NARAEmissionModelV5();
        AccountingPolicy memory initialPolicy = AccountingPolicy({
            policyHash: bytes32(0),
            version: 1,
            epochSeconds: 900,
            rewardIndexScale: 1e27,
            activationDelay: 1,
            minDuration: MIN_DURATION,
            maxDuration: MAX_DURATION,
            durationCurve: DurationCurve.Linear,
            earlyExitEnabled: false,
            earlyExitBps: 0,
            minimumPrincipal: 1,
            maxAdvance: 96,
            rewardAdmissionCap: type(uint256).max / 1e27
        });
        core = new CorePrincipalHarness(
            address(this), address(token), address(reserve), address(model), INITIAL, initialPolicy
        );
        positionNFT = new CorePrincipalNFTStub(address(core));
        core.bindPositionNFT(address(positionNFT));
        reserve.bindCore(address(core));
        core.sealBindings();
        reserve.sealBindings();
        token.transfer(address(reserve), INITIAL);
        reserve.recognizeInitialFunding();
        core.activate();
        token.approve(address(core), type(uint256).max);
    }

    function actionCreate(uint96 amountEntropy, uint32 durationEntropy) external {
        EpochClock memory c = core.clock();
        if (!c.started || c.backlog != 0 || _positionIds.length >= MAX_TRACKED_POSITIONS) return;
        uint256 available = token.balanceOf(address(this));
        uint256 principalHeadroom = SUPPLY - _expectedInventory;
        uint256 upper = available < principalHeadroom ? available : principalHeadroom;
        if (upper > MAX_ACTION_AMOUNT) upper = MAX_ACTION_AMOUNT;
        if (upper == 0) return;
        uint256 amount = uint256(amountEntropy) % upper + 1;
        uint32 selector = durationEntropy % 4;
        uint32 duration = selector == 0 ? 96 : selector == 1 ? 97 : selector == 2 ? 192 : MAX_DURATION;
        CreateRequest memory request = CreateRequest({
            amount: amount,
            duration: duration,
            expectedPolicyHash: core.policy().policyHash,
            deadline: type(uint64).max
        });
        try core.create(request) returns (uint256 id, uint64 generation) {
            if (generation != 1 || id != _positionIds.length + 1) _fail("CREATE_ID");
            _positionIds.push(id);
            _withdrawApplyEpoch[id] = type(uint64).max;
            _expectedInventory += amount;
            ++createSuccesses;
            coverageMask |= COVER_CREATE; // COVERAGE_MARKER: successful exact-receipt create
            emit CampaignCoverage(1, c.wallEpoch, c.nextEpochToClose, amount);
        } catch {
            _fail("CREATE_REVERT");
        }
    }

    function actionAdvance(uint8 entropy) external {
        EpochClock memory c = core.clock();
        if (!c.started || c.backlog == 0) return;
        uint32 count = uint32(entropy) % 96 + 1;
        if (uint64(count) > c.backlog) count = uint32(c.backlog);
        try core.advance(count) returns (AdvanceResult memory) {
            ++advanceSuccesses;
            coverageMask |= COVER_ADVANCE; // COVERAGE_MARKER: principal schedule advancement
            emit CampaignCoverage(2, c.wallEpoch, core.clock().nextEpochToClose, count);
        } catch {
            _fail("ADVANCE_REVERT");
        }
    }

    function actionWithdraw(uint8 entropy) external {
        if (_positionIds.length == 0) return;
        uint256 id = _positionIds[uint256(entropy) % _positionIds.length];
        PositionState memory position = core.position(id, 1);
        if (position.withdrawn) return;
        EpochClock memory c = core.clock();
        ExitPreview memory preview = core.previewWithdraw(address(this), id, 1);
        if (preview.blocker != ActionBlocker.None) return;
        try core.withdrawPrincipal(id, 1, address(this)) returns (uint256 paid) {
            if (paid != position.principal || paid != preview.principalOut) _fail("WITHDRAW_AMOUNT");
            _expectedInventory -= paid;
            _withdrawApplyEpoch[id] = c.wallEpoch + 1;
            ++withdrawalSuccesses;
            coverageMask |= COVER_WITHDRAW; // COVERAGE_MARKER: mature exact-payment withdrawal
            emit CampaignCoverage(3, c.wallEpoch, c.nextEpochToClose, paid);
        } catch {
            _fail("WITHDRAW_REVERT");
        }
    }

    function actionAttemptEarlyWithdraw(uint8 entropy) external {
        if (_positionIds.length == 0) return;
        uint256 id = _positionIds[uint256(entropy) % _positionIds.length];
        PositionState memory beforePosition = core.position(id, 1);
        EpochClock memory c = core.clock();
        if (beforePosition.withdrawn || !c.started || c.wallEpoch >= beforePosition.maturity) return;
        uint256 beforeInventory = _expectedInventory;
        try core.withdrawPrincipal(id, 1, address(this)) returns (uint256) {
            _fail("EARLY_WITHDRAW_SUCCEEDED");
        } catch {
            PositionState memory afterPosition = core.position(id, 1);
            if (afterPosition.withdrawn || _expectedInventory != beforeInventory) _fail("EARLY_WITHDRAW_MUTATED");
            ++earlyWithdrawalRejections;
            coverageMask |= COVER_EARLY_REJECT; // COVERAGE_MARKER: ordinary maturity enforced
            emit CampaignCoverage(4, c.wallEpoch, c.nextEpochToClose, id);
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function coverageCounters() external view returns (uint256 creates, uint256 advances, uint256 withdrawals, uint256 earlyRejects) {
        return (createSuccesses, advanceSuccesses, withdrawalSuccesses, earlyWithdrawalRejections);
    }

    function positionIdsLength() external view returns (uint256) { return _positionIds.length; }

    function echidna_no_oracle_violation() external view returns (bool) { return !_violation; }

    function echidna_supply_is_settled_and_conserved() external view returns (bool) {
        return token.totalSupply() == SUPPLY
            && token.balanceOf(address(this)) + token.balanceOf(address(reserve)) + token.balanceOf(address(core)) == SUPPLY;
    }

    function echidna_principal_balance_and_journal_match() external view returns (bool) {
        PrincipalAccounting memory p = core.principalAccounting();
        if (p.principalInventory != _expectedInventory) return false;
        if (token.balanceOf(address(core)) != p.principalInventory + core.accountedRewards()) return false;
        return int256(p.principalSnapshot) + p.pendingPrincipalDelta == int256(p.principalInventory);
    }

    function echidna_weights_are_common_and_bounded() external view returns (bool) {
        PrincipalAccounting memory p = core.principalAccounting();
        EpochClock memory c = core.clock();
        uint256 expectedWeight;
        uint256 expectedSnapshot;
        for (uint256 i = 0; i < _positionIds.length; ++i) {
            uint256 id = _positionIds[i];
            PositionState memory position = core.position(id, 1);
            if (position.activation <= c.nextEpochToClose && c.nextEpochToClose < position.maturity) {
                expectedWeight += position.modelWeight;
            }
            if (position.createdEpoch + 1 <= c.nextEpochToClose
                && c.nextEpochToClose < _withdrawApplyEpoch[id]) {
                expectedSnapshot += position.principal;
            }
        }
        return p.activeModelWeight == p.activeRewardWeight && p.activeModelWeight <= 4 * SUPPLY
            && p.activeModelWeight == expectedWeight && p.principalSnapshot == expectedSnapshot;
    }

    function echidna_position_and_nft_journals_match() external view returns (bool) {
        PrincipalAccounting memory accounting = core.principalAccounting();
        if (accounting.positionCount != _positionIds.length || positionNFT.mintCount() != _positionIds.length) return false;
        uint256 openPrincipal;
        for (uint256 i = 0; i < _positionIds.length; ++i) {
            uint256 id = _positionIds[i];
            PositionState memory p = core.position(id, 1);
            if (p.generationOwner != address(this) || p.generation != 1 || positionNFT.owners(id) != address(this)
                || p.principal == 0 || p.modelWeight != p.rewardWeight || p.earlyExitEnabled || p.earlyExitBps != 0
                || p.penalty != 0 || p.penaltyCapacityReserved != 0 || p.termsHash == bytes32(0)) return false;
            if (!p.withdrawn) openPrincipal += p.principal;
        }
        return openPrincipal == accounting.principalInventory;
    }

    function _fail(bytes32 code) private { _violation = true; lastViolation = code; }
}
