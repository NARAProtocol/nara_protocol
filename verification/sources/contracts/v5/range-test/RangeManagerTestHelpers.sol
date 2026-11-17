// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReserveState} from "../interfaces/NARAAccountingTypesV5.sol";

/// @dev TEST ONLY: Multisig Safe fixture with configurable getThreshold() and arbitrary execution.
contract RangeTreasurySafeFixture is IERC721Receiver {
    using SafeERC20 for IERC20;

    address public immutable owner = msg.sender;
    uint256 private _threshold;

    constructor(uint256 threshold_) {
        _threshold = threshold_;
    }

    function getThreshold() external view returns (uint256) {
        return _threshold;
    }

    function setThreshold(uint256 threshold_) external {
        require(msg.sender == owner, "not owner");
        _threshold = threshold_;
    }

    function approveToken(address token, address spender, uint256 amount) external {
        require(msg.sender == owner, "not owner");
        IERC20(token).forceApprove(spender, amount);
    }

    function run(address target, bytes calldata data) external returns (bytes memory) {
        require(msg.sender == owner, "not owner");
        (bool ok, bytes memory result) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
        return result;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @dev TEST ONLY: Emission Reserve fixture implementing the V5 Reserve replenishment interface (state, fund, syncFunding).
contract RangeEmissionReserveFixture {
    using SafeERC20 for IERC20;

    address public immutable nara;
    address public immutable core;
    uint256 public cumulativeRecognized;
    uint256 public cumulativeReleased;
    uint256 public fundingSequence;
    uint64 public wallEpoch = 5;

    constructor(address nara_, address core_) {
        nara = nara_;
        core = core_;
    }

    function state() external view returns (ReserveState memory) {
        return ReserveState({
            schemaVersion: 1,
            nara: nara,
            core: core,
            bootstrapAuthority: address(0),
            bindingsSealed: true,
            initialFundingRecognized: true,
            genesisTimestamp: uint64(block.timestamp),
            genesisFunding: 950_000 ether,
            cumulativeRecognized: cumulativeRecognized,
            cumulativeReleased: cumulativeReleased,
            fundingSequence: fundingSequence,
            hasReleasedEpoch: false,
            lastReleasedEpoch: 0
        });
    }

    function fund(uint256 amount) external returns (uint256 received, uint256 sequence, uint64 eligibleEpoch) {
        require(amount != 0, "zero amount");
        uint256 beforeBal = IERC20(nara).balanceOf(address(this));
        IERC20(nara).safeTransferFrom(msg.sender, address(this), amount);
        received = IERC20(nara).balanceOf(address(this)) - beforeBal;
        sequence = ++fundingSequence;
        eligibleEpoch = wallEpoch + 1;
        cumulativeRecognized += received;
    }

    function syncFunding() external returns (uint256 received, uint256 sequence, uint64 eligibleEpoch) {
        uint256 balance = IERC20(nara).balanceOf(address(this));
        uint256 recognizedUnreleased = cumulativeRecognized - cumulativeReleased;
        if (balance <= recognizedUnreleased) return (0, fundingSequence, 0);
        received = balance - recognizedUnreleased;
        sequence = ++fundingSequence;
        eligibleEpoch = wallEpoch + 1;
        cumulativeRecognized += received;
    }
}
