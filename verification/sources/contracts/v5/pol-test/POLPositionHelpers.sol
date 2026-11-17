// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-periphery/lib/v4-core/src/interfaces/callback/IUnlockCallback.sol";

/// @dev TEST ONLY. Deliberately no production capital policy, oracle or budget envelope.
contract POLCapitalPolicyFixture {
    address public immutable owner = msg.sender;
    address public immutable polPosition;
    address public immutable feeVault;
    bool public hasPendingCapitalOperations;
    constructor(address p, address v) { polPosition = p; feeVault = v; }
    function pending(bool b) external { require(msg.sender == owner); hasPendingCapitalOperations = b; }
    function run(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == owner);
        (bool ok, bytes memory result) = polPosition.call(data);
        if (!ok) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        return result;
    }
    function batch(bytes[] calldata calls, bool[] calldata expected) external {
        require(msg.sender == owner && calls.length == expected.length);
        for (uint256 i; i < calls.length; i++) {
            (bool ok,) = polPosition.call(calls[i]); require(ok == expected[i]);
        }
    }
}

contract POLUnlockedCallbackProbe is IUnlockCallback {
    IPoolManager private immutable manager;
    constructor(IPoolManager m) { manager = m; }
    function attempt(address target, bytes calldata data, bytes4 expectedError) external {
        manager.unlock(abi.encode(target, data, expectedError));
    }
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (address target, bytes memory callData, bytes4 expectedError) = abi.decode(data, (address, bytes, bytes4));
        (bool ok, bytes memory result) = target.call(callData);
        require(!ok && result.length >= 4 && bytes4(result) == expectedError);
        return "";
    }
}
