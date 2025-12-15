// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// --------------------------------------------------------------------------
/// Interfaces
/// --------------------------------------------------------------------------
interface INaraJackpotReceiver {
    function onNaraFeeReceived(address from, uint256 amount) external;
}

/// --------------------------------------------------------------------------
/// Base Contracts
/// --------------------------------------------------------------------------
abstract contract Context {
    function _msgSender() internal view virtual returns (address) { return msg.sender; }
}

abstract contract Ownable is Context {
    address private _owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    error OwnableUnauthorizedAccount(address account);
    error OwnableInvalidOwner(address owner);

    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert OwnableInvalidOwner(address(0));
        _owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    modifier onlyOwner() {
        if (_owner != _msgSender()) revert OwnableUnauthorizedAccount(_msgSender());
        _;
    }

    function owner() public view returns (address) { return _owner; }

    function transferOwnership(address newOwner) public onlyOwner {
        if (newOwner == address(0)) revert OwnableInvalidOwner(address(0));
        address old = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(old, newOwner);
    }
}

abstract contract ReentrancyGuard {
    uint256 private _status;
    error ReentrancyGuardReentrantCall();
    constructor() { _status = 1; }
    modifier nonReentrant() {
        if (_status == 2) revert ReentrancyGuardReentrantCall();
        _status = 2;
        _;
        _status = 1;
    }
}
