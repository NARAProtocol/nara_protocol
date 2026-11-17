// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {INARAPositionRendererV5, INARAPositionStatsProviderV5} from "./NARAPositionViewTypesV5.sol";
import {NARAPositionRendererV5} from "./NARAPositionRendererV5.sol";
import {NARAPrincipalLedgerV5} from "./NARAPrincipalLedgerV5.sol";
import {NARALifecycleLedgerV5} from "./NARALifecycleLedgerV5.sol";
import {NARARewardLedgerV5} from "./NARARewardLedgerV5.sol";
import {INARAForgeIdentityV5} from "./NARAModuleInterfacesV5.sol";
import {PositionState} from "../interfaces/NARAAccountingTypesV5.sol";
import {NARAPrincipalPreviewV5, CommonRechargeBlockerV5} from "./NARAPrincipalPreviewV5.sol";

/// @notice Position receipts with atomic financial ownership transfers.
/// @dev Principal is the financial authority; this contract holds no principal/rewards and gives operators no
/// direct claim right. P2.5 lifecycle primitives (LIFECYCLE_DESIGN.md §4.4): Principal-only retirement of a live
/// Active receipt under Principal's own lock, a one-live-receipt-per-frame mint guard (PRO-NFT-03), `_mint`
/// without receiver code for create and recharge (A10), ERC-721-authorized materialization with the recipient
/// forced to the owner for a non-owner caller (A11), the transfer freeze on materialization, and the fixed
/// recipient deny-list plus the O(1) adapter set on transfers only (AR3-04, A31-02). Final artwork, launch fees,
/// schema numbers (P2.11) and royalty configuration remain separate acceptance stages.
contract NARAPositionNFTV5 is ERC721, Ownable2Step {
    enum ReceiptKind { Active, Dormant }
    struct Receipt { uint256 positionId; uint64 generation; ReceiptKind kind; }

    uint256 public constant financialSchemaVersion = 2;
    uint256 public constant RENDER_GAS_LIMIT = 1_400_000;
    uint256 public constant MAX_RENDER_BYTES = 32_768;
    address public immutable renderer;
    address public statsProvider;
    address public immutable core;
    address public immutable rewards;
    /// @notice The Forge peer, copied from `core.forge()` (itself immutable) at construction. Its adapter set is
    /// the only governance-writable value any receipt path reads: one SLOAD, on transfers only (design §4.7).
    address public immutable forge;
    // Fixed peers copied at construction: the lifecycle child (the freeze read on materialization) and the
    // renderer's immutable children (NFT-only recipient sinks; the governor-changeable statsProvider is not one).
    address private immutable _lifecycleLedger;
    address private immutable _art;
    address private immutable _statsReader;
    address private immutable _card;
    bytes32 private immutable _frameDomain;
    uint256 public mintedCount;
    // Listing invalidation survives A->B->A, self-transfer and receipt retirement.
    mapping(uint256 tokenId => uint256) public receiptTransferNonce;
    // Tombstones persist after burn so a retired token ID remains attributable.
    mapping(uint256 tokenId => Receipt) private _receipts;
    mapping(uint256 positionId => mapping(uint64 generation => uint256 tokenId)) public tokenIdOf;
    mapping(uint256 positionId => mapping(uint64 generation => uint256 tokenId)) public dormantTokenIdOf;

    error Unauthorized();
    error InvalidBinding();
    error InvalidReceipt();
    error InvalidRecipient();
    error SettlementPending();
    error RendererFixed();
    error InvalidStatsProvider();
    error RechargeBlocked(CommonRechargeBlockerV5 blocker);
    error AttemptPending();

    event ReceiptMinted(uint256 indexed tokenId, uint256 indexed positionId, uint64 indexed generation, ReceiptKind kind);
    event ReceiptRetired(uint256 indexed tokenId, uint256 indexed positionId, uint64 indexed generation);
    event DormantMaterialized(uint256 indexed retiredTokenId, uint256 indexed dormantTokenId, address indexed recipient);
    event DormantConsumed(uint256 indexed tokenId, uint256 indexed positionId, uint64 indexed generation);
    event StatsProviderChanged(address indexed provider, bytes32 codeHash, uint256 schemaVersion);
    // Standard-shaped invalidation hints. Live block/financial JSON does not
    // provide automatic ERC-4906 notifications; that interface is not advertised.
    event MetadataUpdate(uint256 _tokenId);
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    constructor(address core_, address initialStatsProvider, address existingCard, address presentationGovernor)
        ERC721("NARA Positions", "NARAP") Ownable(presentationGovernor) {
        if (core_.code.length == 0) revert InvalidBinding();
        NARAPrincipalLedgerV5 p = NARAPrincipalLedgerV5(core_);
        address r = p.rewards();
        if (p.SCHEMA_VERSION() != 3 || p.positionNFT() != address(this) || r.code.length == 0
            || p.bindingsSealed() || NARARewardLedgerV5(r).principal() != core_
            || NARARewardLedgerV5(r).SCHEMA_VERSION() != 2) revert InvalidBinding();
        core = core_; rewards = r;
        // The Forge is deployed after this contract (design §2.2): only its precomputed address is copied.
        forge = p.forge(); _lifecycleLedger = p.lifecycleLedger();
        _frameDomain = keccak256(abi.encode(keccak256("NARA_V5_COSMETIC_FRAME_V1"), block.chainid, address(this)));
        // Exact children are created here; arbitrary schema-compatible renderer
        // addresses, including proxies, cannot choose the collection's image.
        address createdRenderer = address(new NARAPositionRendererV5(initialStatsProvider, existingCard));
        renderer = createdRenderer;
        _art = NARAPositionRendererV5(createdRenderer).art();
        _statsReader = NARAPositionRendererV5(createdRenderer).statsReader();
        _card = existingCard; // the renderer's immutable card (checked schema 1 by its constructor)
        _setStatsProvider(initialStatsProvider);
    }

    /// @notice Deprecated: the compositor and artwork can never be replaced.
    function setRenderer(address) external pure { revert RendererFixed(); }

    /// @notice Ownership repairs typed presentation reads, never financial rights,
    /// fixed JSON labels/schema, Card layout or original collectible artwork.
    function setStatsProvider(address provider) external onlyOwner { _setStatsProvider(provider); }
    /// @notice C1 (ACC-05, UPG-N01): presentation governance cannot be renounced.
    function renounceOwnership() public view override onlyOwner { revert InvalidStatsProvider(); }
    function _setStatsProvider(address candidate) private {
        if (candidate.code.length == 0 || (candidate.code.length >= 3 && bytes3(candidate.code) == 0xef0100)) {
            revert InvalidStatsProvider();
        }
        bytes memory input = abi.encodeCall(INARAPositionStatsProviderV5.SCHEMA_VERSION, ());
        bool ok; uint256 size; uint256 schema;
        assembly ("memory-safe") {
            ok := staticcall(30000, candidate, add(input, 32), mload(input), 0, 0)
            size := returndatasize()
            if eq(size, 32) { returndatacopy(0, 0, 32) schema := mload(0) }
        }
        if (!ok || size != 32 || schema != 2) revert InvalidStatsProvider();
        statsProvider = candidate;
        emit StatsProviderChanged(candidate, candidate.codehash, 2);
        if (mintedCount != 0) emit BatchMetadataUpdate(1, mintedCount);
    }

    /// @notice Request a fresh read for one existing receipt. This neither runs
    /// the renderer nor certifies that a marketplace has refreshed its cache.
    function refreshMetadata(uint256 tokenId) external {
        _requireOwned(tokenId);
        emit MetadataUpdate(tokenId);
    }

    /// @notice Persistent cosmetic provenance, including retired receipt IDs.
    /// @dev Predictable, grindable identity; NEVER a financial randomness source.
    /// Its fixed Art child receives only this seed, never financial rarity/state.
    function frameInfo(uint256 tokenId) external view returns (
        uint256 frameId, uint256 originTokenId, uint256 seedVersion, bytes32 cosmeticSeed
    ) {
        frameId = _receipts[tokenId].positionId;
        if (frameId == 0) revert InvalidReceipt();
        originTokenId = tokenIdOf[frameId][1];
        seedVersion = 1;
        cosmeticSeed = keccak256(abi.encode(_frameDomain, frameId, originTokenId));
    }

    /// @notice Bounded optional artwork. Failure never becomes fabricated zero
    /// principal/rewards or a dependency of transfer, claim or principal exit.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        uint256 remainingGas = gasleft();
        if (remainingGas < 80_000) return _unavailable(tokenId);
        uint256 budget = remainingGas - 60_000;
        if (budget > RENDER_GAS_LIMIT) budget = RENDER_GAS_LIMIT;
        bytes memory input = abi.encodeCall(INARAPositionRendererV5.tokenURI, (address(this), tokenId));
        address target = renderer;
        bool ok; uint256 size;
        assembly ("memory-safe") {
            ok := staticcall(budget, target, add(input, 32), mload(input), 0, 0)
            size := returndatasize()
        }
        if (!ok || size < 96 || size > MAX_RENDER_BYTES) return _unavailable(tokenId);
        bytes memory result = new bytes(size);
        assembly ("memory-safe") { returndatacopy(add(result, 32), 0, size) }
        uint256 offset; uint256 length;
        assembly ("memory-safe") { offset := mload(add(result, 32)) length := mload(add(result, 64)) }
        if (offset != 32 || length == 0 || length > size - 64 || size != 64 + ((length + 31) / 32) * 32) return _unavailable(tokenId);
        return abi.decode(result, (string));
    }

    function _unavailable(uint256 tokenId) private pure returns (string memory) {
        return string.concat("data:application/json;base64,", Base64.encode(bytes(string.concat(
            '{"name":"NARA Position #', Strings.toString(tokenId),
            '","description":"Metadata unavailable. Read the position contracts for current principal and rewards. Only the guarded Sale verifies principal and unclaimed rewards at fill; on outside venues the seller may claim or withdraw before settlement.","attributes":[{"trait_type":"Data status","value":"Unavailable"}]}'))));
    }

    /// @notice Historical receipt identity; ownerOf separately establishes existence.
    function receiptInfo(uint256 tokenId) external view returns (Receipt memory r) {
        r = _receipts[tokenId];
        if (r.positionId == 0) revert InvalidReceipt();
    }

    /// @dev Identity-only read also used while Principal authenticates a transfer.
    function activeOwnerOf(uint256 positionId, uint64 generation) external view returns (address) {
        return _ownerOf(tokenIdOf[positionId][generation]);
    }

    /// @dev Create, recharge (and, from P2.6, fusion-output) receipts. One live receipt per frame (PRO-NFT-03):
    /// generation g + 1 opens only after generation g's Active and Dormant receipts are both gone. `_mint` runs no
    /// receiver code while Principal holds its lock (A10); the recipient takes the mint form of the deny-list.
    function mint(address owner, uint256 positionId, uint64 generation) external {
        if (msg.sender != core || NARAPrincipalLedgerV5(core).moduleLockHolder() != core) revert Unauthorized();
        if (positionId == 0 || generation == 0 || tokenIdOf[positionId][generation] != 0) revert InvalidReceipt();
        if (generation > 1 && (_ownerOf(tokenIdOf[positionId][generation - 1]) != address(0)
            || _ownerOf(dormantTokenIdOf[positionId][generation - 1]) != address(0))) revert InvalidReceipt();
        uint256 tokenId = ++mintedCount;
        tokenIdOf[positionId][generation] = tokenId;
        _receipts[tokenId] = Receipt(positionId, generation, ReceiptKind.Active);
        emit ReceiptMinted(tokenId, positionId, generation, ReceiptKind.Active);
        _mint(owner, tokenId);
    }

    /// @notice Burns a live Active receipt that may still carry principal (fusion inputs, P2.6): Principal only,
    /// while it holds its own lock (the mint guard). The tombstone, `tokenIdOf` and the art stay; the burn raises
    /// `receiptTransferNonce` and clears approvals. No Principal call: the financial state is Principal's own.
    function retireActive(uint256 positionId, uint64 generation) external {
        if (msg.sender != core || NARAPrincipalLedgerV5(core).moduleLockHolder() != core) revert Unauthorized();
        uint256 tokenId = tokenIdOf[positionId][generation];
        if (tokenId == 0 || _ownerOf(tokenId) == address(0) || _receipts[tokenId].kind != ReceiptKind.Active) revert InvalidReceipt();
        _burn(tokenId);
        emit ReceiptRetired(tokenId, positionId, generation);
    }

    /// @dev Only Principal may consume a dormant receipt, after exact new funding
    /// and while it holds the complete graph lock. Tombstones/maps are retained.
    /// No Principal financial read is needed inside this identity transition.
    function consumeDormant(address owner, uint256 positionId, uint64 generation,
        uint256 tokenId, uint256 expectedNonce) external
    {
        if (msg.sender != core || NARAPrincipalLedgerV5(core).moduleLockHolder() != core) revert Unauthorized();
        uint256 canonicalId = dormantTokenIdOf[positionId][generation];
        CommonRechargeBlockerV5 blocker = NARAPrincipalPreviewV5.rechargeReceipt(
            owner, tokenId, expectedNonce, canonicalId, receiptTransferNonce[canonicalId], _ownerOf(canonicalId));
        if (blocker != CommonRechargeBlockerV5.None) revert RechargeBlocked(blocker);
        Receipt memory r = _receipts[tokenId];
        if (r.positionId != positionId || r.generation != generation || r.kind != ReceiptKind.Dormant) revert InvalidReceipt();
        _burn(tokenId);
        emit DormantConsumed(tokenId, positionId, generation);
    }

    /// @notice After principal has left and the last eligible pulse is closed,
    /// replace the retired financial receipt with a new collectible-only ID.
    /// Unpaid rewards stay with the archived financial owner without any payout.
    /// @dev A11: any ERC-721-authorized caller; a caller other than the owner may deliver only to the owner.
    /// A31-02: the recipient takes the mint form when it is the owner and the transfer form (adapter set
    /// included) when the owner names a third party. A pending attempt freezes it (A5, R12).
    function materializeDormant(uint256 tokenId, address recipient) external returns (uint256 dormantId) {
        address owner = ownerOf(tokenId);
        if (!_isAuthorized(owner, msg.sender, tokenId)) revert Unauthorized();
        if (msg.sender != owner && recipient != owner) revert InvalidRecipient();
        _validateRecipient(recipient, recipient != owner);
        Receipt memory r = _receipts[tokenId];
        PositionState memory p = NARAPrincipalLedgerV5(core).positionHead(r.positionId);
        if (r.kind != ReceiptKind.Active || p.generation != r.generation || !p.withdrawn
            || p.generationOwner != owner || dormantTokenIdOf[r.positionId][r.generation] != 0) revert InvalidReceipt();
        if (NARALifecycleLedgerV5(_lifecycleLedger).pendingAttempt(r.positionId, r.generation) != bytes32(0)) revert AttemptPending();
        if (NARARewardLedgerV5(rewards).rewardState().nextCheckpoint < p.effectiveEnd) revert SettlementPending();
        _burn(tokenId);
        dormantId = ++mintedCount;
        dormantTokenIdOf[r.positionId][r.generation] = dormantId;
        _receipts[dormantId] = Receipt(r.positionId, r.generation, ReceiptKind.Dormant);
        emit ReceiptMinted(dormantId, r.positionId, r.generation, ReceiptKind.Dormant);
        emit DormantMaterialized(tokenId, dormantId, recipient);
        _safeMint(recipient, dormantId);
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        // OZ performs ERC721 authorization and clears token approval first.
        // No receiver callback occurs until this override has fully returned.
        from = super._update(to, tokenId, auth);
        if (from != address(0)) ++receiptTransferNonce[tokenId];
        // Mints take the mint form (no adapter read, AR3-04); transfers the transfer form.
        if (to != address(0)) _validateRecipient(to, from != address(0));
        if (from != address(0) && to != address(0)) {
            Receipt memory r = _receipts[tokenId];
            if (r.kind == ReceiptKind.Active) {
                NARAPrincipalLedgerV5(core).transferPosition(r.positionId, r.generation, from, to);
            } else {
                PositionState memory p = NARAPrincipalLedgerV5(core).positionHead(r.positionId);
                if (p.generation != r.generation || !p.withdrawn) revert InvalidReceipt();
            }
            emit MetadataUpdate(tokenId);
        }
    }

    /// @dev Principal's fixed deny-list (no external call, no governance-writable storage) plus the NFT-only sinks
    /// (the renderer and its immutable children, and the Card) on every mint and transfer; on a transfer, and on a
    /// materialization to a third party, also the Forge's O(1) adapter set (design §4.4, §4.7). No other mint
    /// makes a Forge call, so no governance action can revert a mint, a refund or a materialization to the owner.
    function _validateRecipient(address recipient, bool transfer) private view {
        if (NARAPrincipalLedgerV5(core).isProtocolSink(recipient) || recipient == renderer || recipient == _art
            || recipient == _statsReader || recipient == _card
            || (transfer && INARAForgeIdentityV5(forge).isAdapterOrFormer(recipient))) revert InvalidRecipient();
    }
}
