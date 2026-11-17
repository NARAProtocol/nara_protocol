// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-periphery/lib/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-periphery/lib/v4-core/src/types/BeforeSwapDelta.sol";
import {TickMath} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/TickMath.sol";
import {NARAPoolOracleV5} from "../oracle/NARAPoolOracleV5.sol";

/// @dev TEST ONLY: callback integration peer, not the NARA fee Hook.
/// trackLiquidity=false deliberately reproduces an incomplete observer.
contract PoolOracleHookFixture is BaseHook {
    using PoolIdLibrary for PoolKey;
    NARAPoolOracleV5 public immutable capitalOracle;
    bool public immutable trackLiquidity;
    uint8 public fault;
    constructor(IPoolManager manager, NARAPoolOracleV5 oracle, bool track) BaseHook(manager) {
        capitalOracle = oracle; trackLiquidity = track;
    }
    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeSwap = true; p.beforeAddLiquidity = true; p.beforeRemoveLiquidity = true;
    }
    function poolKey() public view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(capitalOracle.currency0()), Currency.wrap(capitalOracle.currency1()), 3000, 60, IHooks(this));
    }
    function setFault(uint8 value) external { fault = value; }
    function checkpointLocked() external { capitalOracle.checkpoint(); }
    function pokeMany(uint256 count) external { for (uint256 i; i < count; ++i) capitalOracle.poke(); }
    function price(int24 tick) external pure returns (uint160) { return TickMath.getSqrtPriceAtTick(tick); }
    function state() external view returns (int24 tick, uint128 liquidity) {
        (, tick,,) = StateLibrary.getSlot0(poolManager, poolKey().toId());
        liquidity = StateLibrary.getLiquidity(poolManager, poolKey().toId());
    }
    function _observe(PoolKey calldata key) private {
        require(PoolId.unwrap(key.toId()) == PoolId.unwrap(poolKey().toId()), "wrong fixture pool");
        if (fault == 1) capitalOracle.poke();
        if (fault == 2) capitalOracle.observation();
        if (fault == 3) capitalOracle.samples();
        if (fault == 4) capitalOracle.history(0);
        capitalOracle.checkpoint();
        require(fault != 5, "fixture after-checkpoint failure");
    }
    function _beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        internal override returns (bytes4) {
        if (trackLiquidity) _observe(key);
        return IHooks.beforeAddLiquidity.selector;
    }
    function _beforeRemoveLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        internal override returns (bytes4) {
        if (trackLiquidity) _observe(key);
        return IHooks.beforeRemoveLiquidity.selector;
    }
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal override returns (bytes4, BeforeSwapDelta, uint24) {
        _observe(key); return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
