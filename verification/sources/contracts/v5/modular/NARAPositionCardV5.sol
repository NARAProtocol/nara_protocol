// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {PositionViewV5, PositionStatusV5} from "./NARAPositionViewTypesV5.sol";
import {NARAPositionDisplayV5} from "./NARAPositionDisplayV5.sol";

/// @notice Stateless SVG composition for the NARA Locked Position NFT (mineral 1000x1000 NARA Core + Position Details).
contract NARAPositionCardV5 {
    using Strings for uint256;
    uint256 public constant SCHEMA_VERSION = 2;

    function svg(PositionViewV5 memory v) external pure returns (string memory) {
        (string memory tier,) = NARAPositionDisplayV5.tierStyle(v.rarityTier);
        string memory col = _mineralColor(v.rarityTier);
        string memory principal = NARAPositionDisplayV5.formatUnits(v.attachedPrincipal, 18);
        bool detached = v.status == PositionStatusV5.Dormant || v.status == PositionStatusV5.Withdrawn || v.lifecycle.consumed;

        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="1000" viewBox="0 0 1000 1000" role="img" aria-labelledby="title desc" font-family="monospace">'
            '<title id="title">NARA Position #', v.tokenId.toString(), '</title>'
            '<desc id="desc">', tier, ', ', NARAPositionDisplayV5._status(v.status), ', ', principal, ' NARA principal | '
            'Model ', NARAPositionDisplayV5.formatUnits(v.eligibleModelWeight, 18), ' / ', NARAPositionDisplayV5.formatUnits(v.totalModelWeight, 18),
            ' | Rarity ', NARAPositionDisplayV5.formatUnits(v.eligibleRewardWeight, 18), ' / ', NARAPositionDisplayV5.formatUnits(v.totalRewardWeight, 18), ' | ',
            v.rewardReadSuccess[0] ? string.concat(uint256(v.observedClosedPulses).toString(), " completed 15-minute pulses; not a forecast") : "Unavailable; not a forecast",
            ' | Cap ', NARAPositionDisplayV5.formatUnits(v.award.originalCap, 18), ' NARA | Attempt ', v.lifecycle.pendingAttempt == bytes32(0) ? "None" : "Pending",
            ' | Lineage ', v.lineage[0].toString(), '</desc>'
            '<defs>'
            '<path id="b" d="M25.946 44.938c-.664.845-2.021.375-2.021-.698V33.937a2.26 2.26 0 0 0-2.262-2.262H10.287c-.92 0-1.456-1.04-.92-1.788l7.48-10.471c1.07-1.497 0-3.578-1.842-3.578H1.237c-.92 0-1.456-1.04-.92-1.788L10.013.474c.214-.297.556-.474.92-.474h28.894c.92 0 1.456 1.04.92 1.788l-7.48 10.471c-1.07 1.498 0 3.579 1.842 3.579h11.377c.943 0 1.473 1.088.89 1.83L25.947 44.94z"/>'
            '<radialGradient id="cg" cx="50%" cy="50%" r="50%">'
            '<stop offset="0%" stop-color="', col, '" stop-opacity="0.52"/>'
            '<stop offset="55%" stop-color="', col, '" stop-opacity="0.22"/>'
            '<stop offset="100%" stop-color="#07090A" stop-opacity="0"/></radialGradient>'
            '<pattern id="grid" width="58" height="58" patternUnits="userSpaceOnUse">'
            '<path d="M58 0H0V58" fill="none" stroke="#26241F" stroke-width="1.5"/></pattern>'
            '<linearGradient id="disc" x1="0" y1="0" x2="0" y2="1">'
            '<stop offset="0%" stop-color="#1B1D20"/><stop offset="100%" stop-color="#060708"/></linearGradient>'
            '</defs>'
            '<rect width="1000" height="1000" fill="#07090A"/>'
            '<rect x="40" y="40" width="920" height="714" fill="url(#grid)" opacity="0.36"/>'
            '<rect x="22" y="22" width="956" height="956" rx="20" fill="none" stroke="#26241F" stroke-width="3"/>'
            '<rect x="40" y="40" width="920" height="920" rx="14" fill="none" stroke="#26241F" stroke-width="1"/>'
            '<circle cx="76" cy="82" r="11" fill="', col, '"/>'
            '<text x="102" y="92" fill="#D8D1BD" font-size="28" font-weight="700" letter-spacing="2">NARA POSITION</text>'
            '<text x="102" y="120" fill="#8C8A82" font-size="16" letter-spacing="3">PROOF OF POSITION / GEN ', uint256(v.generation).toString(), ' / ', tier, '</text>'
            '<rect x="740" y="56" width="196" height="48" rx="8" fill="#111417" stroke="', col, '" stroke-width="1.5"/>'
            '<text x="838" y="86" fill="', col, '" font-size="18" font-weight="700" letter-spacing="2" text-anchor="middle">', NARAPositionDisplayV5._status(v.status), '</text>'
            '<circle cx="500" cy="400" r="330" fill="url(#cg)"/>'
            '<g fill="none" stroke="', col, '">'
            '<g><animateTransform attributeName="transform" attributeType="XML" type="rotate" from="0 500 400" to="360 500 400" dur="90s" repeatCount="indefinite"/>'
            '<ellipse cx="500" cy="400" rx="300" ry="126" stroke-width="2.5" opacity="0.62" transform="rotate(24 500 400)"/>'
            '<ellipse cx="500" cy="400" rx="356" ry="148" stroke-width="2" opacity="0.48" transform="rotate(-24 500 400)"/></g>'
            '<circle cx="500" cy="400" r="264" stroke-width="4" opacity="0.58"/>'
            '<circle cx="500" cy="400" r="214" stroke-width="5" opacity="0.76"/>'
            '<circle cx="500" cy="400" r="188" stroke-width="11" stroke-dasharray="2 24" opacity="0.48"/>'
            '<circle cx="500" cy="400" r="158" stroke-width="7.5" opacity="0.92"/>'
            '<path d="M500 148V652 M248 400H752" stroke-width="2" opacity="0.5"/>'
            '<circle cx="500" cy="400" r="102" fill="url(#disc)" stroke-width="4.5"/>'
            '<circle cx="500" cy="400" r="70" stroke-width="1.8" opacity="0.5"/>'
            '</g>'
            '<g transform="rotate(34 500 400)"><path d="M500 400 L396 86 A330 330 0 0 1 604 86 Z" fill="#07090A" opacity="0.82"/>'
            '<path d="M500 400 L396 86 M500 400 L604 86" stroke="#6E2924" stroke-width="4" opacity="0.88"/></g>'
            '<g transform="translate(451,353) scale(2.05)" fill="', col, '"><use href="#b"/></g>'
            '<g fill="#6F6B63" opacity="0.72">'
            '<rect x="906" y="180" width="16" height="3"/><rect x="912" y="214" width="3" height="16"/>'
            '<circle cx="913" cy="255" r="3.5"/><rect x="905" y="282" width="12" height="12" fill="none" stroke="#6F6B63" stroke-width="1.5"/>'
            '<rect x="906" y="316" width="16" height="3"/><circle cx="913" cy="357" r="3.5"/>'
            '<rect x="912" y="384" width="3" height="16"/><rect x="906" y="418" width="16" height="3"/>'
            '<rect x="905" y="452" width="12" height="12" fill="none" stroke="#6F6B63" stroke-width="1.5"/>'
            '<circle cx="913" cy="493" r="3.5"/><rect x="906" y="520" width="16" height="3"/></g>'
            '<rect x="40" y="754" width="920" height="206" rx="0" fill="#0B0D0F" opacity="0.95"/>'
            '<path d="M40 754H960" stroke="', col, '" stroke-width="2" opacity="0.75"/>'
            '<g transform="translate(64,774) scale(0.52)" fill="', col, '"><use href="#b"/></g>'
            '<text x="98" y="793" fill="', col, '" font-size="16" font-weight="700" letter-spacing="3">NARA // LOCKED PRINCIPAL</text>'
            '<text x="64" y="848" fill="#D8D1BD" font-family="Arial,sans-serif" font-size="48" font-weight="800" letter-spacing="1">', principal, ' <tspan font-size="24" fill="', col, '">NARA</tspan></text>'
            '<text x="64" y="882" fill="#D8D1BD" font-size="16" font-weight="700" letter-spacing="1.2">', NARAPositionDisplayV5._withdrawal(v), ' / SHARE ', NARAPositionDisplayV5._share(v), ' / PULSE #', uint256(v.weightEpoch).toString(), '</text>'
            '<text x="64" y="912" fill="', col, '" font-size="14" font-weight="700" letter-spacing="0.8">NARA: ', NARAPositionDisplayV5._reward(v, 0), ' | ETH: ', NARAPositionDisplayV5._reward(v, 1), ' | USDC: ', NARAPositionDisplayV5._reward(v, 2), '</text>'
            '<text x="64" y="940" fill="#6F6B63" font-size="13" letter-spacing="0.8">', detached ? "No principal or rewards attached" : "Principal and unclaimed rewards transfer together", '</text>'
            '<text x="936" y="802" fill="#D8D1BD" font-size="22" font-weight="700" letter-spacing="2" text-anchor="end">POSITION #', v.positionId.toString(), '</text>'
            '<text x="936" y="836" fill="#8C8A82" font-size="18" letter-spacing="2" text-anchor="end">TOKEN #', v.tokenId.toString(), '</text>'
            '<text x="936" y="870" fill="', col, '" font-size="17" font-weight="700" letter-spacing="2" text-anchor="end">BLOCK #', v.asOfBlock.toString(), '</text>'
            '</svg>'
        );
    }

    function _mineralColor(uint8 tier) private pure returns (string memory) {
        if (tier >= 4) return "#C2772E"; // Peat / Burned Amber
        if (tier == 3) return "#A88745"; // Old Brass
        if (tier == 2) return "#397C68"; // Oxidized Copper
        if (tier == 1) return "#8C8A82"; // Smoked Iron
        return "#A88745";                // Warm Mineral Brass default
    }
}
