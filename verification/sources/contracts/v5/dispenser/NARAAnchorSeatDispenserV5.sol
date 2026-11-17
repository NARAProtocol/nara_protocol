// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {NARAPositionNFTV5} from "../modular/NARAPositionNFTV5.sol";
import {NARAPrincipalLedgerV5} from "../modular/NARAPrincipalLedgerV5.sol";
import {NARARewardLedgerV5} from "../modular/NARARewardLedgerV5.sol";
import {NARARewardIngressV5} from "../modular/NARARewardIngressV5.sol";
import {NARAEpochEngineV5} from "../modular/NARAEpochEngineV5.sol";
import {INARAEpochCoordinatorV5, INARAForgeIdentityV5} from "../modular/NARAModuleInterfacesV5.sol";
import {INARAEmissionReserveV5} from "../interfaces/INARAEmissionReserveV5.sol";
import {
    AccountingPolicy,
    CoreBindings,
    CreateRequest,
    DurationCurve,
    EpochClock,
    PositionState,
    ReserveState,
    RewardAsset
} from "../interfaces/NARAAccountingTypesV5.sol";

interface IChainlinkAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

interface INARATokenFlashSinkDispenserV5 {
    function FLASH_FEE_SINK() external view returns (address);
}

interface INARAPositionRendererSinksV5 {
    function art() external view returns (address);
    function statsReader() external view returns (address);
    function card() external view returns (address);
}

/// @title NARAAnchorSeatDispenserV5
/// @notice Chainlink `ETH/USD`-indexed ascending-wave vault receipt dispenser for NARA Protocol V5.
/// @dev Security, oracle, and accounting invariants:
///  1. Unsold `NARA` sits idle inside this contract (`0` active `wNARA` weight = `0%` APR dilution to stakers)
///     until the exact transaction in which a buyer pays native `ETH`.
///  2. Every dispensed Vault Receipt enforces `duration >= MIN_STARTER_DURATION` (`17,280` epochs = `180 days`),
///     and any seat above `1.00 NARA` (where progressive volume brackets `< 100%` apply) strictly enforces
///     `duration == maxDuration` (`35,040` epochs = `365 days @ 4.00x`), blocking short-horizon spot arbitrage.
///  3. Pricing integrates continuously across ascending `USD/NARA` waves with per-slice `minFloorUsd8` clamping
///     (`integrateAdjustedSeatUsd26`) and per-seat summation, guaranteeing strict monotonicity (`dCost/dq > 0`),
///     anti-Sybil super-additivity (`C(a+b) <= C(a)+C(b)`), and exact `0-wei` batch-vs-sequential path independence.
///  4. Chainlink Base `ETH/USD` reads enforce L2 Sequencer Uptime + `1-hour` post-outage grace period,
///     round completeness, staleness bounds (`<= 7,200s`), and native-decimal `[$100, $200,000]` circuit breakers.
///  5. Every purchase splits `requiredEthWei` deterministically:
///     - `5.00%` (`FEE_BPS = 500`, immutable) -> pushed immediately to `NARARewardIngressV5` and unconditionally
///       forwarded via fault-isolated `_tryFlushIngressEth()` so buyers cannot stage/self-capture royalties;
///     - `95.00%` -> delivered to immutable `treasury` (`0xe320...51E3`), falling back to `pendingTreasuryEth`
///       if `treasury` ever exceeds `TREASURY_CALL_GAS` (`DOS-N01` immune);
///     - `msg.value - requiredEthWei` -> refunded last to `msg.sender` under `ReentrancyGuardTransient`.
///  6. Unsold `NARA` can exit ONLY into `NARAPrincipalLedgerV5.create` (paid buyer seat), back to immutable
///     `treasury` (`returnInventoryToTreasury`), or permanently into `NARAEmissionReserveV5.fund` (`retireInventoryToReserve`).
contract NARAAnchorSeatDispenserV5 is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    struct TierSpec {
        uint256 principalWei;
        uint32 durationEpochs;
    }

    struct DispenserQuote {
        uint256 perSeatPrincipalWei;
        uint256 count;
        uint256 totalPrincipalWei;
        uint32 durationEpochs;
        uint256 effectiveUnitsPerSeatWei;
        uint256 rawWaveNumerator26;
        uint256 adjustedUsdNumerator26;
        uint256 totalUsd8;
        uint256 requiredEthWei;
        uint256 feeEthWei;
        uint256 netTreasuryEthWei;
        uint256 ethUsdPrice8;
        uint256 startWaveIndex;
        uint256 endWaveIndex;
    }

    struct DispenserStatus {
        bool salesPaused;
        bool oracleHealthy;
        uint256 availableNaraWei;
        uint256 waveCursorWei;
        uint256 currentWaveIndex;
        uint256 currentWaveBaseUsd8;
        uint256 baseWave0Usd8;
        uint256 waveSizeWei;
        uint256 waveStepBps;
        uint256 minFloorUsd8;
        uint256 totalNaraDispensed;
        uint256 totalSeatsDispensed;
        uint256 totalEthRaised;
        uint256 totalFeeEthToIngress;
        uint256 totalTreasuryEthDelivered;
        uint256 pendingTreasuryEth;
        uint256 totalForcedEthSwept;
        uint256 ethUsdPrice8;
    }

    uint256 public constant SCHEMA_VERSION = 1;
    uint256 public constant SUPPLY = 1_000_000 ether;
    uint256 internal constant USD_SCALE = 1e8;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @notice Immutable 5.00% ETH protocol royalty routed to `NARARewardIngressV5` (matches `NARAPositionSaleV5.FEE_BPS`).
    uint256 public constant FEE_BPS = 500;

    uint8 public constant TIER_COUNT = 5;
    uint16 public constant MAX_BATCH_SEATS = 8;
    uint256 public constant MAX_CUSTOM_SEAT_NARA = 100 ether;
    uint256 public constant MAX_WAVE_INDEX = 32;

    uint32 public constant MIN_STARTER_DURATION = 17_280; // 180 days of 900s epochs
    uint32 public constant MAX_SYNC_EPOCHS = 192; // up to 48h inline catch-up

    // Marginal volume bracket boundaries & rates (strictly positive marginal rates -> strictly monotonic cost):
    uint256 internal constant BRACKET_1_UPPER = 1 ether;
    uint256 internal constant BRACKET_2_UPPER = 3.5 ether;
    uint256 internal constant BRACKET_3_UPPER = 10 ether;
    uint256 internal constant RATE_BRACKET_0_BPS = 10_000; // 100.0% on (0.0 .. 1.0 NARA]
    uint256 internal constant RATE_BRACKET_1_BPS = 9_200; //  92.0% on (1.0 .. 3.5 NARA]
    uint256 internal constant RATE_BRACKET_2_BPS = 8_800; //  88.0% on (3.5 .. 10.0 NARA]
    uint256 internal constant RATE_BRACKET_3_BPS = 8_500; //  85.0% on (> 10.0 NARA)

    // Oracle & wave parameter safety bounds (Base ETH/USD Chainlink heartbeat = 1,200s):
    uint256 public constant SEQUENCER_GRACE_PERIOD = 3_600; // 1 hour post-recovery grace window
    uint64 public constant MIN_ORACLE_STALENESS = 300; // 5 minutes
    uint64 public constant MAX_ORACLE_STALENESS = 7_200; // 2 hours (6x Base ETH/USD 20m heartbeat)
    uint256 public constant MIN_SANITY_ETH_USD8 = 100 * 1e8; // $100 / ETH circuit breaker
    uint256 public constant MAX_SANITY_ETH_USD8 = 200_000 * 1e8; // $200,000 / ETH circuit breaker

    uint256 internal constant MIN_ALLOWED_FLOOR_USD8 = 500 * 1e8; // $500 / NARA minimum floor
    uint256 internal constant MAX_BASE_USD8 = 1_000_000 * 1e8; // $1,000,000 / NARA cap
    uint256 internal constant MIN_WAVE_SIZE_WEI = 10 ether;
    uint256 internal constant MAX_WAVE_SIZE_WEI = 50_000 ether;
    uint256 internal constant MAX_WAVE_STEP_BPS = 5_000; // +50.00% max step per wave

    // Bounded external-call gas constants with EIP-150 63/64 anti-griefing minimums:
    uint256 internal constant TREASURY_CALL_GAS = 60_000;
    uint256 internal constant TREASURY_CALL_MIN_GAS = 120_000;
    uint256 internal constant INGRESS_FLUSH_CALL_GAS = 250_000;
    uint256 internal constant INGRESS_FLUSH_MIN_GAS = 320_000;

    /// @dev EIP-7702 delegation designator prefix (`0xef0100 || address`).
    bytes3 private constant DELEGATION_DESIGNATOR = 0xef0100;

    /// @dev Retired/compromised historical v4 identities forbidden from holding any V5 role.
    address private constant COMPROMISED_DEPLOYER_V4 = 0x5f3A378B685E309AE7404a7483420e49F2FBE6Aa;
    address private constant EXPOSED_RANGER_V4 = 0xfe3A8678A9c729438BB11718bD1391E7Ab491E8e;
    address private constant RETIRED_RANGE_SAFE_V4 = 0x5050BC6dc3E07313D52D05cecD53f727D6CDa245;

    NARAPositionNFTV5 public immutable nft;
    NARAPrincipalLedgerV5 public immutable principal;
    NARARewardLedgerV5 public immutable rewards;
    NARARewardIngressV5 public immutable ingress;
    NARAEpochEngineV5 public immutable engine;
    INARAEmissionReserveV5 public immutable reserve;

    address public immutable nara;
    address public immutable usdc;
    address public immutable treasury;

    // Cached NFT-layer & Forge sinks for complete recipient validation (`L-03`):
    address private immutable _forge;
    address private immutable _nftRenderer;
    address private immutable _nftArt;
    address private immutable _nftStatsReader;
    address private immutable _nftCard;

    IChainlinkAggregatorV3 public immutable ethUsdFeed;
    IChainlinkAggregatorV3 public immutable sequencerUptimeFeed;
    uint8 public immutable oracleDecimals;
    uint256 private immutable _oracleScale;
    uint256 private immutable _minRawAnswer;
    uint256 private immutable _maxRawAnswer;
    uint64 public immutable maxOracleStaleness;
    uint256 public immutable minFloorUsd8;

    bytes32 public immutable policyHash;
    uint256 public immutable minimumPrincipal;
    uint32 public immutable maxDuration;
    uint32 public immutable engineMaxAdvance;

    // Treasury-configurable wave schedule (always bounded >= minFloorUsd8):
    uint256 public baseWave0Usd8;
    uint256 public waveSizeWei;
    uint256 public waveStepBps;
    uint256 public waveCursorWei;
    bool public salesPaused;

    // Monotonic lifetime accounting (`totalEthRaised == totalFeeEthToIngress + totalTreasuryEthDelivered + pendingTreasuryEth`):
    uint256 public totalNaraDispensed;
    uint256 public totalSeatsDispensed;
    uint256 public totalEthRaised;
    uint256 public totalFeeEthToIngress;
    uint256 public totalTreasuryEthDelivered;
    uint256 public pendingTreasuryEth;
    uint256 public totalForcedEthSwept;

    error InvalidBinding();
    error DelegatedDependency(address target);
    error RetiredIdentityForbidden(address account);
    error InvalidWaveConfig();
    error InvalidOracleConfig();
    error SequencerDown();
    error SequencerGracePeriodNotOver(uint256 elapsed, uint256 required);
    error StaleOrInvalidOraclePrice();
    error OraclePriceOutOfBounds(uint256 price8);
    error UnauthorizedTreasury();
    error SalesPausedError();
    error DirectEthForbidden();
    error Expired();
    error FlashActive();
    error InvalidRecipient();
    error InvalidTier(uint8 tierId);
    error InvalidBatchCount(uint16 count);
    error InvalidCustomSeat(uint256 naraAmountWei, uint32 durationEpochs);
    error InsufficientInventory(uint256 availableWei, uint256 requiredWei);
    error SlippageOrPaymentInsufficient(uint256 requiredEthWei, uint256 msgValueWei, uint256 maxEthCostWei);
    error CoreStale(uint64 wallEpoch, uint64 backlog);
    error SyncLimitExceeded(uint32 requested, uint32 maximum);
    error InvalidAcquisition();
    error AccountingInvariantFailed();
    error InsufficientExternalCallGas();
    error IngressTransferFailed();
    error RefundFailed();
    error NothingToSweep();
    error PaymentFailed();
    error InvalidAsset();

    event InventoryDeposited(address indexed sender, uint256 naraAmountWei, uint256 availableAfterWei);
    event InventoryReturnedToTreasury(uint256 naraAmountWei, uint256 availableAfterWei);
    event InventoryRetiredToReserve(uint256 naraAmountWei, uint256 availableAfterWei);
    event WaveConfigUpdated(
        uint256 baseWave0Usd8,
        uint256 waveSizeWei,
        uint256 waveStepBps,
        uint256 waveCursorWei
    );
    event SalesPauseUpdated(bool paused);
    event SeatsDispensed(
        address indexed buyer,
        address indexed recipient,
        uint8 indexed tierId,
        uint16 count,
        uint256 perSeatPrincipalWei,
        uint32 durationEpochs,
        uint256 firstTokenId,
        uint256 lastTokenId,
        uint256 requiredEthWei,
        uint256 feeEthWei,
        uint256 ethUsdPrice8,
        uint256 waveCursorAfterWei
    );
    event TreasuryEthEscrowed(uint256 amountWei, uint256 pendingTotalWei);
    event PendingTreasuryEthCollected(address indexed caller, address indexed recipient, uint256 amountWei);
    event ForcedEthSweptToIngress(address indexed caller, uint256 amountWei);
    event StrayTokenSweptToTreasury(address indexed token, uint256 amount);
    event UnsolicitedNFTSweptToTreasury(address indexed collection, uint256 indexed tokenId);

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert UnauthorizedTreasury();
        _;
    }

    constructor(
        address nft_,
        address ingress_,
        address treasury_,
        address ethUsdFeed_,
        address sequencerUptimeFeed_,
        uint64 maxOracleStaleness_,
        uint256 minFloorUsd8_,
        uint256 baseWave0Usd8_,
        uint256 waveSizeWei_,
        uint256 waveStepBps_
    ) {
        if (
            treasury_ == address(0)
                || treasury_ == address(this)
                || treasury_ == nft_
                || treasury_ == ingress_
                || treasury_ == ethUsdFeed_
                || (sequencerUptimeFeed_ != address(0) && treasury_ == sequencerUptimeFeed_)
        ) revert InvalidBinding();
        if (bytes3(treasury_.code) == DELEGATION_DESIGNATOR) {
            revert DelegatedDependency(treasury_);
        }
        if (
            treasury_ == COMPROMISED_DEPLOYER_V4
                || treasury_ == EXPOSED_RANGER_V4
                || treasury_ == RETIRED_RANGE_SAFE_V4
        ) revert RetiredIdentityForbidden(treasury_);

        _requireContractNotDelegated(nft_);
        _requireContractNotDelegated(ingress_);
        _requireContractNotDelegated(ethUsdFeed_);
        if (nft_ == ingress_ || ethUsdFeed_ == nft_ || ethUsdFeed_ == ingress_) revert InvalidBinding();

        if (sequencerUptimeFeed_ != address(0)) {
            if (
                sequencerUptimeFeed_ == nft_
                    || sequencerUptimeFeed_ == ingress_
                    || sequencerUptimeFeed_ == ethUsdFeed_
            ) revert InvalidBinding();
            _requireContractNotDelegated(sequencerUptimeFeed_);
        }

        // Reciprocal V5 Core graph verification (matches NARAGenesisShieldVaultV5 & NARAPositionSaleV5)
        NARAPositionNFTV5 receipt = NARAPositionNFTV5(nft_);
        address pAddress = receipt.core();
        address rAddress = receipt.rewards();
        _requireContractNotDelegated(pAddress);
        _requireContractNotDelegated(rAddress);
        if (
            pAddress == rAddress
                || pAddress == nft_
                || rAddress == nft_
                || ingress_ == pAddress
                || ingress_ == rAddress
                || receipt.financialSchemaVersion() != 2
        ) revert InvalidBinding();

        NARAPrincipalLedgerV5 p = NARAPrincipalLedgerV5(pAddress);
        NARARewardLedgerV5 r = NARARewardLedgerV5(rAddress);
        address eAddress = p.engine();
        address resAddress = p.reserve();
        address nAddress = p.nara();
        address uAddress = r.usdc();
        address fAddress = p.forge();
        address rendererAddr = receipt.renderer();

        _requireContractNotDelegated(eAddress);
        _requireContractNotDelegated(resAddress);
        _requireContractNotDelegated(nAddress);
        _requireContractNotDelegated(uAddress);
        _requireContractNotDelegated(fAddress);
        _requireContractNotDelegated(rendererAddr);

        INARAPositionRendererSinksV5 rend = INARAPositionRendererSinksV5(rendererAddr);
        address artAddr = rend.art();
        address statsReaderAddr = rend.statsReader();
        address cardAddr = rend.card();

        if (
            p.SCHEMA_VERSION() != 3
                || r.SCHEMA_VERSION() != 2
                || p.positionNFT() != nft_
                || p.rewards() != rAddress
                || r.principal() != pAddress
                || !p.bindingsSealed()
                || !r.initialized()
                || p.moduleLockHolder() != address(0)
                || r.engine() != eAddress
                || r.nara() != nAddress
                || r.reserve() != resAddress
                || p.genesisTimestamp() == 0
                || r.genesisTimestamp() != p.genesisTimestamp()
                || nAddress == uAddress
                || INARATokenFlashSinkDispenserV5(nAddress).FLASH_FEE_SINK() != resAddress
        ) revert InvalidBinding();

        NARARewardIngressV5 fees = NARARewardIngressV5(payable(ingress_));
        if (
            fees.SCHEMA_VERSION() != 1
                || fees.rewards() != rAddress
                || fees.nara() != nAddress
                || fees.usdc() != uAddress
        ) revert InvalidBinding();

        INARAEpochCoordinatorV5 coord = INARAEpochCoordinatorV5(eAddress);
        CoreBindings memory b = coord.bindings();
        (address boundPrincipal, address boundRewards) = coord.financialModules();
        (uint64 genesis,) = coord.principalEpoch();
        if (
            b.schemaVersion != 1
                || !b.bindingsSealed
                || !b.activated
                || b.bootstrapAuthority != address(0)
                || b.positionNFT != nft_
                || b.nara != nAddress
                || b.reserve != resAddress
                || boundPrincipal != pAddress
                || boundRewards != rAddress
                || genesis != p.genesisTimestamp()
                || coord.principalBindingHash() != p.bindingHash()
                || coord.rewardBindingHash() != r.bindingHash()
        ) revert InvalidBinding();

        ReserveState memory rs = INARAEmissionReserveV5(resAddress).state();
        if (
            rs.schemaVersion != 1
                || !rs.bindingsSealed
                || !rs.initialFundingRecognized
                || rs.bootstrapAuthority != address(0)
                || rs.core != eAddress
                || rs.nara != nAddress
                || rs.genesisTimestamp != p.genesisTimestamp()
        ) revert InvalidBinding();

        AccountingPolicy memory pol = p.policy();
        if (
            pol.policyHash == bytes32(0)
                || pol.epochSeconds != 900
                || pol.minDuration != 96
                || pol.maxDuration != 35_040
                || pol.durationCurve != DurationCurve.V4Quadratic
                || pol.earlyExitEnabled
                || pol.minimumPrincipal != 1 ether
                || pol.maxAdvance == 0
                || pol.rewardAdmissionCap != type(uint256).max / 1e27
                || r.admissionCap() != pol.rewardAdmissionCap
        ) revert InvalidBinding();

        if (IERC20(nAddress).totalSupply() != SUPPLY) revert FlashActive();

        // Oracle validation
        if (maxOracleStaleness_ < MIN_ORACLE_STALENESS || maxOracleStaleness_ > MAX_ORACLE_STALENESS) {
            revert InvalidOracleConfig();
        }
        uint8 dec = IChainlinkAggregatorV3(ethUsdFeed_).decimals();
        if (dec < 6 || dec > 18) revert InvalidOracleConfig();

        // Wave config validation
        if (minFloorUsd8_ < MIN_ALLOWED_FLOOR_USD8 || minFloorUsd8_ > MAX_BASE_USD8) {
            revert InvalidWaveConfig();
        }
        _validateWaveSchedule(baseWave0Usd8_, waveSizeWei_, waveStepBps_, minFloorUsd8_);

        nft = receipt;
        principal = p;
        rewards = r;
        ingress = fees;
        engine = NARAEpochEngineV5(eAddress);
        reserve = INARAEmissionReserveV5(resAddress);
        nara = nAddress;
        usdc = uAddress;
        treasury = treasury_;

        _forge = fAddress;
        _nftRenderer = rendererAddr;
        _nftArt = artAddr;
        _nftStatsReader = statsReaderAddr;
        _nftCard = cardAddr;

        uint256 scale = 10 ** uint256(dec);
        ethUsdFeed = IChainlinkAggregatorV3(ethUsdFeed_);
        sequencerUptimeFeed = IChainlinkAggregatorV3(sequencerUptimeFeed_);
        oracleDecimals = dec;
        _oracleScale = scale;
        _minRawAnswer = (MIN_SANITY_ETH_USD8 * scale) / USD_SCALE;
        _maxRawAnswer = (MAX_SANITY_ETH_USD8 * scale) / USD_SCALE;
        maxOracleStaleness = maxOracleStaleness_;
        minFloorUsd8 = minFloorUsd8_;

        policyHash = pol.policyHash;
        minimumPrincipal = pol.minimumPrincipal;
        maxDuration = pol.maxDuration;
        engineMaxAdvance = pol.maxAdvance;

        baseWave0Usd8 = baseWave0Usd8_;
        waveSizeWei = waveSizeWei_;
        waveStepBps = waveStepBps_;

        // Complete protocol/NFT/Forge sink verification (`L-03`):
        if (
            p.isProtocolSink(address(this))
                || p.isProtocolSink(ingress_)
                || _isForbiddenSink(treasury_)
        ) revert InvalidBinding();

        // Prove oracle & sequencer feeds answer cleanly at deployment time
        _readValidatedEthUsdAnswer();
    }

    /// @dev Rejects plain ETH transfers so buyers never send unquoted ETH without receiving a Vault Receipt.
    receive() external payable {
        revert DirectEthForbidden();
    }

    /// @notice Canonical tier specification (`0..4`: Starter 180D, Core 365D, Builder 365D, Whale 365D, Sovereign 365D).
    function tierSpec(uint8 tierId) public view returns (TierSpec memory spec) {
        if (tierId == 0) return TierSpec({principalWei: 1 ether, durationEpochs: MIN_STARTER_DURATION});
        if (tierId == 1) return TierSpec({principalWei: 1.25 ether, durationEpochs: maxDuration});
        if (tierId == 2) return TierSpec({principalWei: 3.5 ether, durationEpochs: maxDuration});
        if (tierId == 3) return TierSpec({principalWei: 10 ether, durationEpochs: maxDuration});
        if (tierId == 4) return TierSpec({principalWei: 25 ether, durationEpochs: maxDuration});
        revert InvalidTier(tierId);
    }

    /// @notice Unsold `NARA` inventory currently available for immediate vault receipt dispensing.
    function availableNara() public view returns (uint256) {
        return IERC20(nara).balanceOf(address(this));
    }

    /// @notice Current active wave index (`0 .. MAX_WAVE_INDEX`).
    function currentWaveIndex() public view returns (uint256) {
        uint256 raw = waveCursorWei / waveSizeWei;
        return raw > MAX_WAVE_INDEX ? MAX_WAVE_INDEX : raw;
    }

    /// @notice Non-reverting consolidated snapshot for frontends and keepers (`I-01` / `MATH-06` immune).
    function dispenserStatus() external view returns (DispenserStatus memory s) {
        (bool healthy, , uint256 price8) = _tryReadValidatedEthUsdAnswer();
        uint256 wIdx = currentWaveIndex();
        s = DispenserStatus({
            salesPaused: salesPaused,
            oracleHealthy: healthy,
            availableNaraWei: availableNara(),
            waveCursorWei: waveCursorWei,
            currentWaveIndex: wIdx,
            currentWaveBaseUsd8: computeWavePriceUsd8(baseWave0Usd8, waveStepBps, wIdx),
            baseWave0Usd8: baseWave0Usd8,
            waveSizeWei: waveSizeWei,
            waveStepBps: waveStepBps,
            minFloorUsd8: minFloorUsd8,
            totalNaraDispensed: totalNaraDispensed,
            totalSeatsDispensed: totalSeatsDispensed,
            totalEthRaised: totalEthRaised,
            totalFeeEthToIngress: totalFeeEthToIngress,
            totalTreasuryEthDelivered: totalTreasuryEthDelivered,
            pendingTreasuryEth: pendingTreasuryEth,
            totalForcedEthSwept: totalForcedEthSwept,
            ethUsdPrice8: healthy ? price8 : 0
        });
    }

    /// @notice Quotes `count` canonical tier Vault Receipts (`tierId` in `0..4`) at live Chainlink `ETH/USD`.
    function quoteTier(uint8 tierId, uint16 count) external view returns (DispenserQuote memory) {
        if (count == 0 || count > MAX_BATCH_SEATS) revert InvalidBatchCount(count);
        TierSpec memory spec = tierSpec(tierId);
        (uint256 rawAnswer, uint256 price8) = _readValidatedEthUsdAnswer();
        return _computeQuote(spec.principalWei, count, spec.durationEpochs, rawAnswer, price8);
    }

    /// @notice Quotes a custom single Vault Receipt (`1.00 .. 100.00 NARA`) at live Chainlink `ETH/USD`.
    function quoteCustom(uint256 naraAmountWei, uint32 durationEpochs)
        external
        view
        returns (DispenserQuote memory)
    {
        _validateCustomSeat(naraAmountWei, durationEpochs);
        (uint256 rawAnswer, uint256 price8) = _readValidatedEthUsdAnswer();
        return _computeQuote(naraAmountWei, 1, durationEpochs, rawAnswer, price8);
    }

    /// @notice Mints and delivers `count` (`1..8`) canonical-tier Vault Receipts atomically to `recipient`.
    function dispenseTier(
        uint8 tierId,
        uint16 count,
        address recipient,
        uint256 maxEthCost,
        uint32 maxAdvanceEpochs,
        uint64 deadline
    )
        external
        payable
        nonReentrant
        returns (uint256 firstTokenId, uint256 lastTokenId, uint256 ethChargedWei)
    {
        if (count == 0 || count > MAX_BATCH_SEATS) revert InvalidBatchCount(count);
        TierSpec memory spec = tierSpec(tierId);
        return _dispense(
            tierId,
            spec.principalWei,
            count,
            spec.durationEpochs,
            recipient,
            maxEthCost,
            maxAdvanceEpochs,
            deadline
        );
    }

    /// @notice Mints and delivers one custom-sized (`1.00 .. 100.00 NARA`) Vault Receipt atomically to `recipient`.
    function dispenseCustom(
        uint256 naraAmountWei,
        uint32 durationEpochs,
        address recipient,
        uint256 maxEthCost,
        uint32 maxAdvanceEpochs,
        uint64 deadline
    ) external payable nonReentrant returns (uint256 tokenId, uint256 ethChargedWei) {
        _validateCustomSeat(naraAmountWei, durationEpochs);
        (tokenId,, ethChargedWei) = _dispense(
            type(uint8).max,
            naraAmountWei,
            1,
            durationEpochs,
            recipient,
            maxEthCost,
            maxAdvanceEpochs,
            deadline
        );
    }

    /// @notice Deposits `NARA` inventory into the dispenser (callable by `treasury` or any inventory supplier).
    function depositInventory(uint256 naraAmountWei) external nonReentrant {
        if (naraAmountWei == 0) revert InvalidCustomSeat(0, 0);
        _requireSettledSupply();
        uint256 beforeBal = IERC20(nara).balanceOf(address(this));
        IERC20(nara).safeTransferFrom(msg.sender, address(this), naraAmountWei);
        uint256 afterBal = IERC20(nara).balanceOf(address(this));
        if (afterBal - beforeBal != naraAmountWei) revert AccountingInvariantFailed();
        emit InventoryDeposited(msg.sender, naraAmountWei, afterBal);
    }

    /// @notice Returns unsold `NARA` inventory strictly to immutable `treasury` (`0xe320...51E3`).
    function returnInventoryToTreasury(uint256 naraAmountWei) external onlyTreasury nonReentrant {
        if (naraAmountWei == 0) revert NothingToSweep();
        _requireSettledSupply();
        uint256 beforeBal = IERC20(nara).balanceOf(address(this));
        if (naraAmountWei > beforeBal) revert InsufficientInventory(beforeBal, naraAmountWei);
        IERC20(nara).safeTransfer(treasury, naraAmountWei);
        uint256 afterBal = IERC20(nara).balanceOf(address(this));
        if (beforeBal - afterBal != naraAmountWei) revert AccountingInvariantFailed();
        emit InventoryReturnedToTreasury(naraAmountWei, afterBal);
    }

    /// @notice Permanently retires unsold `NARA` inventory into `NARAEmissionReserveV5` for community emissions.
    function retireInventoryToReserve(uint256 naraAmountWei) external onlyTreasury nonReentrant {
        if (naraAmountWei == 0) revert NothingToSweep();
        _requireSettledSupply();
        uint256 beforeBal = IERC20(nara).balanceOf(address(this));
        if (naraAmountWei > beforeBal) revert InsufficientInventory(beforeBal, naraAmountWei);
        if (IERC20(nara).allowance(address(this), address(reserve)) != 0) revert AccountingInvariantFailed();
        IERC20(nara).forceApprove(address(reserve), naraAmountWei);
        reserve.fund(naraAmountWei);
        IERC20(nara).forceApprove(address(reserve), 0);
        uint256 afterBal = IERC20(nara).balanceOf(address(this));
        if (
            beforeBal - afterBal != naraAmountWei
                || IERC20(nara).allowance(address(this), address(reserve)) != 0
        ) revert AccountingInvariantFailed();
        emit InventoryRetiredToReserve(naraAmountWei, afterBal);
    }

    /// @notice Updates the ascending wave schedule (`onlyTreasury`), always enforcing `>= minFloorUsd8`.
    function setWaveConfig(
        uint256 newBaseWave0Usd8,
        uint256 newWaveSizeWei,
        uint256 newWaveStepBps,
        bool resetWaveCursor
    ) external onlyTreasury nonReentrant {
        _validateWaveSchedule(newBaseWave0Usd8, newWaveSizeWei, newWaveStepBps, minFloorUsd8);
        baseWave0Usd8 = newBaseWave0Usd8;
        waveSizeWei = newWaveSizeWei;
        waveStepBps = newWaveStepBps;
        if (resetWaveCursor) {
            waveCursorWei = 0;
        }
        emit WaveConfigUpdated(newBaseWave0Usd8, newWaveSizeWei, newWaveStepBps, waveCursorWei);
    }

    /// @notice Pauses or resumes dispenser sales (`onlyTreasury`).
    function setSalesPaused(bool paused) external onlyTreasury nonReentrant {
        salesPaused = paused;
        emit SalesPauseUpdated(paused);
    }

    /// @notice Permissionlessly pushes any escrowed `pendingTreasuryEth` strictly to `treasury` (matches `S-2`).
    function sweepPendingTreasuryEth() external nonReentrant returns (uint256 amountWei) {
        amountWei = pendingTreasuryEth;
        if (amountWei == 0) revert NothingToSweep();
        pendingTreasuryEth = 0;
        totalTreasuryEthDelivered += amountWei;
        (bool ok,) = payable(treasury).call{value: amountWei}("");
        if (!ok) revert PaymentFailed();
        emit PendingTreasuryEthCollected(msg.sender, treasury, amountWei);
    }

    /// @notice Allows `treasury` itself to collect `pendingTreasuryEth` to a chosen safe address if `treasury` rejects ETH.
    function collectPendingTreasuryEth(address recipient)
        external
        onlyTreasury
        nonReentrant
        returns (uint256 amountWei)
    {
        if (
            bytes3(recipient.code) == DELEGATION_DESIGNATOR
                || _isForbiddenSink(recipient)
        ) revert InvalidRecipient();
        amountWei = pendingTreasuryEth;
        if (amountWei == 0) revert NothingToSweep();
        pendingTreasuryEth = 0;
        totalTreasuryEthDelivered += amountWei;
        (bool ok,) = payable(recipient).call{value: amountWei}("");
        if (!ok) revert PaymentFailed();
        emit PendingTreasuryEthCollected(msg.sender, recipient, amountWei);
    }

    /// @notice Permissionlessly sweeps forced `SELFDESTRUCT`/coinbase ETH surplus above `pendingTreasuryEth` to `ingress`.
    /// @dev Tracks forced surplus in `totalForcedEthSwept` (`L-01`) so `totalEthRaised == totalFeeEthToIngress + totalTreasuryEthDelivered + pendingTreasuryEth` holds unconditionally.
    function sweepForcedEthToIngress() external nonReentrant returns (uint256 surplusWei) {
        uint256 bal = address(this).balance;
        if (bal <= pendingTreasuryEth) revert NothingToSweep();
        surplusWei = bal - pendingTreasuryEth;
        totalForcedEthSwept += surplusWei;
        (bool ok,) = payable(address(ingress)).call{value: surplusWei}("");
        if (!ok) revert IngressTransferFailed();
        emit ForcedEthSweptToIngress(msg.sender, surplusWei);
    }

    /// @notice Permissionlessly sweeps any non-`NARA` stray ERC-20 token strictly to `treasury`.
    function sweepStrayTokenToTreasury(address token) external nonReentrant returns (uint256 amount) {
        if (token == address(0) || token == nara) revert InvalidAsset();
        amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert NothingToSweep();
        IERC20(token).safeTransfer(treasury, amount);
        emit StrayTokenSweptToTreasury(token, amount);
    }

    /// @notice Rescues any ERC-721 forced onto this contract via raw `transferFrom` strictly to `treasury` (`L-05`).
    function sweepUnsolicitedNFTToTreasury(address collection, uint256 tokenId) external onlyTreasury nonReentrant {
        if (collection == address(0)) revert InvalidAsset();
        IERC721(collection).transferFrom(address(this), treasury, tokenId);
        emit UnsolicitedNFTSweptToTreasury(collection, tokenId);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Pure Mathematical Pricing Oracles (Exact 0-wei Parity with dispenser-pricing.ts)
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Base `USD/NARA` (`1e8` scale) at `waveIndex` (clamped at `MAX_WAVE_INDEX = 32`).
    function computeWavePriceUsd8(
        uint256 base0Usd8,
        uint256 stepBps,
        uint256 waveIndex
    ) public pure returns (uint256 priceUsd8) {
        uint256 capped = waveIndex > MAX_WAVE_INDEX ? MAX_WAVE_INDEX : waveIndex;
        priceUsd8 = base0Usd8;
        for (uint256 i; i < capped; ++i) {
            priceUsd8 = Math.mulDiv(priceUsd8, BPS_DENOMINATOR + stepBps, BPS_DENOMINATOR, Math.Rounding.Ceil);
        }
    }

    /// @notice Continuous piecewise-linear marginal volume units `U(q)` for one seat of `principalWei`.
    function computeEffectiveUnitsWei(uint256 principalWei) public pure returns (uint256) {
        if (principalWei == 0) revert InvalidCustomSeat(0, 0);
        uint256 weightedBpsSum;

        uint256 s0 = principalWei < BRACKET_1_UPPER ? principalWei : BRACKET_1_UPPER;
        weightedBpsSum += s0 * RATE_BRACKET_0_BPS;

        if (principalWei > BRACKET_1_UPPER) {
            uint256 upper1 = principalWei < BRACKET_2_UPPER ? principalWei : BRACKET_2_UPPER;
            weightedBpsSum += (upper1 - BRACKET_1_UPPER) * RATE_BRACKET_1_BPS;
        }

        if (principalWei > BRACKET_2_UPPER) {
            uint256 upper2 = principalWei < BRACKET_3_UPPER ? principalWei : BRACKET_3_UPPER;
            weightedBpsSum += (upper2 - BRACKET_2_UPPER) * RATE_BRACKET_2_BPS;
        }

        if (principalWei > BRACKET_3_UPPER) {
            weightedBpsSum += (principalWei - BRACKET_3_UPPER) * RATE_BRACKET_3_BPS;
        }

        return Math.mulDiv(weightedBpsSum, 1, BPS_DENOMINATOR, Math.Rounding.Ceil);
    }

    /// @notice Integrates raw `P_wave(s)` across `[cursorWei, cursorWei + totalPrincipalWei]` in `1e26` USD-wei units.
    function integrateWaveNumerator26(
        uint256 base0Usd8,
        uint256 sizeWei,
        uint256 stepBps,
        uint256 cursorWei,
        uint256 totalPrincipalWei
    )
        public
        pure
        returns (uint256 numerator26, uint256 startWaveIndex, uint256 endWaveIndex)
    {
        (numerator26,, startWaveIndex, endWaveIndex) = integrateAdjustedSeatUsd26(
            base0Usd8,
            sizeWei,
            stepBps,
            0,
            cursorWei,
            totalPrincipalWei,
            totalPrincipalWei
        );
    }

    /// @notice Per-seat, per-slice floor-clamped wave integration (`MATH-01` / `L-02` remediation).
    /// @dev Clamps every wave slice's bracket-adjusted USD-wei numerator against `slice * floorUsd8` so higher
    ///      waves can never cross-subsidize sub-floor inventory.
    function integrateAdjustedSeatUsd26(
        uint256 base0Usd8,
        uint256 sizeWei,
        uint256 stepBps,
        uint256 floorUsd8,
        uint256 seatCursorWei,
        uint256 seatPrincipalWei,
        uint256 effectiveUnitsWei
    )
        public
        pure
        returns (
            uint256 rawNumerator26,
            uint256 adjustedNumerator26,
            uint256 startWaveIndex,
            uint256 endWaveIndex
        )
    {
        if (seatPrincipalWei == 0 || effectiveUnitsWei == 0 || sizeWei == 0) revert InvalidWaveConfig();

        uint256 rawStart = seatCursorWei / sizeWei;
        startWaveIndex = rawStart > MAX_WAVE_INDEX ? MAX_WAVE_INDEX : rawStart;

        uint256 cursor = seatCursorWei;
        uint256 remaining = seatPrincipalWei;
        uint256 w = startWaveIndex;
        uint256 currentPrice = computeWavePriceUsd8(base0Usd8, stepBps, w);

        while (remaining > 0) {
            uint256 slice;
            if (w >= MAX_WAVE_INDEX) {
                slice = remaining;
                remaining = 0;
            } else {
                uint256 waveEnd = (w + 1) * sizeWei;
                uint256 availableInWave = waveEnd > cursor ? waveEnd - cursor : 0;
                if (availableInWave == 0) {
                    ++w;
                    currentPrice =
                        Math.mulDiv(currentPrice, BPS_DENOMINATOR + stepBps, BPS_DENOMINATOR, Math.Rounding.Ceil);
                    continue;
                }
                slice = remaining < availableInWave ? remaining : availableInWave;
                cursor += slice;
                remaining -= slice;
            }

            uint256 sliceRaw26 = slice * currentPrice;
            rawNumerator26 += sliceRaw26;
            uint256 sliceDisc26 =
                Math.mulDiv(sliceRaw26, effectiveUnitsWei, seatPrincipalWei, Math.Rounding.Ceil);
            uint256 sliceFloor26 = slice * floorUsd8;
            adjustedNumerator26 += sliceDisc26 < sliceFloor26 ? sliceFloor26 : sliceDisc26;

            if (remaining > 0 && w < MAX_WAVE_INDEX) {
                ++w;
                currentPrice = Math.mulDiv(currentPrice, BPS_DENOMINATOR + stepBps, BPS_DENOMINATOR, Math.Rounding.Ceil);
            }
        }

        uint256 endRaw = (seatCursorWei + seatPrincipalWei - 1) / sizeWei;
        endWaveIndex = endRaw > MAX_WAVE_INDEX ? MAX_WAVE_INDEX : endRaw;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Internal Execution & Validation Helpers
    // ─────────────────────────────────────────────────────────────────────────────

    function _dispense(
        uint8 tierId,
        uint256 perSeatPrincipalWei,
        uint16 count,
        uint32 durationEpochs,
        address recipient,
        uint256 maxEthCost,
        uint32 maxAdvanceEpochs,
        uint64 deadline
    ) private returns (uint256 firstTokenId, uint256 lastTokenId, uint256 ethChargedWei) {
        if (salesPaused) revert SalesPausedError();
        if (block.timestamp > deadline) revert Expired();
        _requireSettledSupply();

        if (recipient == treasury || _isForbiddenSink(recipient)) {
            revert InvalidRecipient();
        }

        (uint256 rawAnswer, uint256 price8) = _readValidatedEthUsdAnswer();
        DispenserQuote memory q =
            _computeQuote(perSeatPrincipalWei, count, durationEpochs, rawAnswer, price8);

        if (msg.value < q.requiredEthWei || q.requiredEthWei > maxEthCost) {
            revert SlippageOrPaymentInsufficient(q.requiredEthWei, msg.value, maxEthCost);
        }

        uint256 naraBefore = IERC20(nara).balanceOf(address(this));
        if (naraBefore < q.totalPrincipalWei) {
            revert InsufficientInventory(naraBefore, q.totalPrincipalWei);
        }

        // Synchronize Engine/Ledger settlement cursor if keeper has a small epoch backlog
        _syncToWall(maxAdvanceEpochs);

        // Effects: advance wave cursor & monotonic lifetime counters BEFORE external calls
        uint256 newCursor = waveCursorWei + q.totalPrincipalWei;
        waveCursorWei = newCursor;
        totalNaraDispensed += q.totalPrincipalWei;
        totalSeatsDispensed += count;
        totalEthRaised += q.requiredEthWei;
        totalFeeEthToIngress += q.feeEthWei;

        // Interactions 1 (Trusted Core ONLY): Mint all `count` Vault Receipts to `address(this)` and clear allowance
        // BEFORE any untrusted external ETH/ERC-721 callbacks execute.
        if (IERC20(nara).allowance(address(this), address(principal)) != 0) {
            revert AccountingInvariantFailed();
        }
        IERC20(nara).forceApprove(address(principal), q.totalPrincipalWei);

        uint256[] memory mintedPositionIds = new uint256[](count);
        uint256[] memory mintedTokenIds = new uint256[](count);

        for (uint16 i; i < count; ++i) {
            uint256 posId = principal.nextPositionId();
            principal.create(
                CreateRequest({
                    amount: perSeatPrincipalWei,
                    duration: durationEpochs,
                    expectedPolicyHash: policyHash,
                    deadline: deadline
                })
            );

            uint256 tokenId = nft.tokenIdOf(posId, 1);
            if (tokenId == 0 || nft.ownerOf(tokenId) != address(this)) {
                revert InvalidAcquisition();
            }
            mintedPositionIds[i] = posId;
            mintedTokenIds[i] = tokenId;
            if (i == 0) firstTokenId = tokenId;
            lastTokenId = tokenId;
        }

        IERC20(nara).forceApprove(address(principal), 0);

        uint256 naraAfter = IERC20(nara).balanceOf(address(this));
        if (
            naraBefore - naraAfter != q.totalPrincipalWei
                || IERC20(nara).allowance(address(this), address(principal)) != 0
        ) revert AccountingInvariantFailed();

        // Interactions 2 (Trusted Core): Push immutable 5.00% ETH royalty to NARARewardIngressV5
        // and unconditionally flush via fault-isolated `_tryFlushIngressEth()` (`L-04` remediation).
        if (q.feeEthWei > 0) {
            (bool feeOk,) = payable(address(ingress)).call{value: q.feeEthWei}("");
            if (!feeOk) revert IngressTransferFailed();
            _tryFlushIngressEth();
        }

        // Interactions 3 (Bounded): Deliver 95.00% net ETH to Treasury Safe (with EIP-150 guard & DOS-N01 escrow fallback)
        if (q.netTreasuryEthWei > 0) {
            if (gasleft() < TREASURY_CALL_MIN_GAS) revert InsufficientExternalCallGas();
            (bool sentTreasury,) =
                payable(treasury).call{gas: TREASURY_CALL_GAS, value: q.netTreasuryEthWei}("");
            if (sentTreasury) {
                totalTreasuryEthDelivered += q.netTreasuryEthWei;
            } else {
                pendingTreasuryEth += q.netTreasuryEthWei;
                emit TreasuryEthEscrowed(q.netTreasuryEthWei, pendingTreasuryEth);
            }
        }

        // Interactions 4 (Untrusted Receiver Callbacks): Safe-transfer receipts to `recipient` & assert post-callback integrity
        for (uint16 i; i < count; ++i) {
            uint256 posId = mintedPositionIds[i];
            uint256 tokenId = mintedTokenIds[i];

            nft.safeTransferFrom(address(this), recipient, tokenId);

            // Post-callback acquisition verification (matches NARAPositionSaleV5 lines 231-234)
            PositionState memory acq = principal.positionHead(posId);
            if (
                nft.ownerOf(tokenId) != recipient
                    || acq.generationOwner != recipient
                    || acq.principal != perSeatPrincipalWei
                    || acq.generation != 1
                    || acq.withdrawn
                    || acq.effectiveEnd != acq.maturity
                    || nft.receiptTransferNonce(tokenId) != 1
            ) revert InvalidAcquisition();
        }

        // Interactions 5 (Untrusted Caller Refund): Refund exact buyer overpayment LAST
        uint256 refundWei = msg.value - q.requiredEthWei;
        if (refundWei > 0) {
            (bool refundOk,) = payable(msg.sender).call{value: refundWei}("");
            if (!refundOk) revert RefundFailed();
        }

        _requireSettledSupply();
        if (address(this).balance < pendingTreasuryEth) revert AccountingInvariantFailed();

        ethChargedWei = q.requiredEthWei;
        emit SeatsDispensed(
            msg.sender,
            recipient,
            tierId,
            count,
            perSeatPrincipalWei,
            durationEpochs,
            firstTokenId,
            lastTokenId,
            q.requiredEthWei,
            q.feeEthWei,
            price8,
            newCursor
        );
    }

    /// @dev Sums exact per-seat quotes across `i = 0 .. count - 1` (`MATH-01` + `MATH-05` 0-wei batch additivity).
    function _computeQuote(
        uint256 perSeatPrincipalWei,
        uint16 count,
        uint32 durationEpochs,
        uint256 rawEthUsdAnswer,
        uint256 ethUsdPrice8
    ) private view returns (DispenserQuote memory q) {
        uint256 effectiveUnits = computeEffectiveUnitsWei(perSeatPrincipalWei);
        uint256 oracleScale = _oracleScale;
        uint256 denom = USD_SCALE * rawEthUsdAnswer;

        uint256 rawWaveNum26;
        uint256 adjustedNum26;
        uint256 totalUsd8;
        uint256 requiredEthWei;
        uint256 feeEthWei;
        uint256 startWave;
        uint256 endWave;

        for (uint16 i; i < count; ++i) {
            uint256 seatCursor = waveCursorWei + uint256(i) * perSeatPrincipalWei;
            (uint256 sRaw26, uint256 sAdj26, uint256 sStart, uint256 sEnd) = integrateAdjustedSeatUsd26(
                baseWave0Usd8,
                waveSizeWei,
                waveStepBps,
                minFloorUsd8,
                seatCursor,
                perSeatPrincipalWei,
                effectiveUnits
            );
            if (i == 0) startWave = sStart;
            endWave = sEnd;

            rawWaveNum26 += sRaw26;
            adjustedNum26 += sAdj26;
            totalUsd8 += Math.mulDiv(sAdj26, 1, 1 ether, Math.Rounding.Ceil);

            uint256 seatReqEth = Math.mulDiv(sAdj26, oracleScale, denom, Math.Rounding.Ceil);
            if (seatReqEth == 0) revert InvalidOracleConfig();
            uint256 seatFeeEth = Math.mulDiv(seatReqEth, FEE_BPS, BPS_DENOMINATOR, Math.Rounding.Floor);

            requiredEthWei += seatReqEth;
            feeEthWei += seatFeeEth;
        }

        uint256 totalPrincipalWei = perSeatPrincipalWei * uint256(count);
        uint256 netTreasuryEthWei = requiredEthWei - feeEthWei;

        q = DispenserQuote({
            perSeatPrincipalWei: perSeatPrincipalWei,
            count: count,
            totalPrincipalWei: totalPrincipalWei,
            durationEpochs: durationEpochs,
            effectiveUnitsPerSeatWei: effectiveUnits,
            rawWaveNumerator26: rawWaveNum26,
            adjustedUsdNumerator26: adjustedNum26,
            totalUsd8: totalUsd8,
            requiredEthWei: requiredEthWei,
            feeEthWei: feeEthWei,
            netTreasuryEthWei: netTreasuryEthWei,
            ethUsdPrice8: ethUsdPrice8,
            startWaveIndex: startWave,
            endWaveIndex: endWave
        });
    }

    function _inspectOracle()
        private
        view
        returns (uint8 errCode, uint256 upDuration, uint256 rawAnswer, uint256 normalizedPrice8)
    {
        if (address(sequencerUptimeFeed) != address(0)) {
            try sequencerUptimeFeed.latestRoundData() returns (
                uint80 seqRoundId,
                int256 seqAnswer,
                uint256 startedAt,
                uint256,
                uint80 seqAnsweredIn
            ) {
                if (
                    seqRoundId == 0
                        || seqAnsweredIn < seqRoundId
                        || startedAt == 0
                        || startedAt > block.timestamp
                        || seqAnswer != 0
                ) return (1, 0, 0, 0);
                upDuration = block.timestamp - startedAt;
                if (upDuration <= SEQUENCER_GRACE_PERIOD) {
                    return (2, upDuration, 0, 0);
                }
            } catch {
                return (1, 0, 0, 0);
            }
        }

        try ethUsdFeed.latestRoundData() returns (
            uint80 roundId,
            int256 answer,
            uint256,
            uint256 updatedAt,
            uint80 answeredInRound
        ) {
            if (
                roundId == 0
                    || answeredInRound < roundId
                    || answer <= 0
                    || updatedAt == 0
                    || updatedAt > block.timestamp
                    || block.timestamp - updatedAt > maxOracleStaleness
            ) return (3, 0, 0, 0);

            rawAnswer = uint256(answer);
            if (rawAnswer > type(uint256).max / USD_SCALE) {
                return (4, 0, rawAnswer, type(uint256).max);
            }
            normalizedPrice8 = (rawAnswer * USD_SCALE) / _oracleScale;

            // Exact native-decimal sanity bounds check (`MATH-03` remediation):
            if (rawAnswer < _minRawAnswer || rawAnswer > _maxRawAnswer) {
                return (4, 0, rawAnswer, normalizedPrice8);
            }
            return (0, upDuration, rawAnswer, normalizedPrice8);
        } catch {
            return (3, 0, 0, 0);
        }
    }

    function _tryReadValidatedEthUsdAnswer()
        private
        view
        returns (bool healthy, uint256 rawAnswer, uint256 normalizedPrice8)
    {
        (uint8 errCode,, uint256 rawAns, uint256 price8) = _inspectOracle();
        return errCode == 0 ? (true, rawAns, price8) : (false, 0, 0);
    }

    function _readValidatedEthUsdAnswer()
        private
        view
        returns (uint256 rawAnswer, uint256 normalizedPrice8)
    {
        (uint8 errCode, uint256 upDuration, uint256 rawAns, uint256 price8) = _inspectOracle();
        if (errCode == 0) return (rawAns, price8);
        if (errCode == 1) revert SequencerDown();
        if (errCode == 2) revert SequencerGracePeriodNotOver(upDuration, SEQUENCER_GRACE_PERIOD);
        if (errCode == 3) revert StaleOrInvalidOraclePrice();
        revert OraclePriceOutOfBounds(price8);
    }

    function _syncToWall(uint32 maxAdvanceEpochs) private returns (uint64 wall) {
        if (maxAdvanceEpochs > MAX_SYNC_EPOCHS) {
            revert SyncLimitExceeded(maxAdvanceEpochs, MAX_SYNC_EPOCHS);
        }
        EpochClock memory clk = engine.clock();
        uint64 remaining = clk.backlog;
        if (remaining > maxAdvanceEpochs) {
            revert CoreStale(clk.wallEpoch, remaining);
        }
        while (remaining > 0) {
            uint32 step = remaining > engineMaxAdvance ? engineMaxAdvance : uint32(remaining);
            engine.advance(step);
            clk = engine.clock();
            remaining = clk.backlog;
        }
        return clk.wallEpoch;
    }

    function _tryFlushIngressEth() private {
        uint256 pendingEth = ingress.pending(RewardAsset.ETH);
        if (pendingEth == 0) return;
        if (gasleft() < INGRESS_FLUSH_MIN_GAS) revert InsufficientExternalCallGas();
        try ingress.forward{gas: INGRESS_FLUSH_CALL_GAS}(RewardAsset.ETH, pendingEth) {} catch {}
    }

    /// @dev Unified protocol, NFT-layer, Forge-adapter, oracle, and retired-identity deny-list (`L-03`).
    function _isForbiddenSink(address a) private view returns (bool) {
        if (
            a == address(0)
                || a == address(this)
                || a == address(ingress)
                || a == address(ethUsdFeed)
                || (address(sequencerUptimeFeed) != address(0) && a == address(sequencerUptimeFeed))
                || a == COMPROMISED_DEPLOYER_V4
                || a == EXPOSED_RANGER_V4
                || a == RETIRED_RANGE_SAFE_V4
                || a == _nftRenderer
                || a == _nftArt
                || a == _nftStatsReader
                || a == _nftCard
                || a == nft.statsProvider()
                || principal.isProtocolSink(a)
                || INARAForgeIdentityV5(_forge).isAdapterOrFormer(a)
        ) return true;
        return false;
    }

    function _validateCustomSeat(uint256 naraAmountWei, uint32 durationEpochs) private view {
        if (naraAmountWei < minimumPrincipal || naraAmountWei > MAX_CUSTOM_SEAT_NARA) {
            revert InvalidCustomSeat(naraAmountWei, durationEpochs);
        }
        // Any seat > 1.00 NARA receives marginal volume bracket discounts (<100%) and MUST seal for full 365D
        if (naraAmountWei > BRACKET_1_UPPER) {
            if (durationEpochs != maxDuration) {
                revert InvalidCustomSeat(naraAmountWei, durationEpochs);
            }
        } else {
            if (durationEpochs < MIN_STARTER_DURATION || durationEpochs > maxDuration) {
                revert InvalidCustomSeat(naraAmountWei, durationEpochs);
            }
        }
    }

    function _validateWaveSchedule(
        uint256 base0Usd8,
        uint256 sizeWei,
        uint256 stepBps,
        uint256 floorUsd8
    ) private pure {
        if (
            base0Usd8 < floorUsd8
                || base0Usd8 > MAX_BASE_USD8
                || sizeWei < MIN_WAVE_SIZE_WEI
                || sizeWei > MAX_WAVE_SIZE_WEI
                || stepBps > MAX_WAVE_STEP_BPS
        ) revert InvalidWaveConfig();
    }

    function _requireSettledSupply() private view {
        if (IERC20(nara).totalSupply() != SUPPLY) revert FlashActive();
    }

    function _requireContractNotDelegated(address target) private view {
        if (target == address(0) || target.code.length == 0) revert InvalidBinding();
        if (bytes3(target.code) == DELEGATION_DESIGNATOR) revert DelegatedDependency(target);
    }
}
