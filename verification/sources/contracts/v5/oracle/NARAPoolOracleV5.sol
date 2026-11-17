// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-periphery/lib/v4-core/src/types/Currency.sol";
import {ICapitalOracleV5} from "../interfaces/ICapitalOracleV5.sol";

interface IObservedPoolHookV5 {
    function poolManager() external view returns (address);
    function capitalOracle() external view returns (address);
    function poolKey() external view returns (PoolKey memory);
}

/// @notice Single-pool tick-time and conservative harmonic-liquidity observations.
/// @dev Requires the bound, source-reviewed Hook to checkpoint BEFORE every swap
/// and liquidity modification. Hook-originated core calls must revert or also
/// checkpoint: Uniswap deliberately skips self-Hook callbacks. Complete graph,
/// manipulation economics and independent source acceptance remain required.
contract NARAPoolOracleV5 is ICapitalOracleV5, ReentrancyGuardTransient {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    struct Sample {
        uint48 timestamp;
        uint64 blockNumber;
        int128 tickSeconds;
        uint48 zeroLiquiditySeconds;
        uint256 inverseLiquidityX192;
    }

    uint256 public constant SCHEMA_VERSION = 1;
    uint256 public constant CAPACITY = 64;
    uint256 public constant PERIOD = 60;
    uint256 private constant Q192 = 1 << 192;
    address public immutable poolManager;
    address public immutable currency0;
    address public immutable currency1;
    uint32 public immutable window;
    address public initializer;
    address public hook;
    bytes32 public poolId;
    bytes32 public hookCodeHash;
    Sample private _latest;
    Sample private _priorBlock;
    Sample[64] private _history;

    error Unauthorized();
    error InvalidBinding();
    error InvalidState();
    error InsufficientHistory();
    event Sealed(address indexed hook, bytes32 indexed poolId, bytes32 hookCodeHash);
    event Checkpoint(uint48 timestamp, uint64 blockNumber, int128 tickSeconds,
        uint48 zeroLiquiditySeconds, uint256 inverseLiquidityX192);

    constructor(IPoolManager manager, address first, address second, uint32 window_) {
        if (address(manager).code.length == 0 || first.code.length == 0 || second.code.length == 0
            || first >= second || window_ < 900 || window_ > 3600) revert InvalidBinding();
        poolManager = address(manager); currency0 = first; currency1 = second;
        window = window_; initializer = msg.sender;
    }

    modifier coherent() {
        if (IPoolManager(poolManager).isUnlocked() || _reentrancyGuardEntered()) revert InvalidState();
        _;
    }

    function seal(address hook_) external nonReentrant {
        if (msg.sender != initializer || hook != address(0)) revert Unauthorized();
        if (IPoolManager(poolManager).isUnlocked() || hook_.code.length == 0
            || uint160(hook_) & 0x0a80 != 0x0a80) revert InvalidBinding();
        IObservedPoolHookV5 h = IObservedPoolHookV5(hook_);
        PoolKey memory key = h.poolKey();
        if (h.poolManager() != poolManager || h.capitalOracle() != address(this)
            || address(key.hooks) != hook_ || Currency.unwrap(key.currency0) != currency0
            || Currency.unwrap(key.currency1) != currency1 || key.fee != 3000 || key.tickSpacing != 60) revert InvalidBinding();
        hook = hook_; hookCodeHash = hook_.codehash; poolId = PoolId.unwrap(key.toId()); initializer = address(0);
        emit Sealed(hook_, poolId, hookCodeHash);
    }

    /// @notice Authenticated pre-change callback. Reads real manager state itself.
    function checkpoint() external nonReentrant {
        if (msg.sender != hook || hook == address(0)) revert Unauthorized();
        if (!IPoolManager(poolManager).isUnlocked()) revert InvalidState();
        _record();
    }

    /// @notice Permissionless maintenance during inactivity, only outside unlocks.
    function poke() external nonReentrant {
        if (hook == address(0) || IPoolManager(poolManager).isUnlocked()) revert InvalidState();
        _record();
    }

    function samples() external view coherent returns (Sample memory latest, Sample memory priorBlock) {
        return (_latest, _priorBlock);
    }
    function history(uint256 index) external view coherent returns (Sample memory) {
        if (index >= CAPACITY) revert InvalidState();
        return _history[index];
    }

    function observation() external view coherent returns (Observation memory value) {
        if (hook == address(0) || hook.codehash != hookCodeHash) revert InvalidState();
        Sample memory end = _latest.blockNumber < block.number ? _latest : _priorBlock;
        if (end.timestamp < window || end.blockNumber == 0 || end.blockNumber >= block.number) revert InsufficientHistory();
        uint48 target = end.timestamp - window;
        uint256 startIndex = CAPACITY;
        uint48 startTime;
        // One retained sample per minute: transaction spam cannot erase a window.
        for (uint256 i; i < CAPACITY; ++i) {
            Sample storage candidate = _history[i];
            if (candidate.blockNumber != 0 && candidate.timestamp <= target
                && (startIndex == CAPACITY || candidate.timestamp > startTime)) {
                startIndex = i; startTime = candidate.timestamp;
            }
        }
        if (startIndex == CAPACITY || end.timestamp - startTime > window + 2 * PERIOD) revert InsufficientHistory();
        Sample memory start = _history[startIndex];
        uint48 elapsed = end.timestamp - start.timestamp;
        int128 tickTotal = end.tickSeconds - start.tickSeconds;
        int128 mean = tickTotal / int128(uint128(elapsed));
        if (tickTotal < 0 && tickTotal % int128(uint128(elapsed)) != 0) --mean;
        uint128 harmonic;
        if (end.zeroLiquiditySeconds == start.zeroLiquiditySeconds) {
            uint256 inverse = end.inverseLiquidityX192 - start.inverseLiquidityX192;
            if (inverse == 0) revert InvalidState();
            uint256 measured = uint256(elapsed) * Q192 / inverse;
            if (measured > type(uint128).max) revert InvalidState();
            harmonic = uint128(measured);
        }
        value = Observation(TickMath.getSqrtPriceAtTick(int24(mean)), start.timestamp, end.timestamp,
            end.blockNumber, harmonic, keccak256(abi.encode(block.chainid, address(this), poolId, start, end)));
    }

    function _record() private {
        if (hook.codehash != hookCodeHash || block.timestamp > type(uint48).max || block.number > type(uint64).max) revert InvalidState();
        IPoolManager manager = IPoolManager(poolManager);
        (uint160 price, int24 tick,,) = manager.getSlot0(PoolId.wrap(poolId));
        if (price == 0) revert InvalidState();
        uint128 liquidity = manager.getLiquidity(PoolId.wrap(poolId));
        Sample memory s = _latest;
        if (s.blockNumber != 0) {
            uint48 elapsed = uint48(block.timestamp) - s.timestamp;
            s.tickSeconds += int128(tick) * int128(uint128(elapsed));
            if (liquidity == 0) s.zeroLiquiditySeconds += elapsed;
            else s.inverseLiquidityX192 += Math.ceilDiv(uint256(elapsed) * Q192, liquidity);
        }
        if (_latest.blockNumber < block.number) _priorBlock = _latest;
        s.timestamp = uint48(block.timestamp); s.blockNumber = uint64(block.number); _latest = s;
        uint256 index = (block.timestamp / PERIOD) % CAPACITY;
        if (_history[index].blockNumber == 0 || _history[index].timestamp / PERIOD != block.timestamp / PERIOD) _history[index] = s;
        emit Checkpoint(s.timestamp, s.blockNumber, s.tickSeconds, s.zeroLiquiditySeconds, s.inverseLiquidityX192);
    }
}
