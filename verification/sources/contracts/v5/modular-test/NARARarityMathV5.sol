// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice Stateless arithmetic for the original-principal capped rarity rule.
/// @dev This reference envelope selects no launch odds, fees, duration curve or
/// rarity award. Supplied amounts and multipliers are unauthenticated inputs:
/// a quote proves neither deposited principal nor ownership of a valid cap.
contract NARARarityMathV5 {
    struct Terms {
        uint256 principal;
        uint256 originalPrincipalCap;
        uint256 rarityMultiplierWad;
        uint256 durationWad;
    }

    struct Quote {
        uint256 rarityPrincipal;
        uint256 commonPrincipal;
        /// @dev Ordinary duration-only reference, NOT selected adaptive demand.
        uint256 commonReferenceWeight;
        uint256 rewardWeight;
        /// @dev Difference of rounded weights; fractional carry can make this
        /// one unit larger than the floor of the exact rarity-only bonus.
        uint256 bonusWeight;
        /// @dev Numerator remainder modulo 1e36. Diagnostic weight precision,
        /// never principal, earned rewards or a separately payable credit.
        uint256 roundingNumerator;
    }

    uint256 public constant SCHEMA_VERSION = 1;
    uint256 private constant WAD = 1e18;
    uint256 private constant SCALE = 1e36;
    uint256 private constant MAX_PRINCIPAL = 1_000_000e18;
    uint256 private constant MAX_RARITY_WAD = 100e18;
    uint256 private constant MAX_DURATION_WAD = 4e18;

    error InvalidPrincipal(uint256 principal);
    error InvalidOriginalPrincipalCap(uint256 originalPrincipalCap);
    error InvalidRarityMultiplier(uint256 rarityMultiplierWad);
    error InvalidDurationMultiplier(uint256 durationWad);

    /// @notice Return the floor of the complete weighted principal expression.
    /// @dev Zero principal is valid arithmetic, not authorization for a zero
    /// deposit. Cap reuse, generations, award policy and model demand must be
    /// authenticated separately. No intermediate weight or tranche is rounded.
    function quote(Terms calldata terms) external pure returns (Quote memory q) {
        uint256 p = terms.principal;
        uint256 c = terms.originalPrincipalCap;
        uint256 a = terms.rarityMultiplierWad;
        uint256 d = terms.durationWad;
        if (p > MAX_PRINCIPAL) revert InvalidPrincipal(p);
        if (c == 0 || c > MAX_PRINCIPAL) revert InvalidOriginalPrincipalCap(c);
        if (a < WAD || a > MAX_RARITY_WAD) revert InvalidRarityMultiplier(a);
        if (d < WAD || d > MAX_DURATION_WAD) revert InvalidDurationMultiplier(d);

        q.rarityPrincipal = p < c ? p : c;
        q.commonPrincipal = p - q.rarityPrincipal;
        // Validated numerator <= 400 * 1e24 * 1e36 = 4e62 (208 bits).
        // Checked uint256 multiplication is sufficient for this exact domain.
        uint256 numerator = d * (p * WAD + q.rarityPrincipal * (a - WAD));
        q.rewardWeight = numerator / SCALE;
        q.commonReferenceWeight = p * d / WAD;
        q.bonusWeight = q.rewardWeight - q.commonReferenceWeight;
        q.roundingNumerator = numerator % SCALE;
    }
}
