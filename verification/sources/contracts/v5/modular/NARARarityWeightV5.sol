// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice The accepted duration-capped reward weight (A6 amended; LIFECYCLE_DESIGN.md §3.3, §5.2).
/// @dev Internal library, inlined by its callers (the admission child and the lifecycle child). Pure
/// arithmetic only: it authenticates no principal, cap, tier or award. One floor at the end.
library NARARarityWeightV5 {
    uint256 private constant WAD = 1e18;
    uint256 private constant MAX_PRINCIPAL = 1_000_000e18;
    uint256 private constant MAX_MULTIPLIER_WAD = 100e18;
    uint256 private constant MAX_DURATION_WAD = 4e18;

    error InvalidWeightTerms();

    /// @notice floor((D*P*WAD + min(P,C)*(A-WAD)*min(D,Daw)) / WAD^2).
    /// @dev Domain: P <= 1e24, C >= 1 (no upper bound: only min(P, C) enters), WAD <= A <= 100e18,
    /// WAD <= D <= 4e18 and WAD <= Daw <= 4e18. The numerator is at most 4e60 + 3.96e62 < 2^256 for every C.
    /// With A == WAD the result is exactly floor(P*D/WAD), the Common model weight.
    function weight(uint256 principal, uint256 originalCap, uint256 multiplierWad, uint256 durationWad,
        uint256 awardedDurationWad) internal pure returns (uint256)
    {
        if (principal > MAX_PRINCIPAL || originalCap == 0 || multiplierWad < WAD || multiplierWad > MAX_MULTIPLIER_WAD
            || durationWad < WAD || durationWad > MAX_DURATION_WAD
            || awardedDurationWad < WAD || awardedDurationWad > MAX_DURATION_WAD) revert InvalidWeightTerms();
        uint256 capped = principal < originalCap ? principal : originalCap;
        uint256 effective = durationWad < awardedDurationWad ? durationWad : awardedDurationWad;
        return (durationWad * principal * WAD + capped * (multiplierWad - WAD) * effective) / (WAD * WAD);
    }

    /// @notice The accepted tier multipliers: 1X, 3X, 10X, 25X, 50X, 100X (owner decision: 100X maximum).
    function multiplierWad(uint8 tier) internal pure returns (uint256) {
        if (tier == 0) return WAD;
        if (tier == 1) return 3e18;
        if (tier == 2) return 10e18;
        if (tier == 3) return 25e18;
        if (tier == 4) return 50e18;
        if (tier == 5) return 100e18;
        revert InvalidWeightTerms();
    }
}
