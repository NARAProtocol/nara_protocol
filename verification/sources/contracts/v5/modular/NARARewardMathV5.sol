// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

library NARARewardMathV5 {
    /// @dev Difference first: lifetime absolute index times a newly admitted
    /// position's weight can overflow even when its earned interval is bounded.
    function scaledCredit(uint256 weight, uint256 fromIndex, uint256 toIndex, uint256 fraction)
        internal pure returns (uint256)
    { return fraction + weight * (toIndex - fromIndex); }
}
