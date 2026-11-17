// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

// TEST-ONLY Echidna harness. This file is excluded from every production deployment inventory.

import {NARATokenV5} from "../NARATokenV5.sol";
import {NARAEmissionModelV5} from "../engine/NARAEmissionModelV5.sol";
import {NARAEmissionReserveV5} from "../reserve/NARAEmissionReserveV5.sol";
import {CoreFundingHarness, CoreFundingPositionNFTStub}
    from "../core-test/CoreFundingTestHelpers.sol";
import {CoreFundingState, FundingClose} from "../core/NARACoreFundingV5.sol";
import {CoreBindings, EpochClock, ReserveDelivery, ReserveState}
    from "../interfaces/NARAAccountingTypesV5.sol";

/// @title Echidna properties for the v5 Core funding boundary
/// @notice Deploys the real token, Reserve and model around the bounded test Core.
/// @dev The Core economic hooks and NFT are deterministic fixtures. These properties
///      cover funding chronology and custody, not the future full Core implementation.
contract CoreFundingProperties {
    uint256 private constant SUPPLY = 1_000_000 ether;
    uint256 private constant INITIAL = 400_000 ether;
    uint256 private constant MAX_ACTION_AMOUNT = 10_000 ether;
    uint32 private constant MAX_ACTION_CLOSES = 4;
    uint256 private constant MAX_HISTORY = 256;
    uint256 private constant COVER_FUND = 1 << 0;
    uint256 private constant COVER_DONATION = 1 << 1;
    uint256 private constant COVER_SYNC = 1 << 2;
    uint256 private constant COVER_ADVANCE = 1 << 3;
    uint256 private constant COVER_ROLLBACK = 1 << 4;
    uint256 private constant COVER_FUTURE_PROTECTION = 1 << 5;
    bytes4 private constant FORCED_SETTLEMENT_FAILURE =
        bytes4(keccak256("ForcedSettlementFailure()"));

    struct FundingEntry {
        uint256 sequence;
        uint64 wallAtRecognition;
        uint64 eligibleEpoch;
        uint256 amount;
        bool directSync;
    }

    NARAEmissionReserveV5 public immutable reserve;
    NARATokenV5 public immutable token;
    NARAEmissionModelV5 public immutable model;
    CoreFundingHarness public immutable core;
    CoreFundingPositionNFTStub public immutable positionNFT;

    FundingEntry[] private _history;
    mapping(uint64 eligibleEpoch => uint256 amount) private _expectedBucket;

    uint256 private _expectedEligible = INITIAL;
    uint256 private _expectedFuture;
    uint256 private _expectedSequence = 1;
    uint256 private _expectedRecognized = INITIAL;
    uint256 private _expectedReleased;
    uint256 private _expectedUnsynced;
    uint64 private _expectedNextEpoch;
    bool private _violation;
    bytes32 public lastViolation;

    uint256 public fundAttempts;
    uint256 public fundSuccesses;
    uint256 public donationSuccesses;
    uint256 public syncAttempts;
    uint256 public syncSuccesses;
    uint256 public advanceAttempts;
    uint256 public advanceSuccesses;
    uint256 public closeChecks;
    uint256 public futureProtectionChecks;
    uint256 public rollbackChecks;
    uint256 public coverageMask;

    event CampaignCoverage(uint8 indexed action, uint64 wallEpoch, uint64 nextEpoch, uint256 amount);

    constructor() {
        reserve = new NARAEmissionReserveV5(address(this), INITIAL);
        token = new NARATokenV5(address(this), address(reserve), "NARA", "NARA");
        reserve.bindToken(address(token));
        model = new NARAEmissionModelV5();
        core = new CoreFundingHarness(address(this), address(token), address(reserve), address(model), INITIAL);
        positionNFT = new CoreFundingPositionNFTStub(address(core));

        core.bindPositionNFT(address(positionNFT));
        reserve.bindCore(address(core));
        core.sealBindings();
        reserve.sealBindings();
        token.transfer(address(reserve), INITIAL);
        reserve.recognizeInitialFunding();
        core.activate();
        token.approve(address(reserve), type(uint256).max);

        _history.push(FundingEntry({
            sequence: 1,
            wallAtRecognition: 0,
            eligibleEpoch: 0,
            amount: INITIAL,
            directSync: false
        }));
    }

    /// @notice Exercises pull funding. Before genesis, failure is required and atomic.
    function actionFund(uint96 entropy) external {
        ++fundAttempts;
        uint256 amount = _boundedAmount(entropy);
        if (amount == 0 || _history.length >= MAX_HISTORY) return;
        EpochClock memory beforeClock = core.clock();
        uint256 beforeBalance = token.balanceOf(address(this));
        uint256 beforeAllowance = token.allowance(address(this), address(reserve));
        try reserve.fund(amount) returns (uint256 received, uint256 sequence, uint64 eligibleEpoch) {
            if (!beforeClock.started) {
                _fail("FUND_BEFORE_START");
                return;
            }
            if (received != amount) _fail("FUND_RECEIPT");
            _recordFunding(sequence, beforeClock.wallEpoch, eligibleEpoch, received, false);
            ++fundSuccesses;
            coverageMask |= COVER_FUND; // COVERAGE_MARKER: successful pull funding
            emit CampaignCoverage(1, beforeClock.wallEpoch, _expectedNextEpoch, received);
        } catch {
            if (beforeClock.started) _fail("FUND_REVERT");
            if (token.balanceOf(address(this)) != beforeBalance
                || token.allowance(address(this), address(reserve)) != beforeAllowance) {
                _fail("FUND_ROLLBACK");
            }
        }
    }

    /// @notice Sends an unrecognized direct donation for later permissionless sync.
    function actionDonate(uint96 entropy) external {
        uint256 amount = _boundedAmount(entropy);
        if (amount == 0) return;
        if (!token.transfer(address(reserve), amount)) {
            _fail("DONATION_TRANSFER");
            return;
        }
        _expectedUnsynced += amount;
        ++donationSuccesses;
        coverageMask |= COVER_DONATION; // COVERAGE_MARKER: direct donation
        EpochClock memory c = core.clock();
        emit CampaignCoverage(2, c.wallEpoch, _expectedNextEpoch, amount);
    }

    /// @notice Recognizes the complete unsynced surplus at the actual wall plus one.
    function actionSync() external {
        ++syncAttempts;
        if (_history.length >= MAX_HISTORY && _expectedUnsynced != 0) return;
        EpochClock memory beforeClock = core.clock();
        try reserve.syncFunding() returns (uint256 received, uint256 sequence, uint64 eligibleEpoch) {
            if (!beforeClock.started) {
                _fail("SYNC_BEFORE_START");
                return;
            }
            if (received == 0) {
                if (_expectedUnsynced != 0 || sequence != _expectedSequence || eligibleEpoch != 0) {
                    _fail("SYNC_ZERO");
                }
                emit CampaignCoverage(3, beforeClock.wallEpoch, _expectedNextEpoch, 0);
                return;
            }
            if (received != _expectedUnsynced) _fail("SYNC_RECEIPT");
            _recordFunding(sequence, beforeClock.wallEpoch, eligibleEpoch, received, true);
            _expectedUnsynced = 0;
            ++syncSuccesses;
            coverageMask |= COVER_SYNC; // COVERAGE_MARKER: positive surplus sync
            emit CampaignCoverage(3, beforeClock.wallEpoch, _expectedNextEpoch, received);
        } catch {
            if (beforeClock.started) _fail("SYNC_REVERT");
        }
    }

    /// @notice Closes at most four available epochs and requests every eligible unit.
    /// @dev Full requests make the history partition independently checkable:
    ///      eligibility below/current/above the cursor equals released/eligible/future.
    function actionAdvance(uint8 entropy) external {
        ++advanceAttempts;
        EpochClock memory c = core.clock();
        if (!c.started || c.backlog == 0) return;
        uint32 count = uint32(entropy) % MAX_ACTION_CLOSES + 1;
        if (uint64(count) > c.backlog) count = uint32(c.backlog);

        for (uint32 i = 0; i < count; ++i) {
            core.setDemand(_expectedNextEpoch + uint64(i), SUPPLY, SUPPLY);
        }

        try core.advanceForTest(count) returns (uint32 closed) {
            if (closed != count) _fail("ADVANCE_COUNT");
            for (uint32 i = 0; i < count; ++i) _applySuccessfulClose();
            ++advanceSuccesses;
            coverageMask |= COVER_ADVANCE; // COVERAGE_MARKER: bounded successful advance
            emit CampaignCoverage(4, c.wallEpoch, _expectedNextEpoch, count);
        } catch {
            _fail("ADVANCE_REVERT");
        }
    }

    /// @notice Forces a post-delivery settlement revert and checks whole-call rollback.
    function actionSettlementRollback() external {
        EpochClock memory c = core.clock();
        if (!c.started || c.backlog == 0) return;
        core.setDemand(_expectedNextEpoch, SUPPLY, SUPPLY);
        bytes32 beforeSnapshot = _snapshot();
        core.setHookFailures(false, true, false);
        bool sawExpectedFailure;
        try core.advanceForTest(1) returns (uint32) {
            _fail("ROLLBACK_SUCCEEDED");
        } catch (bytes memory reason) {
            if (_errorSelector(reason) != FORCED_SETTLEMENT_FAILURE) {
                _fail("ROLLBACK_REASON");
            } else {
                sawExpectedFailure = true;
            }
        }
        core.setHookFailures(false, false, false);
        if (_snapshot() != beforeSnapshot) _fail("ROLLBACK_STATE");
        if (sawExpectedFailure) {
            ++rollbackChecks;
            coverageMask |= COVER_ROLLBACK; // COVERAGE_MARKER: exact settlement rollback
        }
        emit CampaignCoverage(5, c.wallEpoch, _expectedNextEpoch, _expectedEligible);
    }

    function coverageCounters() external view returns (
        uint256 fundingAttempts,
        uint256 fundingSuccesses,
        uint256 donations,
        uint256 synchronizationAttempts,
        uint256 synchronizationSuccesses,
        uint256 advancementAttempts,
        uint256 advancementSuccesses,
        uint256 closes,
        uint256 protectedFutureCloses,
        uint256 rollbackPaths
    ) {
        return (fundAttempts, fundSuccesses, donationSuccesses, syncAttempts, syncSuccesses,
            advanceAttempts, advanceSuccesses, closeChecks, futureProtectionChecks, rollbackChecks);
    }

    function fundingHistoryLength() external view returns (uint256) {
        return _history.length;
    }

    function fundingHistoryAt(uint256 index) external view returns (FundingEntry memory) {
        return _history[index];
    }

    function expectedBucketAt(uint64 eligibleEpoch) external view returns (uint256) {
        return _expectedBucket[eligibleEpoch];
    }

    function echidna_no_oracle_violation() external view returns (bool) {
        return !_violation;
    }

    function echidna_supply_is_settled_and_conserved() external view returns (bool) {
        if (token.totalSupply() != SUPPLY) return false;
        return token.balanceOf(address(this)) + token.balanceOf(address(reserve))
            + token.balanceOf(address(core)) == SUPPLY;
    }

    function echidna_custody_is_exact() external view returns (bool) {
        (uint256 observed, uint256 recognizedUnreleased, uint256 unsynced, uint256 deficit) =
            reserve.custody();
        if (deficit != 0 || observed != token.balanceOf(address(reserve))) return false;
        if (recognizedUnreleased != _expectedRecognized - _expectedReleased) return false;
        return unsynced == _expectedUnsynced && observed == recognizedUnreleased + unsynced;
    }

    function echidna_core_and_reserve_journals_match() external view returns (bool) {
        CoreFundingState memory f = core.fundingState();
        ReserveState memory r = reserve.state();
        if (!f.initialFundingRecognized || !r.initialFundingRecognized) return false;
        if (f.lastFundingSequence != r.fundingSequence
            || f.cumulativeRecognized != r.cumulativeRecognized
            || f.cumulativeReleased != r.cumulativeReleased) return false;
        if (f.eligibleReserve + f.futureReserve + f.cumulativeReleased != f.cumulativeRecognized) {
            return false;
        }
        return r.cumulativeRecognized - r.cumulativeReleased
            == token.balanceOf(address(reserve)) - _expectedUnsynced;
    }

    function echidna_oracle_matches_core_state() external view returns (bool) {
        CoreFundingState memory f = core.fundingState();
        EpochClock memory c = core.clock();
        return f.eligibleReserve == _expectedEligible
            && f.futureReserve == _expectedFuture
            && f.lastFundingSequence == _expectedSequence
            && f.cumulativeRecognized == _expectedRecognized
            && f.cumulativeReleased == _expectedReleased
            && c.nextEpochToClose == _expectedNextEpoch
            && core.accountedNara() == _expectedReleased;
    }

    function echidna_funding_history_has_no_early_capture() external view returns (bool) {
        uint256 releasedPartition;
        uint256 eligiblePartition;
        uint256 futurePartition;
        uint256 recognized;
        for (uint256 i = 0; i < _history.length; ++i) {
            FundingEntry memory entry = _history[i];
            if (entry.sequence != i + 1) return false;
            if (i == 0) {
                if (entry.eligibleEpoch != 0 || entry.amount != INITIAL || entry.directSync) return false;
            } else if (entry.eligibleEpoch != entry.wallAtRecognition + 1) {
                return false;
            }
            if (entry.eligibleEpoch >= _expectedNextEpoch
                && core.reserveFundingAt(entry.eligibleEpoch) != _expectedBucket[entry.eligibleEpoch]) {
                return false;
            }
            recognized += entry.amount;
            if (entry.eligibleEpoch < _expectedNextEpoch) releasedPartition += entry.amount;
            else if (entry.eligibleEpoch == _expectedNextEpoch) eligiblePartition += entry.amount;
            else futurePartition += entry.amount;
        }
        return recognized == _expectedRecognized
            && releasedPartition == _expectedReleased
            && eligiblePartition == _expectedEligible
            && futurePartition == _expectedFuture;
    }

    function echidna_graph_remains_sealed() external view returns (bool) {
        CoreBindings memory b = core.bindings();
        ReserveState memory r = reserve.state();
        return b.bindingsSealed && b.activated && b.bootstrapAuthority == address(0)
            && b.nara == address(token) && b.reserve == address(reserve)
            && b.emissionModel == address(model) && b.positionNFT == address(positionNFT)
            && r.bindingsSealed && r.bootstrapAuthority == address(0) && r.core == address(core)
            && r.nara == address(token);
    }

    function _recordFunding(
        uint256 sequence,
        uint64 wallEpoch,
        uint64 eligibleEpoch,
        uint256 amount,
        bool directSync
    ) private {
        if (amount == 0 || sequence != _expectedSequence + 1 || eligibleEpoch != wallEpoch + 1) {
            _fail("FUNDING_METADATA");
            return;
        }
        _expectedSequence = sequence;
        _expectedRecognized += amount;
        _expectedFuture += amount;
        _expectedBucket[eligibleEpoch] += amount;
        _history.push(FundingEntry(sequence, wallEpoch, eligibleEpoch, amount, directSync));
    }

    function _applySuccessfulClose() private {
        uint64 epoch = _expectedNextEpoch;
        uint256 requested = _expectedEligible;
        if (_expectedFuture != 0) {
            ++futureProtectionChecks;
            coverageMask |= COVER_FUTURE_PROTECTION; // COVERAGE_MARKER: future funds protected
        }
        FundingClose memory result = core.settlementAt(epoch);
        if (result.epoch != epoch || result.eligibleBefore != _expectedEligible
            || result.requested != requested || result.delivered != requested
            || result.status != (requested == 0 ? ReserveDelivery.NotRequested : ReserveDelivery.Succeeded)) {
            _fail("CLOSE_RECEIPT");
        }
        _expectedReleased += requested;
        _expectedEligible = 0;
        ++_expectedNextEpoch;
        uint256 promoted = _expectedBucket[_expectedNextEpoch];
        delete _expectedBucket[_expectedNextEpoch];
        _expectedFuture -= promoted;
        _expectedEligible = promoted;
        ++closeChecks;
    }

    function _boundedAmount(uint96 entropy) private view returns (uint256 amount) {
        uint256 available = token.balanceOf(address(this));
        if (available == 0) return 0;
        amount = uint256(entropy) % MAX_ACTION_AMOUNT + 1;
        if (amount > available) amount = available;
    }

    function _snapshot() private view returns (bytes32) {
        return keccak256(abi.encode(
            core.bindings(),
            core.clock(),
            core.fundingState(),
            reserve.state(),
            token.balanceOf(address(this)),
            token.balanceOf(address(reserve)),
            token.balanceOf(address(core)),
            core.accountedNara(),
            core.settlementCount(),
            core.openCount()
        ));
    }

    function _fail(bytes32 reason) private {
        _violation = true;
        lastViolation = reason;
    }

    function _errorSelector(bytes memory reason) private pure returns (bytes4 observed) {
        if (reason.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            observed := mload(add(reason, 32))
        }
    }
}
