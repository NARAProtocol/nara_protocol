// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @notice Neutral engineering artwork for the local retained-frame candidate.
/// @dev NOT final collection artwork or a financial rarity/award implementation.
/// Only the persistent cosmetic seed enters the SVG. No position, generation,
/// amount, owner, time, provider or token ID can affect the original image.
contract NARAFrameArtV5 {
    using Strings for uint256;
    bytes32 public constant FAMILY = keccak256("NARA_V5_ENGINEERING_FRAME");
    uint256 public constant VERSION = 1;

    function svg(bytes32 seed) external pure returns (string memory) {
        // All branches have identical structure and neutral colors. Predictable
        // offsets make frame identity visible without suggesting a rarity tier.
        uint256 inset = 48 + uint256(seed) % 49;
        string memory ins = inset.toString();
        string memory s = (320 - 2 * inset).toString();
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 320" role="img" aria-label="NARA frame">'
            '<rect width="320" height="320" rx="20" fill="#07090A"/><path d="M32 160H288M160 32V288" stroke="#26241F"/>'
            '<rect x="', ins, '" y="', ins, '" width="', s, '" height="', s,
            '" rx="10" fill="none" stroke="#A88745" stroke-width="2"/><circle cx="160" cy="160" r="',
            (16 + (uint256(seed) >> 8) % 57).toString(),
            '" fill="none" stroke="#C2772E"/><path d="M148 138h26l-7 13h12l-19 30v-13h-12l7-13h-14z" fill="#C2772E"/></svg>'
        );
    }
}
