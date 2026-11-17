// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {NARAEpochEngineV5} from "../modular/NARAEpochEngineV5.sol";

interface IPausableForgeV5 {
    function pauseCommits() external;
}

/// @dev Test-only ERC-3156 flash-loan attacker that attempts arbitrary calls against `NARAGenesisShieldVaultV5`
/// while `NARATokenV5.totalSupply() > 1_000_000 ether`.
contract ShieldFlashAttacker is IERC3156FlashBorrower {
    bytes32 private constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    address public attackTarget;
    bytes public attackCalldata;
    bool public innerCallSucceeded;
    bytes public innerCallReturnData;

    function executeFlashAttack(
        address lender,
        address token,
        uint256 loanAmount,
        address target,
        bytes calldata payload
    ) external {
        attackTarget = target;
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
        (innerCallSucceeded, innerCallReturnData) = attackTarget.call(attackCalldata);
        IERC20(token).approve(msg.sender, amount + fee);
        return CALLBACK_SUCCESS;
    }
}

/// @dev Test-only fake ERC-721 contract attempting to spoof `onERC721Received` on the Shield Vault.
contract SpoofERC721Caller {
    function spoofReceive(address vault, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4)
    {
        return IERC721Receiver(vault).onERC721Received(address(this), from, tokenId, data);
    }
}

/// @dev Test-only contract peer used as governor/guardian Safe stand-in for `NARAForgeV5` deployment.
contract MockSafeContractPeer {
    function pauseForgeCommits(address forge) external {
        IPausableForgeV5(forge).pauseCommits();
    }
}

/// @dev Test-only helper that batches multiple `engine.advance(maxStep)` calls inside a single EVM transaction
/// while preserving `>= 8.5M` gas headroom (`> 2M` above `RELEASE_MINIMUM_GAS = 1M` after `24 * ~260k` gas per chunk).
contract BatchEpochAdvancer {
    function advanceMany(NARAEpochEngineV5 engine, uint32 totalEpochs, uint32 maxStep) external returns (uint32 advanced) {
        uint32 remaining = totalEpochs;
        while (remaining > 0 && gasleft() >= 8_500_000) {
            uint32 chunk = remaining < maxStep ? remaining : maxStep;
            engine.advance(chunk);
            remaining -= chunk;
            advanced += chunk;
        }
    }
}

/// @dev Test-only caller that forwards an exact `gasStipend` to verify `InsufficientExternalCallGas()` deterministically.
contract GasLimitedCaller {
    function callExactGas(address target, uint256 gasStipend, bytes calldata data) external {
        (bool ok, bytes memory ret) = target.call{gas: gasStipend}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}
