// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {NARAPositionCardV5} from "./NARAPositionCardV5.sol";
import {NARAPositionDisplayV5} from "./NARAPositionDisplayV5.sol";
import {NARAFrameArtV5} from "./NARAFrameArtV5.sol";
import {NARAPositionStatsReaderV5} from "./NARAPositionStatsReaderV5.sol";
import {PositionViewV5, INARAPositionViewIdentityV5, INARAPositionStatsProviderV5} from "./NARAPositionViewTypesV5.sol";

/// @notice Fixed metadata/art compositor with replaceable typed statistics.
/// @dev The NFT creates this exact runtime and this constructor creates the Art and strict typed reader.
/// Provider governance can repair reads, not serialization, layout or artwork.
/// Typed validation does not authenticate internally consistent numeric claims.
contract NARAPositionRendererV5 {
    using Strings for uint256;
    uint256 public constant SCHEMA_VERSION = 2;
    // PositionViewV5 has 107 static ABI words, including nested structs/arrays.
    // The artifact-width regression must change with any future schema change.
    uint256 public constant SNAPSHOT_BYTES = 107 * 32;
    uint256 public constant SNAPSHOT_GAS_LIMIT = 780_000;
    uint256 public constant COMPOSITION_RESERVE_GAS = 200_000;
    bytes32 public constant EXPECTED_CARD_CODEHASH = 0x6ed3416c7a0df6903b4677172d7ffbd28e0ff4c71d6f1a6d0e271798dbfb4596;
    address public immutable positionNFT;
    address public immutable art;
    address public immutable statsReader;
    // Initial provider provenance only. Current reads use NFT.statsProvider();
    // there is no fallback to this address when a replacement fails.
    address public immutable lens;
    address public immutable card;
    error InvalidBinding();
    error InvalidTier();
    error InvalidPrecision();
    error StatisticsUnavailable();

    constructor(address lens_, address card_) {
        if (!_schemaTwo(lens_) || !_schemaTwo(card_) || lens_ == card_ || card_.codehash != EXPECTED_CARD_CODEHASH) {
            revert InvalidBinding();
        }
        positionNFT = msg.sender;
        lens = lens_; card = card_;
        art = address(new NARAFrameArtV5());
        statsReader = address(new NARAPositionStatsReaderV5(msg.sender));
    }

    function _schemaTwo(address target) private view returns (bool) {
        if (target.code.length == 0 || (target.code.length >= 3 && bytes3(target.code) == 0xef0100)) return false;
        bytes memory input = abi.encodeCall(INARAPositionStatsProviderV5.SCHEMA_VERSION, ());
        bool ok; uint256 size; uint256 schema;
        assembly ("memory-safe") {
            ok := staticcall(30000, target, add(input, 32), mload(input), 0, 0)
            size := returndatasize()
            if eq(size, 32) { returndatacopy(0, 0, 32) schema := mload(0) }
        }
        return ok && size == 32 && schema == 2;
    }

    function tierStyle(uint8 tier) public pure returns (string memory label, string memory color) {
        return NARAPositionDisplayV5.tierStyle(tier);
    }
    function formatUnits(uint256 amount, uint8 decimals) public pure returns (string memory) {
        return NARAPositionDisplayV5.formatUnits(amount, decimals);
    }
    function tokenURI(address nft, uint256 tokenId) external view returns (string memory) {
        _boundNFT(nft);
        INARAPositionViewIdentityV5 identity = INARAPositionViewIdentityV5(nft);
        identity.ownerOf(tokenId);
        (uint256 positionId, uint64 generation,) = identity.receiptInfo(tokenId);
        (string memory image, string memory frame) = _framePresentation(nft, tokenId);
        address provider = identity.statsProvider();
        uint256 budget = _readBudget();
        if (budget != 0) {
            try NARAPositionStatsReaderV5(statsReader).readMetadata{gas: budget}(tokenId, provider) returns (string memory attrs, string memory facts) {
                uint256 needed = 230_000 + (bytes(attrs).length + bytes(facts).length) * 20;
                if (gasleft() > needed) {
                    return _available(attrs, facts, tokenId, positionId, generation, image, frame, provider);
                }
            } catch { /* Provider/decode/validation failures leave artwork intact. */ }
        }
        return _unavailable(tokenId, positionId, generation, image, frame, provider);
    }

    /// @notice Original image, including burned receipt identities. No financial
    /// contract or statistics provider is called along this independent path.
    function artURI(address nft, uint256 tokenId) external view returns (string memory) {
        _boundNFT(nft);
        (,,,bytes32 seed) = INARAPositionViewIdentityV5(nft).frameInfo(tokenId);
        return _imageURI(NARAFrameArtV5(art).svg(seed));
    }

    function artInfo(address nft, uint256 tokenId) external view returns (bytes32 family, uint256 version, bytes32 svgHash) {
        _boundNFT(nft);
        (,,,bytes32 seed) = INARAPositionViewIdentityV5(nft).frameInfo(tokenId);
        NARAFrameArtV5 a = NARAFrameArtV5(art);
        return (a.FAMILY(), a.VERSION(), keccak256(bytes(a.svg(seed))));
    }

    /// @notice Separate live financial visualization. Never substitutes for art.
    function financialCardURI(address nft, uint256 tokenId) external view returns (string memory) {
        _boundNFT(nft);
        INARAPositionViewIdentityV5 identity = INARAPositionViewIdentityV5(nft);
        identity.ownerOf(tokenId);
        address provider = identity.statsProvider();
        uint256 budget = _readBudget();
        if (budget != 0) {
            try NARAPositionStatsReaderV5(statsReader).readValidatedSnapshot{gas: budget}(tokenId, provider) returns (PositionViewV5 memory v) {
                if (gasleft() > 220_000) {
                    try NARAPositionCardV5(card).svg{gas: gasleft() - 60_000}(v) returns (string memory svgData) {
                        return _imageURI(svgData);
                    } catch {}
                }
            } catch { /* No stale card, fabricated balances or old provider fallback. */ }
        }
        revert StatisticsUnavailable();
    }

    function _boundNFT(address nft) private view {
        if (nft != positionNFT || INARAPositionViewIdentityV5(nft).renderer() != address(this)
            || INARAPositionViewIdentityV5(nft).financialSchemaVersion() != 2) revert InvalidBinding();
    }

    function _readBudget() private view returns (uint256 budget) {
        uint256 remaining = gasleft();
        if (remaining <= COMPOSITION_RESERVE_GAS) return 0;
        budget = remaining - COMPOSITION_RESERVE_GAS;
        if (budget > SNAPSHOT_GAS_LIMIT) budget = SNAPSHOT_GAS_LIMIT;
    }

    function _available(string memory attrs, string memory facts, uint256 tokenId, uint256 positionId, uint64 generation,
        string memory image, string memory frame, address provider) private view returns (string memory)
    {
        // Exact strings avoid JS number rounding. These read facts are not a sale
        // guarantee; execution must validate current backing and reward minima.
        string memory json = string.concat('{"name":"NARA Position #', tokenId.toString(),
            '","description":"A NARA position receipt. Active receipts carry principal and unclaimed rewards. Dormant collectibles carry no principal or old reward rights. Only the guarded Sale verifies principal and unclaimed rewards at fill; on outside venues the seller may claim or withdraw before settlement. Earned rewards are generation history across all owners, not personal ROI. Historical rates are not forecasts and do not include compounding, token price changes or costs.",',
            '"image":"', image, '","attributes":[', attrs, ',', _trait("Data status", "Available"), '],',
            '"nara":{"schema_version":2,"position_id":"', positionId.toString(), '","generation":"', uint256(generation).toString(),
            facts, _providerMetadata(provider, true), ',', frame, '}}');
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function _framePresentation(address nft, uint256 tokenId) private view returns (string memory image, string memory frame) {
        (uint256 frameId, uint256 originTokenId, uint256 seedVersion, bytes32 seed) =
            INARAPositionViewIdentityV5(nft).frameInfo(tokenId);
        NARAFrameArtV5 a = NARAFrameArtV5(art);
        string memory svgData = a.svg(seed);
        image = _imageURI(svgData);
        frame = string.concat('"frame_id":"', frameId.toString(), '","origin_token_id":"', originTokenId.toString(),
            '","cosmetic_seed_version":"', seedVersion.toString(), '","cosmetic_seed":"', uint256(seed).toHexString(32),
            '","art_family":"', uint256(a.FAMILY()).toHexString(32), '","art_version":"', a.VERSION().toString(),
            '","art_svg_hash":"', uint256(keccak256(bytes(svgData))).toHexString(32), '","art_acceptance":"engineering_fixture"');
    }

    function _unavailable(uint256 tokenId, uint256 positionId, uint64 generation,
        string memory image, string memory frame, address provider) private view returns (string memory)
    {
        return string.concat("data:application/json;base64,", Base64.encode(bytes(string.concat(
            '{"name":"NARA Position #', tokenId.toString(),
            '","description":"Statistics unavailable. Read the canonical position contracts for current principal and rewards. Only the guarded Sale verifies principal and unclaimed rewards at fill; on outside venues the seller may claim or withdraw before settlement. The original engineering artwork is retained.",',
            '"image":"', image, '","attributes":[', _trait("Data status", "Unavailable"), '],',
            '"nara":{"schema_version":2,"position_id":"', positionId.toString(), '","generation":"', uint256(generation).toString(),
            '",', _providerMetadata(provider, false), ',', frame, '}}'))));
    }

    function _providerMetadata(address provider, bool available) private view returns (string memory) {
        // Proxy implementation changes are not authenticated by the shell hash.
        return string.concat('"data_status":"', available ? "available" : "unavailable", '","stats_provider":"',
            uint256(uint160(provider)).toHexString(20), '","stats_provider_code_hash":"',
            uint256(provider.codehash).toHexString(32), '"');
    }

    function _imageURI(string memory svgData) private pure returns (string memory) {
        return string.concat("data:image/svg+xml;base64,", Base64.encode(bytes(svgData)));
    }

    function _trait(string memory name, string memory value) private pure returns (string memory) {
        return string.concat('{"trait_type":"', name, '","value":"', value, '"}');
    }
}
