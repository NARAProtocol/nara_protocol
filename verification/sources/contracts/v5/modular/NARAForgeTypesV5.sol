// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {CommonRechargeRequestV5} from "./NARAPrincipalPreviewV5.sol";

enum AttemptKindV5 { Roll, Fusion }
enum AttemptStateV5 { None, Committed, Finalized, Voided, Failed }
enum RollBlockerV5 { None, FlashActive, NotCurrent, RollsNotOpen, NotOwner, NotCurrentGeneration,
    Withdrawn, NotActivated, Ended, TermsChanged, InsufficientRemaining, TransitionPending, Consumed,
    AttemptPending, BelowMinimumPrincipal, AwardExists, FusionSpent, RechargeBlocked, NoAward }
struct RollRequestV5 {
    uint256 positionId; uint64 generation; bytes32 expectedTermsHash;
    uint256 maxFee; uint256 maxOracleFee; uint64 deadline;
}
struct FusionRequestV5 {
    uint256[5] positionIds; uint64[5] generations; bytes32[5] expectedTermsHashes;
    uint256 maxFee; uint256 maxOracleFee; uint64 deadline;
}
struct AttemptV5 {
    AttemptKindV5 kind; AttemptStateV5 state; address payer; address adapter;
    uint64 commitEpoch; uint64 deadlineEpoch; uint16 oddsVersion; uint8 inputTier;
    uint256 requestId; uint256 protocolFee; uint256 oracleFee; uint256 word; uint8 outcomeTier;
}
struct RollQuoteV5 {
    RollBlockerV5 blocker; uint256 valueFee; uint256 fixedFee; uint256 oracleFee;
    uint64 wallEpoch; uint64 deadlineEpoch; uint16 oddsVersion;
}
struct RechargeQuoteV5 {
    RollBlockerV5 blocker; uint256 rent; uint256 rewardWeight; uint256 modelWeight; uint8 tier; uint256 originalCap;
}
interface INARAEntropyAdapterV5 {
    function SCHEMA_VERSION() external view returns (uint256);
    function forge() external view returns (address);
    function quote() external view returns (uint256);
    function request(bytes32 attemptId) external payable returns (uint256);
    function requestOf(bytes32 attemptId) external view returns (uint256);
    function result(uint256 requestId) external view returns (bool, uint64, uint64, uint256);
}
interface INARAForgeAdapterViewV5 {
    error CommitsPaused();
    function adapter() external view returns (address);
}
interface INARAEmissionReferenceV5 { function emissionReference() external view returns (uint256, uint64); }
struct RechargeAwardedRequestV5 { CommonRechargeRequestV5 recharge; uint256 maxRent; }
interface INARAForgeRechargePrincipalV5 {
    function rechargeAwarded(address owner, CommonRechargeRequestV5 calldata request) external
        returns (uint64 generation, uint256 rewardWeight, uint256 modelWeight);
}
