// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {
    EmissionConfig,
    EmissionInputs,
    EmissionQuote,
    EmissionState,
    InvalidEmissionConfig,
    InvalidEmissionInputs,
    InvalidEmissionState
} from "./NARAEmissionTypesV5.sol";

/// @title NARA v5 Adaptive Emission Model
/// @notice Stateless, bounded integer implementation of the retained v4 adaptive
/// emission equations for independent calibration and differential testing.
/// @dev This checked candidate preserves the v4 operation order and floor rounding.
/// It owns no funds or lifecycle state and defines no approved policy defaults,
/// duration weights, rarity values, reward payouts, randomness, or administration.
contract NARAEmissionModelV5 {
    uint256 public constant MODEL_VERSION = 1;
    uint256 public constant WAD = 1e18;
    uint256 public constant FIXED_SUPPLY = 1_000_000 ether;

    /// @dev Arithmetic input envelope only; this does not select a duration curve.
    uint256 public constant MAX_MODEL_WEIGHT = 10_000_000 ether;
    uint256 public constant MAX_BOOTSTRAP_WEIGHT = 10_000_000 ether;

    uint256 private constant MAX_PARAMETER_WAD = 10e18;
    uint256 private constant MAX_GROWTH_FACTOR_WAD = 2e18;

    /// @notice Reverts unless every coefficient is inside the model's arithmetic envelope.
    /// @dev Passing validation establishes bounded arithmetic only, not economic approval.
    function validateConfig(EmissionConfig calldata config) external pure {
        _validateConfig(config);
    }

    /// @notice Calculates the next adaptive state and theoretical NARA target.
    /// @dev Every multiplication/division uses `Math.mulDiv` in the same sequence as
    /// the frozen v4 model, so intermediate floor rounding is intentional. This
    /// function does not cap the target to an available funded reserve.
    function calculateNext(
        EmissionConfig calldata config,
        EmissionState calldata previous,
        EmissionInputs calldata inputs
    ) external pure returns (EmissionQuote memory quote) {
        _validateConfig(config);
        _validateState(previous);
        _validateInputs(inputs);

        uint256 warmup = previous.warmupFactorWad
            + Math.mulDiv(config.warmupRateWad, WAD - previous.warmupFactorWad, WAD);
        uint256 bootstrap = Math.mulDiv(previous.bootstrapWeight, config.bootstrapDecayWad, WAD);

        uint256 denominator = inputs.modelFloat + inputs.modelWeight + bootstrap;
        uint256 weightedLockShare = denominator == 0
            ? 0
            : Math.mulDiv(inputs.modelWeight, WAD, denominator);

        uint256 baseEmission = previous.baseEmission == 0
            ? config.minBaseEmission
            : Math.mulDiv(previous.baseEmission, config.growthFactorWad, WAD);
        baseEmission = _bound(baseEmission, config.minBaseEmission, config.maxBaseEmission);

        uint256 incentive = WAD + Math.mulDiv(config.aWad, weightedLockShare, WAD);
        uint256 penalty = Math.mulDiv(config.bWad, previous.stressWad, WAD);
        uint256 emissionFactor = incentive > penalty ? incentive - penalty : 0;
        uint256 emission = _bound(
            Math.mulDiv(baseEmission, emissionFactor, WAD),
            0,
            config.maxBaseEmission
        );

        uint256 beta = config.beta0Wad + Math.mulDiv(config.mWad, previous.stressWad, WAD);
        uint256 horizon = Math.mulDiv(config.eMax, WAD, beta);

        uint256 retention = 0;
        if (horizon > 0 && inputs.modelFloat < horizon) {
            retention = WAD - Math.mulDiv(inputs.modelFloat, WAD, horizon);
        }

        uint256 admitted = Math.mulDiv(emission, retention, WAD);
        uint256 dripTarget = Math.mulDiv(admitted, config.dripSplitWad, WAD);
        dripTarget = Math.mulDiv(dripTarget, warmup, WAD);

        uint256 target = 0;
        if (inputs.modelWeight > 0) {
            target = Math.mulDiv(
                dripTarget,
                inputs.modelWeight,
                inputs.modelWeight + bootstrap
            );
        }

        uint256 emissionToHorizon = horizon == 0 ? 0 : Math.mulDiv(emission, WAD, horizon);
        uint256 stress = Math.mulDiv(config.cWad, WAD - weightedLockShare, WAD)
            + Math.mulDiv(config.dWad, emissionToHorizon, WAD);
        if (stress > WAD) stress = WAD;

        quote = EmissionQuote({
            nextState: EmissionState({
                baseEmission: baseEmission,
                warmupFactorWad: warmup,
                stressWad: stress,
                bootstrapWeight: bootstrap
            }),
            weightedLockShareWad: weightedLockShare,
            betaWad: beta,
            horizon: horizon,
            retentionWad: retention,
            emission: emission,
            admittedNara: admitted,
            targetNara: target,
            retainedAdmittedNara: admitted - target,
            heartbeat: emission == 0 ? type(uint256).max : horizon / emission
        });
    }

    function _validateConfig(EmissionConfig calldata config) private pure {
        if (config.eMax == 0 || config.eMax > FIXED_SUPPLY) revert InvalidEmissionConfig();
        if (config.beta0Wad == 0 || config.beta0Wad > MAX_PARAMETER_WAD) {
            revert InvalidEmissionConfig();
        }
        if (
            config.mWad > MAX_PARAMETER_WAD || config.aWad > MAX_PARAMETER_WAD
                || config.bWad > MAX_PARAMETER_WAD || config.cWad > MAX_PARAMETER_WAD
                || config.dWad > MAX_PARAMETER_WAD
        ) revert InvalidEmissionConfig();
        if (
            config.dripSplitWad > WAD || config.warmupRateWad > WAD
                || config.bootstrapDecayWad > WAD
        ) revert InvalidEmissionConfig();
        if (
            config.growthFactorWad < WAD || config.growthFactorWad > MAX_GROWTH_FACTOR_WAD
        ) revert InvalidEmissionConfig();
        if (
            config.minBaseEmission > config.maxBaseEmission
                || config.maxBaseEmission > FIXED_SUPPLY
        ) revert InvalidEmissionConfig();
    }

    function _validateState(EmissionState calldata state) private pure {
        if (
            state.baseEmission > FIXED_SUPPLY || state.warmupFactorWad > WAD
                || state.stressWad > WAD || state.bootstrapWeight > MAX_BOOTSTRAP_WEIGHT
        ) revert InvalidEmissionState();
    }

    function _validateInputs(EmissionInputs calldata inputs) private pure {
        if (inputs.modelFloat > FIXED_SUPPLY || inputs.modelWeight > MAX_MODEL_WEIGHT) {
            revert InvalidEmissionInputs();
        }
    }

    function _bound(uint256 value, uint256 minimum, uint256 maximum)
        private
        pure
        returns (uint256)
    {
        return value < minimum ? minimum : (value > maximum ? maximum : value);
    }
}
