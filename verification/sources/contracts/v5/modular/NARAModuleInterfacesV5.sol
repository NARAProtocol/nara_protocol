// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccountingPolicy, CoreBindings, EpochClock, RewardAsset, PositionState} from "../interfaces/NARAAccountingTypesV5.sol";

interface INARARewardCreditIndicesV5 {
    function creditIndices(RewardAsset asset, uint64 start, uint64 end)
        external view returns (uint256 baseFrom, uint256 baseTo, uint256 rarityFrom, uint256 rarityTo);
}

interface INARARewardCheckpointV5 {
    function checkpointPosition(uint256 id, uint64 generation) external;
}

/// @dev Narrow draft boundary for the separately deployed financial realization.
/// The previous aggregate INARAEngineCoreV5 interface is not implemented by this interface.
interface INARAEpochCoordinatorV5 {
    function bindings() external view returns (CoreBindings memory);
    function policy() external view returns (AccountingPolicy memory);
    function clock() external view returns (EpochClock memory);
    function financialModules() external view returns (address principal, address rewards);
    /// @dev Set only when Engine seals and retires its bootstrap authority.
    function principalBindingHash() external view returns (bytes32);
    function rewardBindingHash() external view returns (bytes32);
    /// @dev Genesis is zero until activation; metadata is readable under the graph lock.
    function principalEpoch() external view returns (uint64 genesis, uint64 nextEpochToClose);
}

interface INARARewardLedgerIdentityV5 {
    function engine() external view returns (address);
    function principal() external view returns (address);
    function nara() external view returns (address);
    /// @dev P2.2: the two Rewards-side addresses the Principal's fixed deny-list stores once at initialize (§3.1).
    function usdc() external view returns (address);
    function creditLedger() external view returns (address);
}

/// @dev The Forge identity the Principal (initialize, m-8) and the Engine (bind, §2.2) check (P2.2). The Forge
/// itself lands in P2.3; until then a test-only mock stands at the precomputed peer address.
interface INARAForgeIdentityV5 {
    function principal() external view returns (address);
    function SCHEMA_VERSION() external view returns (uint256);
    function quote() external view returns (address);
    /// @dev P2.5 (design §4.4, §4.7): the O(1) adapter set the NFT reads on transfers only, and on a
    /// materialization to a third party; one SLOAD of the Forge's `wasAdapter`, written only by finalizeAdapter.
    function isAdapterOrFormer(address a) external view returns (bool);
}

interface INARAPositionIdentityV5 {
    function core() external view returns (address);
    function financialSchemaVersion() external view returns (uint256);
    function mint(address owner, uint256 positionId, uint64 generation) external;
    function activeOwnerOf(uint256 positionId, uint64 generation) external view returns (address);
    // Existing ERC721/identity reads; no new financial snapshot bypass.
    function ownerOf(uint256 tokenId) external view returns (address);
    function dormantTokenIdOf(uint256 positionId, uint64 generation) external view returns (uint256);
    function receiptTransferNonce(uint256 tokenId) external view returns (uint256);
    /// @dev Fixed Principal only, under its graph lock. Rechecks current dormant
    /// ownership and nonce after principal funding; never touches reward rights.
    function consumeDormant(address owner, uint256 positionId, uint64 generation,
        uint256 tokenId, uint256 expectedNonce) external;
    function retireActive(uint256 positionId, uint64 generation) external;
}

struct PrincipalLedgerStateV5 {
    bool initialized;
    uint64 openedEpoch;
    uint256 principalInventory;
    uint256 principalSnapshot;
    uint256 activeModelWeight;
    uint256 activeRewardWeight;
    int256 pendingPrincipalDelta;
    uint256 positionCount;
}

struct PrincipalLedgerChangesV5 {
    int256 principalDelta;
    int256 modelWeightDelta;
    int256 rewardWeightDelta;
}

struct RewardLedgerStateV5 {
    bool initialized;
    uint64 openedEpoch;
    uint64 nextCheckpoint;
    uint256 protectedNaraSnapshot;
    int256 pendingNaraDelta;
    uint256 naraAdmissionHeadroom;
    bool receiptPrepared;
}

struct RewardTermsV5 {
    address owner;
    uint64 activation;
    uint64 effectiveEnd;
    uint256 weight;
    // Zero cutover means a single constant interval. Otherwise weight is the
    // retained pre-cutover weight and nextWeight applies from cutover onward.
    uint64 cutover;
    uint256 nextWeight;
    // Ordinary duration-weighted principal, fixed throughout this generation.
    uint256 baseWeight;
}

/// @dev Modular accounting schema 2. No single total-credit index exists.
/// The inherited reference RewardAccounting is unchanged and is not this ABI.
/// Amounts use native asset units; indices and scaled liabilities use RAY.
struct RewardAccountingV5 {
    address token;
    uint8 decimals;
    bool receiptsEnabled;
    uint256 recordedCustody;
    uint256 pendingTotal;
    uint256 banked;
    uint256 baseIndex;
    uint256 rarityIndex;
    uint256 owedScaled;
    uint256 quarantinedScaled;
    uint256 cumulativeAdmitted;
    uint256 cumulativePaid;
    uint256 cumulativeExternal;
    uint256 cumulativeEmissions;
    uint256 cumulativePenalties;
    uint256 penaltyCapacityReserved;
}

struct RewardWeightStateV5 {
    uint64 cutover;
    uint256 previousWeight;
    uint256 nextWeight;
}

// ---- Lifecycle types (LIFECYCLE_DESIGN.md §3.2; P2.1) -------------------------------------------

/// @dev A Failed record (Q8 option (a)): the attempt timed out and no word was ever applied.
uint8 constant NO_OUTCOME = 255;

/// @notice One record per frame (frameId == positionId), written by a roll's finalization (applied,
/// Common or void), by a fusion opening, or (Q8 option (a)) by a roll's timeout. Every field except
/// awardedGeneration is immutable after that write; awardedGeneration only increases and equals the
/// latest generation with rarityApplied (X5). Never raised by recharge or transfer. A frame with a
/// record never rolls again (Q3).
struct FrameAwardV5 {
    uint256 originalCap;        // C in wei: principal at award (roll) or the cap sum (fusion); 0 on a Failed record
    uint256 multiplierWad;      // A of the applied tier (1e18 when tier == 0)
    uint256 awardedDurationWad; // Daw: duration multiplier of the generation the award was won on; fusion: min over inputs
    uint8 tier;                 // applied tier 0..5 (0 for Common, for a voided result and for a Failed record)
    uint8 outcomeTier;          // the drawn tier (provenance; equals tier unless voided); NO_OUTCOME on a Failed record
    uint16 oddsVersion;         // odds table version at commit
    uint64 awardEpoch;          // wall epoch at finalization / fusion opening
    uint64 awardedGeneration;   // generation the award was applied to (0 when never applied)
    uint256 requestId;          // VRF request id of the attempt
    bytes32 attemptId;          // Forge attempt id (nonzero marks "record exists")
}

struct GenerationLifecycleV5 {
    bytes32 pendingAttempt;     // nonzero: transfer, recharge and materialization frozen (A5, R12)
    bool rarityApplied;         // this generation's rewardWeight includes the frame award
    bool consumed;              // fused into fusedInto; withdrawal refused
    bool fusionSpent;           // Q8 option (a): a timed-out fusion spent this generation's fusion right
    uint256 fusedInto;
}

/// @dev AR2-06: which terminal branch finalization took. Applied and RecordedCommon map to the Forge's
/// Finalized, Void and Cancelled to Voided.
enum FinalizeStatusV5 { Applied, RecordedCommon, Void, Cancelled }

/// @dev Written once by the Forge at commit (P2.2). owner, count and commitEpoch share one slot.
struct AttemptInputsV5 {
    address owner;
    uint8 count;
    uint64 commitEpoch;
    uint256[5] ids;
    uint64[5] generations;
}

struct FusionInputTermsV5 {
    uint256 principal;
    uint256 cap;
    uint256 awardedDurationWad;
    uint64 maturity;
}

/// @dev The Principal reads and write primitives its lifecycle child uses. lifecyclePosition is callable by the
/// child only and carries no lock requirement (AR2-08); it returns the stored generation, not the
/// boundary-projected view. openedEpoch is the settled boundary every lifecycle read is dated at. The write
/// primitives (P2.2, P2.6) are lifecycleCommand: the child, while the Principal holds its own lock.
interface INARAPrincipalLifecycleV5 {
    function lifecyclePosition(uint256 id, uint64 generation) external view
        returns (PositionState memory p, uint64 currentGeneration, uint64 transitionCutover);
    function openedEpoch() external view returns (uint64);
    function admissionHelper() external view returns (address);
    function nextPositionId() external view returns (uint256);
    function applyWeightFor(uint256 id, uint64 generation, uint256 newWeight) external returns (bytes32 termsHash);
    function reviseTermsFor(uint256 id, uint64 generation, bytes32 attemptId, uint8 outcomeTier) external returns (bytes32 termsHash);
    function checkpointFor(uint256 id, uint64 generation) external;
    function endGenerationAt(uint256 id, uint64 generation, uint64 k) external;
    function openReclassified(uint256 outputId, PositionState calldata s) external;
    function retireActiveFor(uint256 id, uint64 generation) external;
}

/// @dev The admission child's policy duration multiplier (PV:100-106 under the Principal's policy) and fusion
/// output constructor, read by the lifecycle child at finalization.
interface INARADurationMultiplierV5 {
    function durationMultiplier(uint32 duration) external view returns (uint256);
    function quoteFusionOutput(address owner, uint256 outputId, uint64 cutover,
        FusionInputTermsV5[5] calldata inputs, uint8 outcomeTier, uint16 oddsVersion,
        uint256 requestId, bytes32 attemptId)
        external view returns (PositionState memory s, FrameAwardV5 memory a);
}
