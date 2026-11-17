// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {PositionViewV5, PositionStatusV5} from "./NARAPositionViewTypesV5.sol";

/// @dev Pure display rules shared by JSON and SVG; no economic authority.
library NARAPositionDisplayV5 {
    using Strings for uint256;
    error InvalidTier();
    error InvalidPrecision();
    function tierStyle(uint8 tier) internal pure returns (string memory label, string memory color) {
        if (tier == 0) return ("Common", "#9CA3AF");
        if (tier == 1) return ("Uncommon", "#22C55E");
        if (tier == 2) return ("Rare", "#3B82F6");
        if (tier == 3) return ("Epic", "#A855F7");
        if (tier == 4) return ("Legendary", "#F59E0B");
        if (tier == 5) return ("Exotic", "#67E8F9");
        revert InvalidTier();
    }

    /// @notice Exact decimal text with insignificant trailing zeros removed.
    function formatUnits(uint256 amount, uint8 decimals) internal pure returns (string memory) {
        if (decimals > 18) revert InvalidPrecision();
        uint256 unit = 10 ** decimals;
        string memory whole = (amount / unit).toString();
        uint256 fraction = amount % unit;
        if (fraction == 0) return whole;
        uint256 digits = decimals;
        while (fraction % 10 == 0) { fraction /= 10; --digits; }
        bytes memory tail = new bytes(digits);
        while (digits != 0) { tail[--digits] = bytes1(uint8(48 + fraction % 10)); fraction /= 10; }
        return string.concat(whole, ".", string(tail));
    }

    function _status(PositionStatusV5 status) internal pure returns (string memory) {
        if (status == PositionStatusV5.Pending) return "Pending";
        if (status == PositionStatusV5.Active) return "Active";
        if (status == PositionStatusV5.Matured) return "Matured";
        if (status == PositionStatusV5.Withdrawn) return "Withdrawn";
        return "Dormant";
    }
    function _withdrawal(PositionViewV5 memory v) internal pure returns (string memory) {
        if (v.lifecycle.consumed) return "Consumed in fusion";
        if (v.status == PositionStatusV5.Dormant) return "Collectible only";
        if (v.status == PositionStatusV5.Withdrawn) return "Principal withdrawn";
        if (v.status == PositionStatusV5.Matured) return "Principal available to withdraw";
        uint256 remaining = v.unlockTimestamp - v.asOfTimestamp;
        if (remaining < 60) return "Unlocks in less than 1 minute";
        return string.concat("Unlocks in ", (remaining / 86400).toString(), "d ", ((remaining / 3600) % 24).toString(), "h ", ((remaining / 60) % 60).toString(), "m");
    }
    function _reward(PositionViewV5 memory v, uint8 asset) internal pure returns (string memory) {
        if (!v.rewardReadSuccess[asset]) return "Unavailable";
        if (v.status == PositionStatusV5.Withdrawn || v.status == PositionStatusV5.Dormant || v.lifecycle.consumed) {
            return string.concat("Archived (financial owner: ", formatUnits(v.archivedClaimable[asset], asset == 2 ? 6 : 18), ")");
        }
        return formatUnits(v.attachedClaimable[asset], asset == 2 ? 6 : 18);
    }
    function _asset(uint8 asset) internal pure returns (string memory) { return asset == 0 ? "NARA" : asset == 1 ? "ETH" : "USDC"; }
    function _percent(uint256 ratioWad, bool positive) internal pure returns (string memory) {
        uint256 hundredths = ratioWad / 1e14;
        if (hundredths == 0 && positive) return "Less than 0.01%";
        return string.concat(formatUnits(hundredths, 2), "%");
    }
    function _share(PositionViewV5 memory v) internal pure returns (string memory) {
        return v.totalRewardWeight == 0 ? "No eligible pool" : _percent(v.rewardShareWad, v.eligibleModelWeight != 0 || v.eligibleRewardWeight != 0);
    }
    function _rate(PositionViewV5 memory v) internal pure returns (string memory) {
        if (!v.rewardReadSuccess[0]) return "Unavailable";
        if (!v.historicalNaraRateAvailable) return "Requires 96 completed eligible pulses";
        return _percent(v.historicalNaraRateWad, v.positionRewardsEarned[0] != 0);
    }
}
