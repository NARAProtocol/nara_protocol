// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

// TEST ONLY: differential oracle, compiled with the frozen v4 compiler.
// This reference must never be deployed as part of the v5 protocol.
import {EngineConfig, EpochSnapshot} from "../../v4/NARAEngineTypes.sol";
import {NARAEngineModelLib} from "../../v4/libraries/NARAEngineModelLib.sol";

contract V4EmissionReference {
    function calculate(
        EngineConfig memory config,
        EpochSnapshot memory previous,
        uint256 modelFloat,
        uint256 modelWeight
    ) external pure returns (EpochSnapshot memory) {
        NARAEngineModelLib.validateConfig(config);
        return NARAEngineModelLib.computeNextEpochSnapshot(
            previous, config, modelFloat, 0, modelWeight, 0, 900
        );
    }
}
