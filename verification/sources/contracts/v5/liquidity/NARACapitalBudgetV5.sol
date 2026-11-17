// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPoolManager} from "@uniswap/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/SqrtPriceMath.sol";
import {Pool} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/Pool.sol";
import {PoolKey} from "@uniswap/v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {ICapitalOracleV5} from "../interfaces/ICapitalOracleV5.sol";
import {NARAPOLPositionV5, IPOLHookV5} from "./NARAPOLPositionV5.sol";
import {NARAFeeVaultV5} from "../fee-vault/NARAFeeVaultV5.sol";
import {Limits, HardEnvelope, Bucket, Usage} from "./NARACapitalTypesV5.sol";

interface ICapitalPolicyBindingV5 {
    function polPosition() external view returns (address);
    function feeVault() external view returns (address);
    function capitalBudget() external view returns (address);
    function operationActive() external view returns (bool);
}

/// @notice Immutable capital envelope, delayed operating settings and gross-movement ledger.
/// @dev No funds or arbitrary execution. Recorded usage comes from actual POL lifetime counters.
contract NARACapitalBudgetV5 is ReentrancyGuardTransient {
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    struct Recorded { uint256 naraAdded; uint256 usdcAdded; uint256 naraRemoved; uint256 usdcRemoved; uint128 liquidity; }
    uint256 public constant SCHEMA_VERSION = 1;
    uint256 public constant MIN_DELAY = 1 hours;
    uint256 public constant MAX_DELAY = 7 days;
    uint256 public constant MAX_OPERATION_DEADLINE = 5 minutes;
    uint256 public constant USAGE_BUCKETS = 25;
    NARAPOLPositionV5 public immutable polPosition;
    NARAFeeVaultV5 public immutable feeVault;
    IPoolManager public immutable poolManager;
    ICapitalOracleV5 public immutable oracle;
    bytes32 public immutable oracleCodeHash;
    bytes32 public immutable poolId;
    bytes32 private immutable _slot0Key;
    address public immutable governor;
    address public immutable guardian;
    address public initializer;
    address public policy;
    HardEnvelope private _hard;
    Limits private _limits;
    Limits private _pendingLimits;
    bytes32 private _pendingHash;
    Bucket[25] private _buckets;
    Recorded private _recorded;
    uint256 public operatingDelay = MIN_DELAY;
    uint256 public proposalNonce;
    uint256 public pendingReadyAt;
    uint256 private _pendingDelay;
    bool private _pendingResume;
    uint256 public lastCapitalAt;
    uint256 public capitalNonce;
    bool public paused;
    uint256 public recoveryReadyAt;
    uint256 public recoveryNonce;
    uint128 public recoveryMinNara;
    uint128 public recoveryMinUsdc;
    error Unauthorized();
    error InvalidBinding();
    error InvalidLimits();
    error InvalidState();
    error CapitalLimit();
    error InvalidObservation();
    error PriceDeviation();
    error CapitalTooSoon();
    error Expired();
    event Sealed(address indexed policy);
    event ConfigurationProposed(uint256 indexed nonce, bytes32 indexed configurationHash, uint256 readyAt, uint256 nextDelay, bool resume, Limits nextLimits);
    event ConfigurationApplied(uint256 indexed nonce, bytes32 indexed configurationHash, uint256 delay, bool paused);
    event ConfigurationCancelled(uint256 indexed nonce);
    event Paused(bytes32 indexed reason);
    event CapitalCharged(uint256 indexed nonce, uint8 indexed kind, uint256 grossNara, uint256 grossUsdc, uint256 hour);
    event RecoveryProposed(uint256 indexed nonce, uint256 readyAt, uint128 minNara, uint128 minUsdc);
    event RecoveryCancelled(uint256 indexed nonce);
    event RecoveryExecuted(uint256 indexed nonce, uint256 nara, uint256 usdc);

    constructor(NARAPOLPositionV5 position, ICapitalOracleV5 oracle_, HardEnvelope memory hard, Limits memory initial) {
        if (address(position).code.length == 0 || address(oracle_).code.length == 0 || position.initializer() != msg.sender) revert InvalidBinding();
        NARAFeeVaultV5 vault = position.feeVault();
        if (!vault.bindingsSealed() || position.positionTokenId() != 0) revert InvalidBinding();
        polPosition = position; feeVault = vault; poolManager = vault.poolManager();
        governor = vault.governor(); guardian = vault.guardian(); initializer = msg.sender;
        PoolKey memory key = IPOLHookV5(vault.hook()).poolKey(); poolId = PoolId.unwrap(key.toId()); oracle = oracle_;
        _slot0Key = keccak256(abi.encode(poolId, uint256(6)));
        if (oracle_.SCHEMA_VERSION() != 1 || oracle_.poolManager() != address(vault.poolManager()) || oracle_.poolId() != poolId) revert InvalidBinding();
        oracleCodeHash = address(oracle_).codehash;
        if (hard.maximumPositionLiquidity == 0 || hard.maximumPositionLiquidity > Pool.tickSpacingToMaxLiquidityPerTick(60)
            || hard.minimumOracleLiquidity == 0 || hard.minimumOracleWindow == 0
            || hard.minimumTick < TickMath.MIN_TICK || hard.maximumTick > TickMath.MAX_TICK
            || hard.minimumTick >= hard.maximumTick || hard.minimumTick % 60 != 0 || hard.maximumTick % 60 != 0
            || hard.minimumTickWidth < 60 || hard.minimumTickWidth % 60 != 0) revert InvalidLimits();
        uint160 a = TickMath.getSqrtPriceAtTick(hard.minimumTick);
        uint160 b = TickMath.getSqrtPriceAtTick(hard.maximumTick);
        uint256 maximumDelta = uint128(type(int128).max);
        if (SqrtPriceMath.getAmount0Delta(a, b, hard.maximumPositionLiquidity, true) > maximumDelta
            || SqrtPriceMath.getAmount1Delta(a, b, hard.maximumPositionLiquidity, true) > maximumDelta) revert InvalidLimits();
        _hard = hard; _validateLimits(hard.bounds); _validateLimits(initial); _limits = initial;
        paused = true; // D1: allocation stays closed from seal until a governed resume (MEV-01, DOS-001)
    }
    function seal(address policy_) external nonReentrant {
        if (initializer == address(0) || msg.sender != initializer) revert Unauthorized();
        if (poolManager.isUnlocked() || policy_.code.length == 0 || polPosition.capitalPolicy() != policy_) revert InvalidBinding();
        ICapitalPolicyBindingV5 p = ICapitalPolicyBindingV5(policy_);
        if (p.polPosition() != address(polPosition) || p.feeVault() != address(feeVault) || p.capitalBudget() != address(this)) revert InvalidBinding();
        policy = policy_; initializer = address(0); emit Sealed(policy_);
    }
    function checkOperation(bool addsCapital, uint48 deadline) external view returns (uint160, ICapitalOracleV5.Observation memory) {
        _ready(); if (msg.sender != policy) revert Unauthorized();
        if ((addsCapital && paused) || feeVault.polPaused()) revert InvalidState();
        if (deadline < block.timestamp || deadline > block.timestamp + MAX_OPERATION_DEADLINE) revert Expired();
        _timing();
        NARAPOLPositionV5.Totals memory t = polPosition.totals(); Recorded memory r = _recorded;
        if (t.naraAdded != r.naraAdded || t.usdcAdded != r.usdcAdded || t.naraRemoved != r.naraRemoved
            || t.usdcRemoved != r.usdcRemoved || polPosition.liquidity() != r.liquidity) revert InvalidState();
        return _reference();
    }
    function account(uint8 kind) external nonReentrant returns (uint256 nara, uint256 usdc) {
        _ready(); if (msg.sender != policy) revert Unauthorized(); _timing(); if (kind > 2) revert InvalidState();
        NARAPOLPositionV5.Totals memory t = polPosition.totals(); Recorded memory r = _recorded;
        nara = t.naraAdded - r.naraAdded + t.naraRemoved - r.naraRemoved;
        usdc = t.usdcAdded - r.usdcAdded + t.usdcRemoved - r.usdcRemoved;
        uint128 liquidity = polPosition.liquidity(); Usage memory used = _usage(); Limits memory lim = _limits;
        bool emptyClose = kind == 2 && r.liquidity != 0 && liquidity == 0 && polPosition.positionTokenId() == 0;
        if ((nara == 0 && usdc == 0 && !emptyClose) || nara > lim.perCallNara || usdc > lim.perCallUsdc
            || used.nara + nara > lim.rollingNara || used.usdc + usdc > lim.rollingUsdc
            || used.operations + 1 > lim.maximumOperations || liquidity > _hard.maximumPositionLiquidity) revert CapitalLimit();
        uint256 hour = block.timestamp / 1 hours; Bucket storage bucket = _buckets[hour % USAGE_BUCKETS];
        if (bucket.hour != hour) { bucket.hour = uint48(hour); bucket.nara = 0; bucket.usdc = 0; bucket.operations = 0; }
        bucket.nara += uint128(nara); bucket.usdc += uint128(usdc); ++bucket.operations;
        _recorded = Recorded(t.naraAdded, t.usdcAdded, t.naraRemoved, t.usdcRemoved, liquidity);
        lastCapitalAt = block.timestamp;
        emit CapitalCharged(++capitalNonce, kind, nara, usdc, hour);
    }
    function recordedCapital() external view returns (Recorded memory) { _coherent(); return _recorded; }

    function _slot0Price() private view returns (uint160) {
        return uint160(uint256(poolManager.extsload(_slot0Key)));
    }

    function _reference() private view returns (uint160 p, ICapitalOracleV5.Observation memory ref) {
        p = _slot0Price();
        if (p < TickMath.MIN_SQRT_PRICE || p >= TickMath.MAX_SQRT_PRICE) revert InvalidObservation();
        if (address(oracle).codehash != oracleCodeHash || oracle.poolManager() != address(poolManager) || oracle.poolId() != poolId) revert InvalidObservation();
        ref = oracle.observation();
        Limits memory lim = _limits;
        if (ref.sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || ref.sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE
            || ref.observationId == bytes32(0) || ref.start >= ref.end || ref.end > block.timestamp
            || uint256(ref.end) - ref.start < _hard.minimumOracleWindow || block.timestamp - ref.end > lim.maximumOracleAge
            || ref.endBlock >= block.number || ref.harmonicLiquidity < _hard.minimumOracleLiquidity) revert InvalidObservation();
        uint256 delta = p > ref.sqrtPriceX96 ? p - ref.sqrtPriceX96 : ref.sqrtPriceX96 - p;
        if (delta * 10000 > uint256(ref.sqrtPriceX96) * lim.maximumSqrtDeviationBps) revert PriceDeviation();
    }
    function _timing() private view {
        if (capitalNonce != 0 && block.timestamp < lastCapitalAt + _limits.minimumInterval) revert CapitalTooSoon();
    }
    function _ready() private view {
        if (initializer != address(0) || policy == address(0) || poolManager.isUnlocked()
            || polPosition.capitalPolicy() != policy || feeVault.polController() != address(polPosition)) revert InvalidState();
        if (msg.sender != policy && ICapitalPolicyBindingV5(policy).operationActive()) revert InvalidState();
    }
    function _coherent() private view {
        if (_reentrancyGuardEntered() || poolManager.isUnlocked()
            || (policy != address(0) && msg.sender != policy && ICapitalPolicyBindingV5(policy).operationActive())) revert InvalidState();
    }
    function hardEnvelope() external view returns (HardEnvelope memory) { _coherent(); return _hard; }
    function limits() external view returns (Limits memory) { _coherent(); return _limits; }
    function pendingConfiguration() external view returns (Limits memory, uint256 delay, bool resume) {
        _coherent();
        if (pendingReadyAt == 0) return (_pendingLimits, 0, false);
        return (_pendingLimits, _pendingDelay, _pendingResume);
    }
    function usageBuckets() external view returns (Bucket[25] memory) { _coherent(); return _buckets; }
    function rollingUsage() external view returns (Usage memory) { _coherent(); return _usage(); }
    function hasPendingCapitalOperations() external view returns (bool) { _coherent(); return pendingReadyAt != 0 || recoveryReadyAt != 0; }

    function _pauseInternal() private {
        paused = true;
        if (pendingReadyAt != 0) { pendingReadyAt = 0; emit ConfigurationCancelled(proposalNonce); }
    }

    function proposeRecovery(uint128 minNara, uint128 minUsdc) external nonReentrant {
        _ready(); if (msg.sender != governor) revert Unauthorized();
        if (recoveryReadyAt != 0 || polPosition.positionTokenId() == 0) revert InvalidState();
        _pauseInternal();
        recoveryReadyAt = block.timestamp + MAX_DELAY;
        recoveryMinNara = minNara; recoveryMinUsdc = minUsdc;
        emit RecoveryProposed(++recoveryNonce, recoveryReadyAt, minNara, minUsdc);
    }
    function cancelRecovery(uint256 nonce) external nonReentrant {
        _ready(); if (msg.sender != governor && msg.sender != guardian) revert Unauthorized();
        if (recoveryReadyAt == 0 || nonce != recoveryNonce) revert InvalidState();
        recoveryReadyAt = 0;
        emit RecoveryCancelled(nonce);
    }
    function isRecoveryReady() external view returns (bool ready, uint128 minNara, uint128 minUsdc) {
        _coherent();
        if (recoveryReadyAt != 0 && block.timestamp >= recoveryReadyAt) return (true, recoveryMinNara, recoveryMinUsdc);
        return (false, 0, 0);
    }
    function accountRecovery() external nonReentrant returns (uint256 nara, uint256 usdc) {
        _ready(); if (msg.sender != policy) revert Unauthorized();
        if (recoveryReadyAt == 0 || block.timestamp < recoveryReadyAt) revert InvalidState();
        if (polPosition.positionTokenId() != 0 || polPosition.liquidity() != 0) revert InvalidState();
        NARAPOLPositionV5.Totals memory t = polPosition.totals(); Recorded memory r = _recorded;
        nara = t.naraRemoved - r.naraRemoved; usdc = t.usdcRemoved - r.usdcRemoved;
        _recorded = Recorded(t.naraAdded, t.usdcAdded, t.naraRemoved, t.usdcRemoved, 0);
        emit RecoveryExecuted(recoveryNonce, nara, usdc);
        recoveryReadyAt = 0;
    }
    function canRetire() external view returns (bool) {
        _coherent();
        return initializer == address(0) && pendingReadyAt == 0 && recoveryReadyAt == 0 && _usage().operations == 0
            && (capitalNonce == 0 || block.timestamp >= lastCapitalAt + _limits.minimumInterval);
    }

    function proposeConfiguration(Limits calldata next, uint256 nextDelay, bool resume)
        external nonReentrant
    {
        _ready(); if (msg.sender != governor) revert Unauthorized();
        if (pendingReadyAt != 0 || nextDelay < MIN_DELAY || nextDelay > MAX_DELAY) revert InvalidState();
        _validateLimits(next); _pendingLimits = next; _pendingDelay = nextDelay; _pendingResume = resume;
        bytes32 hash = keccak256(abi.encode(next, nextDelay, resume));
        _pendingHash = hash;
        pendingReadyAt = block.timestamp + operatingDelay; ++proposalNonce;
        emit ConfigurationProposed(proposalNonce, hash, pendingReadyAt, nextDelay, resume, next);
    }
    function executeConfiguration(uint256 nonce) external nonReentrant {
        _ready(); if (pendingReadyAt == 0 || nonce != proposalNonce || block.timestamp < pendingReadyAt) revert InvalidState();
        _limits = _pendingLimits; operatingDelay = _pendingDelay;
        if (_pendingResume) paused = false;
        pendingReadyAt = 0;
        emit ConfigurationApplied(nonce, _pendingHash, operatingDelay, paused);
    }
    function cancelConfiguration(uint256 nonce) external nonReentrant {
        _ready(); if (msg.sender != governor && msg.sender != guardian) revert Unauthorized();
        if (pendingReadyAt == 0 || nonce != proposalNonce) revert InvalidState();
        pendingReadyAt = 0; emit ConfigurationCancelled(nonce);
    }
    function pause(bytes32 reason) external nonReentrant {
        _ready(); if (msg.sender != governor && msg.sender != guardian) revert Unauthorized();
        _pauseInternal();
        emit Paused(reason);
    }

    function _usage() private view returns (Usage memory used) {
        uint256 hour = block.timestamp / 1 hours;
        for (uint256 i; i < USAGE_BUCKETS; ++i) {
            Bucket memory b = _buckets[i];
            if (b.hour <= hour && uint256(b.hour) + 24 >= hour) { used.nara += b.nara; used.usdc += b.usdc; used.operations += b.operations; }
        }
    }
    function _validateLimits(Limits memory lim) private view {
        Limits storage hard = _hard.bounds;
        if (lim.perCallNara == 0 || lim.perCallUsdc == 0 || lim.rollingNara < lim.perCallNara || lim.rollingUsdc < lim.perCallUsdc
            || lim.minimumValueUsdc == 0 || lim.minimumInterval < 900 || lim.maximumOracleAge == 0 || lim.maximumOperations == 0
            || lim.maximumSqrtDeviationBps > 10000 || lim.maximumValueLossBps > 10000
            || lim.perCallNara > hard.perCallNara || lim.perCallUsdc > hard.perCallUsdc
            || lim.rollingNara > hard.rollingNara || lim.rollingUsdc > hard.rollingUsdc
            || lim.minimumValueUsdc < hard.minimumValueUsdc || lim.minimumInterval < hard.minimumInterval
            || lim.maximumOracleAge > hard.maximumOracleAge || lim.maximumOperations > hard.maximumOperations
            || lim.maximumSqrtDeviationBps > hard.maximumSqrtDeviationBps || lim.maximumValueLossBps > hard.maximumValueLossBps) revert InvalidLimits();
    }
}
