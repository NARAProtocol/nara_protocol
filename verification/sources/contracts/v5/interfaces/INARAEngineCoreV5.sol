// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {EmissionConfig, EmissionState} from "../engine/NARAEmissionTypesV5.sol";
import {RewardAsset, CoreBindings, EpochClock, AccountingPolicy, CoreAccounting,
    RewardAccounting, EpochChanges, PositionState, RewardCredit, CreateRequest,
    CreatePreview, ExitPreview, AdvanceResult, EpochOutcome} from "./NARAAccountingTypesV5.sol";

/// @notice Candidate operational/read ABI. It is not a custody implementation.
/// @dev Bootstrap and governance write ABIs remain separate unresolved design gates.
interface INARAEngineCoreV5 {
    error Unauthorized();
    error InvalidState();
    error UnknownGeneration();
    error InvalidRecipient();
    error InvalidTerms();
    error InvalidEpoch();
    error InvalidFundingSequence();
    error AdmissionCapacityExceeded();
    error UnsupportedAsset();
    error AccountingInProgress();

    event PositionCreated(uint256 indexed positionId, uint64 indexed generation, address indexed owner, PositionState position);
    event EarlyExitRequested(uint256 indexed positionId, uint64 indexed generation, uint64 effectiveEnd, uint256 penalty);
    event PrincipalWithdrawn(uint256 indexed positionId, uint64 indexed generation, address indexed recipient, uint256 amount);
    event RewardReceived(RewardAsset indexed asset, address indexed payer, uint64 indexed epoch, uint256 amount);
    event RewardClaimed(uint256 indexed positionId, uint64 indexed generation, RewardAsset indexed asset, address recipient, uint256 amount);
    event ReserveFundingRecorded(uint256 indexed sequence, uint64 indexed eligibleEpoch, uint256 amount);
    event EpochClosed(uint64 indexed epoch, bytes32 indexed policyHash, EpochOutcome outcome);

    function bindings() external view returns (CoreBindings memory);
    function clock() external view returns (EpochClock memory);
    /// @dev Always readable, including from callbacks. Financial getters reject in-progress reads.
    function accountingInProgress() external view returns (bool);
    /// @dev Bound Reserve only; active only immediately around its authorized release call.
    function reserveReleaseContext() external view returns (bool active, uint64 epoch, uint256 maximum);
    function policy() external view returns (AccountingPolicy memory);
    function emissionConfig() external view returns (EmissionConfig memory);
    function emissionState() external view returns (EmissionState memory);
    function accounting() external view returns (CoreAccounting memory);
    function rewardAccounting(RewardAsset asset) external view returns (RewardAccounting memory);
    /// @dev Future/current schedule only; past/pruned epoch queries revert InvalidEpoch.
    function epochChanges(uint64 epoch) external view returns (EpochChanges memory);
    /// @dev Past/pruned buckets revert InvalidEpoch; zero current/future bucket is valid.
    function rewardBucket(RewardAsset asset, uint64 epoch) external view returns (uint256 amount);
    /// @dev Absent checkpoint is explicit; zero is a valid existing index.
    function indexAt(RewardAsset asset, uint64 boundary) external view returns (bool exists, uint256 index);
    /// @dev Missing ID/generation reverts UnknownGeneration, never a zero-filled position.
    function position(uint256 positionId, uint64 generation) external view returns (PositionState memory);
    function credit(uint256 positionId, uint64 generation, RewardAsset asset) external view returns (RewardCredit memory);
    function previewCreate(address caller, CreateRequest calldata request) external view returns (CreatePreview memory);
    function previewEarlyExit(address caller, uint256 positionId, uint64 generation) external view returns (ExitPreview memory);
    function previewWithdraw(address caller, uint256 positionId, uint64 generation) external view returns (ExitPreview memory);

    /// @dev Owner-initiated, common financial alloy only; no arbitrary weight/gift argument.
    function create(CreateRequest calldata request) external returns (uint256 positionId, uint64 generation);
    function requestEarlyExit(uint256 positionId, uint64 generation) external;
    /// @dev Only archived generation owner; independent of catch-up, rewards and NFT calls.
    function withdrawPrincipal(uint256 positionId, uint64 generation, address recipient) external returns (uint256 paid);
    /// @dev Only archived generation owner may redirect payment; NFT approval is insufficient.
    function claim(uint256 positionId, uint64 generation, RewardAsset asset, address recipient) external returns (uint256 paid);
    /// @dev Core chooses chronological epochs and actual funding; caller chooses work bound only.
    function advance(uint32 maxEpochs) external returns (AdvanceResult memory);
    function donateETH() external payable;
    /// @dev NARA/USDC only; actual receipt checked before admission. ETH enum must revert.
    function donateToken(RewardAsset asset, uint256 amount) external returns (uint256 received);

    /// @dev Sealed graph + exact initial funding; sets genesis once to the next 900-second boundary.
    function activate() external;
    /// @dev Bound Reserve only; sequence one, exact expected allocation, once before activation.
    function recordInitialReserveFunding(uint256 sequence, uint256 amount) external;

    /// @dev Bound Reserve only, strictly next sequence, eligible wall+1; no reward credit.
    ///      Called atomically with funding recognition. Genesis uses sealed bootstrap setup.
    function recordReserveFunding(uint256 sequence, uint64 eligibleEpoch, uint256 amount) external;
}
