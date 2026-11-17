// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {NARAPositionNFTV5} from "../modular/NARAPositionNFTV5.sol";
import {NARAPrincipalLedgerV5} from "../modular/NARAPrincipalLedgerV5.sol";
import {NARARewardLedgerV5} from "../modular/NARARewardLedgerV5.sol";
import {NARARewardLensV5} from "../modular/NARARewardLensV5.sol";
import {NARARewardIngressV5} from "../modular/NARARewardIngressV5.sol";
import {NARAEpochEngineV5} from "../modular/NARAEpochEngineV5.sol";
import {
    INARAEpochCoordinatorV5,
    PrincipalLedgerStateV5,
    RewardLedgerStateV5,
    RewardWeightStateV5
} from "../modular/NARAModuleInterfacesV5.sol";
import {INARAEmissionReserveV5} from "../interfaces/INARAEmissionReserveV5.sol";
import {
    AccountingPolicy,
    CoreBindings,
    CreateRequest,
    DurationCurve,
    EpochClock,
    PositionState,
    ReserveState,
    RewardAsset,
    RewardCredit
} from "../interfaces/NARAAccountingTypesV5.sol";

interface INARATokenFlashSinkV5 {
    function FLASH_FEE_SINK() external view returns (address);
}

/// @title NARAGenesisShieldVaultV5
/// @notice Immutable, ownerless (`owner() == address(0)`) programmatic custodian that holds, recycles,
/// and progressively retires the Genesis Shield into `NARAEmissionReserveV5` as organic user commitments grow.
/// @dev Security and economic invariants:
///  1. Zero admin, zero owner, zero upgradeability, zero pause, zero external withdrawal recipient.
///  2. `NARA` held or claimed by this vault can exit ONLY to:
///     - `NARAPrincipalLedgerV5.create(...)` (active Common commitment owned by `address(this)`), or
///     - `NARAEmissionReserveV5.fund(...)` (permanent return to the 15-minute user emission reserve).
///  3. Native `ETH` and `USDC` claimed or swept by this vault can exit ONLY to `NARARewardIngressV5`.
///     Centralized `USDC` pause/blacklist reverts are gas-guarded and fault-isolated so `USDC` can never
///     block `NARA` principal retirement/rollover or `NARA`/`ETH` reward recycling; deferred `USDC` claims
///     remain permissionlessly recoverable via `recyclePositionRewardsById` once `USDC` transfers resume.
///  4. `NARAPositionNFTV5` receipts held by this vault are never transferred, approved, or listed externally.
///  5. Initial Shield tranches may be seeded across `[minDuration, maxDuration]` (supporting either a single
///     365-day commitment or staggered maturities); every subsequent rollover in `rollMatured` re-commits
///     exclusively at `maxDuration` (`35,040` epochs = `365 days @ 4.00x`). Early `sealSeeding()` permanently
///     closes seeding while retaining the immutable `targetModelWeight = 4 * targetPrincipal` floor.
///  6. Retirement into `NARAEmissionReserveV5` is rate-limited by a continuous O(1) linearly decaying leaky
///     bucket (`maxRetirePerWindow` per `2,880` epochs = `30 days`), preventing short-duration flash-stake
///     boundary bursts across epoch windows until `100%` of the Genesis Shield belongs to user emissions.
contract NARAGenesisShieldVaultV5 is IERC721Receiver, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    struct TrancheRef {
        uint256 positionId;
        uint64 generation;
    }

    struct ShieldVaultStatus {
        bool seedingClosed;
        uint256 activeTrancheCount;
        uint256 activeShieldPrincipal;
        uint256 activeShieldModelWeight;
        uint256 committedShieldModelWeight;
        uint256 externalActiveModelWeight;
        uint256 requiredShieldModelWeight;
        uint256 totalSeededPrincipal;
        uint256 totalPrincipalRetired;
        uint256 totalNaraRewardsRecycled;
        uint256 totalEthRewardsRecycled;
        uint256 totalUsdcRewardsRecycled;
        uint64 lastRetireEpoch;
        uint256 decayedRetiredLoad;
        uint256 windowRemainingCapacity;
        uint256 claimableNara;
        uint256 claimableEth;
        uint256 claimableUsdc;
    }

    uint256 public constant SCHEMA_VERSION = 1;
    uint256 public constant SUPPLY = 1_000_000 ether;
    uint256 public constant MAX_DURATION_MULTIPLIER = 4;
    uint256 public constant MAX_SHIELD_TRANCHES = 8;
    uint64 public constant RETIRE_WINDOW_EPOCHS = 2_880; // 30 days of 900-second epochs
    uint32 public constant MAX_SYNC_EPOCHS = 192; // at most 48 hours of inline catch-up per call
    uint256 public constant MAX_TARGET_PRINCIPAL = 250_000 ether;
    /// @notice Bounded gas stipend forwarded to fault-isolated external `USDC` calls (`~2x` cold `FiatTokenProxy` path).
    uint256 public constant EXTERNAL_USDC_CALL_GAS = 450_000;
    /// @notice Minimum caller gas required before a fault-isolated `USDC` call (`63/64 * 500k >= 450k`, blocking EIP-150 griefing).
    uint256 public constant EXTERNAL_USDC_MIN_GAS = 500_000;

    /// @dev Code prefix of an EIP-7702 delegation designator (`0xef0100 || address`).
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
    NARARewardLensV5 public immutable creditLens;

    address public immutable nara;
    address public immutable usdc;
    /// @notice One-time initial seeder (Treasury Safe); loses all seeding rights permanently once `seedingClosed == true`.
    address public immutable genesisSeeder;

    bytes32 public immutable policyHash;
    uint256 public immutable minimumPrincipal;
    uint32 public immutable minDuration;
    uint32 public immutable maxDuration;
    uint32 public immutable engineMaxAdvance;

    /// @notice Maximum Shield principal accepted (`45,000 NARA` target).
    uint256 public immutable targetPrincipal;
    /// @notice Target model-weight floor (`4 * targetPrincipal` = `180,000e18` for `45,000 NARA @ 4.00x`).
    uint256 public immutable targetModelWeight;
    /// @notice Token-bucket burst cap and 30-day (`2,880`-epoch) linear replenishment rate (`maxRetirePerWindow / 2,880` per epoch;
    /// steady-state retirement `<= 1.00x` per `2,880` epochs and `<= 1.000347x` across 15-minute window boundaries).
    uint256 public immutable maxRetirePerWindow;

    bool public seedingClosed;
    uint256 public totalSeededPrincipal;
    uint256 public totalPrincipalRetired;
    uint256 public totalNaraRewardsRecycled;
    uint256 public totalEthRewardsRecycled;
    uint256 public totalUsdcRewardsRecycled;

    /// @notice Linearly decaying rolling retirement load bounded by `maxRetirePerWindow`.
    uint256 public rollingRetiredLoad;
    /// @notice Wall epoch of the most recent positive principal retirement into `reserve`.
    uint64 public lastRetireEpoch;

    TrancheRef[] private _shieldTranches;
    mapping(uint256 positionId => mapping(uint64 generation => bool)) private _isShieldTranche;

    error InvalidBinding();
    error DelegatedDependency(address target);
    error RetiredIdentityForbidden(address account);
    error InvalidTargetConfig();
    error UnauthorizedSeeder();
    error SeedingAlreadyClosed();
    error InvalidSeedArrays();
    error MaxTranchesExceeded();
    error ExceedsTargetPrincipal();
    error InvalidReceiptTransfer();
    error InvalidTrancheIndex();
    error TrancheNotMature(uint64 wallEpoch, uint64 maturityEpoch);
    error CoreStale(uint64 wallEpoch, uint64 backlog);
    error SyncLimitExceeded(uint32 requested, uint32 maximum);
    error Expired();
    error FlashActive();
    error IngressTransferFailed();
    error IsTrackedShieldTranche();
    error NotVaultOwnedPosition();
    error InsufficientExternalCallGas();

    event ShieldTrancheSeeded(
        uint256 indexed positionId,
        uint64 indexed generation,
        uint256 principalAmount,
        uint32 duration,
        uint256 modelWeight
    );
    event ShieldPositionAccepted(
        uint256 indexed tokenId,
        uint256 indexed positionId,
        uint64 indexed generation,
        uint256 principalAmount,
        uint256 modelWeight
    );
    event SeedingSealed(uint256 totalSeededPrincipal);
    event RewardsRecycled(
        uint256 naraToReserve,
        uint256 ethToIngress,
        uint256 usdcToIngress,
        bool ingressFlushed
    );
    event TrancheRolled(
        uint256 indexed oldPositionId,
        uint64 indexed oldGeneration,
        uint256 withdrawnPrincipal,
        uint256 retiredToReserve,
        uint256 recommittedPrincipal,
        uint256 newPositionId,
        uint256 externalActiveModelWeight
    );
    event UnsolicitedPositionSwept(
        uint256 indexed positionId,
        uint64 indexed generation,
        uint256 principalToReserve
    );
    event StrayAssetsSwept(uint256 naraToReserve, uint256 ethToIngress, uint256 usdcToIngress);
    /// @notice Emitted when a centralized `USDC` pause/blacklist blocks an external `USDC` transfer without halting `NARA`/`ETH`.
    /// @param kind `1` = RewardLedger claim deferred, `2` = RewardIngress forward deferred, `3` = stray sweep deferred.
    event UsdcOperationDeferred(uint8 indexed kind, uint256 indexed positionId, uint64 generation, uint256 amountHint);

    constructor(
        address nft_,
        address ingress_,
        address genesisSeeder_,
        uint256 targetPrincipal_,
        uint256 maxRetirePerWindow_
    ) {
        if (genesisSeeder_ == address(0) || genesisSeeder_ == address(this) || genesisSeeder_ == ingress_) {
            revert InvalidBinding();
        }
        if (bytes3(genesisSeeder_.code) == DELEGATION_DESIGNATOR) {
            revert DelegatedDependency(genesisSeeder_);
        }
        if (
            genesisSeeder_ == COMPROMISED_DEPLOYER_V4
                || genesisSeeder_ == EXPOSED_RANGER_V4
                || genesisSeeder_ == RETIRED_RANGE_SAFE_V4
        ) revert RetiredIdentityForbidden(genesisSeeder_);

        _requireContractNotDelegated(nft_);
        _requireContractNotDelegated(ingress_);
        if (nft_ == ingress_) revert InvalidBinding();

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

        _requireContractNotDelegated(eAddress);
        _requireContractNotDelegated(resAddress);
        _requireContractNotDelegated(nAddress);
        _requireContractNotDelegated(uAddress);

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
                || INARATokenFlashSinkV5(nAddress).FLASH_FEE_SINK() != resAddress
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

        if (p.isProtocolSink(address(this)) || p.isProtocolSink(ingress_) || p.isProtocolSink(genesisSeeder_)) {
            revert InvalidBinding();
        }

        AccountingPolicy memory pol = p.policy();
        if (
            pol.policyHash == bytes32(0)
                || pol.epochSeconds != 900
                || pol.minDuration != 96
                || pol.maxDuration != 35_040
                || pol.durationCurve != DurationCurve.V4Quadratic
                || pol.earlyExitEnabled
                || pol.minimumPrincipal == 0
                || pol.maxAdvance == 0
                || pol.rewardAdmissionCap != type(uint256).max / 1e27
                || r.admissionCap() != pol.rewardAdmissionCap
        ) revert InvalidBinding();

        if (IERC20(nAddress).totalSupply() != SUPPLY) revert FlashActive();

        if (
            targetPrincipal_ < pol.minimumPrincipal
                || targetPrincipal_ > MAX_TARGET_PRINCIPAL
                || maxRetirePerWindow_ < pol.minimumPrincipal
                || maxRetirePerWindow_ > targetPrincipal_
        ) revert InvalidTargetConfig();

        nft = receipt;
        principal = p;
        rewards = r;
        ingress = fees;
        engine = NARAEpochEngineV5(eAddress);
        reserve = INARAEmissionReserveV5(resAddress);
        creditLens = new NARARewardLensV5();

        nara = nAddress;
        usdc = uAddress;
        genesisSeeder = genesisSeeder_;

        policyHash = pol.policyHash;
        minimumPrincipal = pol.minimumPrincipal;
        minDuration = pol.minDuration;
        maxDuration = pol.maxDuration;
        engineMaxAdvance = pol.maxAdvance;

        targetPrincipal = targetPrincipal_;
        targetModelWeight = targetPrincipal_ * MAX_DURATION_MULTIPLIER;
        maxRetirePerWindow = maxRetirePerWindow_;
    }

    /// @notice Pure zero-address owner report for explorers and automated security scanners.
    function owner() external pure returns (address) {
        return address(0);
    }

    /// @notice Accepts native ETH from `NARARewardLedgerV5` claims or unsolicited transfers; swept only to `ingress`.
    receive() external payable {}

    /// @notice Pure deterministic O(1) leaky-bucket capacity computation used by `rollMatured` and `vaultStatus`.
    function computeWindowCapacity(
        uint256 currentLoad,
        uint64 lastEpoch,
        uint64 wallEpoch,
        uint256 windowCap
    ) public pure returns (uint256 remainingCapacity, uint256 decayedLoad) {
        if (currentLoad > 0 && wallEpoch > lastEpoch) {
            uint64 elapsed = wallEpoch - lastEpoch;
            if (elapsed >= RETIRE_WINDOW_EPOCHS) {
                decayedLoad = 0;
            } else if (windowCap <= type(uint256).max / RETIRE_WINDOW_EPOCHS) {
                uint256 decay = (windowCap * elapsed) / RETIRE_WINDOW_EPOCHS;
                decayedLoad = currentLoad > decay ? currentLoad - decay : 0;
            } else {
                uint256 decay = (windowCap / RETIRE_WINDOW_EPOCHS) * elapsed;
                decayedLoad = currentLoad > decay ? currentLoad - decay : 0;
            }
        } else {
            decayedLoad = currentLoad;
        }
        remainingCapacity = windowCap > decayedLoad ? windowCap - decayedLoad : 0;
    }

    /// @notice Pure deterministic rollover/retirement splitter enforcing `targetWeight`, `windowRemaining`, and `minPrincipal`.
    function computeRollAllocation(
        uint256 withdrawn,
        uint256 targetWeight,
        uint256 externalActiveWeight,
        uint256 otherCommittedShieldWeight,
        uint256 windowRemaining,
        uint256 minPrincipal
    ) public pure returns (uint256 retiredToReserve, uint256 recommittedPrincipal) {
        uint256 requiredShieldWeight =
            targetWeight > externalActiveWeight ? targetWeight - externalActiveWeight : 0;
        uint256 missingShieldWeight =
            requiredShieldWeight > otherCommittedShieldWeight
                ? requiredShieldWeight - otherCommittedShieldWeight
                : 0;

        uint256 neededPrincipal = (missingShieldWeight / MAX_DURATION_MULTIPLIER)
            + (missingShieldWeight % MAX_DURATION_MULTIPLIER == 0 ? 0 : 1);

        uint256 uncappedRecommit = neededPrincipal < withdrawn ? neededPrincipal : withdrawn;
        uint256 uncappedRetire = withdrawn - uncappedRecommit;

        retiredToReserve = uncappedRetire < windowRemaining ? uncappedRetire : windowRemaining;
        recommittedPrincipal = withdrawn - retiredToReserve;

        if (recommittedPrincipal > 0 && recommittedPrincipal < minPrincipal) {
            if (withdrawn <= windowRemaining) {
                retiredToReserve = withdrawn;
                recommittedPrincipal = 0;
            } else if (withdrawn >= minPrincipal) {
                recommittedPrincipal = minPrincipal;
                retiredToReserve = withdrawn - minPrincipal;
            }
        }
    }

    /// @notice Number of active (unwithdrawn) Shield tranches currently managed by this vault.
    function activeTrancheCount() external view returns (uint256) {
        return _shieldTranches.length;
    }

    /// @notice Returns the `(positionId, generation)` reference at `index`.
    function shieldTranche(uint256 index) external view returns (TrancheRef memory) {
        if (index >= _shieldTranches.length) revert InvalidTrancheIndex();
        return _shieldTranches[index];
    }

    /// @notice Returns all active `(positionId, generation)` Shield tranche references.
    function allShieldTranches() external view returns (TrancheRef[] memory) {
        return _shieldTranches;
    }

    /// @notice Returns whether `(positionId, generation)` is or was an official Shield tranche.
    function isShieldTranche(uint256 positionId, uint64 generation) external view returns (bool) {
        return _isShieldTranche[positionId][generation];
    }

    /// @notice Seeds initial Genesis Shield tranches directly from `genesisSeeder` NARA allowance.
    /// @dev Initial durations may span `[minDuration, maxDuration]` (e.g., staggered maturities or uniform 365d).
    /// Once `totalSeededPrincipal == targetPrincipal` or `sealAfter == true`, seeding closes permanently.
    function seedShield(
        uint256[] calldata amounts,
        uint32[] calldata durations,
        uint32 maxAdvanceEpochs,
        bool sealAfter,
        uint64 deadline
    ) external nonReentrant {
        if (seedingClosed) revert SeedingAlreadyClosed();
        if (msg.sender != genesisSeeder) revert UnauthorizedSeeder();
        if (block.timestamp > deadline) revert Expired();
        _requireSettledSupply();

        uint256 count = amounts.length;
        if (count == 0 || count != durations.length) revert InvalidSeedArrays();
        if (_shieldTranches.length + count > MAX_SHIELD_TRANCHES) revert MaxTranchesExceeded();

        uint256 totalAmount;
        for (uint256 i; i < count; ++i) {
            uint256 amt = amounts[i];
            uint32 dur = durations[i];
            if (amt < minimumPrincipal || dur < minDuration || dur > maxDuration) revert InvalidSeedArrays();
            totalAmount += amt;
        }
        uint256 newSeededTotal = totalSeededPrincipal + totalAmount;
        if (newSeededTotal > targetPrincipal) revert ExceedsTargetPrincipal();

        _syncToWall(maxAdvanceEpochs);

        totalSeededPrincipal = newSeededTotal;
        bool sealedNow = sealAfter || newSeededTotal == targetPrincipal;
        if (sealedNow) {
            seedingClosed = true;
        }

        IERC20(nara).safeTransferFrom(msg.sender, address(this), totalAmount);
        IERC20(nara).forceApprove(address(principal), totalAmount);

        for (uint256 i; i < count; ++i) {
            uint256 posId = principal.nextPositionId();
            _shieldTranches.push(TrancheRef({positionId: posId, generation: 1}));
            _isShieldTranche[posId][1] = true;

            principal.create(
                CreateRequest({
                    amount: amounts[i],
                    duration: durations[i],
                    expectedPolicyHash: policyHash,
                    deadline: deadline
                })
            );
            PositionState memory s = principal.position(posId, 1);
            if (
                s.generationOwner != address(this)
                    || s.principal != amounts[i]
                    || s.withdrawn
                    || s.rewardWeight != s.modelWeight
            ) revert InvalidBinding();

            emit ShieldTrancheSeeded(posId, 1, amounts[i], durations[i], s.modelWeight);
        }

        IERC20(nara).forceApprove(address(principal), 0);

        if (sealedNow) {
            emit SeedingSealed(newSeededTotal);
        }
    }

    /// @notice Accepts an existing active `NARAPositionNFTV5` transferred via `safeTransferFrom` from `genesisSeeder`.
    /// @dev Reverts transfers from any other sender so retail users cannot accidentally lock their NFTs here.
    function onERC721Received(
        address,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override nonReentrant returns (bytes4) {
        if (msg.sender != address(nft)) revert InvalidReceiptTransfer();
        if (seedingClosed) revert SeedingAlreadyClosed();
        if (from != genesisSeeder) revert UnauthorizedSeeder();
        _requireSettledSupply();

        bool sealRequested = data.length == 32 && abi.decode(data, (bool));
        _registerIncomingShieldNFT(tokenId, sealRequested);

        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Registers a vault-owned active `NARAPositionNFTV5` into `_shieldTranches` if `genesisSeeder`
    /// accidentally used raw `ERC721.transferFrom` instead of `safeTransferFrom` before `seedingClosed`.
    function adoptSeededNFT(uint256 tokenId, bool sealAfter) external nonReentrant {
        if (seedingClosed) revert SeedingAlreadyClosed();
        if (msg.sender != genesisSeeder) revert UnauthorizedSeeder();
        _requireSettledSupply();
        _registerIncomingShieldNFT(tokenId, sealAfter);
    }

    /// @notice Permanently closes seeding early if `genesisSeeder` chooses to seed less than `targetPrincipal`.
    /// @dev `targetModelWeight` (`4 * targetPrincipal`) remains the immutable external-weight threshold before retirement begins.
    function sealSeeding() external nonReentrant {
        if (seedingClosed) revert SeedingAlreadyClosed();
        if (msg.sender != genesisSeeder) revert UnauthorizedSeeder();
        seedingClosed = true;
        emit SeedingSealed(totalSeededPrincipal);
    }

    /// @notice Permissionlessly claims settled rewards across all active Shield tranches and routes:
    ///  - `100%` of `NARA` rewards into `NARAEmissionReserveV5.fund(...)`
    ///  - `100%` of `ETH` & `USDC` rewards into `NARARewardIngressV5` (and optionally flushes into `RewardLedger`).
    function recycleRewards(bool flushIngress)
        external
        nonReentrant
        returns (uint256 naraRecycled, uint256 ethRecycled, uint256 usdcRecycled)
    {
        _requireSettledSupply();
        uint256 len = _shieldTranches.length;
        for (uint256 i; i < len; ++i) {
            TrancheRef memory ref = _shieldTranches[i];
            (uint256 n, uint256 e, uint256 u) = _claimPositionRewards(ref.positionId, ref.generation);
            naraRecycled += n;
            ethRecycled += e;
            usdcRecycled += u;
        }
        _finalizeRecycledRewards(naraRecycled, ethRecycled, usdcRecycled, flushIngress);
    }

    /// @notice Permissionlessly claims and recycles settled rewards for a single Shield tranche at `trancheIndex`.
    function recycleTrancheRewards(uint256 trancheIndex, bool flushIngress)
        external
        nonReentrant
        returns (uint256 naraRecycled, uint256 ethRecycled, uint256 usdcRecycled)
    {
        _requireSettledSupply();
        if (trancheIndex >= _shieldTranches.length) revert InvalidTrancheIndex();
        TrancheRef memory ref = _shieldTranches[trancheIndex];
        (naraRecycled, ethRecycled, usdcRecycled) = _claimPositionRewards(ref.positionId, ref.generation);
        _finalizeRecycledRewards(naraRecycled, ethRecycled, usdcRecycled, flushIngress);
    }

    /// @notice Permissionlessly claims settled rewards for any vault-owned `(positionId, generation)` — including
    /// unsolicited `transferFrom` positions OR retired historical Shield generations with deferred `USDC` claims.
    function recyclePositionRewardsById(
        uint256 positionId,
        uint64 generation,
        bool flushIngress
    ) external nonReentrant returns (uint256 naraRecycled, uint256 ethRecycled, uint256 usdcRecycled) {
        _requireSettledSupply();
        PositionState memory p = principal.position(positionId, generation);
        if (p.generationOwner != address(this)) revert NotVaultOwnedPosition();

        (naraRecycled, ethRecycled, usdcRecycled) = _claimPositionRewards(positionId, generation);
        _finalizeRecycledRewards(naraRecycled, ethRecycled, usdcRecycled, flushIngress);
    }

    /// @notice Permissionlessly rolls or retires a matured Shield tranche at `trancheIndex`.
    /// @dev Synchronizes epochs up to `wallEpoch`, claims settled rewards across `[activation, effectiveEnd)`,
    /// withdraws matured principal, retires the portion replaced by organic external user commitments into
    /// `NARAEmissionReserveV5.fund(...)` (bounded by the continuous 30-day leaky bucket `maxRetirePerWindow`),
    /// and re-commits any still-needed Shield balance for `365 days` (`35,040` epochs @ `4.00x`).
    function rollMatured(
        uint256 trancheIndex,
        uint32 maxAdvanceEpochs,
        bool flushIngress,
        uint64 deadline
    )
        external
        nonReentrant
        returns (uint256 retiredToReserve, uint256 recommittedPrincipal, uint256 newPositionId)
    {
        if (block.timestamp > deadline) revert Expired();
        _requireSettledSupply();
        if (trancheIndex >= _shieldTranches.length) revert InvalidTrancheIndex();

        uint64 wall = _syncToWall(maxAdvanceEpochs);

        TrancheRef memory ref = _shieldTranches[trancheIndex];
        PositionState memory pos = principal.position(ref.positionId, ref.generation);
        if (pos.generationOwner != address(this) || pos.withdrawn) revert InvalidBinding();
        if (wall < pos.maturity || wall < pos.effectiveEnd) revert TrancheNotMature(wall, pos.maturity);

        // 1. Claim settled lifetime rewards (NARA + ETH unconditional; USDC fault-isolated if paused/blacklisted).
        (uint256 naraClaimed, uint256 ethClaimed, uint256 usdcClaimed) =
            _claimPositionRewards(ref.positionId, ref.generation);

        // 2. Withdraw matured principal to this contract.
        uint256 withdrawn = principal.withdrawPrincipal(ref.positionId, ref.generation, address(this));

        // 3. Measure genuine external user model weight vs remaining Shield commitments.
        PrincipalLedgerStateV5 memory ps = principal.principalAccounting();
        (uint256 vaultActiveInLedgerWeight, uint256 otherCommittedShieldWeight) =
            _measureOtherTranches(trancheIndex, wall);

        uint256 externalActiveWeight =
            ps.activeModelWeight > vaultActiveInLedgerWeight ? ps.activeModelWeight - vaultActiveInLedgerWeight : 0;

        // 4. Compute O(1) continuous leaky-bucket capacity and exact retirement/recommit split.
        (uint256 windowRemaining, uint256 decayedLoad) =
            computeWindowCapacity(rollingRetiredLoad, lastRetireEpoch, wall, maxRetirePerWindow);

        (retiredToReserve, recommittedPrincipal) = computeRollAllocation(
            withdrawn,
            targetModelWeight,
            externalActiveWeight,
            otherCommittedShieldWeight,
            windowRemaining,
            minimumPrincipal
        );

        // 5. Effects: update all vault accounting and tranche state before external create/fund/forward calls.
        if (retiredToReserve > 0) {
            rollingRetiredLoad = decayedLoad + retiredToReserve;
            lastRetireEpoch = wall;
            totalPrincipalRetired += retiredToReserve;
        }
        if (naraClaimed > 0) {
            totalNaraRewardsRecycled += naraClaimed;
        }
        if (ethClaimed > 0) {
            totalEthRewardsRecycled += ethClaimed;
        }
        if (usdcClaimed > 0) {
            totalUsdcRewardsRecycled += usdcClaimed;
        }

        if (recommittedPrincipal > 0) {
            newPositionId = principal.nextPositionId();
            _shieldTranches[trancheIndex] = TrancheRef({positionId: newPositionId, generation: 1});
            _isShieldTranche[newPositionId][1] = true;
        } else {
            uint256 lastIdx = _shieldTranches.length - 1;
            if (trancheIndex != lastIdx) {
                _shieldTranches[trancheIndex] = _shieldTranches[lastIdx];
            }
            _shieldTranches.pop();
        }

        // 6. Interactions: re-commit needed Shield portion at `maxDuration` (`365D @ 4.00x`).
        if (recommittedPrincipal > 0) {
            IERC20(nara).forceApprove(address(principal), recommittedPrincipal);
            principal.create(
                CreateRequest({
                    amount: recommittedPrincipal,
                    duration: maxDuration,
                    expectedPolicyHash: policyHash,
                    deadline: deadline
                })
            );
            IERC20(nara).forceApprove(address(principal), 0);

            PositionState memory created = principal.position(newPositionId, 1);
            if (
                created.generationOwner != address(this)
                    || created.principal != recommittedPrincipal
                    || created.withdrawn
                    || created.rewardWeight != created.modelWeight
            ) revert InvalidBinding();
        }

        // 7. Route retired principal + claimed NARA rewards into Reserve, and cash rewards into RewardIngress.
        uint256 totalNaraToReserve = retiredToReserve + naraClaimed;
        if (totalNaraToReserve > 0) {
            _fundReserve(totalNaraToReserve);
        }

        bool ingressFlushed = flushIngress ? _flushIngressCash() : false;
        if (naraClaimed > 0 || ethClaimed > 0 || usdcClaimed > 0 || ingressFlushed) {
            emit RewardsRecycled(naraClaimed, ethClaimed, usdcClaimed, ingressFlushed);
        }

        emit TrancheRolled(
            ref.positionId,
            ref.generation,
            withdrawn,
            retiredToReserve,
            recommittedPrincipal,
            newPositionId,
            externalActiveWeight
        );
    }

    /// @notice Sweeps an unsolicited matured `NARAP` position (`transferFrom`) 100% into `Reserve` + `RewardIngress`.
    function sweepUnsolicitedMaturedPosition(
        uint256 positionId,
        uint64 generation,
        uint32 maxAdvanceEpochs,
        bool flushIngress
    ) external nonReentrant returns (uint256 principalToReserve) {
        _requireSettledSupply();
        if (_isShieldTranche[positionId][generation]) revert IsTrackedShieldTranche();

        uint64 wall = _syncToWall(maxAdvanceEpochs);
        PositionState memory p = principal.position(positionId, generation);
        if (p.generationOwner != address(this) || p.withdrawn) revert NotVaultOwnedPosition();
        if (wall < p.maturity || wall < p.effectiveEnd) revert TrancheNotMature(wall, p.maturity);

        (uint256 naraClaimed, uint256 ethClaimed, uint256 usdcClaimed) =
            _claimPositionRewards(positionId, generation);
        principalToReserve = principal.withdrawPrincipal(positionId, generation, address(this));

        if (naraClaimed > 0) totalNaraRewardsRecycled += naraClaimed;
        if (ethClaimed > 0) totalEthRewardsRecycled += ethClaimed;
        if (usdcClaimed > 0) totalUsdcRewardsRecycled += usdcClaimed;

        uint256 totalNara = principalToReserve + naraClaimed;
        if (totalNara > 0) {
            _fundReserve(totalNara);
        }

        bool ingressFlushed = flushIngress ? _flushIngressCash() : false;
        if (naraClaimed > 0 || ethClaimed > 0 || usdcClaimed > 0 || ingressFlushed) {
            emit RewardsRecycled(naraClaimed, ethClaimed, usdcClaimed, ingressFlushed);
        }
        emit UnsolicitedPositionSwept(positionId, generation, principalToReserve);
    }

    /// @notice Sweeps any unsolicited raw `NARA` to `Reserve` and raw `ETH` / `USDC` to `RewardIngress`.
    /// @dev Fault-isolates `USDC` so a Circle pause/blacklist never blocks sweeping `NARA` or `ETH`.
    function sweepStrayAssets(bool flushIngress)
        external
        nonReentrant
        returns (uint256 naraSwept, uint256 ethSwept, uint256 usdcSwept)
    {
        _requireSettledSupply();
        naraSwept = IERC20(nara).balanceOf(address(this));
        if (naraSwept > 0) {
            _fundReserve(naraSwept);
        }

        ethSwept = address(this).balance;
        if (ethSwept > 0) {
            (bool ok,) = payable(address(ingress)).call{value: ethSwept}("");
            if (!ok) revert IngressTransferFailed();
        }

        uint256 usdcBal = IERC20(usdc).balanceOf(address(this));
        if (usdcBal > 0) {
            if (gasleft() < EXTERNAL_USDC_MIN_GAS) revert InsufficientExternalCallGas();
            if (_tryTransferUsdc(address(ingress), usdcBal)) {
                uint256 afterBal = IERC20(usdc).balanceOf(address(this));
                usdcSwept = usdcBal > afterBal ? usdcBal - afterBal : 0;
            } else {
                emit UsdcOperationDeferred(3, 0, 0, usdcBal);
            }
        }

        if (flushIngress) {
            _flushIngressCash();
        }
        if (naraSwept > 0 || ethSwept > 0 || usdcSwept > 0) {
            emit StrayAssetsSwept(naraSwept, ethSwept, usdcSwept);
        }
    }

    /// @notice Coherent read-only snapshot of the Genesis Shield's live principal, weights, retirement progress, and claimable rewards.
    function vaultStatus() external view returns (ShieldVaultStatus memory status) {
        status.seedingClosed = seedingClosed;
        uint256 len = _shieldTranches.length;
        status.activeTrancheCount = len;
        status.totalSeededPrincipal = totalSeededPrincipal;
        status.totalPrincipalRetired = totalPrincipalRetired;
        status.totalNaraRewardsRecycled = totalNaraRewardsRecycled;
        status.totalEthRewardsRecycled = totalEthRewardsRecycled;
        status.totalUsdcRewardsRecycled = totalUsdcRewardsRecycled;
        status.lastRetireEpoch = lastRetireEpoch;

        EpochClock memory c = engine.clock();
        PrincipalLedgerStateV5 memory ps = principal.principalAccounting();
        uint64 opened = ps.openedEpoch;

        for (uint256 i; i < len; ++i) {
            TrancheRef memory ref = _shieldTranches[i];
            PositionState memory p = principal.position(ref.positionId, ref.generation);
            if (!p.withdrawn) {
                status.activeShieldPrincipal += p.principal;
                if (c.started && c.wallEpoch < p.effectiveEnd) {
                    status.committedShieldModelWeight += p.modelWeight;
                }
            }
            if (p.activation <= opened && opened < p.effectiveEnd) {
                status.activeShieldModelWeight += p.modelWeight;
            }
            if (c.started) {
                RewardCredit memory cn = creditLens.credit(rewards, ref.positionId, ref.generation, RewardAsset.NARA);
                RewardCredit memory ce = creditLens.credit(rewards, ref.positionId, ref.generation, RewardAsset.ETH);
                RewardCredit memory cu = creditLens.credit(rewards, ref.positionId, ref.generation, RewardAsset.USDC);
                status.claimableNara += cn.claimable;
                status.claimableEth += ce.claimable;
                status.claimableUsdc += cu.claimable;
            }
        }

        status.externalActiveModelWeight =
            ps.activeModelWeight > status.activeShieldModelWeight ? ps.activeModelWeight - status.activeShieldModelWeight : 0;
        status.requiredShieldModelWeight =
            targetModelWeight > status.externalActiveModelWeight ? targetModelWeight - status.externalActiveModelWeight : 0;

        if (c.started) {
            (status.windowRemainingCapacity, status.decayedRetiredLoad) =
                computeWindowCapacity(rollingRetiredLoad, lastRetireEpoch, c.wallEpoch, maxRetirePerWindow);
        } else {
            status.decayedRetiredLoad = rollingRetiredLoad;
            status.windowRemainingCapacity =
                maxRetirePerWindow > rollingRetiredLoad ? maxRetirePerWindow - rollingRetiredLoad : 0;
        }
    }

    function _registerIncomingShieldNFT(uint256 tokenId, bool sealRequested) private {
        if (_shieldTranches.length >= MAX_SHIELD_TRANCHES) revert MaxTranchesExceeded();

        NARAPositionNFTV5.Receipt memory r = nft.receiptInfo(tokenId);
        if (r.kind != NARAPositionNFTV5.ReceiptKind.Active || nft.ownerOf(tokenId) != address(this)) {
            revert InvalidReceiptTransfer();
        }

        PositionState memory p = principal.position(r.positionId, r.generation);
        if (
            p.generationOwner != address(this)
                || p.withdrawn
                || p.effectiveEnd != p.maturity
                || p.rewardWeight != p.modelWeight
                || p.principal < minimumPrincipal
                || _isShieldTranche[r.positionId][r.generation]
        ) revert InvalidReceiptTransfer();

        // Reject any scheduled future rarity cutover (`t.cutover > openedEpoch`) masked by boundary projection.
        RewardWeightStateV5 memory rw = principal.rewardWeightState(r.positionId, r.generation);
        if (
            rw.cutover != 0
                || rw.previousWeight != p.modelWeight
                || rw.nextWeight != p.modelWeight
                || principal.rarityTier(r.positionId, r.generation) != 0
        ) revert InvalidReceiptTransfer();

        EpochClock memory c = engine.clock();
        if (!c.started || c.wallEpoch >= p.maturity) revert InvalidReceiptTransfer();

        uint256 newSeededTotal = totalSeededPrincipal + p.principal;
        if (newSeededTotal > targetPrincipal) revert ExceedsTargetPrincipal();

        _shieldTranches.push(TrancheRef({positionId: r.positionId, generation: r.generation}));
        _isShieldTranche[r.positionId][r.generation] = true;
        totalSeededPrincipal = newSeededTotal;

        bool sealedNow = sealRequested || newSeededTotal == targetPrincipal;
        if (sealedNow) {
            seedingClosed = true;
        }

        emit ShieldPositionAccepted(tokenId, r.positionId, r.generation, p.principal, p.modelWeight);
        if (sealedNow) {
            emit SeedingSealed(newSeededTotal);
        }
    }

    function _measureOtherTranches(uint256 skipIndex, uint64 wall)
        private
        view
        returns (uint256 vaultActiveInLedgerWeight, uint256 otherCommittedShieldWeight)
    {
        uint256 len = _shieldTranches.length;
        for (uint256 i; i < len; ++i) {
            if (i == skipIndex) continue;
            TrancheRef memory ref = _shieldTranches[i];
            PositionState memory other = principal.position(ref.positionId, ref.generation);
            if (other.activation <= wall && wall < other.effectiveEnd) {
                vaultActiveInLedgerWeight += other.modelWeight;
            }
            if (!other.withdrawn && wall < other.effectiveEnd) {
                otherCommittedShieldWeight += other.modelWeight;
            }
        }
    }

    function _claimPositionRewards(uint256 positionId, uint64 generation)
        private
        returns (uint256 naraClaimed, uint256 ethClaimed, uint256 usdcClaimed)
    {
        // `reserve` is in `principal.isProtocolSink`, so NARA claims to `address(this)` and batches into `reserve.fund`.
        // `ingress` is NOT in `isProtocolSink`, so ETH and USDC stream directly from `RewardLedger` into `RewardIngress`.
        naraClaimed = rewards.claim(positionId, generation, RewardAsset.NARA, address(this));
        ethClaimed = rewards.claim(positionId, generation, RewardAsset.ETH, address(ingress));

        RewardCredit memory cu = creditLens.credit(rewards, positionId, generation, RewardAsset.USDC);
        if (cu.claimable > 0) {
            if (gasleft() < EXTERNAL_USDC_MIN_GAS) revert InsufficientExternalCallGas();
            try rewards.claim{gas: EXTERNAL_USDC_CALL_GAS}(
                positionId,
                generation,
                RewardAsset.USDC,
                address(ingress)
            ) returns (uint256 u) {
                usdcClaimed = u;
            } catch {
                emit UsdcOperationDeferred(1, positionId, generation, cu.claimable);
            }
        }
    }

    function _finalizeRecycledRewards(
        uint256 naraRecycled,
        uint256 ethRecycled,
        uint256 usdcRecycled,
        bool flushIngress
    ) private {
        if (naraRecycled > 0) {
            totalNaraRewardsRecycled += naraRecycled;
        }
        if (ethRecycled > 0) {
            totalEthRewardsRecycled += ethRecycled;
        }
        if (usdcRecycled > 0) {
            totalUsdcRewardsRecycled += usdcRecycled;
        }

        if (naraRecycled > 0) {
            _fundReserve(naraRecycled);
        }

        bool ingressFlushed = flushIngress ? _flushIngressCash() : false;
        if (naraRecycled > 0 || ethRecycled > 0 || usdcRecycled > 0 || ingressFlushed) {
            emit RewardsRecycled(naraRecycled, ethRecycled, usdcRecycled, ingressFlushed);
        }
    }

    function _fundReserve(uint256 amount) private {
        IERC20(nara).forceApprove(address(reserve), amount);
        reserve.fund(amount);
        IERC20(nara).forceApprove(address(reserve), 0);
    }

    function _flushIngressCash() private returns (bool anyFlushedAndClean) {
        EpochClock memory c = engine.clock();
        RewardLedgerStateV5 memory rs = rewards.rewardState();
        if (!c.started || c.backlog != 0 || rs.openedEpoch != c.wallEpoch || rs.nextCheckpoint != c.wallEpoch) {
            return false;
        }

        bool flushedAny;
        uint256 pendingEth = ingress.pending(RewardAsset.ETH);
        if (pendingEth > 0) {
            ingress.forward(RewardAsset.ETH, pendingEth);
            flushedAny = true;
        }
        uint256 pendingUsdc = ingress.pending(RewardAsset.USDC);
        bool usdcDeferred;
        if (pendingUsdc > 0) {
            if (gasleft() < EXTERNAL_USDC_MIN_GAS) revert InsufficientExternalCallGas();
            try ingress.forward{gas: EXTERNAL_USDC_CALL_GAS}(RewardAsset.USDC, pendingUsdc) {
                flushedAny = true;
            } catch {
                usdcDeferred = true;
                emit UsdcOperationDeferred(2, 0, 0, pendingUsdc);
            }
        }
        anyFlushedAndClean = flushedAny && !usdcDeferred;
    }

    /// @dev Bounded-gas, return-bomb-immune ERC-20 `transfer(address,uint256)` helper for `usdc`.
    function _tryTransferUsdc(address to, uint256 amount) private returns (bool ok) {
        address token = usdc;
        uint256 gasCap = EXTERNAL_USDC_CALL_GAS;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 0xa9059cbb00000000000000000000000000000000000000000000000000000000)
            mstore(add(ptr, 0x04), and(to, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(ptr, 0x24), amount)
            mstore(0x00, 0)
            let success := call(gasCap, token, 0, ptr, 0x44, 0x00, 0x20)
            let rdsize := returndatasize()
            ok := and(
                success,
                or(
                    and(gt(rdsize, 0x1f), eq(mload(0x00), 1)),
                    and(iszero(rdsize), gt(extcodesize(token), 0))
                )
            )
        }
    }

    function _syncToWall(uint32 maxAdvanceEpochs) private returns (uint64 wall) {
        if (maxAdvanceEpochs > MAX_SYNC_EPOCHS) {
            revert SyncLimitExceeded(maxAdvanceEpochs, MAX_SYNC_EPOCHS);
        }
        EpochClock memory c = engine.clock();
        if (!c.started) revert InvalidBinding();

        uint32 remainingBudget = maxAdvanceEpochs;
        while (c.backlog > 0 && remainingBudget > 0) {
            uint32 chunk = c.backlog < remainingBudget ? uint32(c.backlog) : remainingBudget;
            if (chunk > engineMaxAdvance) chunk = engineMaxAdvance;
            engine.advance(chunk);
            remainingBudget -= chunk;
            c = engine.clock();
        }
        if (c.backlog != 0) revert CoreStale(c.wallEpoch, c.backlog);

        wall = c.wallEpoch;
        PrincipalLedgerStateV5 memory ps = principal.principalAccounting();
        RewardLedgerStateV5 memory rs = rewards.rewardState();
        if (ps.openedEpoch != wall || rs.openedEpoch != wall || rs.nextCheckpoint != wall) {
            revert CoreStale(wall, 1);
        }
    }

    function _requireSettledSupply() private view {
        if (IERC20(nara).totalSupply() != SUPPLY) revert FlashActive();
    }

    function _requireContractNotDelegated(address target) private view {
        if (target.code.length == 0) revert InvalidBinding();
        if (bytes3(target.code) == DELEGATION_DESIGNATOR) revert DelegatedDependency(target);
    }
}
