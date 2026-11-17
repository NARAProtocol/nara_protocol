// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ICapitalOracleV5} from "../interfaces/ICapitalOracleV5.sol";
import {NARACapitalPolicyV5} from "../liquidity/NARACapitalPolicyV5.sol";
import {NARACapitalValueV5} from "../liquidity/NARACapitalValueV5.sol";

/// @dev TEST ONLY. Its observations are set by a test driver, not independently measured.
contract CapitalOracleFixture is ICapitalOracleV5 {
    uint256 public constant SCHEMA_VERSION = 1;
    address public immutable poolManager;
    bytes32 public immutable poolId;
    Observation private _observation;
    uint256 private _fault;
    address public readTarget;
    constructor(address manager, bytes32 id) { poolManager = manager; poolId = id; }
    function set(Observation calldata value) external { _observation = value; }
    function compoundSameBlock(address policy) external {
        _observation.endBlock = uint64(block.number);
        NARACapitalPolicyV5(policy).compound(1, uint48(block.timestamp));
    }
    function fault(uint256 value) external { _fault = value; }
    function setReadTarget(address target) external { readTarget = target; }
    function observation() external view returns (Observation memory) {
        require(_fault != 1, "test unavailable oracle");
        if (_fault == 2) assembly ("memory-safe") { return(0, 1) }
        if (_fault == 3) {
            (bool ok, bytes memory result) = readTarget.staticcall(abi.encodeWithSignature("rollingUsage()"));
            require(!ok && result.length == 4 && bytes4(result) == bytes4(keccak256("InvalidState()")), "incoherent budget read exposed");
        }
        return _observation;
    }
}

contract CapitalValueProbe {
    function value(uint256 nara, uint256 usdc, uint160 price, bool naraFirst, bool upper) external pure returns (uint256) {
        return NARACapitalValueV5.value(nara, usdc, price, naraFirst, upper);
    }
}
