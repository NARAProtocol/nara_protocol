// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Integer input-fee integration and inversion. Parameters are not launch defaults.
/// @dev Preserves v4's segment floors and cumulative differences. All swap gross
///      amounts fit positive int128; accumulated flow remains uint256.
library NARAHookFeeMathV5 {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_GROSS = uint256(uint128(type(int128).max));

    struct Curve {
        uint16 mediumPressureBps;
        uint16 highPressureBps;
        uint16 extremePressureBps;
        uint16 baseFeeBps;
        uint16 mediumFeeBps;
        uint16 highFeeBps;
        uint16 extremeFeeBps;
        uint16 maxFeeBps;
    }

    error InvalidCurve();
    error AmountOutOfBounds();
    error NetAmountUnavailable();

    function validate(Curve memory c, uint256 depth) internal pure {
        if (c.mediumPressureBps == 0 || c.mediumPressureBps >= c.highPressureBps
            || c.highPressureBps >= c.extremePressureBps || c.maxFeeBps > 5_000
            || c.baseFeeBps > c.maxFeeBps || c.mediumFeeBps > c.maxFeeBps
            || c.highFeeBps > c.maxFeeBps || c.extremeFeeBps > c.maxFeeBps
            || depth > MAX_GROSS) revert InvalidCurve();
    }

    function cumulative(Curve memory c, uint256 flow, uint256 depth) internal pure returns (uint256) {
        validate(c, depth);
        return _cumulative(c, flow, depth);
    }

    function quoteGross(Curve memory c, uint256 priorFlow, uint256 gross, uint256 depth)
        internal pure returns (uint256 fee, uint256 net)
    {
        validate(c, depth);
        if (gross > MAX_GROSS || priorFlow > type(uint256).max - gross) revert AmountOutOfBounds();
        fee = _cumulative(c, priorFlow + gross, depth) - _cumulative(c, priorFlow, depth);
        net = gross - fee;
    }

    /// @notice Smallest gross whose cumulative-fee-adjusted input equals net.
    /// @dev At most four segments; no amount-sized search. Returns zero for zero
    ///      net even if the current rounding phase would permit fee-only gross.
    function grossForNet(Curve memory c, uint256 priorFlow, uint256 net, uint256 depth)
        internal pure returns (uint256 gross, uint256 fee)
    {
        validate(c, depth);
        if (net > MAX_GROSS) revert AmountOutOfBounds();
        if (net == 0) return (0, 0);
        uint256[4] memory ends = _ends(c, depth);
        uint256[4] memory rates = [uint256(c.baseFeeBps), c.mediumFeeBps, c.highFeeBps, c.extremeFeeBps];
        uint256 start;
        uint256 cursor = priorFlow;
        uint256 remaining = net;
        for (uint256 i; i < 4; ++i) {
            uint256 end = ends[i];
            if (cursor < end) {
                uint256 length = Math.min(end - cursor, MAX_GROSS - gross);
                uint256 offset = cursor - start;
                uint256 rate = rates[i];
                uint256 charged = Math.mulDiv(offset + length, rate, BPS) - Math.mulDiv(offset, rate, BPS);
                uint256 capacity = length - charged;
                if (remaining <= capacity) {
                    // net = g - floor((g*rate + phase)/BPS). For net>0:
                    // minimal g = floor((BPS*(net-1)+phase)/(BPS-rate))+1.
                    // net <= int128.max, so this numerator cannot overflow.
                    uint256 phase = mulmod(offset, rate, BPS);
                    uint256 take = (BPS * (remaining - 1) + phase) / (BPS - rate) + 1;
                    gross += take;
                    return (gross, gross - net);
                }
                gross += length;
                remaining -= capacity;
                cursor += length;
                if (gross == MAX_GROSS) revert NetAmountUnavailable();
            }
            start = end;
        }
        revert NetAmountUnavailable();
    }

    function _ends(Curve memory c, uint256 depth) private pure returns (uint256[4] memory) {
        return [Math.mulDiv(depth, c.mediumPressureBps, BPS), Math.mulDiv(depth, c.highPressureBps, BPS),
            Math.mulDiv(depth, c.extremePressureBps, BPS), type(uint256).max];
    }

    function _cumulative(Curve memory c, uint256 flow, uint256 depth) private pure returns (uint256 fee) {
        uint256[4] memory ends = _ends(c, depth);
        uint256[4] memory rates = [uint256(c.baseFeeBps), c.mediumFeeBps, c.highFeeBps, c.extremeFeeBps];
        uint256 start;
        for (uint256 i; i < 4; ++i) {
            uint256 end = Math.min(flow, ends[i]);
            if (end > start) fee += Math.mulDiv(end - start, rates[i], BPS);
            if (flow <= ends[i]) return fee;
            start = ends[i];
        }
    }
}
