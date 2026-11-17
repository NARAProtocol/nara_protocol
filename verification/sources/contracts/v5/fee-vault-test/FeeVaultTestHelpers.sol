// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NARAFeeVaultV5} from "../fee-vault/NARAFeeVaultV5.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-periphery/lib/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-periphery/lib/v4-core/src/types/Currency.sol";

/// @dev TEST ONLY: unrestricted source for real manager claims, not a swap Hook.
contract FeeVaultClaimSource is IUnlockCallback {
    using CurrencyLibrary for Currency;
    IPoolManager public immutable poolManager;
    address public immutable collector;
    address public immutable token;
    address public immutable base;
    bool public skipPrepare;
    bool public duplicateRecord;
    constructor(IPoolManager m, address v, address n, address u) { poolManager = m; collector = v; token = n; base = u; }
    function issue(address asset, uint256 amount, uint256 recordAmount, bytes calldata reentry) external {
        poolManager.unlock(abi.encode(asset, amount, recordAmount, reentry));
    }
    function faults(bool skip, bool duplicate) external { skipPrepare = skip; duplicateRecord = duplicate; }
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager));
        (address asset, uint256 amount, uint256 recordAmount, bytes memory reentry) = abi.decode(data, (address, uint256, uint256, bytes));
        Currency currency = Currency.wrap(asset);
        if (recordAmount != 0 && !skipPrepare) NARAFeeVaultV5(collector).prepareFee(currency);
        poolManager.mint(collector, currency.toId(), amount);
        if (recordAmount != 0) NARAFeeVaultV5(collector).record(currency, recordAmount);
        if (duplicateRecord) NARAFeeVaultV5(collector).record(currency, recordAmount);
        if (reentry.length != 0) { (bool ok,) = collector.call(reentry); require(!ok, "reentry accepted"); }
        poolManager.sync(currency);
        require(IERC20(asset).transfer(address(poolManager), amount));
        require(poolManager.settle() == amount);
        return "";
    }
}

/// @dev TEST ONLY: explicit faults/calls model the unimplemented POL controller.
contract FeeVaultPOLFixture {
    address public immutable poolManager;
    address public immutable feeVault;
    address public immutable nara;
    address public immutable usdc;
    bool public canRetire = true;
    bool public rejectETH;
    bytes public callbackData;
    bool public callbackBlocked;
    address public callbackTarget;
    bytes public callbackResult;
    constructor(address m, address v, address n, address u) { poolManager = m; feeVault = v; nara = n; usdc = u; }
    function setCanRetire(bool b) external { canRetire = b; }
    function setCallback(bool reject, bytes calldata data) external {
        rejectETH = reject; callbackData = data; callbackBlocked = false;
        callbackTarget = feeVault; delete callbackResult;
    }
    function setCallbackTarget(address target) external { callbackTarget = target; }
    function approve(address asset, uint256 amount) external { IERC20(asset).approve(feeVault, amount); }
    function run(bytes calldata data) external payable returns (bytes memory) {
        (bool ok, bytes memory result) = feeVault.call{value: msg.value}(data);
        if (!ok) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        return result;
    }
    receive() external payable {
        require(!rejectETH);
        if (callbackData.length != 0) {
            (bool ok, bytes memory result) = callbackTarget.call(callbackData);
            require(!ok); callbackBlocked = true; callbackResult = result;
        }
    }
}

contract FeeVaultGovernorFixture is IUnlockCallback {
    address public immutable owner = msg.sender;
    address private _probeManager;
    address private _probeTarget;
    bytes private _probeData;
    bool public probeBlocked;
    bytes public probeResult;
    event Created(address indexed deployed);
    /// @dev TEST ONLY: exercises constructor calls from the contract governor.
    function create(bytes memory code) external returns (address deployed) {
        require(msg.sender == owner);
        assembly ("memory-safe") {
            deployed := create(0, add(code, 32), mload(code))
            if iszero(deployed) {
                let p := mload(0x40)
                returndatacopy(p, 0, returndatasize())
                revert(p, returndatasize())
            }
        }
        emit Created(deployed);
    }
    function run(address target, bytes calldata data) external returns (bytes memory) {
        require(msg.sender == owner);
        (bool ok, bytes memory result) = target.call(data);
        if (!ok) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        return result;
    }
    /// @dev TEST ONLY: the authorized governor calls the target during a real manager unlock.
    function probeManagerUnlock(address manager, address target, bytes calldata data) external {
        require(msg.sender == owner && _probeManager == address(0));
        _probeManager = manager; _probeTarget = target; _probeData = data;
        probeBlocked = false; delete probeResult;
        IPoolManager(manager).unlock("");
        _probeManager = address(0); _probeTarget = address(0); delete _probeData;
    }
    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(_probeManager != address(0) && msg.sender == _probeManager);
        (bool ok, bytes memory result) = _probeTarget.call(_probeData);
        require(!ok, "unlock probe accepted");
        probeBlocked = true; probeResult = result;
        return "";
    }
}

/// @dev Force-send probe is test-only; no deployment/production selfdestruct path.
contract FeeVaultForceETH {
    constructor(address payable target) payable { selfdestruct(target); }
}

/// @dev TEST ONLY: install at a local peer address to change only its schema
/// getter. All other calls execute a copied genuine runtime against that peer's
/// original storage. This is fault injection, never a deployable graph member.
contract FeeVaultSchemaFault {
    address private immutable _implementation;
    uint256 public immutable SCHEMA_VERSION;
    uint256 public immutable financialSchemaVersion;
    constructor(address implementation, uint256 schema) {
        _implementation = implementation; SCHEMA_VERSION = schema; financialSchemaVersion = schema;
    }
    fallback() external {
        address implementation = _implementation;
        assembly ("memory-safe") {
            let p := mload(0x40)
            calldatacopy(p, 0, calldatasize())
            let ok := delegatecall(gas(), implementation, p, calldatasize(), 0, 0)
            returndatacopy(p, 0, returndatasize())
            if iszero(ok) { revert(p, returndatasize()) }
            return(p, returndatasize())
        }
    }
}
