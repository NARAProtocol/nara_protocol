// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @dev Types for the bounded v5 adaptive-emission model candidate. These
/// definitions preserve integer model mechanics; they do not approve economic
/// parameters, custody behavior, position weighting, or reserve settlement.

error InvalidEmissionConfig();
error InvalidEmissionState();
error InvalidEmissionInputs();

/// @notice Complete coefficient vector consumed by the adaptive model.
struct EmissionConfig {
    uint256 eMax;
    uint256 beta0Wad;
    uint256 mWad;
    uint256 aWad;
    uint256 bWad;
    uint256 cWad;
    uint256 dWad;
    uint256 dripSplitWad;
    uint256 growthFactorWad;
    uint256 minBaseEmission;
    uint256 maxBaseEmission;
    uint256 warmupRateWad;
    uint256 bootstrapDecayWad;
}

/// @notice Model values carried from one pulse calculation to the next.
struct EmissionState {
    uint256 baseEmission;
    uint256 warmupFactorWad;
    uint256 stressWad;
    uint256 bootstrapWeight;
}

/// @notice Ledger-derived inputs supplied by a future accounting core.
/// @dev `modelFloat` and `modelWeight` are model inputs, not token balances read
/// or position weights calculated by this contract.
struct EmissionInputs {
    uint256 modelFloat;
    uint256 modelWeight;
}

/// @notice One deterministic adaptive-emission calculation.
/// @dev `targetNara` is the final theoretical distribution after drip, warmup,
/// zero-weight handling, and bootstrap dilution. `retainedAdmittedNara` is
/// `admittedNara - targetNara`; it is diagnostic only and is not treasury funds.
/// A future funded reserve may pay less than `targetNara` when funds are unavailable.
struct EmissionQuote {
    EmissionState nextState;
    uint256 weightedLockShareWad;
    uint256 betaWad;
    uint256 horizon;
    uint256 retentionWad;
    uint256 emission;
    uint256 admittedNara;
    uint256 targetNara;
    uint256 retainedAdmittedNara;
    uint256 heartbeat;
}
