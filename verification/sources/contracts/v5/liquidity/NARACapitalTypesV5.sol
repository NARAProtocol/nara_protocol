// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

struct Limits {
    uint128 perCallNara;
    uint128 perCallUsdc;
    uint128 rollingNara;
    uint128 rollingUsdc;
    uint128 minimumValueUsdc;
    uint32 minimumInterval;
    uint32 maximumOracleAge;
    uint16 maximumOperations;
    uint16 maximumSqrtDeviationBps;
    uint16 maximumValueLossBps;
}
struct HardEnvelope {
    Limits bounds;
    uint128 maximumPositionLiquidity;
    uint128 minimumOracleLiquidity;
    uint32 minimumOracleWindow;
    int24 minimumTick;
    int24 maximumTick;
    uint24 minimumTickWidth;
}
struct Bucket { uint128 nara; uint128 usdc; uint48 hour; uint16 operations; }
struct Usage { uint256 nara; uint256 usdc; uint256 operations; }
