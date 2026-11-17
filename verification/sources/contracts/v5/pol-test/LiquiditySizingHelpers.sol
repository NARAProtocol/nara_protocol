// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TickMath} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IPoolManager} from "@uniswap/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";

/// @dev Test-only access to exact pinned dependency behavior; no deployment authority.
contract LiquiditySizingReference {
    function prices(int24[] calldata ticks) external pure returns (uint160[] memory values) {
        values = new uint160[](ticks.length);
        for (uint256 i; i < ticks.length; ++i) values[i] = TickMath.getSqrtPriceAtTick(ticks[i]);
    }
    function legacy(uint160 p, int24 lower, int24 upper, uint128 b0, uint128 b1) external pure returns (uint128) {
        return LiquidityAmounts.getLiquidityForAmounts(p, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), b0, b1);
    }
    function slot0(IPoolManager manager, PoolId id) external view returns (uint160, int24, uint24, uint24) {
        return StateLibrary.getSlot0(manager, id);
    }
    function tickLiquidity(IPoolManager manager, PoolId id, int24 tick) external view returns (uint128, int128) {
        return StateLibrary.getTickLiquidity(manager, id, tick);
    }
}
