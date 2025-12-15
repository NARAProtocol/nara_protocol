// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

abstract contract NaraTiers {
    // ═══════════════════════════════════════════════════════════════════════
    // TIER THRESHOLDS (12 tiers)
    // ═══════════════════════════════════════════════════════════════════════
    uint256 public constant TIER_SEEDLING   = 1e17;        // 0.1 NARA - mining eligible
    uint256 public constant TIER_SPROUT     = 1e18;        // 1 NARA
    uint256 public constant TIER_SAPLING    = 10e18;       // 10 NARA
    uint256 public constant TIER_TREE       = 50e18;       // 50 NARA (NEW)
    uint256 public constant TIER_GROVE      = 100e18;      // 100 NARA
    uint256 public constant TIER_FOREST     = 500e18;      // 500 NARA (NEW)
    uint256 public constant TIER_WOODLAND   = 1_000e18;    // 1,000 NARA
    uint256 public constant TIER_JUNGLE     = 2_500e18;    // 2,500 NARA (NEW)
    uint256 public constant TIER_RAINFOREST = 5_000e18;    // 5,000 NARA
    uint256 public constant TIER_AMAZON     = 10_000e18;   // 10,000 NARA
    uint256 public constant TIER_EDEN       = 50_000e18;   // 50,000 NARA (NEW)
    uint256 public constant TIER_GAIA       = 100_000e18;  // 100,000 NARA

    // Time thresholds for bonus progression
    uint256 public constant TIME_1H   = 1 hours;
    uint256 public constant TIME_6H   = 6 hours;
    uint256 public constant TIME_24H  = 24 hours;
    uint256 public constant TIME_3D   = 3 days;
    uint256 public constant TIME_7D   = 7 days;
    uint256 public constant TIME_14D  = 14 days;
    uint256 public constant TIME_28D  = 28 days;
    uint256 public constant TIME_60D  = 60 days;
    uint256 public constant TIME_90D  = 90 days;
    uint256 public constant TIME_180D = 180 days;
    uint256 public constant TIME_365D = 365 days;

    // ═══════════════════════════════════════════════════════════════════════
    // TIER TIMESTAMPS - tracks when user entered each tier
    // ═══════════════════════════════════════════════════════════════════════
    // ═══════════════════════════════════════════════════════════════════════
    // TIER TIMESTAMPS - tracks when user entered each tier
    // ═══════════════════════════════════════════════════════════════════════
    // Index 0 = Seedling, 1 = Sprout, ..., 11 = Gaia
    mapping(address => uint64[12]) public tierStarts;

    uint256 public miningHoldDurationSeconds = 0;

    // ═══════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════
    event TierEntered(address indexed user, uint8 indexed tierIndex);
    event TierLost(address indexed user, uint8 indexed tierIndex);
    event MiningHoldDurationUpdated(uint256 newSeconds);

    // Abstract function to get balance (implemented by token contract)
    // Abstract function to get balance (implemented by token contract)
    function _balanceOf(address account) internal view virtual returns (uint256);

    // ═══════════════════════════════════════════════════════════════════════
    // TIER UPDATE LOGIC
    // ═══════════════════════════════════════════════════════════════════════
    function _updateTiers(address user, uint256 bal) internal {
        uint64[12] storage starts = tierStarts[user];
        uint64 now64 = uint64(block.timestamp);

        for (uint8 i = 0; i < 12; ) {
            uint256 threshold = _getTierThreshold(i);
            
            if (bal >= threshold) {
                if (starts[i] == 0) {
                    starts[i] = now64;
                    emit TierEntered(user, i);
                }
            } else if (starts[i] != 0) {
                starts[i] = 0;
                emit TierLost(user, i);
            }

            unchecked { ++i; }
        }
    }

    function _getTierThreshold(uint8 index) internal pure returns (uint256) {
        if (index == 0) return TIER_SEEDLING;
        if (index == 1) return TIER_SPROUT;
        if (index == 2) return TIER_SAPLING;
        if (index == 3) return TIER_TREE;
        if (index == 4) return TIER_GROVE;
        if (index == 5) return TIER_FOREST;
        if (index == 6) return TIER_WOODLAND;
        if (index == 7) return TIER_JUNGLE;
        if (index == 8) return TIER_RAINFOREST;
        if (index == 9) return TIER_AMAZON;
        if (index == 10) return TIER_EDEN;
        if (index == 11) return TIER_GAIA;
        return type(uint256).max;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // BONUS CALCULATION
    // ═══════════════════════════════════════════════════════════════════════
    
    /// @notice Get the total holding bonus for a user (amount + time combined)
    /// @dev Returns bonus in basis points (e.g., 5000 = +50%)
    function getHoldingBonus(address user) external view returns (uint256 bonusBps) {
        return _calculateHoldingBonus(user);
    }

    function _calculateHoldingBonus(address user) internal view returns (uint256 bonusBps) {
        uint64[12] storage starts = tierStarts[user];
        uint256 nowSec = block.timestamp;

        if (starts[11] > 0) { // Gaia
            uint256 held = nowSec - starts[11];
            if (held >= TIME_365D) return 18000;
            if (held >= TIME_180D) return 15000;
            if (held >= TIME_90D)  return 13000;
            if (held >= TIME_60D)  return 11000;
            if (held >= TIME_28D)  return 9000;
            return 7000;
        }

        if (starts[10] > 0) { // Eden
            uint256 held = nowSec - starts[10];
            if (held >= TIME_180D) return 13000;
            if (held >= TIME_90D)  return 11500;
            if (held >= TIME_60D)  return 10000;
            if (held >= TIME_28D)  return 8500;
            if (held >= TIME_14D)  return 7000;
            return 5500;
        }

        if (starts[9] > 0) { // Amazon
            uint256 held = nowSec - starts[9];
            if (held >= TIME_90D)  return 10000;
            if (held >= TIME_60D)  return 8800;
            if (held >= TIME_28D)  return 7500;
            if (held >= TIME_14D)  return 6200;
            if (held >= TIME_7D)   return 5000;
            return 4000;
        }

        if (starts[8] > 0) { // Rainforest
            uint256 held = nowSec - starts[8];
            if (held >= TIME_60D)  return 7500;
            if (held >= TIME_28D)  return 6500;
            if (held >= TIME_14D)  return 5500;
            if (held >= TIME_7D)   return 4200;
            if (held >= TIME_3D)   return 3200;
            return 2500;
        }

        if (starts[7] > 0) { // Jungle
            uint256 held = nowSec - starts[7];
            if (held >= TIME_28D)  return 5500;
            if (held >= TIME_14D)  return 4800;
            if (held >= TIME_7D)   return 3800;
            if (held >= TIME_3D)   return 2800;
            if (held >= TIME_24H)  return 2000;
            return 1500;
        }

        if (starts[6] > 0) { // Woodland
            uint256 held = nowSec - starts[6];
            if (held >= TIME_28D)  return 4500;
            if (held >= TIME_14D)  return 3800;
            if (held >= TIME_7D)   return 3000;
            if (held >= TIME_3D)   return 2200;
            if (held >= TIME_24H)  return 1600;
            return 1200;
        }

        if (starts[5] > 0) { // Forest
            uint256 held = nowSec - starts[5];
            if (held >= TIME_14D)  return 3000;
            if (held >= TIME_7D)   return 2500;
            if (held >= TIME_3D)   return 1800;
            if (held >= TIME_24H)  return 1400;
            if (held >= TIME_6H)   return 1000;
            return 700;
        }

        if (starts[4] > 0) { // Grove
            uint256 held = nowSec - starts[4];
            if (held >= TIME_7D)   return 2000;
            if (held >= TIME_3D)   return 1500;
            if (held >= TIME_24H)  return 1100;
            if (held >= TIME_6H)   return 800;
            if (held >= TIME_1H)   return 500;
            return 300;
        }

        if (starts[3] > 0) { // Tree
            uint256 held = nowSec - starts[3];
            if (held >= TIME_7D)   return 1500;
            if (held >= TIME_3D)   return 1200;
            if (held >= TIME_24H)  return 900;
            if (held >= TIME_6H)   return 600;
            if (held >= TIME_1H)   return 400;
            return 200;
        }

        if (starts[2] > 0) { // Sapling
            uint256 held = nowSec - starts[2];
            if (held >= TIME_3D)   return 1000;
            if (held >= TIME_24H)  return 700;
            if (held >= TIME_6H)   return 500;
            if (held >= TIME_1H)   return 300;
            return 150;
        }

        if (starts[1] > 0) { // Sprout
            uint256 held = nowSec - starts[1];
            if (held >= TIME_24H)  return 500;
            if (held >= TIME_6H)   return 300;
            if (held >= TIME_1H)   return 200;
            return 100;
        }

        return 0;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // DETAILED TIER INFO
    // ═══════════════════════════════════════════════════════════════════════

    struct TierInfo {
        uint8 tierIndex;
        string tierName;
        uint256 requiredAmount;
        uint64 enteredAt;
        uint256 timeHeld;
        uint256 currentBonusBps;
        uint256 nextBonusBps;
        uint256 timeToNextBonus;
    }

    function getCurrentTierInfo(address user) external view returns (TierInfo memory info) {
        uint64[12] storage starts = tierStarts[user];
        uint256 bal = _balanceOf(user);
        uint256 nowSec = block.timestamp;

        if (bal >= TIER_GAIA && starts[11] > 0) {
            info.tierIndex = 11;
            info.tierName = "Gaia";
            info.requiredAmount = TIER_GAIA;
            info.enteredAt = starts[11];
            info.timeHeld = nowSec - starts[11];
            (info.currentBonusBps, info.nextBonusBps, info.timeToNextBonus) = _getGaiaBonusDetails(info.timeHeld);
        } else if (bal >= TIER_EDEN && starts[10] > 0) {
            info.tierIndex = 10;
            info.tierName = "Eden";
            info.requiredAmount = TIER_EDEN;
            info.enteredAt = starts[10];
            info.timeHeld = nowSec - starts[10];
            (info.currentBonusBps, info.nextBonusBps, info.timeToNextBonus) = _getEdenBonusDetails(info.timeHeld);
        } else if (bal >= TIER_AMAZON && starts[9] > 0) {
            info.tierIndex = 9;
            info.tierName = "Amazon";
            info.requiredAmount = TIER_AMAZON;
            info.enteredAt = starts[9];
            info.timeHeld = nowSec - starts[9];
            (info.currentBonusBps, info.nextBonusBps, info.timeToNextBonus) = _getAmazonBonusDetails(info.timeHeld);
        } else if (bal >= TIER_RAINFOREST && starts[8] > 0) {
            info.tierIndex = 8;
            info.tierName = "Rainforest";
            info.requiredAmount = TIER_RAINFOREST;
            info.enteredAt = starts[8];
            info.timeHeld = nowSec - starts[8];
            (info.currentBonusBps, info.nextBonusBps, info.timeToNextBonus) = _getRainforestBonusDetails(info.timeHeld);
        } else if (bal >= TIER_JUNGLE && starts[7] > 0) {
            info.tierIndex = 7;
            info.tierName = "Jungle";
            info.requiredAmount = TIER_JUNGLE;
            info.enteredAt = starts[7];
            info.timeHeld = nowSec - starts[7];
            (info.currentBonusBps, info.nextBonusBps, info.timeToNextBonus) = _getJungleBonusDetails(info.timeHeld);
        } else if (bal >= TIER_WOODLAND && starts[6] > 0) {
            info.tierIndex = 6;
            info.tierName = "Woodland";
            info.requiredAmount = TIER_WOODLAND;
            info.enteredAt = starts[6];
            info.timeHeld = nowSec - starts[6];
            (info.currentBonusBps, info.nextBonusBps, info.timeToNextBonus) = _getWoodlandBonusDetails(info.timeHeld);
        } else if (bal >= TIER_FOREST && starts[5] > 0) {
            info.tierIndex = 5;
            info.tierName = "Forest";
            info.requiredAmount = TIER_FOREST;
            info.enteredAt = starts[5];
            info.timeHeld = nowSec - starts[5];
            (info.currentBonusBps, info.nextBonusBps, info.timeToNextBonus) = _getForestBonusDetails(info.timeHeld);
        } else if (bal >= TIER_GROVE && starts[4] > 0) {
            info.tierIndex = 4;
            info.tierName = "Grove";
            info.requiredAmount = TIER_GROVE;
            info.enteredAt = starts[4];
            info.timeHeld = nowSec - starts[4];
            (info.currentBonusBps, info.nextBonusBps, info.timeToNextBonus) = _getGroveBonusDetails(info.timeHeld);
        } else if (bal >= TIER_TREE && starts[3] > 0) {
            info.tierIndex = 3;
            info.tierName = "Tree";
            info.requiredAmount = TIER_TREE;
            info.enteredAt = starts[3];
            info.timeHeld = nowSec - starts[3];
            (info.currentBonusBps, info.nextBonusBps, info.timeToNextBonus) = _getTreeBonusDetails(info.timeHeld);
        } else if (bal >= TIER_SAPLING && starts[2] > 0) {
            info.tierIndex = 2;
            info.tierName = "Sapling";
            info.requiredAmount = TIER_SAPLING;
            info.enteredAt = starts[2];
            info.timeHeld = nowSec - starts[2];
            (info.currentBonusBps, info.nextBonusBps, info.timeToNextBonus) = _getSaplingBonusDetails(info.timeHeld);
        } else if (bal >= TIER_SPROUT && starts[1] > 0) {
            info.tierIndex = 1;
            info.tierName = "Sprout";
            info.requiredAmount = TIER_SPROUT;
            info.enteredAt = starts[1];
            info.timeHeld = nowSec - starts[1];
            (info.currentBonusBps, info.nextBonusBps, info.timeToNextBonus) = _getSproutBonusDetails(info.timeHeld);
        } else if (bal >= TIER_SEEDLING && starts[0] > 0) {
            info.tierIndex = 0;
            info.tierName = "Seedling";
            info.requiredAmount = TIER_SEEDLING;
            info.enteredAt = starts[0];
            info.timeHeld = nowSec - starts[0];
            info.currentBonusBps = 0;
            info.nextBonusBps = 100;
            // Seedling does not have a time-based bonus next. 
            // User must upgrade balance to Sprout to unlock time bonuses.
            info.timeToNextBonus = 0;
        } else {
            info.tierIndex = 255;
            info.tierName = "None";
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // BONUS DETAIL HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    function _getSproutBonusDetails(uint256 held) internal pure returns (uint256 current, uint256 next, uint256 timeToNext) {
        if (held >= TIME_24H) return (500, 0, 0);
        if (held >= TIME_6H) return (300, 500, TIME_24H - held);
        if (held >= TIME_1H) return (200, 300, TIME_6H - held);
        return (100, 200, TIME_1H - held);
    }

    function _getSaplingBonusDetails(uint256 held) internal pure returns (uint256 current, uint256 next, uint256 timeToNext) {
        if (held >= TIME_3D) return (1000, 0, 0);
        if (held >= TIME_24H) return (700, 1000, TIME_3D - held);
        if (held >= TIME_6H) return (500, 700, TIME_24H - held);
        if (held >= TIME_1H) return (300, 500, TIME_6H - held);
        return (150, 300, TIME_1H - held);
    }

    function _getTreeBonusDetails(uint256 held) internal pure returns (uint256 current, uint256 next, uint256 timeToNext) {
        if (held >= TIME_7D) return (1500, 0, 0);
        if (held >= TIME_3D) return (1200, 1500, TIME_7D - held);
        if (held >= TIME_24H) return (900, 1200, TIME_3D - held);
        if (held >= TIME_6H) return (600, 900, TIME_24H - held);
        if (held >= TIME_1H) return (400, 600, TIME_6H - held);
        return (200, 400, TIME_1H - held);
    }

    function _getGroveBonusDetails(uint256 held) internal pure returns (uint256 current, uint256 next, uint256 timeToNext) {
        if (held >= TIME_7D) return (2000, 0, 0);
        if (held >= TIME_3D) return (1500, 2000, TIME_7D - held);
        if (held >= TIME_24H) return (1100, 1500, TIME_3D - held);
        if (held >= TIME_6H) return (800, 1100, TIME_24H - held);
        if (held >= TIME_1H) return (500, 800, TIME_6H - held);
        return (300, 500, TIME_1H - held);
    }

    function _getForestBonusDetails(uint256 held) internal pure returns (uint256 current, uint256 next, uint256 timeToNext) {
        if (held >= TIME_14D) return (3000, 0, 0);
        if (held >= TIME_7D) return (2500, 3000, TIME_14D - held);
        if (held >= TIME_3D) return (1800, 2500, TIME_7D - held);
        if (held >= TIME_24H) return (1400, 1800, TIME_3D - held);
        if (held >= TIME_6H) return (1000, 1400, TIME_24H - held);
        return (700, 1000, TIME_6H - held);
    }

    function _getWoodlandBonusDetails(uint256 held) internal pure returns (uint256 current, uint256 next, uint256 timeToNext) {
        if (held >= TIME_28D) return (4500, 0, 0);
        if (held >= TIME_14D) return (3800, 4500, TIME_28D - held);
        if (held >= TIME_7D) return (3000, 3800, TIME_14D - held);
        if (held >= TIME_3D) return (2200, 3000, TIME_7D - held);
        if (held >= TIME_24H) return (1600, 2200, TIME_3D - held);
        return (1200, 1600, TIME_24H - held);
    }

    function _getJungleBonusDetails(uint256 held) internal pure returns (uint256 current, uint256 next, uint256 timeToNext) {
        if (held >= TIME_28D) return (5500, 0, 0);
        if (held >= TIME_14D) return (4800, 5500, TIME_28D - held);
        if (held >= TIME_7D) return (3800, 4800, TIME_14D - held);
        if (held >= TIME_3D) return (2800, 3800, TIME_7D - held);
        if (held >= TIME_24H) return (2000, 2800, TIME_3D - held);
        return (1500, 2000, TIME_24H - held);
    }

    function _getRainforestBonusDetails(uint256 held) internal pure returns (uint256 current, uint256 next, uint256 timeToNext) {
        if (held >= TIME_60D) return (7500, 0, 0);
        if (held >= TIME_28D) return (6500, 7500, TIME_60D - held);
        if (held >= TIME_14D) return (5500, 6500, TIME_28D - held);
        if (held >= TIME_7D) return (4200, 5500, TIME_14D - held);
        if (held >= TIME_3D) return (3200, 4200, TIME_7D - held);
        return (2500, 3200, TIME_3D - held);
    }

    function _getAmazonBonusDetails(uint256 held) internal pure returns (uint256 current, uint256 next, uint256 timeToNext) {
        if (held >= TIME_90D) return (10000, 0, 0);
        if (held >= TIME_60D) return (8800, 10000, TIME_90D - held);
        if (held >= TIME_28D) return (7500, 8800, TIME_60D - held);
        if (held >= TIME_14D) return (6200, 7500, TIME_28D - held);
        if (held >= TIME_7D) return (5000, 6200, TIME_14D - held);
        return (4000, 5000, TIME_7D - held);
    }

    function _getEdenBonusDetails(uint256 held) internal pure returns (uint256 current, uint256 next, uint256 timeToNext) {
        if (held >= TIME_180D) return (13000, 0, 0);
        if (held >= TIME_90D) return (11500, 13000, TIME_180D - held);
        if (held >= TIME_60D) return (10000, 11500, TIME_90D - held);
        if (held >= TIME_28D) return (8500, 10000, TIME_60D - held);
        if (held >= TIME_14D) return (7000, 8500, TIME_28D - held);
        return (5500, 7000, TIME_14D - held);
    }

    function _getGaiaBonusDetails(uint256 held) internal pure returns (uint256 current, uint256 next, uint256 timeToNext) {
        if (held >= TIME_365D) return (18000, 0, 0);
        if (held >= TIME_180D) return (15000, 18000, TIME_365D - held);
        if (held >= TIME_90D) return (13000, 15000, TIME_180D - held);
        if (held >= TIME_60D) return (11000, 13000, TIME_90D - held);
        if (held >= TIME_28D) return (9000, 11000, TIME_60D - held);
        return (7000, 9000, TIME_28D - held);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // NEXT TIER INFO
    // ═══════════════════════════════════════════════════════════════════════

    struct NextTierInfo {
        uint8 nextTierIndex;
        string nextTierName;
        uint256 requiredAmount;
        uint256 amountNeeded;
        uint256 instantBonusBps;
    }

    function getNextTierInfo(address user) external view returns (NextTierInfo memory info) {
        uint256 bal = _balanceOf(user);

        if (bal < TIER_SEEDLING) {
            info = NextTierInfo(0, "Seedling", TIER_SEEDLING, TIER_SEEDLING - bal, 0);
        } else if (bal < TIER_SPROUT) {
            info = NextTierInfo(1, "Sprout", TIER_SPROUT, TIER_SPROUT - bal, 100);
        } else if (bal < TIER_SAPLING) {
            info = NextTierInfo(2, "Sapling", TIER_SAPLING, TIER_SAPLING - bal, 150);
        } else if (bal < TIER_TREE) {
            info = NextTierInfo(3, "Tree", TIER_TREE, TIER_TREE - bal, 200);
        } else if (bal < TIER_GROVE) {
            info = NextTierInfo(4, "Grove", TIER_GROVE, TIER_GROVE - bal, 300);
        } else if (bal < TIER_FOREST) {
            info = NextTierInfo(5, "Forest", TIER_FOREST, TIER_FOREST - bal, 700);
        } else if (bal < TIER_WOODLAND) {
            info = NextTierInfo(6, "Woodland", TIER_WOODLAND, TIER_WOODLAND - bal, 1200);
        } else if (bal < TIER_JUNGLE) {
            info = NextTierInfo(7, "Jungle", TIER_JUNGLE, TIER_JUNGLE - bal, 1500);
        } else if (bal < TIER_RAINFOREST) {
            info = NextTierInfo(8, "Rainforest", TIER_RAINFOREST, TIER_RAINFOREST - bal, 2500);
        } else if (bal < TIER_AMAZON) {
            info = NextTierInfo(9, "Amazon", TIER_AMAZON, TIER_AMAZON - bal, 4000);
        } else if (bal < TIER_EDEN) {
            info = NextTierInfo(10, "Eden", TIER_EDEN, TIER_EDEN - bal, 5500);
        } else if (bal < TIER_GAIA) {
            info = NextTierInfo(11, "Gaia", TIER_GAIA, TIER_GAIA - bal, 7000);
        } else {
            info = NextTierInfo(255, "Max", 0, 0, 0);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MINING ELIGIBILITY
    // ═══════════════════════════════════════════════════════════════════════

    function canMine(address user) public view returns (bool) {
        uint256 balance = _balanceOf(user);
        if (balance < TIER_SEEDLING) return false;
        
        uint64[12] storage starts = tierStarts[user];
        if (starts[0] == 0) return false;
        
        uint256 holdDuration = block.timestamp - uint256(starts[0]);
        return holdDuration >= miningHoldDurationSeconds;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // LEGACY COMPATIBILITY
    // ═══════════════════════════════════════════════════════════════════════

    function getHighestTierBonus(address user) external view returns (uint256 bonusBps) {
        return _calculateHoldingBonus(user);
    }

    function tiers(address user) external view returns (
        uint64 miningEligibleStart,
        uint64 bronzeStart,
        uint64 silverStart,
        uint64 goldStart,
        uint64 platinumStart,
        uint64 diamondStart
    ) {
        uint64[12] storage starts = tierStarts[user];
        return (
            starts[0],
            starts[1],
            starts[2],
            starts[4],
            starts[6],
            starts[8]
        );
    }
}
