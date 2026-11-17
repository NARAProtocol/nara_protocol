// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NARAPrincipalAdmissionV5, PrincipalAdmissionSnapshotV5} from "./NARAPrincipalAdmissionV5.sol";
import {NARAPrincipalLedgerV5} from "./NARAPrincipalLedgerV5.sol";
import {NARALifecycleLedgerV5} from "./NARALifecycleLedgerV5.sol";
import {GenerationLifecycleV5, INARAPositionIdentityV5, PrincipalLedgerStateV5} from "./NARAModuleInterfacesV5.sol";
import {NARAPrincipalPreviewV5, CommonRechargeRequestV5,
    CommonRechargePreviewV5, CommonRechargeBlockerV5} from "./NARAPrincipalPreviewV5.sol";
import {PositionState, CreateRequest, CreatePreview, ExitPreview, ActionBlocker}
    from "../interfaces/NARAAccountingTypesV5.sol";

/// @notice Read-only principal previews. Execution never calls this contract.
/// Raw terms, snapshots, schedules and policy remain readable from their owner.
contract NARAPrincipalLensV5 {
    function previewCreate(NARAPrincipalLedgerV5 principal, address caller, CreateRequest calldata request)
        public view returns (CreatePreview memory p)
    {
        PrincipalLedgerStateV5 memory accounting = principal.principalAccounting(); // coherent graph required
        return _previewCreate(principal, caller, accounting, request);
    }

    function _previewCreate(NARAPrincipalLedgerV5 principal, address caller,
        PrincipalLedgerStateV5 memory accounting, CreateRequest calldata request)
        private view returns (CreatePreview memory)
    {
        return NARAPrincipalAdmissionV5(principal.admissionHelper()).quoteCreate(caller,
            PrincipalAdmissionSnapshotV5(accounting.initialized, principal.bindingsSealed(),
                principal.genesisTimestamp(), accounting.openedEpoch, accounting.principalInventory), request);
    }

    /// @notice Canonical current dormant identity plus exact Common eligibility
    /// and funding preview. No output authenticates a future transaction.
    /// @dev Shares generation/receipt rules and create math with execution.
    /// Reads require a coherent graph; no callback financial-read bypass exists.
    function previewRechargeCommon(NARAPrincipalLedgerV5 principal, address caller,
        CommonRechargeRequestV5 calldata request) external view returns (CommonRechargePreviewV5 memory p)
    {
        PrincipalLedgerStateV5 memory accounting = principal.principalAccounting();
        PositionState memory old;
        try principal.positionHead(request.positionId) returns (PositionState memory value) { old = value; }
        catch (bytes memory reason) {
            if (reason.length != 4 || bytes4(reason) != NARAPrincipalLedgerV5.UnknownGeneration.selector)
                assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
        }
        p.previousGeneration = old.generation;
        if (old.generation != 0 && old.generation != type(uint64).max) p.nextGeneration = old.generation + 1;
        INARAPositionIdentityV5 nft = INARAPositionIdentityV5(principal.positionNFT());
        p.dormantTokenId = nft.dormantTokenIdOf(request.positionId, old.generation);
        if (p.dormantTokenId != 0) {
            p.transferNonce = nft.receiptTransferNonce(p.dormantTokenId);
            p.dormantOwner = nft.ownerOf(p.dormantTokenId);
        }
        p.funding.policyHash = NARAPrincipalAdmissionV5(principal.admissionHelper()).policyHash();
        if (old.generation != 0) {
            GenerationLifecycleV5 memory l = NARALifecycleLedgerV5(principal.lifecycleLedger()).lifecycle(request.positionId, old.generation);
            if (l.pendingAttempt != bytes32(0) || l.consumed) {
                p.blocker = CommonRechargeBlockerV5.UnsupportedTerms;
                return p;
            }
            if (l.rarityApplied) old.rewardWeight = old.modelWeight;
        }
        p.blocker = NARAPrincipalPreviewV5.rechargeGeneration(old, request.expectedGeneration, accounting.openedEpoch);
        if (p.blocker != CommonRechargeBlockerV5.None) return p;
        // Match execution's blocker precedence before receipt retirement.
        p.funding = _previewCreate(principal, caller, accounting, request.funding);
        if (p.funding.blocker != ActionBlocker.None) {
            p.blocker = CommonRechargeBlockerV5.FundingBlocked; return p;
        }
        p.blocker = NARAPrincipalPreviewV5.rechargeReceipt(caller, request.dormantTokenId,
            request.expectedTransferNonce, p.dormantTokenId, p.transferNonce, p.dormantOwner);
    }

    function previewWithdraw(NARAPrincipalLedgerV5 principal, address caller, uint256 id, uint64 generation)
        external view returns (ExitPreview memory p)
    {
        PositionState memory s;
        try principal.position(id, generation) returns (PositionState memory value) { s = value; }
        catch (bytes memory reason) {
            if (reason.length == 4 && bytes4(reason) == NARAPrincipalLedgerV5.UnknownGeneration.selector) {
                p.blocker = ActionBlocker.UnknownGeneration; return p;
            }
            assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
        }
        p.effectiveEnd = s.effectiveEnd;
        bool consumed = NARALifecycleLedgerV5(principal.lifecycleLedger()).lifecycle(id, generation).consumed;
        (bool started, uint64 wall) = _wall(principal.bindingsSealed(), principal.genesisTimestamp());
        if (caller != s.generationOwner) p.blocker = ActionBlocker.NotOwner;
        else if (s.withdrawn || consumed) p.blocker = ActionBlocker.AlreadyWithdrawn;
        else if (!started) p.blocker = ActionBlocker.NotStarted;
        else if (wall < s.maturity) p.blocker = ActionBlocker.NotMature;
        else if (wall == type(uint64).max) p.blocker = ActionBlocker.InvalidTerms;
        else p.principalOut = s.principal;
    }

    function _wall(bool initialized, uint64 genesis) private view returns (bool, uint64) {
        if (!initialized || block.timestamp < genesis) return (false, 0);
        uint256 wall = (block.timestamp - genesis) / 900;
        if (wall > type(uint64).max) revert NARAPrincipalLedgerV5.InvalidEpoch();
        return (true, uint64(wall));
    }
}
