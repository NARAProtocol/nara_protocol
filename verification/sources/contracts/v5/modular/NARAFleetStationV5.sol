// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {NARAPositionNFTV5} from "./NARAPositionNFTV5.sol";
import {NARAPrincipalLedgerV5} from "./NARAPrincipalLedgerV5.sol";
import {NARARewardLedgerV5} from "./NARARewardLedgerV5.sol";
import {PositionState, RewardAsset} from "../interfaces/NARAAccountingTypesV5.sol";

/// @title NARAFleetStationV5
/// @notice On-chain Armada Fleet Station for NARA Position NFTs.
/// @dev Manages 6 formation slots per player with a 7-day commitment cycle.
/// Provides up to +50.00% reward synergy multiplier scaled on the total weight of
/// actively locked cards. Early unslots forfeit the synergy bonus to the survivor pool.
contract NARAFleetStationV5 is IERC721Receiver, ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant SCHEMA_VERSION = 1;
    uint256 public constant MAX_SLOTS = 6;
    uint256 public constant ARMADA_CYCLE = 7 days;
    uint256 public constant MIN_SLOT_PRINCIPAL = 50 ether; // 50 NARA minimum per slot
    uint16 public constant MAX_SYNERGY_BPS = 5000; // +50.00% hard ceiling
    uint16 public constant BPS = 10_000;

    // Hard fee boundaries
    uint256 public constant MIN_FEE = 0.0001 ether;
    uint256 public constant MAX_FEE = 0.0100 ether;

    // Configurable fees (governed within hard bounds)
    uint256 public slotFee = 0.0005 ether;
    uint256 public batchFillFee = 0.0025 ether;
    uint256 public matureUnslotFee = 0.0002 ether;
    uint256 public earlyUnslotFee = 0.0020 ether;

    // Core protocol addresses
    address public immutable positionNFT;
    address public immutable principalLedger;
    address public immutable rewardLedger;
    address public immutable naraToken;
    address public immutable feeVault;

    struct SlotInfo {
        uint256 tokenId;
        uint256 positionId;
        uint64 generation;
        uint64 slottedAt;
        uint64 cycleExpiry;
        uint256 principal;
        uint256 baseWeight;
        uint8 alloyTier;
    }

    struct FleetDeckView {
        address user;
        uint256 slottedCount;
        uint256 totalSlottedPrincipal;
        uint256 totalBaseWeight;
        uint256 effectiveWeight;
        uint16 totalSynergyBps;
        uint16 formationBonusBps;
        uint16 spectrumBonusBps;
        uint16 flagshipBonusBps;
        bool isHexaArmada;
        bool isFullSpectrum;
        bool isFlagshipEquipped;
        bool isCycleMature;
        uint64 earliestCycleExpiry;
        SlotInfo[6] slots;
    }

    // Storage
    mapping(address => SlotInfo[MAX_SLOTS]) private _userSlots;
    mapping(uint256 => address) public slottedTokenOwner;
    mapping(uint256 => uint8) public testTierOverride; // Optional test/staging tier override
    mapping(uint256 => bool) public hasTestTierOverride;
    bool private _claimingRewards;

    // Survivor Pools & Synergy Reserves
    uint256 public survivorPoolEth;
    uint256 public survivorPoolNara;
    uint256 public totalArmadaWeight;

    // Errors
    error InvalidBinding();
    error InvalidFee();
    error InvalidSlot();
    error SlotOccupied();
    error SlotEmpty();
    error Unauthorized();
    error InvalidReceipt();
    error AlreadyWithdrawn();
    error PrincipalTooLow();
    error CycleNotMature();
    error InvalidParameter();
    error TransferFailed();

    // Events
    event CardSlotted(address indexed user, uint8 indexed slotIndex, uint256 indexed tokenId, uint256 principal, uint256 baseWeight, uint8 alloyTier, uint64 cycleExpiry);
    event CardUnslotted(address indexed user, uint8 indexed slotIndex, uint256 indexed tokenId, bool wasEarlyForfeit, uint256 feePaid);
    event FleetHarvested(address indexed user, address indexed recipient, uint256 baseNara, uint256 bonusNara, uint256 baseEth, uint256 bonusEth, uint256 usdcAmount, uint16 synergyBps);
    event SynergyReserveFunded(address indexed donor, uint256 amount);
    event FeesUpdated(uint256 slotFee, uint256 batchFillFee, uint256 matureUnslotFee, uint256 earlyUnslotFee);
    event SurvivorSweep(address indexed recipient, uint256 ethAmount, uint256 naraAmount);

    constructor(
        address positionNFT_,
        address principalLedger_,
        address rewardLedger_,
        address naraToken_,
        address feeVault_,
        address governor_
    ) Ownable(governor_) {
        if (positionNFT_.code.length == 0 || principalLedger_.code.length == 0 || rewardLedger_.code.length == 0
            || naraToken_.code.length == 0 || governor_ == address(0)) revert InvalidBinding();
        positionNFT = positionNFT_;
        principalLedger = principalLedger_;
        rewardLedger = rewardLedger_;
        naraToken = naraToken_;
        feeVault = feeVault_;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view override returns (bytes4) {
        if (msg.sender != positionNFT) revert Unauthorized();
        return this.onERC721Received.selector;
    }

    // ============================================================
    // Slotting Operations
    // ============================================================

    /// @notice Slot a single Position NFT into an open formation slot.
    /// @param slotIndex Index from 0 to 5.
    /// @param tokenId The ERC-721 token ID of the position receipt.
    function slotCard(uint8 slotIndex, uint256 tokenId) external payable nonReentrant {
        if (msg.value != slotFee) revert InvalidFee();
        _slotCard(msg.sender, slotIndex, tokenId);
        survivorPoolEth += msg.value;
    }

    /// @notice Batch fill all 6 formation slots at a discounted fee.
    /// @param tokenIds Array of exactly 6 token IDs.
    function fillDeck(uint256[6] calldata tokenIds) external payable nonReentrant {
        if (msg.value != batchFillFee) revert InvalidFee();
        for (uint8 i = 0; i < MAX_SLOTS; ++i) {
            _slotCard(msg.sender, i, tokenIds[i]);
        }
        survivorPoolEth += msg.value;
    }

    function _slotCard(address user, uint8 slotIndex, uint256 tokenId) private {
        if (slotIndex >= MAX_SLOTS) revert InvalidSlot();
        if (_userSlots[user][slotIndex].tokenId != 0) revert SlotOccupied();
        if (slottedTokenOwner[tokenId] != address(0)) revert SlotOccupied();
        if (NARAPositionNFTV5(positionNFT).ownerOf(tokenId) != user) revert Unauthorized();

        NARAPositionNFTV5.Receipt memory r = NARAPositionNFTV5(positionNFT).receiptInfo(tokenId);
        if (r.kind != NARAPositionNFTV5.ReceiptKind.Active) revert InvalidReceipt();

        PositionState memory pos = NARAPrincipalLedgerV5(principalLedger).position(r.positionId, r.generation);
        if (pos.withdrawn) revert AlreadyWithdrawn();
        if (pos.principal < MIN_SLOT_PRINCIPAL) revert PrincipalTooLow();

        uint8 alloy = hasTestTierOverride[tokenId]
            ? testTierOverride[tokenId]
            : NARAPrincipalLedgerV5(principalLedger).rarityTier(r.positionId, r.generation);

        uint64 expiry = uint64(block.timestamp + ARMADA_CYCLE);
        _userSlots[user][slotIndex] = SlotInfo(
            tokenId,
            r.positionId,
            r.generation,
            uint64(block.timestamp),
            expiry,
            pos.principal,
            pos.rewardWeight,
            alloy
        );
        slottedTokenOwner[tokenId] = user;

        NARAPositionNFTV5(positionNFT).safeTransferFrom(user, address(this), tokenId);

        emit CardSlotted(user, slotIndex, tokenId, pos.principal, pos.rewardWeight, alloy, expiry);
    }

    // ============================================================
    // Unslotting Operations
    // ============================================================

    /// @notice Unslot a card. If unslotted before 7 days, forfeits synergy bonus and charges early fee.
    /// @param slotIndex Index from 0 to 5.
    function unslotCard(uint8 slotIndex) external payable nonReentrant {
        if (slotIndex >= MAX_SLOTS) revert InvalidSlot();
        SlotInfo memory slot = _userSlots[msg.sender][slotIndex];
        if (slot.tokenId == 0) revert SlotEmpty();

        bool isEarly = block.timestamp < slot.cycleExpiry;
        uint256 requiredFee = isEarly ? earlyUnslotFee : matureUnslotFee;
        if (msg.value != requiredFee) revert InvalidFee();

        // Harvest any accrued rewards before clearing slot
        _harvestSlot(msg.sender, slotIndex, msg.sender, !isEarly);

        uint256 tokenId = slot.tokenId;
        delete _userSlots[msg.sender][slotIndex];
        delete slottedTokenOwner[tokenId];

        survivorPoolEth += msg.value;

        // Return NFT to user
        NARAPositionNFTV5(positionNFT).safeTransferFrom(address(this), msg.sender, tokenId);

        emit CardUnslotted(msg.sender, slotIndex, tokenId, isEarly, msg.value);
    }

    // ============================================================
    // Harvesting & Reward Synergy
    // ============================================================

    /// @notice Harvest rewards for all active slots in user's deck.
    /// @param recipient Address to receive harvested resources.
    function harvestFleet(address recipient) external nonReentrant returns (
        uint256 totalBaseNara, uint256 totalBonusNara,
        uint256 totalBaseEth, uint256 totalBonusEth,
        uint256 totalUsdc
    ) {
        if (recipient == address(0)) revert Unauthorized();
        FleetDeckView memory deck = getFleetDeck(msg.sender);
        for (uint8 i = 0; i < MAX_SLOTS; ++i) {
            if (deck.slots[i].tokenId != 0) {
                bool slotMature = block.timestamp >= deck.slots[i].cycleExpiry;
                (uint256 bNara, uint256 bonNara, uint256 bEth, uint256 bonEth, uint256 usdc) = 
                    _harvestSlot(msg.sender, i, recipient, slotMature);
                totalBaseNara += bNara; totalBonusNara += bonNara;
                totalBaseEth += bEth; totalBonusEth += bonEth;
                totalUsdc += usdc;
            }
        }
        emit FleetHarvested(msg.sender, recipient, totalBaseNara, totalBonusNara, totalBaseEth, totalBonusEth, totalUsdc, deck.totalSynergyBps);
    }

    function _harvestSlot(address user, uint8 slotIndex, address recipient, bool includeBonus) private returns (
        uint256 baseNara, uint256 bonusNara,
        uint256 baseEth, uint256 bonusEth,
        uint256 usdcPaid
    ) {
        SlotInfo memory slot = _userSlots[user][slotIndex];
        if (slot.tokenId == 0) return (0, 0, 0, 0, 0);

        NARARewardLedgerV5 rewards = NARARewardLedgerV5(rewardLedger);

        // Claim base NARA
        baseNara = rewards.claim(slot.positionId, slot.generation, RewardAsset.NARA, address(this));

        // Claim base ETH
        _claimingRewards = true;
        baseEth = rewards.claim(slot.positionId, slot.generation, RewardAsset.ETH, address(this));
        _claimingRewards = false;

        // Claim base USDC
        usdcPaid = rewards.claim(slot.positionId, slot.generation, RewardAsset.USDC, address(this));

        uint16 synergyBps = includeBonus ? _calculateSynergyBps(user) : 0;

        if (synergyBps > 0) {
            // Calculate and cap NARA bonus
            uint256 targetBonusNara = (baseNara * synergyBps) / BPS;
            bonusNara = targetBonusNara > survivorPoolNara ? survivorPoolNara : targetBonusNara;
            survivorPoolNara -= bonusNara;

            // Calculate and cap ETH bonus from survivor pool
            uint256 targetBonusEth = (baseEth * synergyBps) / BPS;
            bonusEth = targetBonusEth > survivorPoolEth ? survivorPoolEth : targetBonusEth;
            survivorPoolEth -= bonusEth;
        }

        // Deliver NARA
        uint256 totalNara = baseNara + bonusNara;
        if (totalNara > 0) {
            IERC20(naraToken).safeTransfer(recipient, totalNara);
        }

        // Deliver ETH
        uint256 totalEth = baseEth + bonusEth;
        if (totalEth > 0) {
            (bool success, ) = payable(recipient).call{value: totalEth}("");
            if (!success) revert TransferFailed();
        }

        // Deliver USDC
        if (usdcPaid > 0) {
            address usdcToken = rewards.usdc();
            IERC20(usdcToken).safeTransfer(recipient, usdcPaid);
        }
    }

    // ============================================================
    // Synergy Mathematics & Views
    // ============================================================

    /// @notice Get real-time formation telemetry for a user's deck.
    function getFleetDeck(address user) public view returns (FleetDeckView memory v) {
        v.user = user;
        uint256 activeCount = 0;
        uint256 totalPrincipal = 0;
        uint256 totalWeight = 0;
        bool allMature = true;
        uint64 earliestExpiry = type(uint64).max;

        bool[5] memory hasTier; // Tiers 0..4

        for (uint8 i = 0; i < MAX_SLOTS; ++i) {
            SlotInfo memory slot = _userSlots[user][i];
            v.slots[i] = slot;
            if (slot.tokenId != 0) {
                ++activeCount;
                totalPrincipal += slot.principal;
                totalWeight += slot.baseWeight;
                if (slot.alloyTier <= 4) {
                    hasTier[slot.alloyTier] = true;
                }
                if (slot.cycleExpiry < earliestExpiry) {
                    earliestExpiry = slot.cycleExpiry;
                }
                if (block.timestamp < slot.cycleExpiry) {
                    allMature = false;
                }
            }
        }

        v.slottedCount = activeCount;
        v.totalSlottedPrincipal = totalPrincipal;
        v.totalBaseWeight = totalWeight;
        v.isCycleMature = activeCount > 0 && allMature;
        v.earliestCycleExpiry = earliestExpiry == type(uint64).max ? 0 : earliestExpiry;

        if (activeCount == 0) return v;

        // Formation bonus: +5% per card from 2 up to 6 (+25%)
        if (activeCount >= 6) { v.formationBonusBps = 2500; v.isHexaArmada = true; }
        else if (activeCount == 5) v.formationBonusBps = 2000;
        else if (activeCount == 4) v.formationBonusBps = 1500;
        else if (activeCount == 3) v.formationBonusBps = 1000;
        else if (activeCount == 2) v.formationBonusBps = 500;

        // Full Spectrum: +15% if all 5 tiers (0..4) are present
        if (hasTier[0] && hasTier[1] && hasTier[2] && hasTier[3] && hasTier[4]) {
            v.spectrumBonusBps = 1500;
            v.isFullSpectrum = true;
        }

        // Flagship Escort: +10% if Slot 0 has Tier 4 (24K Celestial Aurum)
        if (v.slots[0].alloyTier == 4) {
            v.flagshipBonusBps = 1000;
            v.isFlagshipEquipped = true;
        }

        uint16 totalBps = v.formationBonusBps + v.spectrumBonusBps + v.flagshipBonusBps;
        if (totalBps > MAX_SYNERGY_BPS) totalBps = MAX_SYNERGY_BPS;
        v.totalSynergyBps = totalBps;

        v.effectiveWeight = totalWeight + (totalWeight * totalBps) / BPS;
    }

    function _calculateSynergyBps(address user) private view returns (uint16) {
        return getFleetDeck(user).totalSynergyBps;
    }

    // ============================================================
    // Synergy Reserve Funding & Treasury Sweeps
    // ============================================================

    /// @notice Permissionlessly fund the NARA bonus matching reserve.
    function fundSynergyReserve(uint256 amount) external nonReentrant {
        IERC20(naraToken).safeTransferFrom(msg.sender, address(this), amount);
        survivorPoolNara += amount;
        emit SynergyReserveFunded(msg.sender, amount);
    }

    /// @notice Fund ETH directly to the survivor pool.
    receive() external payable {
        if (!_claimingRewards) {
            survivorPoolEth += msg.value;
        }
    }

    // ============================================================
    // Governance Controls (Bounded & Timelocked)
    // ============================================================

    function updateFees(
        uint256 newSlotFee,
        uint256 newBatchFillFee,
        uint256 newMatureUnslotFee,
        uint256 newEarlyUnslotFee
    ) external onlyOwner {
        if (newSlotFee < MIN_FEE || newSlotFee > MAX_FEE) revert InvalidParameter();
        if (newBatchFillFee < MIN_FEE || newBatchFillFee > MAX_FEE) revert InvalidParameter();
        if (newMatureUnslotFee < MIN_FEE || newMatureUnslotFee > MAX_FEE) revert InvalidParameter();
        if (newEarlyUnslotFee < MIN_FEE || newEarlyUnslotFee > MAX_FEE) revert InvalidParameter();

        slotFee = newSlotFee;
        batchFillFee = newBatchFillFee;
        matureUnslotFee = newMatureUnslotFee;
        earlyUnslotFee = newEarlyUnslotFee;

        emit FeesUpdated(newSlotFee, newBatchFillFee, newMatureUnslotFee, newEarlyUnslotFee);
    }

    /// @dev Test/staging helper allowing testing of all alloy tiers before CardForge roll engine is bound.
    function setTestTierOverride(uint256 tokenId, uint8 tier) external onlyOwner {
        testTierOverride[tokenId] = tier;
        hasTestTierOverride[tokenId] = true;
    }
}
