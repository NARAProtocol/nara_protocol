// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {NARAPositionNFTV5} from "./NARAPositionNFTV5.sol";
import {NARAPrincipalLedgerV5} from "./NARAPrincipalLedgerV5.sol";
import {NARARewardLedgerV5} from "./NARARewardLedgerV5.sol";
import {NARARewardLensV5} from "./NARARewardLensV5.sol";
import {NARARewardIngressV5} from "./NARARewardIngressV5.sol";
import {INARAEpochCoordinatorV5} from "./NARAModuleInterfacesV5.sol";
import {CoreBindings, PositionState, RewardAsset, RewardCredit} from "../interfaces/NARAAccountingTypesV5.sol";

/// @notice Fixed-NFT native-ETH sales with atomic principal and unpaid-credit bounds.
/// @dev First-Sale terms (owner decision C5, 2026-10-08; FIX_PLAN 3.4-3.6):
/// a per-seller counter with `cancelAll`, a constructor-fixed listing lifetime
/// cap, `Cancelled` on overwrite, pull payouts, credit minima in native units,
/// no self-purchase and a 0.5% fee pushed to the bound RewardIngress.
/// The adapter has no administration, graph-lock authority or escrow beyond
/// seller proceeds awaiting withdrawal. Constructor checks establish reciprocal
/// bindings, not audited code identity. Deployment is permissionless: only the
/// published canonical address's events count as NARA sales (SAL-N02).
/// Revoking this adapter's ERC-721 approval pauses a listing without cancelling
/// it; a later approval resumes it until `cancel`, `cancelAll`, a transfer or
/// its expiry (at most `maxListingLifetime` after listing) ends it.
/// Owner decisions S-1 and S-2 (2026-10-13): the constructor refuses a fee
/// recipient whose code is an EIP-7702 delegation designator, and anyone may
/// pay a seller its credited proceeds to the seller's own address.
contract NARAPositionSaleV5 is ReentrancyGuardTransient {
    struct Listing {
        uint256 listingId;
        address seller;
        uint256 tokenId;
        uint256 transferNonce;
        uint256 positionId;
        uint64 generation;
        bytes32 termsHash;
        uint256 price;
        uint64 expiry;
        // Seller-wide counter at listing time; `cancelAll` voids every listing
        // that carries an older value, whatever its approval or code state.
        uint256 sellerNonce;
    }

    struct BuyerBounds {
        uint256 expectedListingId;
        uint256 minPrincipal;
        // NARA, native ETH, USDC in each asset's native base units (18, 18, 6
        // decimals), compared with RewardCredit.claimable. Never 1e27-scaled.
        uint256[3] minClaimable;
        uint64 minRewardCheckpoint;
        uint64 deadline;
        uint8 minRarityTier;
    }

    uint256 public constant SCHEMA_VERSION = 2;
    /// @notice Fee retained from every purchase price and pushed to the ingress (5% = 500 bps).
    uint256 public constant FEE_BPS = 500;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @notice Bounds for the owner-supplied lifetime cap (decision C5 / O4).
    uint64 public constant MIN_LISTING_LIFETIME = 1 hours;
    uint64 public constant MAX_LISTING_LIFETIME = 365 days;
    /// @dev Code prefix of an EIP-7702 delegation designator (`0xef0100 || address`).
    /// No deployed contract starts with 0xef (EIP-3541), so the prefix is decisive.
    bytes3 private constant DELEGATION_DESIGNATOR = 0xef0100;
    NARAPositionNFTV5 public immutable nft;
    NARAPrincipalLedgerV5 public immutable principal;
    NARARewardLedgerV5 public immutable rewards;
    NARARewardLensV5 public immutable creditLens;
    NARARewardIngressV5 public immutable ingress;
    /// @notice Longest interval between listing and expiry, in seconds.
    uint64 public immutable maxListingLifetime;
    uint256 public lastListingId;
    /// @notice Seller-wide invalidation counter; incremented by `cancelAll`.
    mapping(address seller => uint256) public sellerNonce;
    /// @notice Net sale proceeds awaiting the seller's own withdrawal.
    mapping(address seller => uint256) public proceeds;
    /// @notice Sum of every uncollected credit; always covered by this balance.
    uint256 public outstandingProceeds;
    mapping(uint256 tokenId => Listing) private _listings;

    error InvalidBinding();
    error DelegatedIngress();
    error InvalidLifetime();
    error InvalidListing();
    error InvalidBacking();
    error Expired();
    error InvalidExpiry();
    error InvalidPayment();
    error Unauthorized();
    error SelfPurchase();
    error PaymentFailed();
    error InvalidAcquisition();
    error NothingToWithdraw();

    event Listed(
        uint256 indexed listingId, uint256 indexed tokenId, address indexed seller,
        uint256 transferNonce, uint256 positionId, uint64 generation,
        bytes32 termsHash, uint256 price, uint64 expiry
    );
    event Cancelled(uint256 indexed listingId, uint256 indexed tokenId, address indexed seller);
    event CancelledAll(address indexed seller, uint256 sellerNonce);
    event Purchased(
        uint256 indexed listingId, uint256 indexed tokenId, address indexed buyer,
        address seller, uint256 price, uint256 fee
    );
    event ProceedsWithdrawn(address indexed seller, address indexed recipient, uint256 amount);

    constructor(address nft_, address ingress_, uint64 maxListingLifetime_) {
        if (maxListingLifetime_ < MIN_LISTING_LIFETIME || maxListingLifetime_ > MAX_LISTING_LIFETIME) revert InvalidLifetime();
        if (nft_.code.length == 0 || ingress_.code.length == 0 || ingress_ == nft_) revert InvalidBinding();
        // S-1: a delegated EOA running the ingress code answers every getter below
        // like the canonical ingress, but its key holder would own the fees.
        if (bytes3(ingress_.code) == DELEGATION_DESIGNATOR) revert DelegatedIngress();
        NARAPositionNFTV5 receipt = NARAPositionNFTV5(nft_);
        address pAddress = receipt.core();
        address rAddress = receipt.rewards();
        if (pAddress.code.length == 0 || rAddress.code.length == 0
            || pAddress == rAddress || pAddress == nft_ || rAddress == nft_
            || ingress_ == pAddress || ingress_ == rAddress
            || receipt.financialSchemaVersion() != 2) revert InvalidBinding();
        NARAPrincipalLedgerV5 p = NARAPrincipalLedgerV5(pAddress);
        NARARewardLedgerV5 r = NARARewardLedgerV5(rAddress);
        if (p.SCHEMA_VERSION() != 3 || r.SCHEMA_VERSION() != 2
            || p.positionNFT() != nft_ || p.rewards() != rAddress || r.principal() != pAddress
            || !p.bindingsSealed() || !r.initialized() || p.moduleLockHolder() != address(0)
            || p.engine().code.length == 0 || r.engine() != p.engine()
            || r.nara() != p.nara() || r.reserve() != p.reserve()
            || p.genesisTimestamp() == 0 || r.genesisTimestamp() != p.genesisTimestamp()) revert InvalidBinding();
        NARARewardIngressV5 fees = NARARewardIngressV5(payable(ingress_));
        if (fees.SCHEMA_VERSION() != 1 || fees.rewards() != rAddress
            || fees.nara() != p.nara() || fees.usdc() != r.usdc()) revert InvalidBinding();
        INARAEpochCoordinatorV5 engine = INARAEpochCoordinatorV5(p.engine());
        CoreBindings memory b = engine.bindings();
        (address boundPrincipal, address boundRewards) = engine.financialModules();
        (uint64 genesis,) = engine.principalEpoch();
        if (b.schemaVersion != 1 || !b.bindingsSealed || !b.activated
            || b.bootstrapAuthority != address(0) || b.positionNFT != nft_
            || b.nara != p.nara() || b.reserve != p.reserve()
            || boundPrincipal != pAddress || boundRewards != rAddress || genesis != p.genesisTimestamp()
            || engine.principalBindingHash() != p.bindingHash()
            || engine.rewardBindingHash() != r.bindingHash()) revert InvalidBinding();
        nft = receipt;
        principal = p;
        rewards = r;
        ingress = fees;
        maxListingLifetime = maxListingLifetime_;
        // This helper's code is fixed by this build, never supplied by a seller,
        // buyer or presentation governor. Every failed financial read reverts.
        creditLens = new NARARewardLensV5();
    }

    /// @notice Raw pending record. A nonzero record is not a validity preview:
    /// ownership, nonce, backing, approvals, credits, the seller counter and
    /// time may have changed.
    function listing(uint256 tokenId) external view returns (Listing memory) {
        return _listings[tokenId];
    }

    /// @notice Only the receipt owner can list or replace an offer. An ERC721
    /// approval to this adapter is separately necessary when a buyer purchases.
    /// Replacing a live record emits `Cancelled` for the replaced ID.
    function list(uint256 tokenId, uint256 price, uint64 expiry)
        external nonReentrant returns (uint256 listingId)
    {
        if (price == 0) revert InvalidPayment();
        if (expiry <= block.timestamp) revert Expired();
        if (expiry - block.timestamp > maxListingLifetime) revert InvalidExpiry();
        if (nft.ownerOf(tokenId) != msg.sender) revert Unauthorized();
        (NARAPositionNFTV5.Receipt memory receipt, PositionState memory p) = _activeBacking(tokenId, msg.sender);
        uint256 nonce = nft.receiptTransferNonce(tokenId);
        Listing memory previous = _listings[tokenId];
        if (previous.listingId != 0) emit Cancelled(previous.listingId, tokenId, previous.seller);
        listingId = ++lastListingId;
        _listings[tokenId] = Listing(
            listingId, msg.sender, tokenId, nonce, receipt.positionId,
            receipt.generation, p.termsHash, price, expiry, sellerNonce[msg.sender]
        );
        emit Listed(
            listingId, tokenId, msg.sender, nonce, receipt.positionId,
            receipt.generation, p.termsHash, price, expiry
        );
    }

    /// @notice The recorded seller can cancel even after transferring the NFT.
    /// A stale cancellation cannot remove a replacement with a different ID.
    function cancel(uint256 tokenId, uint256 expectedListingId) external nonReentrant {
        Listing memory offer = _listings[tokenId];
        if (offer.listingId == 0 || offer.listingId != expectedListingId) revert InvalidListing();
        if (offer.seller != msg.sender) revert Unauthorized();
        delete _listings[tokenId];
        emit Cancelled(offer.listingId, tokenId, offer.seller);
    }

    /// @notice Void every listing the caller has ever recorded in one
    /// transaction, including paused ones its approvals or code no longer let
    /// fill. Records stay readable; `purchase` rejects them with InvalidListing.
    function cancelAll() external nonReentrant {
        uint256 next = ++sellerNonce[msg.sender];
        emit CancelledAll(msg.sender, next);
    }

    /// @notice Acquire the entire active receipt. The seller is credited its
    /// price net of the fee for later withdrawal; the fee goes to the ingress.
    /// @dev Bounds apply immediately before acquisition. The receiver may claim
    /// or withdraw after acquiring ownership, so credits are not rechecked after
    /// callbacks. Any additional transfer, self-transfer or burn invalidates the
    /// purchase. The seller runs no code during a purchase, so a seller whose
    /// account rejects ETH can still sell (DOS-N01, CHN-N01).
    function purchase(uint256 tokenId, BuyerBounds calldata bounds) external payable nonReentrant {
        Listing memory offer = _listings[tokenId];
        if (offer.listingId == 0 || offer.listingId != bounds.expectedListingId) revert InvalidListing();
        if (offer.sellerNonce != sellerNonce[offer.seller]) revert InvalidListing();
        if (block.timestamp > offer.expiry || block.timestamp > bounds.deadline) revert Expired();
        if (msg.sender == offer.seller) revert SelfPurchase();
        // Forced ETH surplus never substitutes for this buyer's exact payment.
        if (msg.value != offer.price) revert InvalidPayment();
        delete _listings[tokenId];

        _checkAcquisition(offer, bounds);
        uint256 fee = offer.price * FEE_BPS / BPS_DENOMINATOR;
        uint256 net = offer.price - fee;
        proceeds[offer.seller] += net;
        outstandingProceeds += net;
        if (fee != 0) {
            // The ingress receive() only logs; it is the fixed reward inventory.
            (bool forwarded,) = payable(address(ingress)).call{value: fee}("");
            if (!forwarded) revert PaymentFailed();
        }
        nft.safeTransferFrom(offer.seller, msg.sender, tokenId);

        PositionState memory acquired = principal.positionHead(offer.positionId);
        if (nft.ownerOf(tokenId) != msg.sender || acquired.generationOwner != msg.sender
            || acquired.generation != offer.generation
            || nft.receiptTransferNonce(tokenId) != offer.transferNonce + 1) revert InvalidAcquisition();
        emit Purchased(offer.listingId, tokenId, msg.sender, offer.seller, offer.price, fee);
    }

    /// @notice Collect every credited sale proceed to a recipient of the
    /// seller's choice. Forced surplus is never paid out; only credits are.
    function withdrawProceeds(address recipient) external nonReentrant returns (uint256 amount) {
        if (recipient == address(0)) revert InvalidPayment();
        return _withdraw(msg.sender, recipient);
    }

    /// @notice Pay `seller` every proceed credited to it, to `seller` itself
    /// (S-2). Anyone may call; no other recipient can be chosen. Native ETH is
    /// the only currency the Sale credits. A seller whose account rejects ETH
    /// keeps its credit and can still `withdrawProceeds` to another recipient.
    function withdrawProceedsFor(address seller) external nonReentrant returns (uint256 amount) {
        return _withdraw(seller, seller);
    }

    /// @dev The one accounting and event of both withdrawals: the credit is
    /// cleared before the transfer, and a rejected payment reverts in full.
    function _withdraw(address seller, address recipient) private returns (uint256 amount) {
        amount = proceeds[seller];
        if (amount == 0) revert NothingToWithdraw();
        proceeds[seller] = 0;
        outstandingProceeds -= amount;
        (bool paid,) = payable(recipient).call{value: amount}("");
        if (!paid) revert PaymentFailed();
        emit ProceedsWithdrawn(seller, recipient, amount);
    }

    function _activeBacking(uint256 tokenId, address seller) private view returns (
        NARAPositionNFTV5.Receipt memory receipt, PositionState memory p
    ) {
        receipt = nft.receiptInfo(tokenId);
        p = principal.positionHead(receipt.positionId);
        if (receipt.kind != NARAPositionNFTV5.ReceiptKind.Active
            || receipt.generation != p.generation || p.generationOwner != seller
            || p.withdrawn || p.effectiveEnd != p.maturity || p.principal == 0
            || nft.tokenIdOf(receipt.positionId, receipt.generation) != tokenId) revert InvalidBacking();
    }

    function _checkAcquisition(Listing memory offer, BuyerBounds calldata bounds) private view {
        if (nft.ownerOf(offer.tokenId) != offer.seller
            || nft.receiptTransferNonce(offer.tokenId) != offer.transferNonce) revert InvalidBacking();
        (NARAPositionNFTV5.Receipt memory receipt, PositionState memory p) = _activeBacking(offer.tokenId, offer.seller);
        if (receipt.positionId != offer.positionId || receipt.generation != offer.generation
            || p.termsHash != offer.termsHash || p.principal < bounds.minPrincipal
            || principal.rarityTier(offer.positionId, offer.generation) < bounds.minRarityTier) revert InvalidBacking();
        if (rewards.rewardState().nextCheckpoint < bounds.minRewardCheckpoint) revert InvalidBacking();
        // All three reads are mandatory even for zero minima. No partial-read
        // fallback or settlement loop can silently redefine the acquired asset.
        for (uint8 i; i < 3; ++i) {
            RewardCredit memory credit = creditLens.credit(rewards, offer.positionId, offer.generation, RewardAsset(i));
            if (credit.generationOwner != offer.seller || credit.generation != offer.generation
                || credit.claimable < bounds.minClaimable[i]) revert InvalidBacking();
        }
    }
}
