// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {EmissionQuote} from "../engine/NARAEmissionTypesV5.sol";

// DRAFT ABI schema only: no storage, custody implementation or approved economics.
enum RewardAsset { NARA, ETH, USDC }
enum DurationCurve { Linear, V4Quadratic }
enum ActionBlocker { None, NotSealed, NotStarted, Paused, CoreStale, UnknownGeneration, NotOwner, Pending, NotMature, AlreadyWithdrawn, TransitionPending, InvalidTerms, AdmissionCapacity, FlashActive, InsufficientBalance, InsufficientAllowance }
enum ReserveDelivery { NotRequested, Succeeded, Failed }

struct CoreBindings {
    uint256 schemaVersion;
    address nara;
    address reserve;
    address emissionModel;
    address positionNFT;
    address bootstrapAuthority;
    bool bindingsSealed;
    bool activated;
    uint256 expectedGenesisFunding;
}

struct EpochClock {
    bool started;
    uint64 genesisTimestamp;
    uint64 wallEpoch;
    uint64 nextEpochToClose;
    uint64 backlog;
    uint256 nextBoundaryTimestamp;
}

struct AccountingPolicy {
    bytes32 policyHash;
    uint64 version;
    uint32 epochSeconds;
    uint256 rewardIndexScale;
    uint32 activationDelay;
    uint32 minDuration;
    uint32 maxDuration;
    DurationCurve durationCurve;
    bool earlyExitEnabled;
    uint16 earlyExitBps;
    uint256 minimumPrincipal;
    uint32 maxAdvance;
    uint256 rewardAdmissionCap;
}

/// @dev Recorded inventories, not balanceOf observations. Includes pending penalties.
struct CoreAccounting {
    uint256 principalInventory;
    uint256 principalSnapshot;
    uint256 protectedRewardSnapshot;
    uint256 eligibleReserve;
    uint256 futureReserve;
    uint256 lastFundingSequence;
    uint256 activeModelWeight;
    uint256 activeRewardWeight;
    int256 pendingPrincipalDelta;
    int256 pendingRewardDelta;
    bool admissionsPaused;
}

/// @dev Asset amounts use native base units; index and *Scaled fields use RAY.
struct RewardAccounting {
    address token;
    uint8 decimals;
    bool receiptsEnabled;
    uint256 recordedCustody;
    uint256 pendingTotal;
    uint256 banked;
    uint256 index;
    uint256 owedScaled;
    uint256 quarantinedScaled;
    uint256 cumulativeAdmitted;
    uint256 cumulativePaid;
    uint256 cumulativeExternal;
    uint256 cumulativeEmissions;
    uint256 cumulativePenalties;
    uint256 penaltyCapacityReserved;
}

struct EpochChanges {
    int256 principalDelta;
    int256 rewardDelta;
    int256 modelWeightDelta;
    int256 rewardWeightDelta;
    uint256 penaltyAmount;
    uint256 penaltyCapacityRelease;
    uint256 reserveFunding;
}

/// @dev Archived financial owner is distinct from future dormant NFT ownership.
struct PositionState {
    address generationOwner;
    uint64 generation;
    uint64 createdEpoch;
    uint64 activation;
    uint64 maturity;
    uint64 effectiveEnd;
    uint32 duration;
    uint256 principal;
    uint256 modelWeight;
    uint256 rewardWeight;
    bool earlyExitEnabled;
    uint16 earlyExitBps;
    uint256 penalty;
    uint256 penaltyCapacityReserved;
    bool withdrawn;
    bytes32 termsHash;
}

struct RewardCredit {
    address generationOwner;
    uint64 generation;
    uint64 accruedThrough;
    uint256 closedCreditScaled;
    uint256 claimable;
    uint256 fractionScaled;
    uint256 cumulativePaid;
    bool hasUnsettledEpochs;
    uint64 pendingFrom;
    uint64 pendingThrough;
    bool openEpochEligible;
}

struct CreateRequest {
    uint256 amount;
    uint32 duration;
    bytes32 expectedPolicyHash;
    uint64 deadline;
}

struct CreatePreview {
    ActionBlocker blocker;
    bytes32 policyHash;
    uint256 modelWeight;
    uint256 rewardWeight;
    uint64 activation;
    uint64 maturity;
    uint256 penaltyCapacityRequired;
}

struct ExitPreview {
    ActionBlocker blocker;
    uint64 effectiveEnd;
    uint256 principalOut;
    uint256 penalty;
}

struct AdvanceResult {
    uint64 fromEpoch;
    uint64 nextEpochToClose;
    uint64 remainingBacklog;
    uint32 closedCount;
    uint32 failedReserveCalls;
}

/// @dev Event-backed historical record; not a promise to store all quotes forever.
struct EpochOutcome {
    uint256 principalSnapshot;
    uint256 protectedRewardSnapshot;
    uint256 reserveSnapshot;
    uint256 modelFloat;
    uint256 modelWeight;
    uint256 rewardWeight;
    EmissionQuote quote;
    uint256 reserveRequested;
    uint256 reserveDelivered;
    ReserveDelivery deliveryStatus;
    uint256[3] grossAllocation;
    uint256[3] indexDelta;
}

struct ReserveState {
    uint256 schemaVersion;
    address nara;
    address core;
    address bootstrapAuthority;
    bool bindingsSealed;
    bool initialFundingRecognized;
    uint64 genesisTimestamp;
    uint256 genesisFunding;
    uint256 cumulativeRecognized;
    uint256 cumulativeReleased;
    uint256 fundingSequence;
    bool hasReleasedEpoch;
    uint64 lastReleasedEpoch;
}
