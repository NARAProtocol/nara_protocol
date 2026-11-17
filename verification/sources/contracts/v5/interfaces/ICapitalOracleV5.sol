// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

interface ICapitalOracleV5 {
    struct Observation {
        uint160 sqrtPriceX96;
        uint48 start;
        uint48 end;
        uint64 endBlock;
        uint128 harmonicLiquidity;
        bytes32 observationId;
    }
    function SCHEMA_VERSION() external view returns (uint256);
    function poolManager() external view returns (address);
    function poolId() external view returns (bytes32);
    function observation() external view returns (Observation memory);
}

