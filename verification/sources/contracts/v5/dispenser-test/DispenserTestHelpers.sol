// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @dev Configurable Chainlink AggregatorV3 test double for `ETH/USD` and `L2 Sequencer Uptime`.
contract MockChainlinkAggregatorV5 {
    uint8 public decimals;
    uint80 public roundId;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public answeredInRound;
    bool public shouldRevert;

    constructor(uint8 decimals_, int256 initialAnswer_) {
        decimals = decimals_;
        roundId = 1;
        answer = initialAnswer_;
        startedAt = block.timestamp > 7_200 ? block.timestamp - 7_200 : 1;
        updatedAt = block.timestamp;
        answeredInRound = 1;
    }

    function setRoundData(
        uint80 roundId_,
        int256 answer_,
        uint256 startedAt_,
        uint256 updatedAt_,
        uint80 answeredInRound_
    ) external {
        roundId = roundId_;
        answer = answer_;
        startedAt = startedAt_;
        updatedAt = updatedAt_;
        answeredInRound = answeredInRound_;
    }

    function setAnswerFresh(int256 answer_) external {
        ++roundId;
        answer = answer_;
        updatedAt = block.timestamp;
        answeredInRound = roundId;
    }

    function setShouldRevert(bool flag) external {
        shouldRevert = flag;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        require(!shouldRevert, "FEED_REVERT");
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}

/// @dev Adversarial buyer attempting reentrancy from `onERC721Received` and/or ETH refund `receive()`.
contract MaliciousReentrantDispenserBuyerV5 is IERC721Receiver {
    address public dispenser;
    bytes public attackCalldata;
    uint256 public attackValue;
    bool public attackOnReceiveNFT;
    bool public attackOnRefund;
    bool public reentrancySucceeded;

    function configureAttack(
        address dispenser_,
        bytes calldata data_,
        uint256 value_,
        bool onNFT_,
        bool onRefund_
    ) external payable {
        dispenser = dispenser_;
        attackCalldata = data_;
        attackValue = value_;
        attackOnReceiveNFT = onNFT_;
        attackOnRefund = onRefund_;
        reentrancySucceeded = false;
    }

    function executePurchase(bytes calldata purchaseData) external payable {
        (bool ok, bytes memory ret) = dispenser.call{value: msg.value}(purchaseData);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external override returns (bytes4) {
        if (attackOnReceiveNFT) {
            (bool ok,) = dispenser.call{value: attackValue}(attackCalldata);
            if (ok) reentrancySucceeded = true;
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {
        if (attackOnRefund) {
            (bool ok,) = dispenser.call{value: attackValue}(attackCalldata);
            if (ok) reentrancySucceeded = true;
        }
    }
}

/// @dev Adversarial buyer that transfers the freshly received Vault Receipt inside `onERC721Received`
/// to verify post-callback `InvalidAcquisition()` protection (`receiptTransferNonce != 1` / `ownerOf != recipient`).
contract ReceiptMutatingDispenserBuyerV5 is IERC721Receiver {
    address public nft;
    address public forwardTarget;
    bool public selfTransfer;

    constructor(address nft_, address forwardTarget_, bool selfTransfer_) {
        nft = nft_;
        forwardTarget = forwardTarget_;
        selfTransfer = selfTransfer_;
    }

    function executePurchase(address dispenser, bytes calldata purchaseData) external payable {
        (bool ok, bytes memory ret) = dispenser.call{value: msg.value}(purchaseData);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external override returns (bytes4) {
        address dest = selfTransfer ? address(this) : forwardTarget;
        IERC721(nft).transferFrom(address(this), dest, tokenId);
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}

/// @dev Contract buyer that accepts ERC-721 receipts cleanly but reverts on `receive()` ETH refunds.
contract EthRefundRejectingBuyerV5 is IERC721Receiver {
    function executePurchase(address dispenser, bytes calldata purchaseData) external payable {
        (bool ok, bytes memory ret) = dispenser.call{value: msg.value}(purchaseData);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {
        revert("NO_ETH_REFUND");
    }
}

/// @dev Configurable Treasury Safe stand-in that can either accept ETH cleanly, revert `receive()`,
/// or burn `> 60,000` gas via storage writes to exercise `DOS-N01` `pendingTreasuryEth` escrow fallback.
contract ConfigurableTreasuryMockV5 is IERC721Receiver {
    uint8 public mode; // 0 = accept, 1 = revert, 2 = burn > 80k gas
    mapping(uint256 => uint256) public gasSink;
    uint256 public sinkCursor;

    function setMode(uint8 mode_) external {
        mode = mode_;
    }

    function exec(address target, uint256 value, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {
        if (mode == 1) revert("TREASURY_REJECT_ETH");
        if (mode == 2) {
            for (uint256 i; i < 6; ++i) {
                gasSink[++sinkCursor] = block.number + i + 1;
            }
        }
    }
}

/// @dev Sends forced native ETH to `target` without triggering `receive()` via `selfdestruct` in constructor.
contract ForceEthSenderV5 {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}

/// @dev Minimal plain ERC-721 mock for testing `sweepUnsolicitedNFTToTreasury` on external collections.
contract MockExternalNFTV5 is ERC721 {
    constructor() ERC721("ExternalNFT", "EXT") {}

    function mintRaw(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
}

/// @dev Payable exact-gas caller for testing EIP-150 `InsufficientExternalCallGas()` on payable dispense calls (`T-01`).
contract PayableGasLimitedCallerV5 is IERC721Receiver {
    function callPayableExactGas(address target, uint256 gasStipend, bytes calldata data) external payable {
        (bool ok, bytes memory ret) = target.call{gas: gasStipend, value: msg.value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}

/// @dev Payable ERC-3156 flash-loan attacker for verifying `FlashActive()` on ETH-bearing dispense calls
/// and positive `DOS-E01` rescue liveness during an active `NARATokenV5` flash mint (`T-02`).
contract PayableFlashAttackerV5 is IERC3156FlashBorrower, IERC721Receiver {
    bytes32 private constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    address public attackTarget;
    uint256 public attackValue;
    bytes public attackCalldata;
    bool public innerCallSucceeded;
    bytes public innerCallReturnData;

    function executeFlashAttack(
        address lender,
        address token,
        uint256 loanAmount,
        address target,
        uint256 callValue,
        bytes calldata payload
    ) external {
        attackTarget = target;
        attackValue = callValue;
        attackCalldata = payload;
        innerCallSucceeded = false;
        delete innerCallReturnData;
        IERC3156FlashLender(lender).flashLoan(this, token, loanAmount, "");
    }

    function onFlashLoan(
        address,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata
    ) external override returns (bytes32) {
        (innerCallSucceeded, innerCallReturnData) = attackTarget.call{value: attackValue}(attackCalldata);
        IERC20(token).approve(msg.sender, amount + fee);
        return CALLBACK_SUCCESS;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}

