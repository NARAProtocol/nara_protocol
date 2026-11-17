// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {NARACapitalValueV5} from "./NARACapitalValueV5.sol";
import {TickMath} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/SqrtPriceMath.sol";
import {Pool} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/Pool.sol";

/// @notice Exact, stateless liquidity sizing for the canonical 60-tick NARA pool.
/// @dev Not an oracle or execution authorization. The capital policy must supply a
/// checked current price, approved budgets and remaining capacity at BOTH ticks.
contract NARALiquiditySizerV5 {
    struct Quote {
        uint128 liquidity;
        uint128 amount0;
        uint128 amount1;
        uint128 unused0;
        uint128 unused1;
    }
    uint256 public constant SCHEMA_VERSION = 1;
    int24 public constant TICK_SPACING = 60;
    uint256 public constant MAX_SEARCH_STEPS = 128;
    uint128 public constant MAX_INPUT_AMOUNT = uint128(1) << 127; // int128 minimum debit magnitude
    error InvalidRange();
    error InvalidPrice();
    error QuoteInvariant();

    function maxLiquidityPerTick() public pure returns (uint128) {
        return Pool.tickSpacingToMaxLiquidityPerTick(TICK_SPACING);
    }

    /// @notice Maximal liquidity within token budgets and supplied additional-liquidity cap.
    /// @dev Addition costs round up exactly as PoolManager does. The search is bounded
    /// over uint128, without intermediate budget-side casts or rounded inverse formulas.
    /// Shared tick occupancy is not available to this pure function; maxLiquidity must
    /// already account for existing liquidity at both boundaries and policy limits.
    function quote(uint160 price, int24 lower, int24 upper, uint128 budget0, uint128 budget1, uint128 maxLiquidity)
        public pure returns (Quote memory q)
    {
        (uint160 a, uint160 b) = _prices(price, lower, upper);
        uint128 cap = maxLiquidityPerTick();
        if (maxLiquidity < cap) cap = maxLiquidity;
        uint256 effective0 = budget0 < MAX_INPUT_AMOUNT ? budget0 : MAX_INPUT_AMOUNT;
        uint256 effective1 = budget1 < MAX_INPUT_AMOUNT ? budget1 : MAX_INPUT_AMOUNT;
        q.unused0 = budget0; q.unused1 = budget1;
        if (cap == 0 || (price < b && budget0 == 0) || (price > a && budget1 == 0)) return q;

        (uint256 c0, uint256 c1) = _amounts(price, a, b, cap, true);
        uint256 low;
        uint256 high = cap;
        if (c0 <= effective0 && c1 <= effective1) low = cap;
        else {
            high = uint256(cap) - 1;
            for (uint256 step; step < MAX_SEARCH_STEPS && low < high; ++step) {
                uint256 mid = (low + high + 1) / 2;
                (c0, c1) = _amounts(price, a, b, uint128(mid), true);
                if (c0 <= effective0 && c1 <= effective1) low = mid;
                else high = mid - 1;
            }
            if (low != high) revert QuoteInvariant();
        }
        (c0, c1) = _amounts(price, a, b, uint128(low), true);
        if (c0 > effective0 || c1 > effective1) revert QuoteInvariant();
        q.liquidity = uint128(low); q.amount0 = uint128(c0); q.amount1 = uint128(c1);
        q.unused0 = budget0 - q.amount0; q.unused1 = budget1 - q.amount1;
    }

    /// @notice Exact quote plus conservative USDC value bounds at an independent reference.
    /// @dev Pure arithmetic only; caller must authenticate and validate reference freshness.
    function valuedQuote(uint160 price, uint160 referencePrice, int24 lower, int24 upper,
        uint128 budget0, uint128 budget1, uint128 cap, bool naraFirst)
        external pure returns (Quote memory q, uint256 fairValueFloor, uint256 paidValueCeil, uint256 valueLossBps)
    {
        q = quote(price, lower, upper, budget0, budget1, cap);
        (uint160 a, uint160 b) = _prices(referencePrice, lower, upper);
        (uint256 fair0, uint256 fair1) = _amounts(referencePrice, a, b, q.liquidity, false);
        fairValueFloor = NARACapitalValueV5.value(naraFirst ? fair0 : fair1, naraFirst ? fair1 : fair0, referencePrice, naraFirst, false);
        paidValueCeil = NARACapitalValueV5.value(naraFirst ? q.amount0 : q.amount1, naraFirst ? q.amount1 : q.amount0, referencePrice, naraFirst, true);
        if (paidValueCeil > fairValueFloor) valueLossBps = fairValueFloor == 0 ? type(uint256).max
            : Math.mulDiv(paidValueCeil - fairValueFloor, 10000, fairValueFloor, Math.Rounding.Ceil);
    }
    function principalValue(uint256 nara, uint256 usdc, uint160 referencePrice, bool naraFirst) external pure returns (uint256) {
        if (referencePrice < TickMath.MIN_SQRT_PRICE || referencePrice >= TickMath.MAX_SQRT_PRICE) revert InvalidPrice();
        return NARACapitalValueV5.value(nara, usdc, referencePrice, naraFirst, false);
    }

    /// @notice Principal amounts only: round up for additions, down for removals.
    /// @dev Excludes accrued LP fees, Hook fees and already banked inventory.
    function amounts(uint160 price, int24 lower, int24 upper, uint128 liquidity, bool roundUp)
        external pure returns (uint256 amount0, uint256 amount1)
    {
        (uint160 a, uint160 b) = _prices(price, lower, upper);
        return _amounts(price, a, b, liquidity, roundUp);
    }

    function _prices(uint160 price, int24 lower, int24 upper) private pure returns (uint160, uint160) {
        if (lower >= upper || lower < TickMath.MIN_TICK || upper > TickMath.MAX_TICK
            || lower % TICK_SPACING != 0 || upper % TICK_SPACING != 0) revert InvalidRange();
        if (price < TickMath.MIN_SQRT_PRICE || price >= TickMath.MAX_SQRT_PRICE) revert InvalidPrice();
        return (TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper));
    }
    function _amounts(uint160 p, uint160 a, uint160 b, uint128 l, bool up) private pure returns (uint256 c0, uint256 c1) {
        if (p <= a) c0 = SqrtPriceMath.getAmount0Delta(a, b, l, up);
        else if (p >= b) c1 = SqrtPriceMath.getAmount1Delta(a, b, l, up);
        else {
            c0 = SqrtPriceMath.getAmount0Delta(p, b, l, up);
            c1 = SqrtPriceMath.getAmount1Delta(a, p, l, up);
        }
    }
}
