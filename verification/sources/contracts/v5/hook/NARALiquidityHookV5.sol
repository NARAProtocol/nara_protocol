// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-periphery/lib/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-periphery/lib/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {NARAHookFeeMathV5 as Fees} from "../liquidity/NARAHookFeeMathV5.sol";
import {NARAHookFeeCalculatorV5} from "../liquidity/NARAHookFeeCalculatorV5.sol";
import {NARAPoolOracleV5} from "../oracle/NARAPoolOracleV5.sol";

interface IHookFeeVaultV5 {
    function SCHEMA_VERSION() external view returns (uint256);
    function poolManager() external view returns (address);
    function nara() external view returns (address);
    function usdc() external view returns (address);
    function governor() external view returns (address);
    function guardian() external view returns (address);
    function initializer() external view returns (address);
    function hook() external view returns (address);
    function bindingsSealed() external view returns (bool);
    function prepareFee(Currency currency) external;
    function record(Currency currency, uint256 amount) external;
}

/// @notice Fresh single-pool Hook candidate, with realized input fees and exact Vault receipts.
/// @dev Final parameters, rounding disclosure, independent review and deployment
/// acceptance remain required. The pool is NARA/USDC with v4's fixed fee/tick spacing.
contract NARALiquidityHookV5 is BaseHook {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    struct Terms { Fees.Curve curve; uint256 depth; uint64 version; }
    struct PendingTerms { Terms terms; uint64 effectiveAt; bool exists; }
    struct BlockFlow { uint256 blockNumber; uint256 gross; uint256 fee; Terms terms; }
    uint256 public constant SCHEMA_VERSION = 1;
    uint256 public constant FEE_UPDATE_DELAY = 7 days;
    uint256 public constant MIN_PROTOCOL_DEPTH = 1_000_000;
    uint24 public constant CANONICAL_POOL_FEE = 3_000;
    int24 public constant CANONICAL_TICK_SPACING = 60;
    address public immutable token;
    address public immutable base;
    address public immutable collector;
    address public immutable governor;
    address public immutable guardian;
    uint160 public immutable initialPrice;
    NARAHookFeeCalculatorV5 public immutable feeCalculator;
    NARAPoolOracleV5 public immutable capitalOracle;
    address public initializer;
    bool public poolRegistered;
    bool public tradingPaused = true;
    PoolId public registeredPoolId;
    mapping(address => Terms) private _configured;
    mapping(address => PendingTerms) private _pending;
    mapping(address => uint64) private _nonce;
    mapping(address => BlockFlow) private _flows;

    bool transient private _busy;
    bool transient private _probing;
    bytes32 transient private _context;
    uint256 transient private _prior;
    uint256 transient private _expectedInput;
    uint256 transient private _expectedOutput;
    uint256 transient private _fee;
    uint256 transient private _gross;

    error Unauthorized();
    error UnauthorizedPool();
    error InvalidBinding();
    error InvalidState();
    error InvalidExecution();
    error ProbeResult(int128 amount0, int128 amount1);
    error ProbeDidNotRevert();
    error UnauthorizedProbe();
    // Preserve decoding of errors now bubbled from the fixed calculator.
    error InvalidCurve();
    error AmountOutOfBounds();
    error NetAmountUnavailable();
    event PoolRegistered(PoolId indexed poolId, uint160 openingPrice);
    event TradingPauseChanged(bool paused, bytes32 indexed evidence);
    event TermsProposed(address indexed currency, uint64 indexed nonce, uint64 effectiveAt, Fees.Curve curve, uint256 depth);
    event TermsCancelled(address indexed currency, uint64 indexed nonce);
    event TermsApplied(address indexed currency, uint64 indexed version, uint64 effectiveAt);
    event RealizedFee(address indexed currency, uint64 indexed termsVersion, bool exactInput, uint256 requested, uint256 gross, uint256 poolInput, uint256 fee, uint256 output);

    constructor(IPoolManager manager, IHookFeeVaultV5 vault, NARAPoolOracleV5 oracle_, address initializer_, uint160 price_,
        Fees.Curve memory buy, Fees.Curve memory sell, uint256 tokenDepth, uint256 baseDepth) BaseHook(manager)
    {
        if (address(manager).code.length == 0 || address(vault).code.length == 0 || initializer_ == address(0)
            || vault.SCHEMA_VERSION() != 1 || vault.poolManager() != address(manager)
            || vault.bindingsSealed() || vault.initializer() != initializer_
            || price_ < TickMath.MIN_SQRT_PRICE || price_ >= TickMath.MAX_SQRT_PRICE) revert InvalidBinding();
        address n = vault.nara(); address u = vault.usdc(); address g = vault.governor(); address guard = vault.guardian();
        if (n.code.length == 0 || u.code.length == 0 || n == u || g.code.length == 0 || guard == address(0)
            || n == address(this) || u == address(this) || g == address(this) || guard == address(this)) revert InvalidBinding();
        if (address(oracle_).code.length == 0 || oracle_.SCHEMA_VERSION() != 1 || oracle_.poolManager() != address(manager)
            || oracle_.initializer() != initializer_ || oracle_.hook() != address(0)
            || oracle_.currency0() != (n < u ? n : u) || oracle_.currency1() != (n < u ? u : n)) revert InvalidBinding();
        feeCalculator = new NARAHookFeeCalculatorV5(); capitalOracle = oracle_;
        _validateTerms(buy, baseDepth); _validateTerms(sell, tokenDepth);
        token = n; base = u; collector = address(vault); governor = g; guardian = guard;
        initializer = initializer_; initialPrice = price_;
        _configured[n] = Terms(sell, tokenDepth, 1); _configured[u] = Terms(buy, baseDepth, 1);
        _nonce[n] = 1; _nonce[u] = 1;
    }

    modifier management() {
        if (_busy || poolManager.isUnlocked()) revert InvalidState();
        _busy = true; _; _busy = false;
    }
    modifier coherentRead() { if (_busy) revert InvalidState(); _; }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true; p.beforeSwap = true; p.afterSwap = true;
        p.beforeAddLiquidity = true; p.beforeRemoveLiquidity = true;
        p.beforeSwapReturnDelta = true; p.afterSwapReturnDelta = true;
    }

    function registerPool() external management {
        if (msg.sender != initializer || poolRegistered) revert Unauthorized();
        IHookFeeVaultV5 v = IHookFeeVaultV5(collector);
        if (!v.bindingsSealed() || v.hook() != address(this)) revert InvalidBinding();
        PoolKey memory key = _key();
        if (capitalOracle.hook() != address(this) || capitalOracle.poolId() != PoolId.unwrap(key.toId())
            || capitalOracle.initializer() != address(0)) revert InvalidBinding();
        registeredPoolId = key.toId(); poolRegistered = true; initializer = address(0);
        emit PoolRegistered(registeredPoolId, initialPrice);
    }

    /// @notice Initial opening and later unpause are explicit governor actions.
    /// Guardian may only stop swaps; Vault forwarding and principal exits are separate.
    function setTradingPaused(bool paused, bytes32 evidence) external management {
        if (paused ? msg.sender != governor && msg.sender != guardian : msg.sender != governor) revert Unauthorized();
        if (!poolRegistered || paused == tradingPaused || evidence == bytes32(0)) revert InvalidState();
        if (!paused) { (uint160 price,,,) = poolManager.getSlot0(registeredPoolId); if (price == 0) revert InvalidState(); }
        tradingPaused = paused; emit TradingPauseChanged(paused, evidence);
    }

    /// @notice A complete curve/depth pair takes effect at a UTC 900-second boundary
    /// at least seven days ahead. Activation does not depend on a keeper transaction.
    function proposeTerms(address currency, Fees.Curve calldata curve, uint256 depth) external management {
        if (msg.sender != governor) revert Unauthorized();
        if (!poolRegistered) revert InvalidState();
        _requireCurrency(currency); _validateTerms(curve, depth); _applyMatured(currency);
        if (_pending[currency].exists) revert InvalidState();
        uint256 effectiveAt = (block.timestamp + FEE_UPDATE_DELAY + 899) / 900 * 900;
        if (effectiveAt > type(uint64).max) revert InvalidState();
        uint64 nonce = ++_nonce[currency];
        _pending[currency] = PendingTerms(Terms(curve, depth, nonce), uint64(effectiveAt), true);
        emit TermsProposed(currency, nonce, uint64(effectiveAt), curve, depth);
    }
    function cancelTerms(address currency, uint64 nonce) external management {
        if (msg.sender != governor) revert Unauthorized();
        _requireCurrency(currency); PendingTerms storage p = _pending[currency];
        if (!p.exists || p.terms.version != nonce || block.timestamp >= p.effectiveAt) revert InvalidState();
        delete _pending[currency]; emit TermsCancelled(currency, nonce);
    }
    /// @notice Materialize already-effective terms; this never controls activation time.
    function applyTerms(address currency, uint64 nonce) external management {
        _requireCurrency(currency); PendingTerms storage p = _pending[currency];
        if (!p.exists || p.terms.version != nonce || block.timestamp < p.effectiveAt) revert InvalidState();
        _applyMatured(currency);
    }
    function feeState(address currency) external view coherentRead returns (
        Terms memory effective, PendingTerms memory pending, BlockFlow memory lastFlow, bool currentBlock
    ) {
        _requireCurrency(currency); effective = _effective(currency); pending = _pending[currency]; lastFlow = _flows[currency];
        currentBlock = lastFlow.gross != 0 && lastFlow.blockNumber == block.number;
    }
    /// @notice Gross-budget fee quote, not a guarantee of full execution at a price limit.
    /// Real partial/output quotes must use the compatible Quoter and final settlement.
    function quoteGross(address currency, uint256 requested) external view coherentRead returns (uint256 fee, uint256 net, uint64 version) {
        _requireCurrency(currency);
        (Terms memory terms, uint256 prior) = _swapTerms(currency);
        (fee, net) = feeCalculator.quoteGross(terms.curve, prior, requested, terms.depth); version = terms.version;
    }
    function poolKey() external view returns (PoolKey memory) { return _key(); }

    /// @notice Observed virtual pool inventory is telemetry only, never fee depth.
    /// Preserve v4's protection against transient liquidity/price manipulation of fees.
    function liveDepth(address currency) external view coherentRead returns (uint256) {
        _requireCurrency(currency); if (!poolRegistered) return 0;
        uint128 liquidity = poolManager.getLiquidity(registeredPoolId);
        (uint160 price,,,) = poolManager.getSlot0(registeredPoolId);
        return feeCalculator.virtualDepth(liquidity, price, currency == (token < base ? token : base));
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160 price) internal view override returns (bytes4) {
        _validatePool(key); if (price != initialPrice) revert InvalidExecution();
        return IHooks.beforeInitialize.selector;
    }
    function _beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        internal override returns (bytes4) {
        _checkpointLiquidity(key); return IHooks.beforeAddLiquidity.selector;
    }
    function _beforeRemoveLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        internal override returns (bytes4) {
        _checkpointLiquidity(key); return IHooks.beforeRemoveLiquidity.selector;
    }
    function _checkpointLiquidity(PoolKey calldata key) private {
        _validatePool(key); if (_busy) revert InvalidState();
        _busy = true; capitalOracle.checkpoint(); _busy = false;
    }
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal override returns (bytes4, BeforeSwapDelta, uint24)
    {
        _validatePool(key);
        if (_busy || tradingPaused || params.amountSpecified == 0 || params.amountSpecified > int256(Fees.MAX_GROSS)
            || params.amountSpecified < -int256(Fees.MAX_GROSS)) revert InvalidExecution();
        _busy = true; _context = keccak256(abi.encode(sender, key, params));
        capitalOracle.checkpoint();
        address currency = Currency.unwrap(params.zeroForOne ? key.currency0 : key.currency1);
        (Terms memory terms, uint256 prior) = _swapTerms(currency); _prior = prior;
        if (params.amountSpecified > 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        uint256 requested = uint256(-params.amountSpecified);
        (uint256 reservation, uint256 netBudget) = feeCalculator.quoteGross(terms.curve, prior, requested, terms.depth);
        if (netBudget == 0) revert InvalidExecution();
        SwapParams memory probe = SwapParams(params.zeroForOne, -int256(netBudget), params.sqrtPriceLimitX96);
        _probing = true;
        (bool ok, bytes memory data) = address(this).call(abi.encodeCall(this.probeSwap, (key, probe)));
        _probing = false;
        if (ok) revert ProbeDidNotRevert();
        if (data.length != 68 || bytes4(data) != ProbeResult.selector) {
            assembly ("memory-safe") { revert(add(data, 32), mload(data)) }
        }
        int128 amount0; int128 amount1;
        assembly ("memory-safe") { amount0 := mload(add(data, 36)) amount1 := mload(add(data, 68)) }
        (uint256 actualInput, uint256 actualOutput) = _amounts(params.zeroForOne, amount0, amount1);
        if (actualInput > netBudget || (actualInput != 0 && actualOutput == 0)) revert InvalidExecution();
        uint256 fee; uint256 gross;
        // Preserve the explicitly disclosed candidate full-input rounding policy.
        // Partial/output executions use least-debit inversion; no fee for no fill.
        if (actualInput == netBudget) { fee = reservation; gross = requested; }
        else (gross, fee) = feeCalculator.grossForNet(terms.curve, prior, actualInput, terms.depth);
        _expectedInput = actualInput; _expectedOutput = actualOutput; _fee = fee; _gross = gross;
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(fee)), 0), 0);
    }
    function probeSwap(PoolKey calldata key, SwapParams calldata params) external {
        if (msg.sender != address(this) || !_busy || !_probing) revert UnauthorizedProbe();
        BalanceDelta delta = poolManager.swap(key, params, "");
        revert ProbeResult(delta.amount0(), delta.amount1());
    }
    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal override returns (bytes4, int128)
    {
        if (!_busy || _context != keccak256(abi.encode(sender, key, params))) revert InvalidExecution();
        (uint256 actualInput, uint256 actualOutput) = _amounts(params.zeroForOne, delta.amount0(), delta.amount1());
        Currency input = params.zeroForOne ? key.currency0 : key.currency1;
        address currency = Currency.unwrap(input);
        (Terms memory terms, uint256 prior) = _swapTerms(currency);
        if (prior != _prior) revert InvalidExecution();
        uint256 gross; uint256 fee; bool exactInput = params.amountSpecified < 0;
        if (exactInput) {
            if (actualInput != _expectedInput || actualOutput != _expectedOutput) revert InvalidExecution();
            gross = _gross; fee = _fee;
        } else {
            if (actualInput != 0 && actualOutput == 0) revert InvalidExecution();
            (gross, fee) = feeCalculator.grossForNet(terms.curve, prior, actualInput, terms.depth);
        }
        if (gross != 0) {
            BlockFlow storage f = _flows[currency];
            if (prior == 0) { f.blockNumber = block.number; f.fee = 0; f.terms = terms; }
            f.gross = prior + gross; f.fee += fee;
        }
        if (fee != 0) {
            IHookFeeVaultV5(collector).prepareFee(input);
            poolManager.mint(collector, input.toId(), fee);
            IHookFeeVaultV5(collector).record(input, fee);
        }
        emit RealizedFee(currency, terms.version, exactInput, uint256(exactInput ? -params.amountSpecified : params.amountSpecified), gross, actualInput, fee, actualOutput);
        _busy = false; _context = 0; _prior = 0; _expectedInput = 0; _expectedOutput = 0; _fee = 0; _gross = 0;
        return (IHooks.afterSwap.selector, exactInput ? int128(0) : int128(uint128(fee)));
    }

    function _key() private view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(token < base ? token : base), Currency.wrap(token < base ? base : token),
            CANONICAL_POOL_FEE, CANONICAL_TICK_SPACING, IHooks(address(this)));
    }
    function _validatePool(PoolKey calldata key) private view {
        if (!poolRegistered || address(key.hooks) != address(this)
            || PoolId.unwrap(key.toId()) != PoolId.unwrap(registeredPoolId)) revert UnauthorizedPool();
    }
    function _requireCurrency(address currency) private view { if (currency != token && currency != base) revert InvalidBinding(); }
    function _validateTerms(Fees.Curve memory curve, uint256 depth) private view {
        feeCalculator.validate(curve, depth);
    }
    function _effective(address currency) private view returns (Terms memory) {
        PendingTerms storage p = _pending[currency];
        return p.exists && block.timestamp >= p.effectiveAt ? p.terms : _configured[currency];
    }
    function _swapTerms(address currency) private view returns (Terms memory terms, uint256 prior) {
        BlockFlow storage f = _flows[currency];
        if (f.gross != 0 && f.blockNumber == block.number) return (f.terms, f.gross);
        return (_effective(currency), 0);
    }
    function _applyMatured(address currency) private {
        PendingTerms storage p = _pending[currency];
        if (p.exists && block.timestamp >= p.effectiveAt) {
            uint64 effectiveAt = p.effectiveAt; uint64 version = p.terms.version;
            _configured[currency] = p.terms; delete _pending[currency]; emit TermsApplied(currency, version, effectiveAt);
        }
    }
    function _amounts(bool zeroForOne, int128 amount0, int128 amount1) private pure returns (uint256 input, uint256 output) {
        int128 a = zeroForOne ? amount0 : amount1; int128 b = zeroForOne ? amount1 : amount0;
        if (a > 0 || b < 0) revert InvalidExecution();
        return (uint256(-int256(a)), uint256(int256(b)));
    }
}
