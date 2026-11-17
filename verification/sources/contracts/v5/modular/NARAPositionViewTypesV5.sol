// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PositionState, RewardCredit} from "../interfaces/NARAAccountingTypesV5.sol";
import {FrameAwardV5, GenerationLifecycleV5} from "./NARAModuleInterfacesV5.sol";

enum PositionStatusV5 { Pending, Active, Matured, Withdrawn, Dormant }
struct PositionViewV5 {
    uint256 schemaVersion;
    uint256 tokenId;
    uint256 positionId;
    uint64 generation;
    uint8 receiptKind;
    uint8 rarityTier;
    address nftOwner;
    PositionStatusV5 status;
    bool transferable;
    uint256 attachedPrincipal;
    uint64 wallEpoch;
    uint256 unlockTimestamp;
    uint256 asOfBlock;
    uint256 asOfTimestamp;
    PositionState financial;
    bool[3] rewardReadSuccess;
    RewardCredit[3] rewards;
    uint256[3] attachedClaimable;
    uint64 weightEpoch;
    bool weightSnapshotCurrent;
    bool currentPulseEligible;
    uint256 eligibleRewardWeight;
    uint256 totalRewardWeight;
    uint256 rewardShareWad;
    // Generation history across all owners; never the current buyer's profit.
    uint256[3] positionRewardsEarned;
    uint64 observedClosedPulses;
    uint256 naraRewardRatioWad;
    bool historicalNaraRateAvailable;
    uint256 historicalNaraRateWad;
    FrameAwardV5 award;
    GenerationLifecycleV5 lifecycle;
    uint256[5] lineage;
    uint256 eligibleModelWeight;
    uint256 totalModelWeight;
    uint256[3] archivedClaimable;
}

interface INARAPositionViewIdentityV5 {
    function renderer() external view returns (address);
    function statsProvider() external view returns (address);
    function core() external view returns (address);
    function rewards() external view returns (address);
    function financialSchemaVersion() external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function receiptInfo(uint256 tokenId) external view returns (uint256 positionId, uint64 generation, uint8 kind);
    function frameInfo(uint256 tokenId) external view returns (
        uint256 frameId, uint256 originTokenId, uint256 seedVersion, bytes32 cosmeticSeed
    );
}
/// @notice Replaceable presentation reads. The fixed compositor accepts no
/// provider strings, JSON, SVG or arbitrary attributes. Typed data is not proof
/// of financial truth; execution continues to use the financial authorities.
interface INARAPositionStatsProviderV5 {
    function SCHEMA_VERSION() external view returns (uint256);
    function snapshot(address nft, uint256 tokenId) external view returns (PositionViewV5 memory);
}
interface INARAPositionRendererV5 {
    function SCHEMA_VERSION() external view returns (uint256);
    function tokenURI(address nft, uint256 tokenId) external view returns (string memory);
    function artURI(address nft, uint256 tokenId) external view returns (string memory);
    function artInfo(address nft, uint256 tokenId) external view returns (bytes32 family, uint256 version, bytes32 svgHash);
    function financialCardURI(address nft, uint256 tokenId) external view returns (string memory);
}
