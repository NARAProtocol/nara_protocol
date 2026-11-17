// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice Reviewed incident adapter: new requests stop; existing attempts stay on their original adapter.
contract NARANullEntropyAdapterV5 {
    uint256 public constant SCHEMA_VERSION = 1;
    address public immutable forge;
    error Disabled(); error InvalidForge();
    constructor(address forge_) { if (forge_ == address(0)) revert InvalidForge(); forge = forge_; }
    function quote() external pure returns (uint256) { return 0; }
    function request(bytes32) external payable returns (uint256) { revert Disabled(); }
    function requestOf(bytes32) external pure returns (uint256) { return 0; }
    function result(uint256) external pure returns (bool, uint64, uint64, uint256) { return (false, 0, 0, 0); }
}
