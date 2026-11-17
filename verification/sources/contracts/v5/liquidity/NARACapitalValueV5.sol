// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Conservative USDC-raw valuation using the canonical raw-currency sqrt price.
/// No decimals conversion is added: pool price already includes token precision.
library NARACapitalValueV5 {
    function value(uint256 nara, uint256 usdc, uint160 price, bool naraFirst, bool upper)
        internal pure returns (uint256)
    {
        Math.Rounding rounding = upper ? Math.Rounding.Ceil : Math.Rounding.Floor;
        uint256 naraValue;
        if (price <= type(uint128).max) {
            uint256 ratio = uint256(price) * price;
            naraValue = naraFirst ? Math.mulDiv(nara, ratio, 1 << 192, rounding)
                : Math.mulDiv(nara, 1 << 192, ratio, rounding);
        } else {
            // The ratio approximation must bound the final value in the intended
            // direction. For inverse conversion an upper denominator gives a lower value.
            bool ratioUp = naraFirst == upper;
            uint256 ratio = Math.mulDiv(price, price, 1 << 64, ratioUp ? Math.Rounding.Ceil : Math.Rounding.Floor);
            naraValue = naraFirst ? Math.mulDiv(nara, ratio, 1 << 128, rounding)
                : Math.mulDiv(nara, 1 << 128, ratio, rounding);
        }
        return naraValue + usdc;
    }
}
