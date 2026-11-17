// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NARAEpochEngineV5, EpochFundingStateV5} from "./NARAEpochEngineV5.sol";
import {NARAPrincipalLedgerV5} from "./NARAPrincipalLedgerV5.sol";
import {NARARewardLedgerV5} from "./NARARewardLedgerV5.sol";
import {PrincipalLedgerStateV5, PrincipalLedgerChangesV5, RewardLedgerStateV5} from "./NARAModuleInterfacesV5.sol";
import {CoreAccounting, EpochChanges} from "../interfaces/NARAAccountingTypesV5.sol";
import {NARAEmissionModelV5} from "../engine/NARAEmissionModelV5.sol";
import {EmissionInputs, EmissionQuote} from "../engine/NARAEmissionTypesV5.sol";

/// @notice Read-only composition of authoritative financial module getters.
/// No custody, privileged writes or dependency of any financial execution path.
contract NARAFinancialLensV5 {
    error UnboundGraph();

    function accounting(NARAEpochEngineV5 engine) external view returns (CoreAccounting memory) {
        return _accounting(engine);
    }
    /// @dev Current/future schedules only. Owners reject already consumed epochs.
    /// Penalties/capacity releases are exactly zero in this disabled-early-exit slice.
    function epochChanges(NARAEpochEngineV5 engine, uint64 epoch) external view returns (EpochChanges memory c) {
        (NARAPrincipalLedgerV5 p, NARARewardLedgerV5 r) = _modules(engine);
        PrincipalLedgerChangesV5 memory pc = p.principalChangesAt(epoch);
        c.principalDelta = pc.principalDelta; c.modelWeightDelta = pc.modelWeightDelta; c.rewardWeightDelta = pc.rewardWeightDelta;
        c.rewardDelta = r.rewardChangesAt(epoch); c.reserveFunding = engine.reserveFundingAt(epoch);
    }
    /// @notice Quotes the current opening snapshot; requested NARA is neither an
    /// actual payout nor a promise that a pulse is closable at this wall time.
    function previewEmission(NARAEpochEngineV5 engine) external view returns (
        EmissionInputs memory inputs, EmissionQuote memory quote, uint256 headroom, uint256 requestedNara
    ) {
        CoreAccounting memory c = _accounting(engine);
        (, NARARewardLedgerV5 rewards) = _modules(engine);
        inputs = EmissionInputs(1_000_000 ether - c.principalSnapshot - c.protectedRewardSnapshot - c.eligibleReserve, c.activeModelWeight);
        quote = NARAEmissionModelV5(engine.bindings().emissionModel).calculateNext(engine.emissionConfig(), engine.emissionState(), inputs);
        headroom = rewards.rewardState().naraAdmissionHeadroom;
        uint256 maximum = headroom < c.eligibleReserve ? headroom : c.eligibleReserve;
        if (c.activeRewardWeight != 0) requestedNara = quote.targetNara < maximum ? quote.targetNara : maximum;
    }
    function _accounting(NARAEpochEngineV5 engine) private view returns (CoreAccounting memory) {
        (NARAPrincipalLedgerV5 principal, NARARewardLedgerV5 rewards) = _modules(engine);
        EpochFundingStateV5 memory f = engine.fundingState();
        PrincipalLedgerStateV5 memory p = principal.principalAccounting(); RewardLedgerStateV5 memory r = rewards.rewardState();
        return CoreAccounting(p.principalInventory, p.principalSnapshot, r.protectedNaraSnapshot,
            f.eligibleReserve, f.futureReserve, f.lastFundingSequence, p.activeModelWeight,
            p.activeRewardWeight, p.pendingPrincipalDelta, r.pendingNaraDelta, false);
    }
    function _modules(NARAEpochEngineV5 engine) private view returns (NARAPrincipalLedgerV5 p, NARARewardLedgerV5 r) {
        (address principal, address rewards) = engine.financialModules();
        if (principal == address(0) || rewards == address(0)) revert UnboundGraph();
        return (NARAPrincipalLedgerV5(principal), NARARewardLedgerV5(rewards));
    }
}
