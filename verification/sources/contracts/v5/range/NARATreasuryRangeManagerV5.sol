// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IAllowanceTransfer} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-periphery/lib/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {ReserveState} from "../interfaces/NARAAccountingTypesV5.sol";

interface INARATreasuryPositionManagerV5 {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function nextTokenId() external view returns (uint256);
    function poolManager() external view returns (IPoolManager);
    function permit2() external view returns (address);
    function ownerOf(uint256 tokenId) external view returns (address);
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity);
}

interface INARALiquidityHookBindingV5 {
    function token() external view returns (address);
    function base() external view returns (address);
    function collector() external view returns (address);
    function capitalOracle() external view returns (address);
    function poolManager() external view returns (IPoolManager);
    function CANONICAL_POOL_FEE() external view returns (uint24);
    function CANONICAL_TICK_SPACING() external view returns (int24);
    function poolRegistered() external view returns (bool);
    function poolKey() external view returns (PoolKey memory);
}

interface INARAFeeVaultBindingV5 {
    function nara() external view returns (address);
    function usdc() external view returns (address);
    function hook() external view returns (address);
    function bindingsSealed() external view returns (bool);
}

interface INARAPoolOracleBindingV5 {
    function hook() external view returns (address);
    function poolId() external view returns (bytes32);
    function poolManager() external view returns (IPoolManager);
}

interface INARAEmissionReserveBindingV5 {
    function state() external view returns (ReserveState memory);
    function fund(uint256 amount) external returns (uint256 received, uint256 sequence, uint64 eligibleEpoch);
    function syncFunding() external returns (uint256 received, uint256 sequence, uint64 eligibleEpoch);
}

interface ISafeMultisigV5 {
    function getThreshold() external view returns (uint256);
}

/// @title NARA Treasury Range Manager V5
/// @notice V5-bound treasury range periphery with:
///         - Explicit binding to NARALiquidityHookV5 (0x2ACC flags + codehash pin), NARAFeeVaultV5, NARAPoolOracleV5, and NARAEmissionReserveV5
///         - Immediate (0-second delay) USDC proceeds delivery to TREASURY_SAFE on settle, expire, cancel, or sweep
///         - Mandatory 7-day timelock (NARA_WITHDRAWAL_DELAY) on raw NARA withdrawals back to TREASURY_SAFE
///         - Immediate (0-second delay) NARA usage for upside SellNara range orders or replenishment into NARAEmissionReserveV5
contract NARATreasuryRangeManagerV5 is ReentrancyGuardTransient, IERC721Receiver {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 public constant SCHEMA_VERSION = 1;
    uint256 public constant MAX_SETTLE_BATCH = 16;
    uint256 public constant MAX_ACTIVE_PAGE_SIZE = 100;
    uint64 public constant NARA_WITHDRAWAL_DELAY = 7 days;
    uint64 public constant MIN_ORDER_TTL = 1 hours;
    uint64 public constant MAX_ORDER_TTL = 7 days;
    uint160 public constant HOOK_PERMISSION_MASK = 0x3FFF;
    uint160 public constant V5_HOOK_PERMISSION_FLAGS = 0x2ACC;

    address public constant RETIRED_RANGER_BOT = 0xfe3A8678A9c729438BB11718bD1391E7Ab491E8e;
    address public constant RETIRED_V4_RANGE_SAFE = 0x5050BC6dc3E07313D52D05cecD53f727D6CDa245;

    enum OrderSide {
        SellNara,
        BuyNara
    }

    enum OrderStatus {
        None,
        Active,
        Settled,
        Cancelled,
        Expired
    }

    struct RangeOrder {
        uint256 tokenId;
        uint256 inputAmount;
        uint256 minimumOutputAmount;
        bytes32 strategyHash;
        uint160 terminalSqrtPriceX96;
        uint128 liquidity;
        int24 tickLower;
        int24 tickUpper;
        uint64 createdBlock;
        uint64 expiresAt;
        uint64 terminalBlock;
        OrderSide side;
        OrderStatus status;
    }

    struct PendingNaraWithdrawal {
        uint256 amount;
        uint64 readyAt;
    }

    struct ConstructorParams {
        address treasurySafe;
        address nara;
        address usdc;
        address feeVault;
        address poolOracle;
        address emissionReserve;
        address poolManager;
        address positionManager;
        address permit2;
        address hook;
        bytes32 expectedHookCodehash;
        bytes32 expectedPoolId;
        uint8 maxActiveSellOrders;
        uint8 maxActiveBuyOrders;
    }

    error ZeroAddress();
    error NotAContract(address target);
    error RetiredIdentityForbidden(address account);
    error SafeThresholdTooLow(uint256 threshold);
    error UnauthorizedSafe(address caller);
    error InvalidPeripheryBinding();
    error InvalidHookPermissions(uint160 actualFlags);
    error InvalidHookCodehash(bytes32 actual, bytes32 expected);
    error PoolNotInitialized();
    error WrongPoolId(bytes32 derived, bytes32 expected);
    error ManagerUnlocked();
    error ZeroValue();
    error ZeroStrategyHash();
    error DeadlineExpired(uint256 deadline, uint256 timestamp);
    error DeadlineTooLarge(uint256 deadline);
    error InvalidOrderTtl(uint64 ttl);
    error InvalidTickRange();
    error MaxActiveOrdersReached(OrderSide side, uint256 current, uint256 maxAllowed);
    error ZeroLiquidity();
    error MinimumOutputTooHigh(uint256 minimum, uint256 expected);
    error InsufficientAvailableNara(uint256 requested, uint256 available);
    error UnexpectedInputAmount(uint256 expected, uint256 received);
    error InvalidPositionState(uint256 tokenId);
    error OrderNotFound(uint256 orderId);
    error OrderNotActive(uint256 orderId, OrderStatus status);
    error OrderNotSettleable(uint256 orderId);
    error OrderNotExpired(uint256 orderId, uint64 expiresAt, uint256 currentTimestamp);
    error OrderCreationIsPaused();
    error InvalidBatchSize(uint256 size);
    error OutputBelowMinimum(address token, uint256 minimum, uint256 actual);
    error UnexpectedPositionNft(address operator, address from, uint256 tokenId);
    error WithdrawalAlreadyQueued(uint256 amount, uint64 readyAt);
    error NoWithdrawalQueued();
    error WithdrawalNotReady(uint64 readyAt, uint256 currentTimestamp);
    error ResidualUsdcBalance(uint256 usdcBalance);
    error ResidualAllowance(address token, uint256 erc20Allowance, uint256 permit2Allowance);

    IERC20 public immutable NARA;
    IERC20 public immutable USDC;
    address public immutable TREASURY_SAFE;
    address public immutable FEE_VAULT;
    address public immutable POOL_ORACLE;
    address public immutable EMISSION_RESERVE;
    IPoolManager public immutable POOL_MANAGER;
    INARATreasuryPositionManagerV5 public immutable POSITION_MANAGER;
    IAllowanceTransfer public immutable PERMIT2;
    IHooks public immutable HOOK;
    bytes32 public immutable EXPECTED_HOOK_CODEHASH;
    uint24 public immutable POOL_FEE;
    int24 public immutable TICK_SPACING;
    PoolId public immutable POOL_ID;
    bool public immutable NARA_IS_CURRENCY0;

    Currency internal immutable _currency0;
    Currency internal immutable _currency1;

    uint8 public maxActiveSellOrders;
    uint8 public maxActiveBuyOrders;
    uint8 public activeSellOrderCount;
    uint8 public activeBuyOrderCount;
    bool public orderCreationPaused;
    uint256 public orderCount;

    PendingNaraWithdrawal public pendingNaraWithdrawal;

    mapping(uint256 orderId => RangeOrder order) private _orders;
    mapping(uint256 tokenId => uint256 orderId) public tokenIdToOrderId;
    uint256[] private _activeOrderIds;
    mapping(uint256 orderId => uint256 indexPlusOne) private _activeIndexPlusOne;

    uint256 private _expectedMintTokenId;

    event OrderCreated(
        uint256 indexed orderId,
        uint256 indexed tokenId,
        bytes32 indexed strategyHash,
        OrderSide side,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 maximumInputAmount,
        uint256 inputAmount,
        uint256 inputRefund,
        uint256 minimumOutputAmount,
        uint160 creationSqrtPriceX96,
        int24 creationTick,
        uint64 expiresAt
    );
    event OrderSettled(
        uint256 indexed orderId,
        uint256 indexed tokenId,
        bytes32 indexed strategyHash,
        uint256 naraRetained,
        uint256 usdcSentToSafe,
        uint160 settlementSqrtPriceX96,
        int24 settlementTick,
        uint64 settlementBlock
    );
    event OrderExpired(
        uint256 indexed orderId,
        uint256 indexed tokenId,
        bytes32 indexed strategyHash,
        uint256 naraRetained,
        uint256 usdcSentToSafe,
        uint64 expiredBlock
    );
    event OrderCancelled(
        uint256 indexed orderId,
        uint256 indexed tokenId,
        bytes32 indexed strategyHash,
        uint256 naraRetained,
        uint256 usdcSentToSafe,
        uint64 cancellationBlock
    );
    event NaraDeposited(address indexed from, uint256 amount);
    event NaraWithdrawalQueued(uint256 amount, uint64 readyAt);
    event NaraWithdrawalExecuted(address indexed to, uint256 amount);
    event NaraWithdrawalCancelled(uint256 amount);
    event NaraTransferredToReserve(uint256 amount, bool synced, uint256 sequence, uint64 eligibleEpoch);
    event UsdcSweptToSafe(address indexed to, uint256 amount);
    event MaxActiveOrdersUpdated(uint8 maxSellOrders, uint8 maxBuyOrders);
    event OrderCreationPausedChanged(bool paused);

    constructor(ConstructorParams memory p) {
        if (
            p.treasurySafe == address(0) || p.nara == address(0) || p.usdc == address(0)
                || p.feeVault == address(0) || p.poolOracle == address(0) || p.emissionReserve == address(0)
                || p.poolManager == address(0) || p.positionManager == address(0)
                || p.permit2 == address(0) || p.hook == address(0)
        ) revert ZeroAddress();
        if (p.treasurySafe == RETIRED_RANGER_BOT || p.treasurySafe == RETIRED_V4_RANGE_SAFE) {
            revert RetiredIdentityForbidden(p.treasurySafe);
        }
        _requireContract(p.treasurySafe);
        _requireContract(p.nara);
        _requireContract(p.usdc);
        _requireContract(p.feeVault);
        _requireContract(p.poolOracle);
        _requireContract(p.emissionReserve);
        _requireContract(p.poolManager);
        _requireContract(p.positionManager);
        _requireContract(p.permit2);
        _requireContract(p.hook);

        uint256 threshold = ISafeMultisigV5(p.treasurySafe).getThreshold();
        if (threshold < 2) revert SafeThresholdTooLow(threshold);
        if (p.nara == p.usdc) revert InvalidPeripheryBinding();
        if (p.maxActiveSellOrders == 0 || p.maxActiveBuyOrders == 0) revert ZeroValue();

        TREASURY_SAFE = p.treasurySafe;
        NARA = IERC20(p.nara);
        USDC = IERC20(p.usdc);
        FEE_VAULT = p.feeVault;
        POOL_ORACLE = p.poolOracle;
        EMISSION_RESERVE = p.emissionReserve;
        POOL_MANAGER = IPoolManager(p.poolManager);
        POSITION_MANAGER = INARATreasuryPositionManagerV5(p.positionManager);
        PERMIT2 = IAllowanceTransfer(p.permit2);
        HOOK = IHooks(p.hook);
        EXPECTED_HOOK_CODEHASH = p.expectedHookCodehash;

        bool naraFirst = uint160(p.nara) < uint160(p.usdc);
        NARA_IS_CURRENCY0 = naraFirst;
        _currency0 = Currency.wrap(naraFirst ? p.nara : p.usdc);
        _currency1 = Currency.wrap(naraFirst ? p.usdc : p.nara);

        INARALiquidityHookBindingV5 hookBinding = INARALiquidityHookBindingV5(p.hook);
        POOL_FEE = hookBinding.CANONICAL_POOL_FEE();
        TICK_SPACING = hookBinding.CANONICAL_TICK_SPACING();
        if (POOL_FEE != 3000 || TICK_SPACING != 60) revert InvalidPeripheryBinding();

        PoolKey memory key = _poolKey();
        PoolId derivedPoolId = key.toId();
        if (PoolId.unwrap(derivedPoolId) != p.expectedPoolId) {
            revert WrongPoolId(PoolId.unwrap(derivedPoolId), p.expectedPoolId);
        }
        POOL_ID = derivedPoolId;

        maxActiveSellOrders = p.maxActiveSellOrders;
        maxActiveBuyOrders = p.maxActiveBuyOrders;

        _assertImmutableBindings();
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(derivedPoolId);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();
    }

    modifier onlyTreasurySafe() {
        _requireTreasurySafe();
        _;
    }

    modifier poolLocked() {
        _requirePoolLocked();
        _;
    }

    function depositNara(uint256 amount) external onlyTreasurySafe nonReentrant poolLocked {
        if (amount == 0) revert ZeroValue();
        uint256 beforeBal = NARA.balanceOf(address(this));
        NARA.safeTransferFrom(TREASURY_SAFE, address(this), amount);
        uint256 received = NARA.balanceOf(address(this)) - beforeBal;
        if (received != amount) revert UnexpectedInputAmount(amount, received);
        emit NaraDeposited(TREASURY_SAFE, amount);
    }

    function availableNaraBalance() public view returns (uint256) {
        uint256 bal = NARA.balanceOf(address(this));
        uint256 reserved = pendingNaraWithdrawal.amount;
        return bal > reserved ? bal - reserved : 0;
    }

    function queueNaraWithdrawal(uint256 amount)
        external
        onlyTreasurySafe
        nonReentrant
        poolLocked
        returns (uint64 readyAt)
    {
        if (amount == 0) revert ZeroValue();
        if (pendingNaraWithdrawal.amount != 0) {
            revert WithdrawalAlreadyQueued(pendingNaraWithdrawal.amount, pendingNaraWithdrawal.readyAt);
        }
        uint256 available = NARA.balanceOf(address(this));
        if (amount > available) revert InsufficientAvailableNara(amount, available);
        readyAt = uint64(block.timestamp) + NARA_WITHDRAWAL_DELAY;
        pendingNaraWithdrawal = PendingNaraWithdrawal({amount: amount, readyAt: readyAt});
        emit NaraWithdrawalQueued(amount, readyAt);
    }

    function cancelNaraWithdrawal() external onlyTreasurySafe nonReentrant poolLocked {
        uint256 amount = pendingNaraWithdrawal.amount;
        if (amount == 0) revert NoWithdrawalQueued();
        delete pendingNaraWithdrawal;
        emit NaraWithdrawalCancelled(amount);
    }

    function executeNaraWithdrawal() external nonReentrant poolLocked returns (uint256 amount) {
        PendingNaraWithdrawal memory pending = pendingNaraWithdrawal;
        if (pending.amount == 0) revert NoWithdrawalQueued();
        if (block.timestamp < pending.readyAt) {
            revert WithdrawalNotReady(pending.readyAt, block.timestamp);
        }
        delete pendingNaraWithdrawal;
        amount = pending.amount;
        NARA.safeTransfer(TREASURY_SAFE, amount);
        emit NaraWithdrawalExecuted(TREASURY_SAFE, amount);
    }

    function transferNaraToReserve(uint256 amount, bool callFund)
        external
        onlyTreasurySafe
        nonReentrant
        poolLocked
        returns (uint256 sequence, uint64 eligibleEpoch)
    {
        if (amount == 0) revert ZeroValue();
        uint256 available = availableNaraBalance();
        if (amount > available) revert InsufficientAvailableNara(amount, available);
        if (callFund) {
            NARA.forceApprove(EMISSION_RESERVE, amount);
            uint256 received;
            (received, sequence, eligibleEpoch) = INARAEmissionReserveBindingV5(EMISSION_RESERVE).fund(amount);
            NARA.forceApprove(EMISSION_RESERVE, 0);
            if (received != amount) revert UnexpectedInputAmount(amount, received);
        } else {
            NARA.safeTransfer(EMISSION_RESERVE, amount);
        }
        emit NaraTransferredToReserve(amount, callFund, sequence, eligibleEpoch);
    }

    function sweepUsdcToSafe() external nonReentrant poolLocked returns (uint256 usdcAmount) {
        usdcAmount = USDC.balanceOf(address(this));
        if (usdcAmount != 0) {
            USDC.safeTransfer(TREASURY_SAFE, usdcAmount);
            emit UsdcSweptToSafe(TREASURY_SAFE, usdcAmount);
        }
    }

    function createSellNaraOrder(
        int24 tickLower,
        int24 tickUpper,
        uint128 maximumNaraInput,
        uint128 minimumUsdcOutput,
        bytes32 strategyHash,
        uint64 orderTtlSeconds,
        uint64 deadline,
        bool useHeldNara
    ) external onlyTreasurySafe nonReentrant poolLocked returns (uint256 orderId, uint256 tokenId) {
        return _createOrder(
            OrderSide.SellNara,
            tickLower,
            tickUpper,
            maximumNaraInput,
            minimumUsdcOutput,
            strategyHash,
            orderTtlSeconds,
            deadline,
            useHeldNara
        );
    }

    function createBuyNaraOrder(
        int24 tickLower,
        int24 tickUpper,
        uint128 maximumUsdcInput,
        uint128 minimumNaraOutput,
        bytes32 strategyHash,
        uint64 orderTtlSeconds,
        uint64 deadline
    ) external onlyTreasurySafe nonReentrant poolLocked returns (uint256 orderId, uint256 tokenId) {
        return _createOrder(
            OrderSide.BuyNara,
            tickLower,
            tickUpper,
            maximumUsdcInput,
            minimumNaraOutput,
            strategyHash,
            orderTtlSeconds,
            deadline,
            false
        );
    }

    function settle(uint256 orderId)
        external
        nonReentrant
        poolLocked
        returns (uint256 naraRetained, uint256 usdcSentToSafe)
    {
        return _settle(orderId);
    }

    function settleMany(uint256[] calldata orderIds)
        external
        nonReentrant
        poolLocked
        returns (uint256 totalNaraRetained, uint256 totalUsdcSentToSafe)
    {
        uint256 length = orderIds.length;
        if (length == 0 || length > MAX_SETTLE_BATCH) revert InvalidBatchSize(length);
        for (uint256 i; i < length; ++i) {
            (uint256 naraOut, uint256 usdcOut) = _settle(orderIds[i]);
            totalNaraRetained += naraOut;
            totalUsdcSentToSafe += usdcOut;
        }
    }

    function expireOrder(uint256 orderId)
        external
        nonReentrant
        poolLocked
        returns (uint256 naraRetained, uint256 usdcSentToSafe)
    {
        RangeOrder storage order = _activeOrder(orderId);
        if (block.timestamp < order.expiresAt) {
            revert OrderNotExpired(orderId, order.expiresAt, block.timestamp);
        }
        _assertManagedPosition(orderId, order);

        uint256 tokenId = order.tokenId;
        order.status = OrderStatus.Expired;
        order.terminalBlock = uint64(block.number);
        _decrementSideCount(order.side);
        _removeActiveOrder(orderId);

        (naraRetained, usdcSentToSafe) = _burnAndRouteProceeds(tokenId, 0, 0, uint64(block.timestamp));
        _assertBurned(tokenId);

        emit OrderExpired(orderId, tokenId, order.strategyHash, naraRetained, usdcSentToSafe, order.terminalBlock);
    }

    function cancel(
        uint256 orderId,
        uint128 minNaraOut,
        uint128 minUsdcOut,
        uint64 deadline
    ) external onlyTreasurySafe nonReentrant poolLocked returns (uint256 naraRetained, uint256 usdcSentToSafe) {
        _checkDeadline(deadline);
        RangeOrder storage order = _activeOrder(orderId);
        _assertManagedPosition(orderId, order);

        uint256 tokenId = order.tokenId;
        order.status = OrderStatus.Cancelled;
        order.terminalBlock = uint64(block.number);
        _decrementSideCount(order.side);
        _removeActiveOrder(orderId);

        (naraRetained, usdcSentToSafe) = _burnAndRouteProceeds(tokenId, minNaraOut, minUsdcOut, deadline);
        if (naraRetained < minNaraOut) revert OutputBelowMinimum(address(NARA), minNaraOut, naraRetained);
        if (usdcSentToSafe < minUsdcOut) revert OutputBelowMinimum(address(USDC), minUsdcOut, usdcSentToSafe);
        _assertBurned(tokenId);

        emit OrderCancelled(orderId, tokenId, order.strategyHash, naraRetained, usdcSentToSafe, order.terminalBlock);
    }

    function setMaxActiveOrders(uint8 maxSellOrders, uint8 maxBuyOrders) external onlyTreasurySafe {
        if (maxSellOrders == 0 || maxBuyOrders == 0) revert ZeroValue();
        maxActiveSellOrders = maxSellOrders;
        maxActiveBuyOrders = maxBuyOrders;
        emit MaxActiveOrdersUpdated(maxSellOrders, maxBuyOrders);
    }

    function pauseOrderCreation() external onlyTreasurySafe {
        orderCreationPaused = true;
        emit OrderCreationPausedChanged(true);
    }

    function unpauseOrderCreation() external onlyTreasurySafe {
        orderCreationPaused = false;
        emit OrderCreationPausedChanged(false);
    }

    function getOrder(uint256 orderId) external view returns (RangeOrder memory order) {
        order = _orders[orderId];
        if (order.status == OrderStatus.None) revert OrderNotFound(orderId);
    }

    function activeOrderCount() external view returns (uint256) {
        return _activeOrderIds.length;
    }

    function getActiveOrderIds(uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory orderIds, uint256 nextOffset)
    {
        if (limit > MAX_ACTIVE_PAGE_SIZE) revert InvalidBatchSize(limit);
        uint256 length = _activeOrderIds.length;
        if (offset >= length || limit == 0) return (new uint256[](0), length);
        uint256 end = offset + limit;
        if (end > length) end = length;
        orderIds = new uint256[](end - offset);
        for (uint256 i; i < orderIds.length; ++i) orderIds[i] = _activeOrderIds[offset + i];
        nextOffset = end;
    }

    function isSettleable(uint256 orderId) public view returns (bool) {
        RangeOrder storage order = _orders[orderId];
        if (order.status != OrderStatus.Active || tokenIdToOrderId[order.tokenId] != orderId) return false;
        if (POSITION_MANAGER.ownerOf(order.tokenId) != address(this)) return false;
        uint128 liquidity = POSITION_MANAGER.getPositionLiquidity(order.tokenId);
        if (liquidity == 0 || liquidity != order.liquidity) return false;
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(POOL_ID);
        return _terminalAt(order.side, order.terminalSqrtPriceX96, sqrtPriceX96);
    }

    function canonicalPoolKey() external view returns (PoolKey memory) {
        return _poolKey();
    }

    function assertOperationalClean() external view returns (bool) {
        bytes32 actualHookHash = address(HOOK).codehash;
        if (actualHookHash != EXPECTED_HOOK_CODEHASH) {
            revert InvalidHookCodehash(actualHookHash, EXPECTED_HOOK_CODEHASH);
        }
        uint256 usdcBalance = USDC.balanceOf(address(this));
        if (usdcBalance != 0) revert ResidualUsdcBalance(usdcBalance);
        _assertAllowanceClean(NARA);
        _assertAllowanceClean(USDC);
        return true;
    }

    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata)
        external
        view
        override
        returns (bytes4)
    {
        if (
            msg.sender != address(POSITION_MANAGER) || from != address(0)
                || tokenId == 0 || tokenId != _expectedMintTokenId
        ) revert UnexpectedPositionNft(operator, from, tokenId);
        return IERC721Receiver.onERC721Received.selector;
    }

    function sqrtPriceAtTick(int24 tick) external pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(tick);
    }

    function quoteSingleSidedOrder(
        OrderSide side,
        int24 tickLower,
        int24 tickUpper,
        uint128 maximumInputAmount
    )
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 currentTick,
            uint160 terminalSqrtPriceX96,
            uint128 liquidity,
            uint256 expectedOutput
        )
    {
        _validateTicks(tickLower, tickUpper);
        (sqrtPriceX96, currentTick,,) = POOL_MANAGER.getSlot0(POOL_ID);
        uint160 sqrtLower = this.sqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = this.sqrtPriceAtTick(tickUpper);
        bool inputIsCurrency0 = (side == OrderSide.SellNara) ? NARA_IS_CURRENCY0 : !NARA_IS_CURRENCY0;
        _validateCreationSide(inputIsCurrency0, sqrtPriceX96, sqrtLower, sqrtUpper);
        terminalSqrtPriceX96 = inputIsCurrency0 ? sqrtUpper : sqrtLower;
        (liquidity, expectedOutput) =
            _quoteSingleSidedRange(inputIsCurrency0, sqrtLower, sqrtUpper, maximumInputAmount);
    }

    function _createOrder(
        OrderSide side,
        int24 tickLower,
        int24 tickUpper,
        uint128 maximumInputAmount,
        uint128 minimumOutputAmount,
        bytes32 strategyHash,
        uint64 orderTtlSeconds,
        uint64 deadline,
        bool useHeldNara
    ) internal returns (uint256 orderId, uint256 tokenId) {
        if (orderCreationPaused) revert OrderCreationIsPaused();
        if (maximumInputAmount == 0 || minimumOutputAmount == 0) revert ZeroValue();
        if (strategyHash == bytes32(0)) revert ZeroStrategyHash();
        if (orderTtlSeconds < MIN_ORDER_TTL || orderTtlSeconds > MAX_ORDER_TTL) {
            revert InvalidOrderTtl(orderTtlSeconds);
        }
        _checkDeadline(deadline);
        _incrementSideCount(side);

        (
            uint160 sqrtPriceX96,
            int24 currentTick,
            uint160 terminalSqrtPriceX96,
            uint128 liquidity,
            uint256 expectedOutput
        ) = this.quoteSingleSidedOrder(side, tickLower, tickUpper, maximumInputAmount);
        if (liquidity == 0) revert ZeroLiquidity();
        if (minimumOutputAmount > expectedOutput) {
            revert MinimumOutputTooHigh(minimumOutputAmount, expectedOutput);
        }
        bool inputIsCurrency0 = (side == OrderSide.SellNara) ? NARA_IS_CURRENCY0 : !NARA_IS_CURRENCY0;

        IERC20 inputToken = side == OrderSide.SellNara ? NARA : USDC;
        uint256 balanceBeforeMint;
        if (side == OrderSide.SellNara && useHeldNara) {
            uint256 available = availableNaraBalance();
            if (maximumInputAmount > available) {
                revert InsufficientAvailableNara(maximumInputAmount, available);
            }
            balanceBeforeMint = NARA.balanceOf(address(this));
        } else {
            uint256 beforePull = inputToken.balanceOf(address(this));
            inputToken.safeTransferFrom(TREASURY_SAFE, address(this), maximumInputAmount);
            balanceBeforeMint = inputToken.balanceOf(address(this));
            if (balanceBeforeMint - beforePull != maximumInputAmount) {
                revert UnexpectedInputAmount(maximumInputAmount, balanceBeforeMint - beforePull);
            }
        }

        _approvePositionManager(inputToken, maximumInputAmount, deadline);
        tokenId = POSITION_MANAGER.nextTokenId();
        _expectedMintTokenId = tokenId;
        _mintPosition(inputIsCurrency0, tickLower, tickUpper, liquidity, maximumInputAmount, deadline);
        _expectedMintTokenId = 0;
        _clearPositionManagerApproval(inputToken);

        uint256 balanceAfterMint = inputToken.balanceOf(address(this));
        if (balanceAfterMint >= balanceBeforeMint) revert InvalidPositionState(tokenId);
        uint256 inputAmount = balanceBeforeMint - balanceAfterMint;
        if (inputAmount > maximumInputAmount) revert InvalidPositionState(tokenId);
        uint256 inputRefund = maximumInputAmount - inputAmount;
        if (side == OrderSide.BuyNara && inputRefund != 0) {
            USDC.safeTransfer(TREASURY_SAFE, inputRefund);
        } else if (side == OrderSide.SellNara && !useHeldNara && inputRefund != 0) {
            NARA.safeTransfer(TREASURY_SAFE, inputRefund);
        }

        if (
            POSITION_MANAGER.ownerOf(tokenId) != address(this)
                || POSITION_MANAGER.getPositionLiquidity(tokenId) != liquidity
        ) revert InvalidPositionState(tokenId);

        uint64 expiresAt = uint64(block.timestamp) + orderTtlSeconds;
        orderId = ++orderCount;
        if (tokenIdToOrderId[tokenId] != 0) revert InvalidPositionState(tokenId);
        RangeOrder storage order = _orders[orderId];
        order.tokenId = tokenId;
        order.inputAmount = inputAmount;
        order.minimumOutputAmount = minimumOutputAmount;
        order.strategyHash = strategyHash;
        order.terminalSqrtPriceX96 = terminalSqrtPriceX96;
        order.liquidity = liquidity;
        order.tickLower = tickLower;
        order.tickUpper = tickUpper;
        order.createdBlock = uint64(block.number);
        order.expiresAt = expiresAt;
        order.side = side;
        order.status = OrderStatus.Active;
        tokenIdToOrderId[tokenId] = orderId;
        _addActiveOrder(orderId);

        emit OrderCreated(
            orderId,
            tokenId,
            strategyHash,
            side,
            tickLower,
            tickUpper,
            liquidity,
            maximumInputAmount,
            inputAmount,
            inputRefund,
            minimumOutputAmount,
            sqrtPriceX96,
            currentTick,
            expiresAt
        );
    }

    function _settle(uint256 orderId) internal returns (uint256 naraRetained, uint256 usdcSentToSafe) {
        RangeOrder storage order = _activeOrder(orderId);
        (uint160 sqrtPriceX96, int24 currentTick,,) = POOL_MANAGER.getSlot0(POOL_ID);
        if (!_terminalAt(order.side, order.terminalSqrtPriceX96, sqrtPriceX96)) {
            revert OrderNotSettleable(orderId);
        }
        _assertManagedPosition(orderId, order);

        uint256 tokenId = order.tokenId;
        uint128 minNaraOut = order.side == OrderSide.BuyNara ? uint128(order.minimumOutputAmount) : 0;
        uint128 minUsdcOut = order.side == OrderSide.SellNara ? uint128(order.minimumOutputAmount) : 0;
        order.status = OrderStatus.Settled;
        order.terminalBlock = uint64(block.number);
        _decrementSideCount(order.side);
        _removeActiveOrder(orderId);

        (naraRetained, usdcSentToSafe) = _burnAndRouteProceeds(tokenId, minNaraOut, minUsdcOut, uint64(block.timestamp));
        if (naraRetained < minNaraOut) revert OutputBelowMinimum(address(NARA), minNaraOut, naraRetained);
        if (usdcSentToSafe < minUsdcOut) revert OutputBelowMinimum(address(USDC), minUsdcOut, usdcSentToSafe);
        _assertBurned(tokenId);

        emit OrderSettled(
            orderId,
            tokenId,
            order.strategyHash,
            naraRetained,
            usdcSentToSafe,
            sqrtPriceX96,
            currentTick,
            order.terminalBlock
        );
    }

    function _mintPosition(
        bool inputIsCurrency0,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint128 maximumInputAmount,
        uint64 deadline
    ) internal {
        bytes[] memory params = new bytes[](2);
        uint128 amount0Max = inputIsCurrency0 ? maximumInputAmount : 0;
        uint128 amount1Max = inputIsCurrency0 ? 0 : maximumInputAmount;
        params[0] = abi.encode(
            _poolKey(),
            tickLower,
            tickUpper,
            uint256(liquidity),
            amount0Max,
            amount1Max,
            address(this),
            bytes("")
        );
        params[1] = abi.encode(_currency0, _currency1);
        POSITION_MANAGER.modifyLiquidities(abi.encode(hex"020d", params), deadline);
    }

    function _burnAndRouteProceeds(
        uint256 tokenId,
        uint128 minNaraOut,
        uint128 minUsdcOut,
        uint64 deadline
    ) internal returns (uint256 naraRetained, uint256 usdcSentToSafe) {
        uint256 naraBefore = NARA.balanceOf(address(this));
        uint256 usdcBefore = USDC.balanceOf(address(this));

        bytes[] memory params = new bytes[](2);
        uint128 amount0Min = NARA_IS_CURRENCY0 ? minNaraOut : minUsdcOut;
        uint128 amount1Min = NARA_IS_CURRENCY0 ? minUsdcOut : minNaraOut;
        params[0] = abi.encode(tokenId, amount0Min, amount1Min, bytes(""));
        params[1] = abi.encode(_currency0, _currency1, address(this));
        POSITION_MANAGER.modifyLiquidities(abi.encode(hex"0311", params), deadline);

        naraRetained = NARA.balanceOf(address(this)) - naraBefore;
        usdcSentToSafe = USDC.balanceOf(address(this)) - usdcBefore;
        if (usdcSentToSafe != 0) {
            USDC.safeTransfer(TREASURY_SAFE, usdcSentToSafe);
        }
    }

    function _approvePositionManager(IERC20 token, uint128 amount, uint64 deadline) internal {
        if (deadline > type(uint48).max) revert DeadlineTooLarge(deadline);
        token.forceApprove(address(PERMIT2), amount);
        PERMIT2.approve(address(token), address(POSITION_MANAGER), uint160(amount), uint48(deadline));
    }

    function _clearPositionManagerApproval(IERC20 token) internal {
        PERMIT2.approve(address(token), address(POSITION_MANAGER), 0, 0);
        token.forceApprove(address(PERMIT2), 0);
    }

    function _activeOrder(uint256 orderId) internal view returns (RangeOrder storage order) {
        order = _orders[orderId];
        if (order.status == OrderStatus.None) revert OrderNotFound(orderId);
        if (order.status != OrderStatus.Active) revert OrderNotActive(orderId, order.status);
    }

    function _incrementSideCount(OrderSide side) internal {
        if (side == OrderSide.SellNara) {
            if (activeSellOrderCount >= maxActiveSellOrders) {
                revert MaxActiveOrdersReached(side, activeSellOrderCount, maxActiveSellOrders);
            }
            unchecked { ++activeSellOrderCount; }
        } else {
            if (activeBuyOrderCount >= maxActiveBuyOrders) {
                revert MaxActiveOrdersReached(side, activeBuyOrderCount, maxActiveBuyOrders);
            }
            unchecked { ++activeBuyOrderCount; }
        }
    }

    function _decrementSideCount(OrderSide side) internal {
        if (side == OrderSide.SellNara) {
            if (activeSellOrderCount > 0) {
                unchecked { --activeSellOrderCount; }
            }
        } else {
            if (activeBuyOrderCount > 0) {
                unchecked { --activeBuyOrderCount; }
            }
        }
    }

    function _assertManagedPosition(uint256 orderId, RangeOrder storage order) internal view {
        uint256 tokenId = order.tokenId;
        if (
            tokenIdToOrderId[tokenId] != orderId
                || POSITION_MANAGER.ownerOf(tokenId) != address(this)
                || POSITION_MANAGER.getPositionLiquidity(tokenId) != order.liquidity
        ) revert InvalidPositionState(tokenId);
    }

    function _assertBurned(uint256 tokenId) internal view {
        if (POSITION_MANAGER.getPositionLiquidity(tokenId) != 0) revert InvalidPositionState(tokenId);
    }

    function _validateTicks(int24 tickLower, int24 tickUpper) internal view {
        if (
            tickLower < TickMath.MIN_TICK || tickUpper > TickMath.MAX_TICK
                || tickLower >= tickUpper
                || tickLower % TICK_SPACING != 0 || tickUpper % TICK_SPACING != 0
        ) revert InvalidTickRange();
    }

    function _validateCreationSide(
        bool inputIsCurrency0,
        uint160 sqrtPriceX96,
        uint160 sqrtLower,
        uint160 sqrtUpper
    ) internal pure {
        if (inputIsCurrency0 ? sqrtPriceX96 > sqrtLower : sqrtPriceX96 < sqrtUpper) {
            revert InvalidTickRange();
        }
    }

    function _quoteSingleSidedRange(
        bool inputIsCurrency0,
        uint160 sqrtLower,
        uint160 sqrtUpper,
        uint128 maximumInputAmount
    ) private pure returns (uint128 liquidity, uint256 expectedOutput) {
        uint256 span = uint256(sqrtUpper - sqrtLower);
        uint256 q96 = 1 << 96;
        if (inputIsCurrency0) {
            uint256 intermediate = Math.mulDiv(sqrtLower, sqrtUpper, q96);
            liquidity = uint128(Math.mulDiv(maximumInputAmount, intermediate, span));
            expectedOutput = Math.mulDiv(liquidity, span, q96);
        } else {
            liquidity = uint128(Math.mulDiv(maximumInputAmount, q96, span));
            expectedOutput = Math.mulDiv(uint256(liquidity) << 96, span, sqrtUpper) / sqrtLower;
        }
    }

    function _terminalAt(OrderSide side, uint160 terminalSqrtPriceX96, uint160 sqrtPriceX96)
        internal
        view
        returns (bool)
    {
        bool inputIsCurrency0 = (side == OrderSide.SellNara) ? NARA_IS_CURRENCY0 : !NARA_IS_CURRENCY0;
        return inputIsCurrency0
            ? sqrtPriceX96 >= terminalSqrtPriceX96
            : sqrtPriceX96 <= terminalSqrtPriceX96;
    }

    function _poolKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: _currency0,
            currency1: _currency1,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: HOOK
        });
    }

    function _assertImmutableBindings() internal view {
        uint160 hookFlags = uint160(address(HOOK)) & HOOK_PERMISSION_MASK;
        if (hookFlags != V5_HOOK_PERMISSION_FLAGS) revert InvalidHookPermissions(hookFlags);
        bytes32 actualHookHash = address(HOOK).codehash;
        if (actualHookHash != EXPECTED_HOOK_CODEHASH) {
            revert InvalidHookCodehash(actualHookHash, EXPECTED_HOOK_CODEHASH);
        }

        INARALiquidityHookBindingV5 hookBinding = INARALiquidityHookBindingV5(address(HOOK));
        INARAFeeVaultBindingV5 vaultBinding = INARAFeeVaultBindingV5(FEE_VAULT);
        INARAPoolOracleBindingV5 oracleBinding = INARAPoolOracleBindingV5(POOL_ORACLE);
        ReserveState memory reserveState = INARAEmissionReserveBindingV5(EMISSION_RESERVE).state();

        PoolKey memory hookKey = hookBinding.poolKey();
        if (
            address(POSITION_MANAGER.poolManager()) != address(POOL_MANAGER)
                || POSITION_MANAGER.permit2() != address(PERMIT2)
                || hookBinding.token() != address(NARA)
                || hookBinding.base() != address(USDC)
                || hookBinding.collector() != FEE_VAULT
                || hookBinding.capitalOracle() != POOL_ORACLE
                || address(hookBinding.poolManager()) != address(POOL_MANAGER)
                || hookBinding.CANONICAL_POOL_FEE() != POOL_FEE
                || hookBinding.CANONICAL_TICK_SPACING() != TICK_SPACING
                || !hookBinding.poolRegistered()
                || PoolId.unwrap(hookKey.toId()) != PoolId.unwrap(POOL_ID)
                || vaultBinding.nara() != address(NARA)
                || vaultBinding.usdc() != address(USDC)
                || vaultBinding.hook() != address(HOOK)
                || !vaultBinding.bindingsSealed()
                || oracleBinding.hook() != address(HOOK)
                || oracleBinding.poolId() != PoolId.unwrap(POOL_ID)
                || address(oracleBinding.poolManager()) != address(POOL_MANAGER)
                || reserveState.nara != address(NARA)
        ) revert InvalidPeripheryBinding();
    }

    function _assertAllowanceClean(IERC20 token) internal view {
        uint256 erc20Allowance = token.allowance(address(this), address(PERMIT2));
        (uint160 permit2Allowance,,) =
            PERMIT2.allowance(address(this), address(token), address(POSITION_MANAGER));
        if (erc20Allowance != 0 || permit2Allowance != 0) {
            revert ResidualAllowance(address(token), erc20Allowance, permit2Allowance);
        }
    }

    function _addActiveOrder(uint256 orderId) internal {
        _activeOrderIds.push(orderId);
        _activeIndexPlusOne[orderId] = _activeOrderIds.length;
    }

    function _removeActiveOrder(uint256 orderId) internal {
        uint256 indexPlusOne = _activeIndexPlusOne[orderId];
        if (indexPlusOne == 0) revert OrderNotFound(orderId);
        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = _activeOrderIds.length - 1;
        if (index != lastIndex) {
            uint256 lastOrderId = _activeOrderIds[lastIndex];
            _activeOrderIds[index] = lastOrderId;
            _activeIndexPlusOne[lastOrderId] = indexPlusOne;
        }
        _activeOrderIds.pop();
        delete _activeIndexPlusOne[orderId];
    }

    function _checkDeadline(uint64 deadline) internal view {
        if (deadline < block.timestamp) revert DeadlineExpired(deadline, block.timestamp);
    }

    function _requireTreasurySafe() internal view {
        if (msg.sender != TREASURY_SAFE) revert UnauthorizedSafe(msg.sender);
    }

    function _requirePoolLocked() internal view {
        if (POOL_MANAGER.isUnlocked()) revert ManagerUnlocked();
    }

    function _requireContract(address target) internal view {
        if (target.code.length == 0) revert NotAContract(target);
    }
}
