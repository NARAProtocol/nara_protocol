// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPoolManager} from "@uniswap/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {StateLibrary} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/TickMath.sol";
import {NARAFeeVaultV5} from "../fee-vault/NARAFeeVaultV5.sol";
import {RewardAsset} from "../interfaces/NARAAccountingTypesV5.sol";
import {NARAPOLPositionV5} from "./NARAPOLPositionV5.sol";
import {NARALiquiditySizerV5} from "./NARALiquiditySizerV5.sol";
import {ICapitalOracleV5} from "../interfaces/ICapitalOracleV5.sol";
import {NARACapitalBudgetV5} from "./NARACapitalBudgetV5.sol";
import {Limits, HardEnvelope, Usage} from "./NARACapitalTypesV5.sol";

/// @notice Bounded POL capital allocation; funds and the LP NFT remain in their custody modules.
/// @dev Oracle construction/identity, launch envelopes and recovery require separate acceptance.
/// The oracle is an immutable external dependency, never a caller-supplied reference price.
contract NARACapitalPolicyV5 is ReentrancyGuardTransient {
    using TransientStateLibrary for IPoolManager;

    struct Plan {
        NARALiquiditySizerV5.Quote quote;
        uint160 price;
        bytes32 observationId;
        uint256 referenceValueFloor;
        uint256 inputValueCeil;
        int24 lower;
        int24 upper;
    }
    struct HardRange {
        uint128 maximumPositionLiquidity;
        int24 minimumTick;
        int24 maximumTick;
        uint24 minimumTickWidth;
    }
    uint256 public constant SCHEMA_VERSION = 1;
    NARAPOLPositionV5 public immutable polPosition;
    NARAFeeVaultV5 public immutable feeVault;
    IPoolManager public immutable poolManager;
    NARALiquiditySizerV5 public immutable sizer;
    bytes32 public immutable poolId;
    address public immutable operator;
    bool public immutable naraFirst;
    int24 public immutable initialLower;
    int24 public immutable initialUpper;
    HardRange private _hard;
    NARACapitalBudgetV5 public immutable capitalBudget;

    error Unauthorized();
    error InvalidBinding();
    error InvalidState();
    error InvalidRange();
    error InvalidObservation();
    error PriceDeviation();
    error CapitalLimit();
    error NoLiquidity();
    error ValueLoss();
    event CapitalExecuted(uint256 indexed nonce, uint8 indexed kind, bytes32 indexed observationId,
        uint256 grossNara, uint256 grossUsdc, uint256 referenceValueFloor, int24 lower, int24 upper);

    constructor(NARAPOLPositionV5 position, NARALiquiditySizerV5 sizer_, address operator_,
        NARACapitalBudgetV5 budget_, int24 lower, int24 upper)
    {
        if (address(position).code.length == 0 || address(sizer_).code.length == 0
            || address(budget_).code.length == 0 || position.initializer() != msg.sender || operator_ == address(0)) revert InvalidBinding();
        NARAFeeVaultV5 vault = position.feeVault();
        if (!vault.bindingsSealed() || sizer_.SCHEMA_VERSION() != 1
            || budget_.SCHEMA_VERSION() != 1 || address(budget_.polPosition()) != address(position)
            || address(budget_.feeVault()) != address(vault) || budget_.initializer() != msg.sender
            || operator_ == vault.governor() || operator_ == vault.guardian() || operator_ == address(position)
            || operator_ == address(vault) || operator_ == address(budget_.oracle())) revert InvalidBinding();
        polPosition = position; feeVault = vault; poolManager = vault.poolManager(); sizer = sizer_;
        capitalBudget = budget_; operator = operator_; naraFirst = vault.nara() < vault.usdc();
        poolId = budget_.poolId();
        HardEnvelope memory env = budget_.hardEnvelope();
        _hard = HardRange(env.maximumPositionLiquidity, env.minimumTick, env.maximumTick, env.minimumTickWidth);
        _range(lower, upper); initialLower = lower; initialUpper = upper;
    }
    function operationActive() external view returns (bool) { return _reentrancyGuardEntered(); }
    /// @dev Retirement obligations include queued settings and unexpired capital usage.
    function hasPendingCapitalOperations() external view returns (bool) {
        _coherent(); return !capitalBudget.canRetire();
    }

    /// @notice Operator-only compounding uses policy-selected budgets and the existing range (D1: MEV-01, DOS-001).
    function compound(uint128 minimumLiquidity, uint48 deadline) external nonReentrant {
        if (msg.sender != operator) revert Unauthorized();
        (uint160 p, ICapitalOracleV5.Observation memory ref) = _begin(deadline, true);
        (int24 lower, int24 upper) = _currentRange();
        Plan memory plan = _plan(p, ref, lower, upper, 0, 0);
        _add(plan, minimumLiquidity, deadline);
        _finish(0, ref.observationId, p, plan.referenceValueFloor, lower, upper);
    }
    /// @notice The capital operator can change range only inside the immutable envelope.
    function rebalance(int24 lower, int24 upper, uint128 minimumLiquidity, uint48 deadline) external nonReentrant {
        if (msg.sender != operator) revert Unauthorized();
        _range(lower, upper);
        (uint160 p, ICapitalOracleV5.Observation memory ref) = _begin(deadline, true);
        NARAPOLPositionV5.Totals memory beforeTotals = polPosition.totals();
        _remove(polPosition.liquidity(), p, deadline);
        NARAPOLPositionV5.Totals memory afterRemoval = polPosition.totals();
        Plan memory plan = _plan(p, ref, lower, upper, afterRemoval.naraRemoved - beforeTotals.naraRemoved,
            afterRemoval.usdcRemoved - beforeTotals.usdcRemoved);
        _add(plan, minimumLiquidity, deadline);
        _finish(1, ref.observationId, p, plan.referenceValueFloor, lower, upper);
    }
    /// @notice Bounded deallocation returns principal only to the fixed Fee Vault.
    /// Policy pause restricts new allocation; Vault pause and stale oracle still require recovery.
    function withdraw(uint128 liquidity, uint48 deadline) external nonReentrant {
        if (msg.sender != operator) revert Unauthorized();
        (uint160 p, ICapitalOracleV5.Observation memory ref) = _begin(deadline, false);
        NARAPOLPositionV5.Totals memory beforeTotals = polPosition.totals();
        int24 lower = polPosition.tickLower(); int24 upper = polPosition.tickUpper();
        _remove(liquidity, p, deadline);
        NARAPOLPositionV5.Totals memory afterTotals = polPosition.totals();
        uint256 value = sizer.principalValue(afterTotals.naraRemoved - beforeTotals.naraRemoved,
            afterTotals.usdcRemoved - beforeTotals.usdcRemoved, ref.sqrtPriceX96, naraFirst);
        if (value < capitalBudget.limits().minimumValueUsdc && polPosition.positionTokenId() != 0) revert CapitalLimit();
        _finish(2, ref.observationId, p, value, lower, upper);
    }
    function recover(uint48 deadline) external nonReentrant {
        _ready();
        (bool ready, uint128 minNara, uint128 minUsdc) = capitalBudget.isRecoveryReady();
        if (!ready) revert InvalidState();
        polPosition.remove(NARAPOLPositionV5.Remove(polPosition.liquidity(), minNara, minUsdc, deadline), true);
        capitalBudget.accountRecovery();
    }
    function previewCompound() external view returns (Plan memory) {
        _coherent(); _ready();
        (uint160 p, ICapitalOracleV5.Observation memory ref) = capitalBudget.checkOperation(true, uint48(block.timestamp));
        (int24 lower, int24 upper) = _currentRange();
        return _plan(p, ref, lower, upper, 0, 0);
    }

    function _currentRange() private view returns (int24 lower, int24 upper) {
        if (polPosition.positionTokenId() == 0) return (initialLower, initialUpper);
        return (polPosition.tickLower(), polPosition.tickUpper());
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) { return a < b ? a : b; }

    function _slot0Price() private view returns (uint160) {
        return uint160(uint256(poolManager.extsload(keccak256(abi.encode(poolId, uint256(6))))));
    }

    function _tickGross(int24 tick) private view returns (uint128) {
        (uint128 gross,) = StateLibrary.getTickLiquidity(poolManager, PoolId.wrap(poolId), tick);
        return gross;
    }

    function _plan(uint160 p, ICapitalOracleV5.Observation memory ref, int24 lower, int24 upper,
        uint256 removedNara, uint256 removedUsdc) private view returns (Plan memory plan)
    {
        _range(lower, upper); Usage memory used = capitalBudget.rollingUsage(); Limits memory lim = capitalBudget.limits();
        if (used.operations >= lim.maximumOperations || used.nara + removedNara > lim.rollingNara
            || used.usdc + removedUsdc > lim.rollingUsdc || removedNara > lim.perCallNara || removedUsdc > lim.perCallUsdc) revert CapitalLimit();
        uint256 n = _min(feeVault.inventory(RewardAsset.NARA).booked.polRaw,
            _min(lim.perCallNara - removedNara, lim.rollingNara - used.nara - removedNara));
        uint256 u = _min(feeVault.inventory(RewardAsset.USDC).booked.polRaw,
            _min(lim.perCallUsdc - removedUsdc, lim.rollingUsdc - used.usdc - removedUsdc));
        uint128 currentL = polPosition.liquidity();
        if (currentL >= _hard.maximumPositionLiquidity) revert CapitalLimit();
        uint128 g0 = _tickGross(lower);
        uint128 g1 = _tickGross(upper);
        uint128 gross = g0 > g1 ? g0 : g1; uint128 maxTick = sizer.maxLiquidityPerTick();
        if (gross >= maxTick) revert CapitalLimit();
        uint128 cap = uint128(_min(_hard.maximumPositionLiquidity - currentL, maxTick - gross));
        (NARALiquiditySizerV5.Quote memory q, uint256 fair, uint256 paid, uint256 lossBps) = sizer.valuedQuote(
            p, ref.sqrtPriceX96, lower, upper, uint128(naraFirst ? n : u), uint128(naraFirst ? u : n), cap, naraFirst);
        if (q.liquidity == 0) revert NoLiquidity();
        if (fair < lim.minimumValueUsdc) revert CapitalLimit();
        if (lossBps > lim.maximumValueLossBps) revert ValueLoss();
        plan = Plan(q, p, ref.observationId, fair, paid, lower, upper);
    }
    function _add(Plan memory plan, uint128 minimumLiquidity, uint48 deadline) private {
        if (minimumLiquidity == 0 || plan.quote.liquidity < minimumLiquidity) revert NoLiquidity();
        polPosition.add(plan.lower, plan.upper, NARAPOLPositionV5.Add(plan.quote.liquidity,
            naraFirst ? plan.quote.amount0 : plan.quote.amount1, naraFirst ? plan.quote.amount1 : plan.quote.amount0,
            plan.price, plan.price, deadline));
    }
    function _remove(uint128 amount, uint160 p, uint48 deadline) private {
        uint128 total = polPosition.liquidity(); if (amount == 0 || amount > total) revert NoLiquidity();
        (uint256 a0, uint256 a1) = sizer.amounts(p, polPosition.tickLower(), polPosition.tickUpper(), amount, false);
        if (a0 > uint128(type(int128).max) || a1 > uint128(type(int128).max)) revert CapitalLimit();
        polPosition.remove(NARAPOLPositionV5.Remove(amount, uint128(naraFirst ? a0 : a1), uint128(naraFirst ? a1 : a0), deadline), amount == total);
    }
    function _begin(uint48 deadline, bool adding) private view returns (uint160, ICapitalOracleV5.Observation memory) {
        _ready(); return capitalBudget.checkOperation(adding, deadline);
    }
    function _finish(uint8 kind, bytes32 observationId, uint160 price, uint256 referenceValue, int24 lower, int24 upper) private {
        if (_slot0Price() != price) revert PriceDeviation();
        (uint256 n, uint256 u) = capitalBudget.account(kind);
        emit CapitalExecuted(capitalBudget.capitalNonce(), kind, observationId, n, u, referenceValue, lower, upper);
    }
    function _range(int24 lower, int24 upper) private view {
        if (lower < _hard.minimumTick || upper > _hard.maximumTick || lower >= upper || lower % 60 != 0 || upper % 60 != 0
            || uint24(upper - lower) < _hard.minimumTickWidth) revert InvalidRange();
    }
    function _ready() private view {
        if (poolManager.isUnlocked() || capitalBudget.policy() != address(this) || capitalBudget.initializer() != address(0) || polPosition.capitalPolicy() != address(this) || feeVault.polController() != address(polPosition)) revert InvalidState();
    }
    function _coherent() private view { if (_reentrancyGuardEntered() || poolManager.isUnlocked()) revert InvalidState(); }
}
