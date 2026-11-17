// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NARAHookFeeMathV5 as Fees} from "./NARAHookFeeMathV5.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Stateless execution of the unchanged, independently modeled fee math.
/// @dev Created once by the Hook constructor; no custody, authority or configuration.
contract NARAHookFeeCalculatorV5 {
    uint256 public constant SCHEMA_VERSION = 1;
    error InvalidState();
    function validate(Fees.Curve calldata curve, uint256 depth) external pure {
        Fees.validate(curve, depth);
        if (depth != 0 && depth < 1_000_000) revert InvalidState();
    }
    function quoteGross(Fees.Curve calldata curve, uint256 prior, uint256 gross, uint256 depth)
        external pure returns (uint256 fee, uint256 net) {
        return Fees.quoteGross(curve, prior, gross, depth);
    }
    function grossForNet(Fees.Curve calldata curve, uint256 prior, uint256 net, uint256 depth)
        external pure returns (uint256 gross, uint256 fee) {
        return Fees.grossForNet(curve, prior, net, depth);
    }
    function virtualDepth(uint128 liquidity, uint160 price, bool currencyZero) external pure returns (uint256) {
        if (liquidity == 0 || price == 0) return 0;
        return currencyZero ? Math.mulDiv(liquidity, 2 ** 96, price) : Math.mulDiv(liquidity, price, 2 ** 96);
    }
}
