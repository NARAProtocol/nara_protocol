// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ReserveState} from "./NARAAccountingTypesV5.sol";

/// @notice Candidate replenishable reserve ABI, with no principal or reward-credit powers.
interface INARAEmissionReserveV5 {
    error Unauthorized();
    error InvalidState();
    error InvalidAmount();
    error InvalidEpoch();
    error ReserveInsolvent();
    error FlashActive();

    event FundingRecognized(uint256 indexed sequence, uint64 indexed eligibleEpoch, address indexed caller, uint256 amount, bool directTransferSync);
    event Released(uint64 indexed epoch, uint256 requested, uint256 delivered);
    event InitialFundingRecognized(uint256 indexed sequence, uint256 amount);

    function state() external view returns (ReserveState memory);
    /// @dev Token observation can fail explicitly; a deficit is distinct from zero surplus.
    function custody() external view returns (uint256 observedBalance, uint256 recognizedUnreleased, uint256 unsynced, uint256 deficit);
    /// @dev Once, after sealing and before activation. Recognize only the fixed initial amount.
    function recognizeInitialFunding() external;
    /// @dev Pulls from msg.sender and records only new actual receipt; atomic Core notification.
    function fund(uint256 amount) external returns (uint256 received, uint256 sequence, uint64 eligibleEpoch);
    /// @dev Permissionless excess recognition; repeat sync returns zero with no new sequence.
    function syncFunding() external returns (uint256 received, uint256 sequence, uint64 eligibleEpoch);
    /// @dev Bound Core only; recipient fixed to Core; one success per current closing epoch.
    ///      Core authorizes <= its eligible reserve and unreserved admission capacity.
    ///      A failed subcall rolls back; Core can close with zero and never retry a closed epoch.
    function releaseForEpoch(uint64 epoch, uint256 requested) external returns (uint256 delivered);
}
