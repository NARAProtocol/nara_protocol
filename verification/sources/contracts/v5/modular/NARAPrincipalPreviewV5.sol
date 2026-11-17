// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccountingPolicy, DurationCurve, CreateRequest, CreatePreview, ActionBlocker, PositionState}
    from "../interfaces/NARAAccountingTypesV5.sol";

struct PrincipalPreviewContextV5 {
    address caller;
    address principal;
    address engine;
    address reserve;
    address rewards;
    bool bindingsSealed;
    bool started;
    uint64 wall;
    uint64 cursor;
    uint256 inventory;
    uint256 timestamp;
}

/// @dev Candidate Common mechanics. These fields authorize no fee or rarity policy.
struct CommonRechargeRequestV5 {
    uint256 positionId;
    uint64 expectedGeneration;
    uint256 dormantTokenId;
    uint256 expectedTransferNonce;
    CreateRequest funding;
}
enum CommonRechargeBlockerV5 {
    None, UnknownGeneration, StaleGeneration, NotWithdrawn, NotSettled,
    MissingDormantReceipt, NotDormantOwner, StaleReceipt, StaleTransferNonce,
    GenerationOverflow, UnsupportedTerms, FundingBlocked
}
struct CommonRechargePreviewV5 {
    CommonRechargeBlockerV5 blocker;
    uint64 previousGeneration;
    uint64 nextGeneration;
    uint256 dormantTokenId;
    uint256 transferNonce;
    address dormantOwner;
    CreatePreview funding;
}

/// @dev Shared term-validation/math source for execution and the read-only Lens.
/// Token balance/allowance observations remain at the calling boundary.
library NARAPrincipalPreviewV5 {
    uint256 private constant SUPPLY = 1_000_000 ether;
    uint256 private constant WAD = 1e18;

    /// @dev Same eligibility rule for execution and Lens. Only Principal supplies
    /// the canonical head; no caller-provided financial terms are executable.
    /// All generations in this candidate are canonically Common. A later award
    /// implementation must add canonical rarity authentication before reuse.
    function rechargeGeneration(PositionState memory old, uint64 expectedGeneration, uint64 closedThrough)
        internal pure returns (CommonRechargeBlockerV5)
    {
        if (old.generationOwner == address(0)) return CommonRechargeBlockerV5.UnknownGeneration;
        if (old.generation != expectedGeneration) return CommonRechargeBlockerV5.StaleGeneration;
        if (!old.withdrawn) return CommonRechargeBlockerV5.NotWithdrawn;
        if (old.effectiveEnd != old.maturity || old.rewardWeight != old.modelWeight
            || old.earlyExitEnabled || old.penalty != 0 || old.penaltyCapacityReserved != 0)
            return CommonRechargeBlockerV5.UnsupportedTerms;
        if (closedThrough < old.effectiveEnd) return CommonRechargeBlockerV5.NotSettled;
        if (old.generation == type(uint64).max) return CommonRechargeBlockerV5.GenerationOverflow;
        return CommonRechargeBlockerV5.None;
    }

    /// @dev Pure receipt identity rule reused by the NFT retirement and Lens.
    /// Identity reads may occur under the Principal lock; no partial financial
    /// state is exposed and no owner/nonce comes from a caller-selected peer.
    function rechargeReceipt(
        address caller, uint256 expectedTokenId, uint256 expectedNonce,
        uint256 canonicalTokenId, uint256 currentNonce, address currentOwner
    ) internal pure returns (CommonRechargeBlockerV5) {
        if (canonicalTokenId == 0 || currentOwner == address(0)) return CommonRechargeBlockerV5.MissingDormantReceipt;
        if (expectedTokenId != canonicalTokenId) return CommonRechargeBlockerV5.StaleReceipt;
        if (expectedNonce != currentNonce) return CommonRechargeBlockerV5.StaleTransferNonce;
        if (caller != currentOwner) return CommonRechargeBlockerV5.NotDormantOwner;
        return CommonRechargeBlockerV5.None;
    }

    function create(AccountingPolicy memory policy, PrincipalPreviewContextV5 memory c, CreateRequest memory r)
        internal pure returns (CreatePreview memory p)
    {
        p.policyHash = policy.policyHash;
        if (!c.bindingsSealed) { p.blocker = ActionBlocker.NotSealed; return p; }
        if (!c.started) { p.blocker = ActionBlocker.NotStarted; return p; }
        if (c.cursor != c.wall) { p.blocker = ActionBlocker.CoreStale; return p; }
        if (c.caller == address(0) || c.caller == c.principal || c.caller == c.reserve
            || c.caller == c.engine || c.caller == c.rewards || r.expectedPolicyHash != policy.policyHash
            || c.timestamp > r.deadline || r.amount < policy.minimumPrincipal || r.amount > SUPPLY
            || r.duration < policy.minDuration || r.duration > policy.maxDuration
            || r.amount > SUPPLY - c.inventory) {
            p.blocker = ActionBlocker.InvalidTerms; return p;
        }
        uint256 activation = uint256(c.wall) + policy.activationDelay;
        uint256 maturity = activation + r.duration;
        if (maturity > type(uint64).max) { p.blocker = ActionBlocker.InvalidTerms; return p; }
        p.activation = uint64(activation); p.maturity = uint64(maturity);
        uint256 multiplier = durationMultiplier(policy.durationCurve, r.duration);
        p.modelWeight = r.amount * multiplier / WAD; p.rewardWeight = p.modelWeight;
    }

    /// @dev The duration multiplier D (WAD) of a validated duration; the same arithmetic serves the Common
    /// quote above, the admission child's durationMultiplier read and the awarded quote (P2.1).
    /// Callers validate minDuration <= duration <= maxDuration first.
    function durationMultiplier(DurationCurve curve, uint32 duration) internal pure returns (uint256 multiplier) {
        if (curve == DurationCurve.Linear) {
            multiplier = WAD + 3 * WAD * (duration - 96) / 34_944;
        } else {
            uint256 ratio = uint256(duration) * WAD / 35_040;
            multiplier = WAD + (WAD / 2) * ratio / WAD + (5 * WAD / 2) * (ratio * ratio / WAD) / WAD;
        }
    }
}
