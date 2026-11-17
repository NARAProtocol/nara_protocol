// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

// TEST ONLY. Aggregated deployment/oracle code is never protocol inventory.
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {NARATokenV5} from "../NARATokenV5.sol";
import {NARAEmissionReserveV5} from "../reserve/NARAEmissionReserveV5.sol";
import {NARAEmissionModelV5} from "../engine/NARAEmissionModelV5.sol";
import {EmissionConfig, EmissionState, EmissionInputs, EmissionQuote} from "../engine/NARAEmissionTypesV5.sol";
import {NARAPrincipalLedgerV5} from "../modular/NARAPrincipalLedgerV5.sol";
import {CommonRechargeRequestV5, CommonRechargeBlockerV5} from "../modular/NARAPrincipalPreviewV5.sol";
import {NARAEpochEngineV5, EpochFundingStateV5} from "../modular/NARAEpochEngineV5.sol";
import {NARARewardLedgerV5} from "../modular/NARARewardLedgerV5.sol";
import {NARARewardLensV5} from "../modular/NARARewardLensV5.sol";
// Include every selected read module in the exact static-analysis closure.
import {NARAPrincipalLensV5} from "../modular/NARAPrincipalLensV5.sol";
import {NARAFinancialLensV5} from "../modular/NARAFinancialLensV5.sol";
// The Ingress is deployed as the Sale's fee sink (P3.6); forwarding stays outside these actions.
import {NARAPositionNFTV5} from "../modular/NARAPositionNFTV5.sol";
import {NARAPositionSaleV5} from "../modular/NARAPositionSaleV5.sol";
import {NARARewardIngressV5} from "../modular/NARARewardIngressV5.sol";
import {NARAPositionLensV5} from "../modular/NARAPositionLensV5.sol";
import {NARAPositionRendererV5} from "../modular/NARAPositionRendererV5.sol";
import {NARAPositionCardV5} from "../modular/NARAPositionCardV5.sol";
import {PositionViewV5} from "../modular/NARAPositionViewTypesV5.sol";
import {PrincipalLedgerStateV5, RewardLedgerStateV5, RewardAccountingV5, FrameAwardV5} from "../modular/NARAModuleInterfacesV5.sol";
import {AccountingPolicy, DurationCurve, EpochClock, CreateRequest, PositionState, RewardAsset,
    RewardCredit, ReserveState, AdvanceResult} from "../interfaces/NARAAccountingTypesV5.sol";
// Retain the strict baseline's test-only source closure; no NFT stub is deployed.
import {ModularNFTStub} from "../modular-test/ModularPrincipalTestHelpers.sol";
import {NARAMockForgeV5} from "../modular-test/NARAMockForgeV5.sol";
import {NARAForgeV5} from "../modular/NARAForgeV5.sol";
import {NARAForgeQuoteV5} from "../modular/NARAForgeQuoteV5.sol";
import {NARAEntropyAdapterV5} from "../modular/NARAEntropyAdapterV5.sol";
import {NARANullEntropyAdapterV5} from "../modular/NARANullEntropyAdapterV5.sol";
import {NARAMockGovernorV5, NARAMockVRFWrapperV5, NARAHostileEntropyAdapterV5} from "../modular-test/NARAMockVRFWrapperV5.sol";
import {NARALifecycleLedgerV5} from "../modular/NARALifecycleLedgerV5.sol";
import {RollRequestV5, FusionRequestV5, AttemptV5, AttemptStateV5, RollBlockerV5, RechargeAwardedRequestV5} from "../modular/NARAForgeTypesV5.sol";
import {ModularUSDC} from "../modular-test/ModularAssetTestHelpers.sol";
import {CoreFundingFlashProbe} from "../core-test/CoreFundingTestHelpers.sol";
interface EntropyHevmV5 { function warp(uint256 timestamp) external; }

contract ModularFuzzActor is IERC721Receiver {
    address private immutable _harness;
    bool private _rejectNft;
    address private _sale;
    address private _nft;
    address private _nftTarget;
    address private _ethTarget;
    bytes private _nftPayload;
    bytes private _ethPayload;
    uint256 private _nftValue;
    uint256 private _ethValue;
    bool private _saleRejectNft;
    bool private _saleRejectEth;
    bool public nftCallbackSucceeded;
    bool public ethCallbackSucceeded;
    bytes public nftCallbackResult;
    bytes public ethCallbackResult;
    constructor(NARATokenV5 token, NARAPrincipalLedgerV5 principal) {
        _harness = msg.sender; token.approve(address(principal), type(uint256).max);
    }
    function invoke(address target, bytes calldata data) external returns (bool, bytes memory) {
        require(msg.sender == _harness, "harness only"); return target.call(data);
    }
    function invokeValue(address target, bytes calldata data, uint256 value) external returns (bool, bytes memory) {
        require(msg.sender == _harness, "harness only"); return target.call{value: value}(data);
    }
    function bindSale(address sale_, address nft_) external {
        require(msg.sender == _harness && _sale == address(0), "harness only"); _sale = sale_; _nft = nft_;
    }
    function configureNFT(address target, bytes calldata data, uint256 value, bool reject) external {
        require(msg.sender == _harness, "harness only");
        _nftTarget = target; _nftPayload = data; _nftValue = value; _saleRejectNft = reject;
        nftCallbackSucceeded = false; delete nftCallbackResult;
    }
    function configureETH(address target, bytes calldata data, uint256 value, bool reject) external {
        require(msg.sender == _harness, "harness only");
        _ethTarget = target; _ethPayload = data; _ethValue = value; _saleRejectEth = reject;
        ethCallbackSucceeded = false; delete ethCallbackResult;
    }
    function batch(address[] calldata targets, bytes[] calldata payloads) external {
        require(msg.sender == _harness || msg.sender == address(this), "actor batch only");
        require(targets.length == payloads.length && targets.length <= 3, "actor batch shape");
        for (uint256 i; i < targets.length; ++i) {
            (bool ok, bytes memory data) = targets[i].call(payloads[i]);
            if (!ok) assembly ("memory-safe") { revert(add(data, 32), mload(data)) }
        }
    }
    function rejectNft(bool value) external { require(msg.sender == _harness, "harness only"); _rejectNft = value; }
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        require(!_rejectNft, "receiver rejection");
        if (msg.sender == _nft && _nftTarget != address(0))
            (nftCallbackSucceeded, nftCallbackResult) = _nftTarget.call{value: _nftValue}(_nftPayload);
        if (_saleRejectNft) return bytes4(0);
        return IERC721Receiver.onERC721Received.selector;
    }
    receive() external payable {
        if (msg.sender == _sale) {
            require(!_saleRejectEth, "sale actor payment rejected");
            if (_ethTarget != address(0)) (ethCallbackSucceeded, ethCallbackResult) = _ethTarget.call{value: _ethValue}(_ethPayload);
        }
    }
}

/// @dev TEST ONLY: exercise forced surplus without manufacturing account balances.
contract ModularSaleForceETH {
    constructor(address payable recipient) payable { selfdestruct(recipient); }
}

/// @notice Stateful Common generation/recharge graph with separately owned principal,
/// rewards and epochs. The oracle accrues each position at each close, independently
/// of the implementation's lazy index-difference claim calculation.
/// @dev The pure emission calculator is shared: independent equation correctness
/// comes from the separate BigInt tests. USDC and actors remain fixtures; actual
/// NFT, lens, renderer and card modules are exercised without changing their code.
contract ModularFinancialProperties is IERC721Receiver {
    uint256 private constant SUPPLY = 1_000_000 ether;
    uint256 private constant INITIAL = 700_000 ether;
    uint256 private constant RAY = 1e27;
    uint256 private constant MAX_GENERATION_RECORDS = 64;
    uint256 public constant REQUIRED_COVERAGE = (uint256(1) << 32) - 1;
    // P2.10 oracle constants, stated independently of the Engine: T of the reserve-scaled release (B3) and the
    // emission reference's time constant in sampled closes (LIFECYCLE_DESIGN §5.4).
    uint256 private constant RELEASE_HORIZON_EPOCHS = 140_160;
    uint256 private constant REFERENCE_WINDOW = 2_880;

    struct FrameOracle { uint256 headIndexPlusOne; uint256 originTokenId; }
    struct PositionOracle {
        uint256 frameId;
        uint64 generation;
        uint32 duration;
        bytes32 birthTermsHash;
        bool dormantConsumed;
        bool fusionConsumed;
        bool savedDormantNonce;
        uint256 replayDormantNonce;
        uint256 activeTransferNonce;
        uint256 dormantTransferNonce;
        address owner;
        uint256 activeTokenId;
        uint256 dormantTokenId;
        address dormantOwner;
        address approved;
        uint256 amount;
        uint256 weight;
        uint256 previousWeight;
        uint64 weightCutover;
        uint256 baseWeight;
        uint64 created;
        uint64 activation;
        uint64 end;
        uint64 withdrawalBoundary;
        bool withdrawn;
        uint256[3] credits;
        uint256[3] paid;
    }
    struct AssetOracle {
        uint256 custody;
        uint256 pending;
        uint256 bank;
        uint256 baseIndex;
        uint256 rarityIndex;
        uint256 owed;
        uint256 quarantine;
        uint256 admitted;
        uint256 paid;
        uint256 externalReceived;
        uint256 emissions;
    }
    struct SaleOfferOracle {
        uint256 listingId;
        address seller;
        uint256 tokenId;
        uint256 transferNonce;
        uint256 positionId;
        uint64 generation;
        bytes32 termsHash;
        uint256 price;
        uint64 expiry;
        uint256 sellerNonce;
    }
    // PLACEHOLDER lifetime cap for the harness (owner value C5/O4 not yet supplied).
    uint64 private constant SALE_LIFETIME = 30 days;
    uint256 private constant SALE_FEE_BPS = 500;

    NARAEmissionReserveV5 public immutable reserve;
    NARATokenV5 public immutable token;
    NARAEmissionModelV5 public immutable model;
    ModularUSDC public immutable usdc;
    NARAEpochEngineV5 public immutable engine;
    NARAPrincipalLedgerV5 public immutable principal;
    NARARewardLedgerV5 public immutable rewards;
    NARAPositionNFTV5 public immutable nft;
    NARAForgeV5 public immutable forge;
    NARAEntropyAdapterV5 public immutable entropyAdapter;
    NARAMockVRFWrapperV5 public immutable entropyWrapper;
    NARAMockGovernorV5 public immutable entropyGovernor;
    NARAMockGovernorV5 public immutable entropyGuardian;
    NARANullEntropyAdapterV5 public immutable entropyNull;
    NARAHostileEntropyAdapterV5 public immutable entropyHostile;
    NARALifecycleLedgerV5 public immutable lifecycle;
    struct EntropyOracle { bytes32 id; uint256 positionIndex; uint256 requestId; uint256 fee; uint256 word; uint64 deliveredAt; bool terminal; bool failed; bool isFusion; uint8 inputTier; uint256[5] indices; address adapter; }
    EntropyOracle[] private _entropy;
    uint256 public entropyCommits;
    uint256 public fusionCommits;
    uint256 public fusionsFinalized;
    uint256 public fusionsCancelled;
    uint256 public entropyCallbacks;
    uint256 public entropyFinalized;
    uint256 public entropyFailed;
    uint256 public entropyRefunded;
    uint256 public entropyForwarded;
    mapping(address => uint256) private _entropyRefund;
    NARARewardLensV5 public immutable lens;
    NARAPositionLensV5 public immutable positionLens;
    NARAPositionRendererV5 public immutable renderer;
    NARAPositionCardV5 public immutable card;
    CoreFundingFlashProbe public immutable flashProbe;
    NARAPositionSaleV5 public immutable sale;
    NARARewardIngressV5 public immutable ingress;
    uint256[3] public nativeExpected;
    uint256 public initialNative;
    uint256 public saleSurplus;
    uint256 public saleProceedsTotal;
    uint256 public ingressFees;
    uint256 public saleLastId;
    uint256[5] public saleLifecycleModes;
    uint256[5] public salePurchaseContexts;
    uint256[9] public saleStaleModes;
    uint256[15] public saleInputModes;
    uint256[11] public saleCallbackModes;
    mapping(address => uint256) private _sellerNonce;
    mapping(address => uint256) private _proceeds;
    uint256[3] public saleBuyerAssetClaims;
    uint256 public distinctSalePurchases;
    uint256 public selfSalePurchases;
    uint256 public completedSaleClaimCycles;
    uint256 public saleSurplusChecks;
    mapping(uint256 => SaleOfferOracle) private _saleOffers;
    mapping(uint256 => address) private _saleClaimOwner;
    mapping(uint256 => uint8) private _saleFractionMask;
    mapping(uint256 => uint8) private _saleClaimedMask;
    ModularFuzzActor[2] public actors;
    PositionOracle[] private _positions;
    mapping(uint256 => FrameOracle) private _frames;
    uint256 private _frameCount;
    AssetOracle[3] private _assets;
    mapping(uint8 => mapping(uint64 => uint256)) private _buckets;
    mapping(uint64 => uint256) private _fundingAt;
    mapping(uint64 => int256) private _rewardChanges;
    uint64 private _next;
    uint256 private _principalInventory;
    uint256 private _rewardSnapshot;
    int256 private _rewardPending;
    uint256 private _eligible = INITIAL;
    uint256 private _future;
    uint256 private _recognized = INITIAL;
    uint256 private _released;
    uint256 private _sequence = 1;
    uint256 private _unsynced;
    uint256 private _minted;
    EmissionConfig private _config;
    EmissionState private _modelState;
    // P2.10: R_ref = T x floor(maxBaseEmission x dripSplit / 1e18) and the oracle's own (sum, weight, samples).
    uint256 private immutable _referenceRelease;
    uint256 private _referenceSum;
    uint256 private _referenceWeight;
    uint64 private _referenceSamples;
    bool private _violation;
    bytes32 public lastViolation;
    uint256 public coverageMask;
    uint256[32] public coverageCounters;
    uint256 public successfulRecharges;
    uint256 public awardedRecharges;
    uint256 public rechargedWithdrawals;
    uint256[3] public archivedAssetClaims;
    uint256[3] public rechargedAssetClaims;
    uint256[4] public rejectedRechargeModes;
    event CampaignCoverage(uint8 indexed action, uint64 wall, uint64 cursor, uint256 amount);
    // Distinct topics keep an executable source location for each required path
    // when the optimizer merges calls to the common counter helper.
    event PathPrincipalCreated(uint256 amount);
    event PathNaraReceived(uint256 amount);
    event PathEthReceived(uint256 amount);
    event PathUsdcReceived(uint256 amount);
    event PathPulseSettled(uint256 count);
    event PathNaraClaimed(uint256 amount);
    event PathEthClaimed(uint256 amount);
    event PathUsdcClaimed(uint256 amount);
    event PathPrincipalWithdrawn(uint256 amount);
    event PathReserveFunded(uint256 amount);
    event PathSurplusRecognized(uint256 amount);
    event PathFlashMutationRejected(uint256 amount);
    event PathClaimFailureRolledBack(uint256 amount);
    event PathUnauthorizedClaimRejected(uint256 id);
    event PathActiveReceiptTransferred(uint256 id);
    event PathNftReceiverFailureRolledBack(uint256 id);
    event PathDormantMaterialized(uint256 id);
    event PathDormantReceiptTransferred(uint256 id);
    event PathStaleReceiptRejected(uint256 id);
    event PathPositionMetadataRead(uint256 id);
    event PathCommonRecharged(uint256 generation);
    event PathArchivedGenerationClaimed(uint256 amount);
    event PathRechargedGenerationClaimed(uint256 amount);
    event PathRechargeFailureRolledBack(uint256 mode);
    event PathSaleOfferLifecycle(uint256 id);
    event PathSalePurchased(uint256 id);
    event PathSaleSelfPurchased(uint256 id);
    event PathSaleBuyerAssetsClaimed(uint256 id);
    event PathSaleStaleOfferRejected(uint256 mode);
    event PathSaleInputsRejected(uint256 mode);
    event PathSaleCallbacksChecked(uint256 mode);
    event PathSaleSurplusPreserved(uint256 amount);
    event OraclePulseClosed(uint64 indexed epoch, uint256 baseWeight, uint256 rarityWeight,
        uint256[3] allocation, uint256[3] baseIndexDelta, uint256[3] rarityIndexDelta);

    constructor() payable {
        // CREATE nonces of this new contract start at one. Only the twelve new
        // expressions below create contracts before the predicted peers exist.
        reserve = new NARAEmissionReserveV5(address(this), INITIAL); // nonce 1
        token = new NARATokenV5(address(this), address(reserve), "NARA", "NARA"); // 2
        reserve.bindToken(address(token));
        model = new NARAEmissionModelV5(); // 3
        usdc = new ModularUSDC(); // 4
        _config = EmissionConfig(SUPPLY, 8e15, 25e16, 125e16, 9e17, 5e17, 5e17,
            85e16, 1000104e12, 2e17, 5 ether, 133e13, 9991e14);
        _modelState = EmissionState(5e17, 0, 0, 0);
        _referenceRelease = RELEASE_HORIZON_EPOCHS * (_config.maxBaseEmission * _config.dripSplitWad / 1e18);
        AccountingPolicy memory policy = AccountingPolicy(bytes32(0), 1, 900, RAY, 1, 96, 35_040,
            DurationCurve.V4Quadratic, false, 0, 1, 96, type(uint256).max / RAY); // P2.9: the pinned curve and exact cap
        engine = new NARAEpochEngineV5(address(this), address(token), address(reserve), address(model),
            INITIAL, policy, _config, _modelState); // 5
        address predictedRewards = address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", address(this), uint8(7))))));
        address predictedNFT = address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", address(this), uint8(11))))));
        address predictedForge = address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", address(this), uint8(16))))));
        principal = new NARAPrincipalLedgerV5(address(this), address(token), address(engine), predictedRewards, predictedNFT, predictedForge); // 6
        rewards = new NARARewardLedgerV5(address(engine), address(principal), address(usdc)); // 7
        lens = new NARARewardLensV5(); // 8
        positionLens = new NARAPositionLensV5(address(lens)); // 9
        card = new NARAPositionCardV5(); // 10
        nft = new NARAPositionNFTV5(address(principal), address(positionLens), address(card), address(this)); // 11
        // Nested Renderer/Art CREATE calls do not consume this deployer nonce.
        renderer = NARAPositionRendererV5(nft.renderer());
        entropyGovernor = new NARAMockGovernorV5(); // 12
        entropyGuardian = new NARAMockGovernorV5(); // 13
        entropyWrapper = new NARAMockVRFWrapperV5(address(entropyGovernor)); // 14; test-only coordinator
        entropyAdapter = new NARAEntropyAdapterV5(predictedForge, address(entropyWrapper), address(entropyGovernor), 100_000, 3); // 15
        forge = new NARAForgeV5(address(principal), address(entropyAdapter), address(entropyGovernor), address(entropyGuardian), 4); // 16
        entropyWrapper.setPrice(0); // Exact zero-fee conforming fixture; native-payment adversaries run in the EDR suite.
        lifecycle = NARALifecycleLedgerV5(principal.lifecycleLedger());
        entropyNull = new NARANullEntropyAdapterV5(address(forge));
        entropyHostile = new NARAHostileEntropyAdapterV5(address(forge));
        entropyHostile.setMode(1,1,99_000);
        require(address(rewards) == predictedRewards && address(nft) == predictedNFT && address(forge) == predictedForge, "predicted graph");
        engine.bindFinancialModules(address(principal), address(rewards)); reserve.bindCore(address(engine));
        engine.sealBindings(); reserve.sealBindings(); token.transfer(address(reserve), INITIAL);
        reserve.recognizeInitialFunding(); engine.activate();
        ingress = new NARARewardIngressV5(address(rewards));
        sale = new NARAPositionSaleV5(address(nft), address(ingress), SALE_LIFETIME);
        token.approve(address(principal), type(uint256).max); token.approve(address(rewards), type(uint256).max);
        token.approve(address(reserve), type(uint256).max); usdc.mint(address(this), 1e30); usdc.approve(address(rewards), type(uint256).max);
        token.approve(address(forge), type(uint256).max);
        initialNative = msg.value; nativeExpected[0] = msg.value;
        for (uint256 i; i < 2; ++i) {
            actors[i] = new ModularFuzzActor(token, principal); token.transfer(address(actors[i]), 25_000 ether);
            actors[i].bindSale(address(sale), address(nft));
            (bool approved,) = actors[i].invoke(address(token), abi.encodeCall(token.approve, (address(forge), type(uint256).max)));
            require(approved, "forge approval");
            uint256 funding = msg.value / 4;
            (bool funded,) = address(actors[i]).call{value: funding}(""); require(funded, "actor funding");
            nativeExpected[0] -= funding; nativeExpected[i + 1] = funding;
        }
        flashProbe = new CoreFundingFlashProbe(address(token), address(engine)); token.transfer(address(flashProbe), 100 ether);
    }

    function actionCreate(uint8 ownerEntropy, uint96 amountEntropy, uint8 durationEntropy) external {
        EpochClock memory c = engine.clock();
        if (!c.started || c.backlog != 0 || _positions.length >= MAX_GENERATION_RECORDS) return;
        address owner = _owner(ownerEntropy); uint256 upper = _fundingUpper(owner);
        if (upper == 0) return;
        uint256 amount = uint256(amountEntropy) % upper + 1; uint32 duration = _duration(durationEntropy);
        uint256 payerBefore = token.balanceOf(owner); uint256 custodyBefore = token.balanceOf(address(principal));
        (bool ok, bytes memory data) = _invoke(owner, address(principal), abi.encodeCall(principal.create,
            (CreateRequest(amount, duration, principal.policy().policyHash, type(uint64).max))));
        if (!ok) { _fail("CREATE_REVERT"); return; }
        (uint256 id, uint64 generation) = abi.decode(data, (uint256, uint64));
        if (id != _frameCount + 1 || generation != 1) { _fail("CREATE_ID"); return; }
        if (token.balanceOf(owner) + amount != payerBefore || token.balanceOf(address(principal)) != custodyBefore + amount)
            _fail("CREATE_RECEIPT");
        ++_frameCount; _appendGeneration(id, generation, owner, amount, duration, c.wallEpoch);
        _cover(0, amount);
        emit PathPrincipalCreated(amount); // COVERAGE_MARKER: exact principal creation
    }

    function actionDonate(uint8 assetEntropy, uint96 entropy) external {
        EpochClock memory c = engine.clock(); if (!c.started || c.backlog != 0) return;
        uint8 a = assetEntropy % 3;
        uint256 available = a == 0 ? token.balanceOf(address(this)) : a == 1 ? address(this).balance : usdc.balanceOf(address(this));
        uint256 upper = _min(available, a == 2 ? 1e6 : 1 ether); if (upper == 0) return;
        uint256 amount = uint256(entropy) % upper + 1;
        bool ok;
        if (a == 1) (ok,) = address(rewards).call{value: amount}(abi.encodeCall(rewards.donateETH, ()));
        else (ok,) = address(rewards).call(abi.encodeCall(rewards.donateToken, (RewardAsset(a), amount)));
        if (!ok) { _fail("DONATE_REVERT"); return; }
        if (a == 1) nativeExpected[0] -= amount;
        AssetOracle storage l = _assets[a]; l.custody += amount; l.pending += amount; l.admitted += amount; l.externalReceived += amount;
        _buckets[a][c.wallEpoch] += amount;
        if (a == 0) {
            _scheduleReward(c.wallEpoch + 1, int256(amount));
            _cover(1, amount);
            emit PathNaraReceived(amount); // COVERAGE_MARKER: NARA receipt
        } else if (a == 1) {
            _cover(2, amount);
            emit PathEthReceived(amount); // COVERAGE_MARKER: ETH receipt
        } else {
            _cover(3, amount);
            emit PathUsdcReceived(amount); // COVERAGE_MARKER: USDC receipt
        }
    }

    function actionAdvance(uint8 entropy) external {
        EpochClock memory c = engine.clock(); if (!c.started || c.backlog == 0) return;
        uint32 count = uint32(_min(uint256(entropy) % 16 + 1, c.backlog));
        _advanceOracle(count);
    }
    function _advanceOracle(uint32 count) private {
        for (uint32 i; i < count; ++i) _closeOracle();
        try engine.advance(count) returns (AdvanceResult memory r) {
            if (r.closedCount != count || r.failedReserveCalls != 0 || r.nextEpochToClose != _next) _fail("ADVANCE_RESULT");
            _cover(4, count);
            emit PathPulseSettled(count); // COVERAGE_MARKER: sequential pulse settlement
        } catch { _fail("ADVANCE_REVERT"); }
    }

    function actionClaim(uint8 positionEntropy, uint8 assetEntropy) external {
        if (_positions.length == 0) return;
        uint256 i = uint256(positionEntropy) % _positions.length; uint8 a = assetEntropy % 3;
        PositionOracle storage p = _positions[i]; uint256 expected = p.credits[a] / RAY;
        uint256 beforeBalance = _assetBalance(a, p.owner);
        (bool ok, bytes memory data) = _invoke(p.owner, address(rewards),
            abi.encodeCall(rewards.claim, (p.frameId, p.generation, RewardAsset(a), p.owner)));
        if (!ok) { _fail("CLAIM_REVERT"); return; }
        if (data.length != 32 || abi.decode(data, (uint256)) != expected || _assetBalance(a, p.owner) != beforeBalance + expected) {
            _fail("CLAIM_AMOUNT"); return;
        }
        p.credits[a] -= expected * RAY; p.paid[a] += expected;
        if (a == 1) nativeExpected[_nativeIndex(p.owner)] += expected;
        AssetOracle storage l = _assets[a]; l.custody -= expected; l.paid += expected; l.owed -= expected * RAY;
        if (a == 0 && expected != 0) _scheduleReward(engine.clock().wallEpoch + 1, -int256(expected));
        if (expected != 0) {
            if (a == 0) {
                _cover(5, expected);
                emit PathNaraClaimed(expected); // COVERAGE_MARKER: positive NARA claim
            } else if (a == 1) {
                _cover(6, expected);
                emit PathEthClaimed(expected); // COVERAGE_MARKER: positive ETH claim
            } else {
                _cover(7, expected);
                emit PathUsdcClaimed(expected); // COVERAGE_MARKER: positive USDC claim
            }
            _recordGenerationClaim(p, a, expected);
            _recordSaleClaim(i, a, expected);
        }
    }

    function actionWithdraw(uint8 entropy) external {
        if (_positions.length == 0) return;
        uint256 i = uint256(entropy) % _positions.length; PositionOracle storage p = _positions[i];
        EpochClock memory c = engine.clock(); if (p.withdrawn || p.fusionConsumed || !c.started || c.wallEpoch < p.end) return;
        uint256 ownerBalanceBefore = token.balanceOf(p.owner);
        (bool ok, bytes memory data) = _invoke(p.owner, address(principal), abi.encodeCall(principal.withdrawPrincipal, (p.frameId, p.generation, p.owner)));
        if (!ok) { _fail("WITHDRAW_REVERT"); return; }
        if (abi.decode(data, (uint256)) != p.amount || token.balanceOf(p.owner) != ownerBalanceBefore + p.amount)
            _fail("WITHDRAW_AMOUNT");
        p.withdrawn = true; p.withdrawalBoundary = c.wallEpoch + 1; _principalInventory -= p.amount;
        if (p.generation > 1) ++rechargedWithdrawals;
        _cover(8, p.amount);
        emit PathPrincipalWithdrawn(p.amount); // COVERAGE_MARKER: mature principal return during any backlog
    }

    function actionFund(uint96 entropy) external {
        EpochClock memory c = engine.clock(); if (!c.started) return;
        uint256 upper = _min(token.balanceOf(address(this)), 100 ether); if (upper == 0) return;
        uint256 amount = uint256(entropy) % upper + 1;
        try reserve.fund(amount) returns (uint256 received, uint256 sequence, uint64 epoch) {
            _recordFunding(received, sequence, epoch, c.wallEpoch, amount);
            _cover(9, received);
            emit PathReserveFunded(received); // COVERAGE_MARKER: future-dated pull funding
        } catch { _fail("FUND_REVERT"); }
    }

    function actionDonateReserve(uint96 entropy) external {
        uint256 upper = _min(token.balanceOf(address(this)), 100 ether); if (upper == 0) return;
        uint256 amount = uint256(entropy) % upper + 1; token.transfer(address(reserve), amount); _unsynced += amount;
    }
    function actionSync() external {
        EpochClock memory c = engine.clock(); if (!c.started) return;
        try reserve.syncFunding() returns (uint256 amount, uint256 sequence, uint64 epoch) {
            if (_unsynced == 0) { if (amount != 0 || sequence != _sequence || epoch != 0) _fail("EMPTY_SYNC"); return; }
            _recordFunding(amount, sequence, epoch, c.wallEpoch, _unsynced); _unsynced = 0;
            _cover(10, amount);
            emit PathSurplusRecognized(amount); // COVERAGE_MARKER: positive direct-surplus recognition
        } catch { _fail("SYNC_REVERT"); }
    }

    function actionFlash(uint96 entropy) external {
        if (!engine.clock().started) return;
        uint256 amount = uint256(entropy) % 1 ether + 1;
        uint256 fee = token.flashFee(address(token), amount); if (token.balanceOf(address(flashProbe)) < fee) return;
        try flashProbe.borrow(amount, abi.encodeCall(engine.advance, (1))) {
            if (flashProbe.lastCoreCallSuccess()
                || keccak256(flashProbe.lastCoreCallReturn()) != keccak256(abi.encodeWithSelector(NARAEpochEngineV5.FlashActive.selector)))
                _fail("FLASH_ADVANCE");
            _unsynced += fee;
            _cover(11, amount);
            emit PathFlashMutationRejected(amount); // COVERAGE_MARKER: flash-time mutation rejection
        } catch { _fail("FLASH_REVERT"); }
    }

    function actionFailedClaim(uint8 entropy, uint8 faultEntropy) external {
        if (_positions.length == 0) return;
        uint256 i = uint256(entropy) % _positions.length; PositionOracle storage p = _positions[i];
        if (p.credits[2] < RAY) return;
        usdc.setMode(faultEntropy % 3 + 1);
        (bool ok,) = _invoke(p.owner, address(rewards), abi.encodeCall(rewards.claim, (p.frameId, p.generation, RewardAsset.USDC, p.owner)));
        usdc.setMode(0); if (ok) _fail("FAULTY_CLAIM_SUCCEEDED");
        _cover(12, p.credits[2] / RAY);
        emit PathClaimFailureRolledBack(p.credits[2] / RAY); // COVERAGE_MARKER: failed selected-asset claim rollback
    }
    function actionUnauthorized(uint8 entropy) external {
        if (_positions.length == 0) return;
        uint256 i = uint256(entropy) % _positions.length; PositionOracle storage p = _positions[i];
        address headOwner = _positions[_frames[p.frameId].headIndexPlusOne - 1].owner;
        address other = p.dormantConsumed && headOwner != p.owner ? headOwner : _differentOwner(p.owner, 1);
        (bool ok, bytes memory data) = _invoke(other, address(rewards),
            abi.encodeCall(rewards.claim, (p.frameId, p.generation, RewardAsset.NARA, other)));
        if (ok || keccak256(data) != keccak256(abi.encodeWithSelector(NARARewardLedgerV5.Unauthorized.selector)))
            _fail("UNAUTHORIZED_CLAIM");
        _cover(13, p.frameId);
        emit PathUnauthorizedClaimRejected(p.frameId); // COVERAGE_MARKER: archived owner authorization
    }

    function actionTransfer(uint8 entropy, uint8 recipientEntropy, uint8 modeEntropy) external {
        if (_positions.length == 0) return;
        uint256 i = uint256(entropy) % _positions.length; PositionOracle storage p = _positions[i];
        if (p.withdrawn || p.fusionConsumed || !_isCurrent(i) || lifecycle.pendingAttempt(p.frameId, p.generation) != bytes32(0)) return;
        address recipient = _differentOwner(p.owner, recipientEntropy); address caller = p.owner;
        uint8 mode = modeEntropy % 3;
        if (mode == 2) {
            caller = _differentOwner(p.owner, 1);
            (bool approved,) = _invoke(p.owner, address(nft), abi.encodeCall(nft.approve, (caller, p.activeTokenId)));
            if (!approved) { _fail("APPROVE_REVERT"); return; }
            p.approved = caller;
        }
        bytes memory input = mode == 1
            ? abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", p.owner, recipient, p.activeTokenId)
            : abi.encodeCall(nft.transferFrom, (p.owner, recipient, p.activeTokenId));
        (bool ok,) = _invoke(caller, address(nft), input);
        if (!ok) { _fail("TRANSFER_REVERT"); return; }
        // All unclaimed fractions and open intervals travel together. Payout
        // history remains position history, not a new owner's claim.
        p.owner = recipient; p.approved = address(0); ++p.activeTransferNonce;
        _clearSaleClaim(p.activeTokenId);
        _cover(14, p.activeTokenId);
        emit PathActiveReceiptTransferred(p.activeTokenId); // COVERAGE_MARKER: actual active NFT ownership transfer
    }

    function actionFailedNftTransfer(uint8 entropy) external {
        if (_positions.length == 0) return;
        uint256 i = uint256(entropy) % _positions.length; PositionOracle storage p = _positions[i];
        if (p.withdrawn || p.fusionConsumed || !_isCurrent(i)) return;
        ModularFuzzActor receiver = p.owner == address(actors[0]) ? actors[1] : actors[0];
        (bool approved,) = _invoke(p.owner, address(nft), abi.encodeCall(nft.approve, (address(receiver), p.activeTokenId)));
        if (!approved) { _fail("FAULT_APPROVE_REVERT"); return; }
        p.approved = address(receiver); receiver.rejectNft(true);
        (bool ok,) = _invoke(p.owner, address(nft), abi.encodeWithSignature(
            "safeTransferFrom(address,address,uint256)", p.owner, address(receiver), p.activeTokenId));
        receiver.rejectNft(false);
        if (ok) _fail("REJECTED_NFT_TRANSFER");
        // The properties also check restored approval and financial owner.
        _cover(15, p.activeTokenId);
        emit PathNftReceiverFailureRolledBack(p.activeTokenId); // COVERAGE_MARKER: NFT receiver failure restores financial rights
    }

    function actionMaterialize(uint8 entropy, uint8 recipientEntropy) external {
        if (_positions.length == 0) return;
        uint256 i = uint256(entropy) % _positions.length; PositionOracle storage p = _positions[i];
        if (!p.withdrawn || p.dormantTokenId != 0 || !_isCurrent(i)) return;
        address recipient = _owner(recipientEntropy);
        (bool ok, bytes memory data) = _invoke(p.owner, address(nft), abi.encodeCall(nft.materializeDormant, (p.activeTokenId, recipient)));
        if (_next < p.end) { if (ok) _fail("EARLY_DORMANT"); return; }
        if (!ok) { _fail("MATERIALIZE_REVERT"); return; }
        uint256 id = abi.decode(data, (uint256));
        p.dormantTokenId = ++_minted; p.dormantOwner = recipient; p.approved = address(0); ++p.activeTransferNonce;
        if (id != p.dormantTokenId) _fail("DORMANT_ID");
        // p.owner is the immutable old financial owner after withdrawal.
        _cover(16, id);
        emit PathDormantMaterialized(id); // COVERAGE_MARKER: fresh dormant receipt preserves archived owner
    }

    function actionDormantTransfer(uint8 entropy, uint8 recipientEntropy) external {
        if (_positions.length == 0) return;
        uint256 i = uint256(entropy) % _positions.length; PositionOracle storage p = _positions[i];
        if (p.dormantTokenId == 0 || p.dormantConsumed || !_isCurrent(i)) return;
        address recipient = _differentOwner(p.dormantOwner, recipientEntropy);
        (bool ok,) = _invoke(p.dormantOwner, address(nft), abi.encodeCall(nft.transferFrom, (p.dormantOwner, recipient, p.dormantTokenId)));
        if (!ok) { _fail("DORMANT_TRANSFER_REVERT"); return; }
        if (!p.savedDormantNonce) { p.savedDormantNonce = true; p.replayDormantNonce = p.dormantTransferNonce; }
        p.dormantOwner = recipient; ++p.dormantTransferNonce;
        _cover(17, p.dormantTokenId);
        emit PathDormantReceiptTransferred(p.dormantTokenId); // COVERAGE_MARKER: dormant gift cannot transfer archived rewards
    }

    function actionStaleReceipt(uint8 entropy) external {
        if (_positions.length == 0) return;
        uint256 i = uint256(entropy) % _positions.length; PositionOracle storage p = _positions[i];
        if (!p.withdrawn) return;
        address other = _differentOwner(p.owner, 1);
        (bool ok,) = _invoke(p.owner, address(nft), abi.encodeCall(nft.transferFrom, (p.owner, other, p.activeTokenId)));
        if (ok) _fail("STALE_RECEIPT_TRANSFER");
        if (p.dormantConsumed) {
            (ok,) = _invoke(p.dormantOwner, address(nft), abi.encodeCall(nft.transferFrom,
                (p.dormantOwner, other, p.dormantTokenId)));
            if (ok) _fail("CONSUMED_DORMANT_TRANSFER");
            for (uint256 k; k < 2; ++k) {
                uint256 tokenId = k == 0 ? p.activeTokenId : p.dormantTokenId;
                // Ordinary call: a staticcall would also reject a LIVE metadata event.
                bytes memory result;
                (ok, result) = _invoke(p.owner, address(nft), abi.encodeCall(nft.refreshMetadata, (tokenId)));
                if (ok || !_nonexistent(result, tokenId)) _fail("CONSUMED_REFRESH");
            }
        }
        _cover(18, p.activeTokenId);
        emit PathStaleReceiptRejected(p.activeTokenId); // COVERAGE_MARKER: withdrawn or burned financial receipt cannot sell backing
    }

    function actionReadPosition(uint8 entropy) external {
        if (_positions.length == 0) return;
        uint256 i = uint256(entropy) % _positions.length;
        i = _frames[_positions[i].frameId].headIndexPlusOne - 1; PositionOracle storage p = _positions[i];
        if (p.fusionConsumed) return;
        uint256 id = p.dormantTokenId == 0 ? p.activeTokenId : p.dormantTokenId;
        try positionLens.snapshot(address(nft), id) returns (PositionViewV5 memory v) {
            bool attached = !p.withdrawn;
            if (v.schemaVersion != 2 || v.positionId != p.frameId || v.tokenId != id || v.generation != p.generation
                || v.rarityTier != principal.rarityTier(p.frameId, p.generation)
                || v.financial.generationOwner != p.owner || v.financial.principal != p.amount
                || v.nftOwner != (p.dormantTokenId == 0 ? p.owner : p.dormantOwner)
                || v.attachedPrincipal != (attached ? p.amount : 0)
                || v.weightEpoch != _next || v.weightSnapshotCurrent != (_next == engine.clock().wallEpoch)) _fail("POSITION_VIEW");
            for (uint8 a; a < 3; ++a) {
                if (!v.rewardReadSuccess[a] || v.rewards[a].closedCreditScaled != p.credits[a]
                    || v.positionRewardsEarned[a] != p.paid[a] + p.credits[a] / RAY
                    || v.attachedClaimable[a] != (attached ? p.credits[a] / RAY : 0)
                    || v.archivedClaimable[a] != (attached ? 0 : p.credits[a] / RAY)) _fail("POSITION_REWARD_VIEW");
            }
        } catch { _fail("POSITION_VIEW_REVERT"); }
        // Normal real renderer must fit the NFT budget, not silently degrade.
        try renderer.tokenURI(address(nft), id) returns (string memory expected) {
            try nft.tokenURI(id) returns (string memory uri) {
                if (keccak256(bytes(uri)) != keccak256(bytes(expected))) _fail("METADATA_FALLBACK");
            } catch { _fail("METADATA_REVERT"); }
        } catch { _fail("DIRECT_RENDER_REVERT"); }
        _cover(19, id);
        emit PathPositionMetadataRead(id); // COVERAGE_MARKER: real position lens and bounded metadata agree
    }

    // P2.3 LC-INV C/SC/NR/G/X1-X4: independent attempt journal over the real Forge.
    // A campaign must first catch up >=2,880 weighted closes; no production warm-up override.
    function initializeEntropyCampaign() external {
        require(_positions.length == 0 && _next == 0, "one fresh campaign initialization");
        EntropyHevmV5 vm = EntropyHevmV5(address(uint160(uint256(keccak256("hevm cheat code")))));
        uint256 genesis = principal.genesisTimestamp(); vm.warp(genesis);
        this.actionCreate(0,100 ether-1,3); this.actionCreate(1,1900 ether-1,3);
        vm.warp(genesis + 2881 * 900);
        while (engine.clock().backlog != 0) _advanceOracle(uint32(_min(48,engine.clock().backlog)));
        require(_referenceSamples >= 2880 && !_violation, "weighted warm-up required");
    }
    function actionEntropyCommit(uint8 entropy) external {
        if (_positions.length == 0 || _entropy.length >= 64 || forge.commitsPaused()) return;
        uint256 i = entropy % _positions.length; PositionOracle storage p = _positions[i];
        EpochClock memory c = engine.clock();
        if (c.backlog != 0 || _referenceSamples < REFERENCE_WINDOW || !_isCurrent(i) || p.withdrawn || p.fusionConsumed
            || p.activation > c.wallEpoch || p.end <= c.wallEpoch + 7 || p.amount < 10 ether
            || lifecycle.award(p.frameId).attemptId != bytes32(0) || lifecycle.pendingAttempt(p.frameId,p.generation) != bytes32(0)) return;
        uint256 d = _durationWad(p.duration); uint256 total = principal.principalAccounting().activeRewardWeight;
        uint256 emission = _referenceSum * 1e18 / _referenceWeight;
        uint256[4] memory multipliers = [uint256(3),10,25,50]; uint256[4] memory tickets = [uint256(25_000),15_000,8_000,1_000];
        uint256 numerator;
        for (uint256 t; t < 4; ++t) {
            uint256 next = p.amount * d * multipliers[t] / 1e18;
            numerator += tickets[t] * (next * total / (total-p.weight+next) - p.weight);
        }
        uint256 den = 10 * 100_000 * total;
        uint256 value = (emission * 35_040 * numerator + den - 1) / den;
        uint256 fee = (value > 1 ether ? value : 1 ether) + 0.5 ether;
        if (token.balanceOf(p.owner) < fee) return;
        uint256 beforeBalance = token.balanceOf(p.owner);
        (bool ok, bytes memory data) = _invoke(p.owner,address(forge),abi.encodeCall(forge.commitRoll,
            (RollRequestV5(p.frameId,p.generation,p.birthTermsHash,fee,0,type(uint64).max))));
        if (!ok) { _fail("ENTROPY_COMMIT"); return; }
        (bytes32 id,uint256 requestId) = abi.decode(data,(bytes32,uint256));
        if (token.balanceOf(p.owner) + fee != beforeBalance) _fail("ENTROPY_FEE");
        uint256[5] memory empty;
        _entropy.push(EntropyOracle(id,i,requestId,fee,0,0,false,false,false,0,empty,forge.adapter())); ++entropyCommits;
    }
    function actionEntropyCommitFusion(uint8 ownerEntropy, uint8 tierEntropy) external {
        if (_positions.length < 5 || _positions.length >= MAX_GENERATION_RECORDS || _entropy.length >= 64 || forge.commitsPaused()) return;
        EpochClock memory c = engine.clock();
        if (!c.started || c.backlog != 0 || _referenceSamples < REFERENCE_WINDOW) return;
        address owner = _owner(ownerEntropy);
        uint8 targetTier = tierEntropy % 5;
        uint256[5] memory idx; uint256[5] memory ids; uint64[5] memory gs; bytes32[5] memory hashes;
        uint256 found;
        for (uint256 f = 1; f <= _frameCount && found < 5; ++f) {
            uint256 h = _frames[f].headIndexPlusOne - 1;
            PositionOracle storage p = _positions[h];
            if (p.owner != owner || p.withdrawn || p.fusionConsumed || p.activation > c.wallEpoch
                || p.end <= c.wallEpoch + 7 || p.weightCutover > c.wallEpoch) continue;
            if (lifecycle.pendingAttempt(p.frameId, p.generation) != bytes32(0)
                || lifecycle.lifecycle(p.frameId, p.generation).fusionSpent) continue;
            uint8 t = principal.rarityTier(p.frameId, p.generation);
            if (t != targetTier) continue;
            FrameAwardV5 memory aw = lifecycle.award(p.frameId);
            if (aw.attemptId != bytes32(0) && aw.outcomeTier != 255 && aw.tier != targetTier) continue;
            idx[found] = h; ids[found] = p.frameId; gs[found] = p.generation; hashes[found] = p.birthTermsHash;
            ++found;
        }
        if (found < 5) return;
        uint256 fee = _oracleFusionTotalFee(idx, targetTier, c.wallEpoch);
        if (token.balanceOf(owner) < fee) return;
        uint256 beforeBalance = token.balanceOf(owner);
        (bool ok, bytes memory data) = _invoke(owner, address(forge), abi.encodeCall(forge.commitFusion,
            (FusionRequestV5(ids, gs, hashes, fee, 0, type(uint64).max))));
        if (!ok) { _fail("ENTROPY_FUSION_COMMIT"); return; }
        (bytes32 id, uint256 requestId) = abi.decode(data, (bytes32, uint256));
        if (token.balanceOf(owner) + fee != beforeBalance) _fail("ENTROPY_FUSION_FEE");
        _entropy.push(EntropyOracle(id, idx[0], requestId, fee, 0, 0, false, false, true, targetTier, idx, forge.adapter()));
        ++entropyCommits; ++fusionCommits;
    }
    function _oracleFusionTotalFee(uint256[5] memory idx, uint8 tier, uint64 wall) private view returns (uint256) {
        uint256 sumP; uint256 sumC; uint256 kIn; uint256 own; uint256 daw = 4e18; uint64 maturity = wall + 97;
        uint256[5] memory caps;
        for (uint256 j; j < 5; ++j) {
            PositionOracle storage p = _positions[idx[j]];
            FrameAwardV5 memory aw = lifecycle.award(p.frameId);
            bool awarded = aw.attemptId != bytes32(0) && aw.outcomeTier != 255;
            caps[j] = awarded ? aw.originalCap : p.amount;
            uint256 dawJ = awarded ? aw.awardedDurationWad : _durationWad(p.duration);
            if (dawJ < daw) daw = dawJ;
            sumP += p.amount; sumC += caps[j]; kIn += _min(p.amount, caps[j]); own += p.weight;
            if (p.end > maturity) maturity = p.end;
        }
        uint256 d = _durationWad(uint32(maturity - wall - 1));
        uint256 total = principal.principalAccounting().activeRewardWeight;
        uint256 emission = _referenceSum * 1e18 / _referenceWeight;
        NARAForgeQuoteV5 q = NARAForgeQuoteV5(forge.quote());
        uint256 fee = q.fusionFee(sumP, sumC, kIn, own, tier, d, daw, total, emission);
        uint256 ext;
        if (tier != 0) {
            bool extended;
            uint256 aWad = (tier == 1 ? 3 : tier == 2 ? 10 : tier == 3 ? 25 : 50) * 1e18;
            uint256 dExt = _min(d, daw);
            for (uint256 j; j < 5; ++j) {
                PositionOracle storage p = _positions[idx[j]];
                if (p.end < maturity) {
                    extended = true;
                    ext += q.rentRaw(p.amount, caps[j], aWad, dExt, daw, maturity - p.end, total, emission);
                }
            }
            if (extended && ext < 1 ether) ext = 1 ether;
        }
        return fee + ext;
    }
    function actionEntropyDeliver(uint8 entropy, uint256 word) external {
        if (_entropy.length == 0) return; EntropyOracle storage a = _entropy[entropy % _entropy.length];
        if (a.adapter != address(entropyAdapter)) return;
        uint256[] memory words = new uint256[](1); words[0] = word;
        entropyWrapper.fulfill(address(entropyAdapter),a.requestId,words,100_000);
        if (a.deliveredAt == 0) { a.deliveredAt = uint64(block.timestamp); a.word = word; ++entropyCallbacks; }
    }
    function actionEntropyTerminal(uint8 entropy) external {
        if (_entropy.length == 0) return; EntropyOracle storage a = _entropy[entropy % _entropy.length]; if (a.terminal) return;
        AttemptV5 memory actual = forge.attempt(a.id); PositionOracle storage p = _positions[a.positionIndex];
        uint64 wall = engine.clock().wallEpoch;
        bool onTime = a.deliveredAt != 0 && a.deliveredAt < principal.genesisTimestamp() + actual.deadlineEpoch * 900;
        if (onTime) {
            if (engine.clock().backlog != 0) return;
            if (a.isFusion) {
                uint256 ticket = a.word % 100_000;
                uint8 outTier;
                if (a.inputTier == 4) outTier = ticket < 75_000 ? 5 : 4;
                else {
                    uint8 step = ticket < 98_889 ? 0 : ticket < 99_889 ? 1 : ticket < 99_989 ? 2 : ticket < 99_999 ? 3 : 4;
                    outTier = uint8(_min(a.inputTier + step, 4));
                }
                bool valid = true;
                for (uint256 j; j < 5; ++j) {
                    PositionOracle storage pj = _positions[a.indices[j]];
                    FrameAwardV5 memory aw = lifecycle.award(pj.frameId);
                    bool badAward = aw.attemptId != bytes32(0) && aw.outcomeTier != 255 && aw.tier != a.inputTier;
                    if (!_isCurrent(a.indices[j]) || pj.withdrawn || pj.fusionConsumed || pj.owner != actual.payer
                        || principal.rarityTier(pj.frameId, pj.generation) != a.inputTier || badAward) valid = false;
                }
                try forge.finalize{gas: 3_000_000}(a.id) {} catch { _fail("ENTROPY_FINALIZE"); return; }
                if (valid) { _applyFusionOracle(a.indices, actual.payer, wall, outTier, a.id); ++fusionsFinalized; }
                else ++fusionsCancelled;
            } else {
                uint256 oldWeight = p.weight; bytes32 oldTerms = p.birthTermsHash;
                uint256 ticket = a.word % 100_000;
                uint8 tier = ticket < 51_000 ? 0 : ticket < 76_000 ? 1 : ticket < 91_000 ? 2 : ticket < 99_000 ? 3 : 4;
                bool live = _isCurrent(a.positionIndex) && !p.withdrawn && !p.fusionConsumed && p.activation <= wall && wall + 1 < p.end;
                try forge.finalize{gas: 2_000_000}(a.id) {} catch { _fail("ENTROPY_FINALIZE"); return; }
                if (live && tier != 0) {
                    uint256 multiplier = tier == 1 ? 3 : tier == 2 ? 10 : tier == 3 ? 25 : 50;
                    p.previousWeight = oldWeight; p.weightCutover = wall + 1;
                    p.weight = p.amount * _durationWad(p.duration) * multiplier / 1e18;
                    p.birthTermsHash = keccak256(abi.encode(keccak256("NARA_V5_REWARD_TERMS_REVISION_V1"),block.chainid,
                        address(principal),p.frameId,p.generation,oldTerms,p.weightCutover,oldWeight,p.weight));
                } else p.birthTermsHash = keccak256(abi.encode(keccak256("NARA_V5_AWARD_RECORDED_REVISION_V1"),block.chainid,
                    address(principal),p.frameId,p.generation,oldTerms,a.id,tier));
            }
            _unsynced += a.fee; entropyForwarded += a.fee; ++entropyFinalized;
        } else {
            if (block.timestamp < principal.genesisTimestamp() + actual.deadlineEpoch * 900) return;
            try forge.fail{gas: 1_500_000}(a.id) {} catch { _fail("ENTROPY_FAIL"); return; }
            _entropyRefund[actual.payer] += a.fee; a.failed = true; ++entropyFailed;
        }
        a.terminal = true;
    }
    function _applyFusionOracle(uint256[5] memory idx, address owner, uint64 wall, uint8 outTier, bytes32 attemptId) private {
        uint64 cutover = wall + 1; uint64 maturity = cutover + 96;
        uint256 sumP; uint256 sumC; uint256 daw = 4e18;
        for (uint256 j; j < 5; ++j) {
            PositionOracle storage pj = _positions[idx[j]];
            FrameAwardV5 memory aw = lifecycle.award(pj.frameId);
            bool awarded = aw.attemptId != bytes32(0) && aw.outcomeTier != 255;
            uint256 capJ = awarded ? aw.originalCap : pj.amount;
            uint256 dawJ = awarded ? aw.awardedDurationWad : _durationWad(pj.duration);
            if (dawJ < daw) daw = dawJ;
            sumP += pj.amount; sumC += capJ;
            uint64 origMat = pj.activation + pj.duration;
            if (origMat > maturity) maturity = origMat;
            pj.fusionConsumed = true; pj.approved = address(0); ++pj.activeTransferNonce;
            _clearSaleClaim(pj.activeTokenId);
            if (cutover < pj.end) pj.end = cutover;
            pj.withdrawalBoundary = cutover;
        }
        uint256 outFrame = ++_frameCount;
        uint32 durOut = uint32(maturity - cutover);
        uint256 dOut = _durationWad(durOut);
        uint256 baseW = sumP * dOut / 1e18;
        uint256 aWad = (outTier == 0 ? 1 : outTier == 1 ? 3 : outTier == 2 ? 10 : outTier == 3 ? 25 : outTier == 4 ? 50 : 100) * 1e18;
        uint256 rewW = (dOut * sumP * 1e18 + _min(sumP, sumC) * (aWad - 1e18) * _min(dOut, daw)) / 1e36;
        _positions.push(); PositionOracle storage p = _positions[_positions.length - 1];
        p.frameId = outFrame; p.generation = 1; p.duration = durOut; p.owner = owner;
        p.amount = sumP; p.created = wall; p.activation = cutover; p.end = maturity;
        p.withdrawalBoundary = type(uint64).max;
        p.baseWeight = baseW; p.weight = rewW;
        p.activeTokenId = ++_minted;
        if (nft.tokenIdOf(outFrame, 1) != p.activeTokenId) _fail("FUSION_RECEIPT_ID");
        _frames[outFrame].headIndexPlusOne = _positions.length;
        _frames[outFrame].originTokenId = p.activeTokenId;
        PositionState memory birth;
        birth.generationOwner = owner; birth.generation = 1; birth.createdEpoch = wall;
        birth.activation = cutover; birth.maturity = maturity; birth.effectiveEnd = maturity; birth.duration = durOut;
        birth.principal = sumP; birth.modelWeight = baseW; birth.rewardWeight = rewW;
        p.birthTermsHash = keccak256(abi.encode(keccak256("NARA_V5_MODULAR_FUSION_TERMS_V1"),
            block.chainid, address(principal), principal.policy().policyHash, outFrame, birth, attemptId));
    }
    function actionEntropyRefund(uint8 entropy) external {
        address owner = _owner(entropy); uint256 amount = _entropyRefund[owner]; if (amount == 0) return;
        uint256 beforeBalance = token.balanceOf(owner);
        (bool ok,) = _invoke(owner,address(forge),abi.encodeCall(forge.withdrawRefund,(owner)));
        if (!ok || token.balanceOf(owner) != beforeBalance + amount) { _fail("ENTROPY_REFUND"); return; }
        delete _entropyRefund[owner]; entropyRefunded += amount;
    }
    function actionEntropyGuardian(uint8 entropy) external {
        entropyGuardian.callTarget(address(forge), entropy % 2 == 0 ? abi.encodeCall(forge.pauseCommits,()) : abi.encodeCall(forge.unpauseCommits,()));
    }
    function actionEntropyGovernance(uint8 entropy) external {
        if (forge.pendingAdapter() != address(0)) return;
        entropyGovernor.cycles(address(forge),address(entropyNull),uint256(entropy)%8+1);
    }
    function actionEntropyAdapterGovernance(uint8 entropy) external {
        entropyHostile.setMode(uint256(entropy)%7+1,uint64(block.timestamp),99_000);
        address pending = forge.pendingAdapter();
        if (pending == address(0)) {
            address next = forge.adapter() == address(entropyAdapter) ? address(entropyHostile) : address(entropyAdapter);
            entropyGovernor.callTarget(address(forge),abi.encodeCall(forge.proposeAdapter,(next)));
        } else if (block.timestamp >= forge.adapterReadyAt()) forge.finalizeAdapter(pending,forge.pendingProposal());
    }
    function echidna_entropy_conservation_and_cross_module() external view returns (bool) {
        uint256 pending; uint256 escrow; uint256 refunds;
        for (uint256 i; i < _entropy.length; ++i) {
            EntropyOracle storage a = _entropy[i]; AttemptV5 memory actual = forge.attempt(a.id);
            PositionOracle storage p = _positions[a.positionIndex];
            if (actual.requestId != a.requestId || actual.protocolFee != a.fee || actual.adapter != a.adapter) return false;
            if (a.adapter == address(entropyAdapter)
                && (entropyAdapter.requestOf(a.id) != a.requestId || entropyAdapter.attemptOf(a.requestId) != a.id)) return false;
            uint256 count = a.isFusion ? 5 : 1;
            if (!a.terminal) { ++pending; escrow += a.fee;
                if (actual.state != AttemptStateV5.Committed) return false;
                for (uint256 j; j < count; ++j) {
                    PositionOracle storage pj = a.isFusion ? _positions[a.indices[j]] : p;
                    if (lifecycle.pendingAttempt(pj.frameId, pj.generation) != a.id) return false;
                }
            } else {
                if (actual.state == AttemptStateV5.Committed) return false;
                for (uint256 j; j < count; ++j) {
                    PositionOracle storage pj = a.isFusion ? _positions[a.indices[j]] : p;
                    if (lifecycle.pendingAttempt(pj.frameId, pj.generation) == a.id) return false;
                }
            }
        }
        for (uint8 i; i < 3; ++i) { address owner = _owner(i); refunds += _entropyRefund[owner];
            if (forge.naraRefund(owner) != _entropyRefund[owner]) return false; }
        PrincipalLedgerStateV5 memory s = principal.principalAccounting();
        return pending == forge.pendingTotal() && escrow == forge.escrowedNara() && refunds == forge.naraRefundTotal()
            && token.balanceOf(address(forge)) == escrow + refunds && address(forge).balance == 0
            && (s.activeModelWeight == 0) == (s.activeRewardWeight == 0)
            && entropyCommits == _entropy.length && entropyFinalized + entropyFailed + pending == entropyCommits;
    }
    function _durationWad(uint32 duration) private pure returns (uint256) {
        uint256 ratio = uint256(duration) * 1e18 / 35_040;
        return 1e18 + (1e18 / 2) * ratio / 1e18 + (5 * 1e18 / 2) * (ratio * ratio / 1e18) / 1e18;
    }
    function _weightAt(PositionOracle storage p, uint64 epoch) private view returns (uint256) {
        return p.weightCutover != 0 && epoch < p.weightCutover ? p.previousWeight : p.weight;
    }

    function _closeOracle() private {
        (uint256 capital, uint256 baseWeight, uint256 rarityWeight) = _historicalPrincipal(_next);
        EmissionQuote memory q = model.calculateNext(_config, _modelState, EmissionInputs(SUPPLY - capital - _rewardSnapshot - _eligible, baseWeight));
        uint256 headroom = type(uint256).max / RAY - _assets[0].admitted;
        // P2.10 (B3): requested = min(target x min(eligible, R_ref) / R_ref, eligible / T, headroom), only with weight.
        uint256 scaled = _eligible < _referenceRelease ? q.targetNara * _eligible / _referenceRelease : q.targetNara;
        uint256 delivered = baseWeight == 0 ? 0 : _min(scaled, _min(_eligible / RELEASE_HORIZON_EPOCHS, _min(_eligible, headroom)));
        if (rarityWeight != 0) { // P2.10 (section 5.4): a close with reward weight is one sample, a zero delivery included
            _referenceSum = ((REFERENCE_WINDOW - 1) * _referenceSum + delivered) / REFERENCE_WINDOW;
            _referenceWeight = ((REFERENCE_WINDOW - 1) * _referenceWeight + 1e18) / REFERENCE_WINDOW; ++_referenceSamples;
        }
        _eligible -= delivered; _released += delivered; _rewardSnapshot += delivered;
        uint256[3] memory allocation; uint256[3] memory baseDeltas; uint256[3] memory rarityDeltas;
        for (uint8 a; a < 3; ++a) {
            AssetOracle storage l = _assets[a]; uint256 bucket = _buckets[a][_next]; delete _buckets[a][_next];
            uint256 emission = a == 0 ? delivered : 0;
            l.custody += emission; l.admitted += emission; l.emissions += emission; l.pending -= bucket;
            uint256 total = bucket + l.bank + emission;
            if (baseWeight == 0 || rarityWeight == 0) l.bank = total;
            else {
                // Split the entire pulse once, including prior bank and emissions.
                // Independent floors belong to global quarantine, not user carry.
                uint256 rarityAmount = total * 2000 / 10_000;
                uint256 baseStep = (total - rarityAmount) * RAY / baseWeight;
                uint256 rarityStep = rarityAmount * RAY / rarityWeight;
                uint256 owed = baseStep * baseWeight + rarityStep * rarityWeight;
                l.bank = 0; l.baseIndex += baseStep; l.rarityIndex += rarityStep;
                l.owed += owed; l.quarantine += total * RAY - owed;
                allocation[a] = total; baseDeltas[a] = baseStep; rarityDeltas[a] = rarityStep;
                // Direct per-position accrual: no lazy anchors or index subtraction.
                for (uint256 i; i < _positions.length; ++i) {
                    PositionOracle storage p = _positions[i];
                    if (p.activation <= _next && _next < p.end)
                        p.credits[a] += p.baseWeight * baseStep + _weightAt(p, _next) * rarityStep;
                }
            }
        }
        emit OraclePulseClosed(_next, baseWeight, rarityWeight, allocation, baseDeltas, rarityDeltas);
        _modelState = q.nextState; ++_next;
        uint256 promotion = _fundingAt[_next]; delete _fundingAt[_next]; _future -= promotion; _eligible += promotion;
        int256 delta = _rewardChanges[_next]; delete _rewardChanges[_next];
        _rewardSnapshot = delta >= 0 ? _rewardSnapshot + uint256(delta) : _rewardSnapshot - uint256(-delta); _rewardPending -= delta;
    }

    function echidna_no_oracle_violation() external view returns (bool) { return !_violation; }
    function echidna_settled_supply_and_wallets() external view returns (bool) {
        return token.totalSupply() == SUPPLY && token.balanceOf(address(this)) + token.balanceOf(address(reserve))
            + token.balanceOf(address(principal)) + token.balanceOf(address(rewards)) + token.balanceOf(address(engine))
            + token.balanceOf(address(actors[0])) + token.balanceOf(address(actors[1])) + token.balanceOf(address(flashProbe))
            + token.balanceOf(address(forge)) == SUPPLY;
    }
    function echidna_graph_and_cursor_agree() external view returns (bool) {
        RewardLedgerStateV5 memory r = rewards.rewardState(); PrincipalLedgerStateV5 memory p = principal.principalAccounting();
        return principal.moduleLockHolder() == address(0) && !engine.accountingInProgress()
            && engine.clock().nextEpochToClose == _next && p.openedEpoch == _next && r.openedEpoch == _next && r.nextCheckpoint == _next
            && p.initialized && r.initialized && !r.receiptPrepared && engine.bindings().bindingsSealed
            && engine.bindings().bootstrapAuthority == address(0) && principal.bindingHash() == engine.principalBindingHash()
            && rewards.bindingHash() == engine.rewardBindingHash() && engine.graphHash() != bytes32(0);
    }
    function echidna_principal_history_and_weights() external view returns (bool) {
        PrincipalLedgerStateV5 memory actual = principal.principalAccounting();
        (uint256 snapshot, uint256 baseWeight, uint256 rarityWeight) = _historicalPrincipal(_next);
        if (actual.principalInventory != _principalInventory || token.balanceOf(address(principal)) != _principalInventory
            || actual.principalSnapshot != snapshot || actual.activeModelWeight != baseWeight || actual.activeRewardWeight != rarityWeight
            || int256(snapshot) + actual.pendingPrincipalDelta != int256(_principalInventory)
            || actual.positionCount != _frameCount) return false;
        uint64[64] memory generations; uint256[64] memory heads;
        for (uint256 i; i < _positions.length; ++i) {
            PositionOracle storage p = _positions[i];
            if (p.frameId == 0 || p.frameId > _frameCount || p.generation != ++generations[p.frameId - 1]) return false;
            heads[p.frameId - 1] = i + 1;
            PositionState memory state = principal.position(p.frameId, p.generation);
            if (!_termsMatch(p, state)) return false;
        }
        for (uint256 frame = 1; frame <= _frameCount; ++frame) {
            if (heads[frame - 1] != _frames[frame].headIndexPlusOne || heads[frame - 1] == 0) return false;
            if (!_termsMatch(_positions[heads[frame - 1] - 1], principal.positionHead(frame))) return false;
        }
        return true;
    }

    function echidna_reward_ledgers_and_credits() external view returns (bool) {
        for (uint8 a; a < 3; ++a) {
            AssetOracle storage l = _assets[a]; RewardAccountingV5 memory s = rewards.rewardAccounting(RewardAsset(a));
            (bool settled, uint256 baseIndex, uint256 rarityIndex) = rewards.indicesAt(RewardAsset(a), _next);
            uint256 observed = a == 0 ? token.balanceOf(address(rewards)) : a == 1 ? address(rewards).balance : usdc.balanceOf(address(rewards));
            if (observed != l.custody || s.recordedCustody != l.custody || s.pendingTotal != l.pending || s.banked != l.bank
                || s.baseIndex != l.baseIndex || s.rarityIndex != l.rarityIndex
                || !settled || baseIndex != l.baseIndex || rarityIndex != l.rarityIndex
                || s.owedScaled != l.owed || s.quarantinedScaled != l.quarantine || s.cumulativeAdmitted != l.admitted
                || s.cumulativePaid != l.paid || s.cumulativeExternal != l.externalReceived || s.cumulativeEmissions != l.emissions
                || s.cumulativePenalties != 0 || s.penaltyCapacityReserved != 0
                || l.custody * RAY != (l.pending + l.bank) * RAY + l.owed + l.quarantine || l.admitted != l.custody + l.paid) return false;
            uint256 summed;
            for (uint256 i; i < _positions.length; ++i) {
                PositionOracle storage p = _positions[i];
                RewardCredit memory c = lens.credit(rewards, p.frameId, p.generation, RewardAsset(a));
                uint64 wall = engine.clock().wallEpoch;
                uint64 through = wall < p.end ? wall : p.end;
                uint64 from = p.activation > _next ? p.activation : _next; if (from > through) from = through;
                if (c.generationOwner != p.owner || c.generation != p.generation
                    || c.closedCreditScaled != p.credits[a] || c.cumulativePaid != p.paid[a]
                    || c.claimable != p.credits[a] / RAY || c.fractionScaled != p.credits[a] % RAY
                    || c.pendingFrom != from || c.pendingThrough != through || c.hasUnsettledEpochs != (from < through)) return false;
                summed += p.credits[a];
            }
            if (summed != l.owed) return false;
        }
        return true;
    }
    function echidna_dated_nara_and_funding() external view returns (bool) {
        EpochFundingStateV5 memory f = engine.fundingState(); ReserveState memory s = reserve.state();
        RewardLedgerStateV5 memory r = rewards.rewardState();
        return f.eligibleReserve == _eligible && f.futureReserve == _future && f.cumulativeRecognized == _recognized
            && f.cumulativeReleased == _released && f.lastFundingSequence == _sequence && s.fundingSequence == _sequence
            && s.cumulativeRecognized == _recognized && s.cumulativeReleased == _released
            && token.balanceOf(address(reserve)) == _recognized - _released + _unsynced && token.balanceOf(address(engine)) == 0
            && _recognized == _eligible + _future + _released && r.protectedNaraSnapshot == _rewardSnapshot
            && r.pendingNaraDelta == _rewardPending && int256(_rewardSnapshot) + _rewardPending == int256(_assets[0].custody);
    }
    function echidna_model_state_matches_historical_inputs() external view returns (bool) {
        EmissionState memory s = engine.emissionState();
        return s.baseEmission == _modelState.baseEmission && s.warmupFactorWad == _modelState.warmupFactorWad
            && s.stressWad == _modelState.stressWad && s.bootstrapWeight == _modelState.bootstrapWeight;
    }
    function echidna_emission_reference_matches_oracle() external view returns (bool) {
        (uint256 naraPerEpoch, uint64 samples) = engine.emissionReference();
        return samples == _referenceSamples
            && naraPerEpoch == (_referenceWeight == 0 ? 0 : _referenceSum * 1e18 / _referenceWeight);
    }

    function echidna_nft_receipts_and_owners() external view returns (bool) {
        if (nft.mintedCount() != _minted || nft.core() != address(principal) || nft.rewards() != address(rewards)) return false;
        uint256[3] memory balances; uint256 consumed; uint256 retiredFrames; uint256 materializations; uint256 live;
        for (uint256 i; i < _positions.length; ++i) {
            PositionOracle storage p = _positions[i];
            NARAPositionNFTV5.Receipt memory active = nft.receiptInfo(p.activeTokenId);
            if (active.positionId != p.frameId || active.generation != p.generation
                || active.kind != NARAPositionNFTV5.ReceiptKind.Active
                || nft.tokenIdOf(p.frameId, p.generation) != p.activeTokenId
                || nft.dormantTokenIdOf(p.frameId, p.generation) != p.dormantTokenId
                || nft.receiptTransferNonce(p.activeTokenId) != p.activeTransferNonce
                || !_frameMatches(p.activeTokenId, p.frameId)) return false;
            if (p.dormantTokenId != 0) {
                ++materializations;
                if (!p.withdrawn || _next < p.end || !_burned(p.activeTokenId)
                    || nft.receiptTransferNonce(p.dormantTokenId) != p.dormantTransferNonce
                    || !_frameMatches(p.dormantTokenId, p.frameId)) return false;
                NARAPositionNFTV5.Receipt memory dormant = nft.receiptInfo(p.dormantTokenId);
                if (dormant.positionId != p.frameId || dormant.generation != p.generation
                    || dormant.kind != NARAPositionNFTV5.ReceiptKind.Dormant) return false;
            }
            if (nft.activeOwnerOf(p.frameId, p.generation) != (p.dormantTokenId == 0 && !p.fusionConsumed ? p.owner : address(0))) return false;
            if (p.dormantConsumed) {
                ++consumed;
                if (_isCurrent(i) || p.dormantTokenId == 0 || !_burned(p.dormantTokenId) || p.approved != address(0)) return false;
                continue;
            }
            if (p.fusionConsumed) {
                ++retiredFrames;
                if (!_isCurrent(i) || p.withdrawn || p.dormantTokenId != 0 || !_burned(p.activeTokenId) || p.approved != address(0)) return false;
                continue;
            }
            if (!_isCurrent(i)) return false;
            uint256 liveId = p.dormantTokenId == 0 ? p.activeTokenId : p.dormantTokenId;
            address liveOwner = p.dormantTokenId == 0 ? p.owner : p.dormantOwner;
            try nft.ownerOf(liveId) returns (address owner) { if (owner != liveOwner) return false; } catch { return false; }
            if (nft.getApproved(liveId) != p.approved) return false;
            ++live;
            if (liveOwner == address(this)) ++balances[0];
            else if (liveOwner == address(actors[0])) ++balances[1];
            else if (liveOwner == address(actors[1])) ++balances[2];
            else return false;
        }
        return _positions.length == _frameCount + consumed && _minted == _positions.length + materializations
            && live + retiredFrames == _frameCount && nft.balanceOf(address(this)) == balances[0]
            && nft.balanceOf(address(actors[0])) == balances[1] && nft.balanceOf(address(actors[1])) == balances[2];
    }

    function oracleRecordCount() external view returns (uint256) { return _positions.length; }
    function oracleFrameCount() external view returns (uint256) { return _frameCount; }
    function oraclePosition(uint256 index) external view returns (PositionOracle memory) { return _positions[index]; }
    function oracleHeadIndex(uint256 frame) external view returns (uint256) { return _frames[frame].headIndexPlusOne - 1; }

    function actionRecharge(uint8 recordEntropy, uint96 amountEntropy, uint8 durationEntropy) external {
        if (_positions.length == 0 || _positions.length >= MAX_GENERATION_RECORDS) return;
        uint256 i = uint256(recordEntropy) % _positions.length; PositionOracle storage old = _positions[i];
        EpochClock memory c = engine.clock();
        if (!_rechargeReady(i, c)) return;
        address owner = old.dormantOwner; uint256 upper = _fundingUpper(owner); if (upper == 0) return;
        uint256 amount = uint256(amountEntropy) % upper + 1; uint32 duration = _duration(durationEntropy);
        uint256 frame = old.frameId; uint64 expectedGeneration = old.generation + 1;
        bytes32 oldState = _archivedStateHash(old);
        uint256 payerBefore = token.balanceOf(owner); uint256 custodyBefore = token.balanceOf(address(principal));
        CommonRechargeRequestV5 memory request = _rechargeRequest(old, amount, duration);
        (bool ok, bytes memory data) = _invoke(owner, address(principal), abi.encodeCall(principal.rechargeCommon, (request)));
        if (!ok) { _fail("RECHARGE_REVERT"); return; }
        if (abi.decode(data, (uint64)) != expectedGeneration) { _fail("RECHARGE_GENERATION"); return; }
        if (token.balanceOf(owner) + amount != payerBefore || token.balanceOf(address(principal)) != custodyBefore + amount)
            _fail("RECHARGE_RECEIPT");
        if (_archivedStateHash(old) != oldState) _fail("RECHARGE_OLD_STATE");
        old.dormantConsumed = true; ++old.dormantTransferNonce; old.approved = address(0);
        _appendGeneration(frame, expectedGeneration, owner, amount, duration, c.wallEpoch);
        ++successfulRecharges;
        if (expectedGeneration >= 3 && (coverageMask & (1 << 20)) == 0) {
            _cover(20, expectedGeneration);
            emit PathCommonRecharged(expectedGeneration); // COVERAGE_MARKER: repeated same-frame Common recharge through generation three
        }
    }

    // P2.4 LC-INV C/SC/NR/D02 (design §5.6, §8.3): the award-preserving recharge through the real Forge. The oracle
    // prices the rent independently (design §5.4, Q4: 25% of the 20% tranche over the new lock's own duration, one
    // share floor each, one final ceiling, the 1-NARA floor) and predicts the capped weight on min(P, C) with the
    // frame's recorded C, A and Daw; the rent is unsynced Reserve NARA until a sync.
    function actionEntropyRechargeAwarded(uint8 recordEntropy, uint96 amountEntropy, uint8 durationEntropy) external {
        if (_positions.length == 0 || _positions.length >= MAX_GENERATION_RECORDS) return;
        uint256 i = uint256(recordEntropy) % _positions.length; PositionOracle storage old = _positions[i];
        EpochClock memory c = engine.clock();
        if (!_rechargeReady(i, c) || _referenceSamples < REFERENCE_WINDOW) return;
        uint256 frame = old.frameId; FrameAwardV5 memory a = lifecycle.award(frame); if (a.tier == 0) return;
        address owner = old.dormantOwner; uint256 upper = _fundingUpper(owner); if (upper == 0) return;
        uint256 amount = uint256(amountEntropy) % upper + 1; uint32 duration = _duration(durationEntropy);
        uint256 d = _durationWad(duration);
        uint256 rare = (d * amount * 1e18 + _min(amount, a.originalCap) * (a.multiplierWad - 1e18) * _min(d, a.awardedDurationWad)) / 1e36;
        uint256 rent = _awardedRent(rare, amount * d / 1e18, duration);
        if (token.balanceOf(owner) < amount + rent) return;
        uint64 expectedGeneration = old.generation + 1; bytes32 oldState = _archivedStateHash(old);
        uint256 payerBefore = token.balanceOf(owner); uint256 custodyBefore = token.balanceOf(address(principal));
        uint256 reserveBefore = token.balanceOf(address(reserve));
        (bool ok, bytes memory data) = _invoke(owner, address(forge), abi.encodeCall(forge.rechargeAwarded,
            (RechargeAwardedRequestV5(_rechargeRequest(old, amount, duration), rent))));
        if (!ok) { _fail("AWARDED_RECHARGE_REVERT"); return; }
        if (abi.decode(data, (uint64)) != expectedGeneration) { _fail("AWARDED_RECHARGE_GENERATION"); return; }
        if (token.balanceOf(owner) + amount + rent != payerBefore || token.balanceOf(address(principal)) != custodyBefore + amount
            || token.balanceOf(address(reserve)) != reserveBefore + rent) _fail("AWARDED_RECHARGE_RECEIPT");
        if (_archivedStateHash(old) != oldState) _fail("AWARDED_RECHARGE_OLD_STATE");
        FrameAwardV5 memory after_ = lifecycle.award(frame);
        if (after_.awardedGeneration != expectedGeneration || after_.originalCap != a.originalCap || after_.tier != a.tier
            || after_.multiplierWad != a.multiplierWad || after_.awardedDurationWad != a.awardedDurationWad
            || after_.attemptId != a.attemptId) _fail("AWARDED_RECHARGE_RECORD");
        old.dormantConsumed = true; ++old.dormantTransferNonce; old.approved = address(0);
        _unsynced += rent;
        _appendAwardedGeneration(frame, expectedGeneration, owner, amount, duration, c.wallEpoch, rare, a.attemptId);
        ++successfulRecharges; ++awardedRecharges;
    }
    function _awardedRent(uint256 rare, uint256 common, uint32 duration) private view returns (uint256 rent) {
        uint256 total = principal.principalAccounting().activeRewardWeight;
        if (total != 0) {
            uint256 gain = rare * total / (total + rare) - common * total / (total + common);
            uint256 den = 20 * total;
            rent = ((_referenceSum * 1e18 / _referenceWeight) * duration * gain + den - 1) / den;
        }
        if (rent < 1 ether) rent = 1 ether;
    }
    function _appendAwardedGeneration(uint256 frame, uint64 generation, address owner, uint256 amount, uint32 duration,
        uint64 wall, uint256 rewardWeight, bytes32 attemptId) private
    {
        _appendGeneration(frame, generation, owner, amount, duration, wall);
        PositionOracle storage p = _positions[_positions.length - 1];
        p.weight = rewardWeight; // the frame's award on min(P, C); baseWeight stays the Common model weight
        PositionState memory birth;
        birth.generationOwner = owner; birth.generation = generation; birth.createdEpoch = wall;
        birth.activation = p.activation; birth.maturity = p.end; birth.effectiveEnd = p.end; birth.duration = duration;
        birth.principal = amount; birth.modelWeight = p.baseWeight; birth.rewardWeight = rewardWeight;
        p.birthTermsHash = keccak256(abi.encode(keccak256("NARA_V5_MODULAR_AWARDED_TERMS_V1"),
            block.chainid, address(principal), principal.policy().policyHash, frame, birth, attemptId));
    }

    function _recordGenerationClaim(PositionOracle storage p, uint8 asset, uint256 amount) private {
        if (p.dormantConsumed) {
            ++archivedAssetClaims[asset];
            if ((coverageMask & (1 << 21)) == 0 && archivedAssetClaims[0] != 0
                && archivedAssetClaims[1] != 0 && archivedAssetClaims[2] != 0) {
                _cover(21, amount);
                emit PathArchivedGenerationClaimed(amount); // COVERAGE_MARKER: all three assets positively claimed from archived generations after recharge
            }
        }
        if (p.generation > 1) {
            ++rechargedAssetClaims[asset];
            if ((coverageMask & (1 << 22)) == 0 && rechargedAssetClaims[0] != 0
                && rechargedAssetClaims[1] != 0 && rechargedAssetClaims[2] != 0) {
                _cover(22, amount);
                emit PathRechargedGenerationClaimed(amount); // COVERAGE_MARKER: all three assets positively claimed from recharged generations
            }
        }
    }

    function actionRejectedRecharge(uint8 recordEntropy, uint8 modeEntropy) external {
        if (_positions.length == 0) return;
        uint256 i = uint256(recordEntropy) % _positions.length; PositionOracle storage p = _positions[i];
        uint8 mode = modeEntropy % 4; address caller = p.dormantOwner; bytes memory expectedError;
        EpochClock memory c = engine.clock();
        if (mode == 1) {
            if (!p.dormantConsumed || _isCurrent(i)) return;
            expectedError = abi.encodeWithSelector(NARAPrincipalLedgerV5.RechargeBlocked.selector, CommonRechargeBlockerV5.StaleGeneration);
        } else {
            if (!_rechargeReady(i, c)) return;
            if (mode == 0) {
                if (!p.savedDormantNonce || p.replayDormantNonce >= p.dormantTransferNonce) return;
                expectedError = abi.encodeWithSelector(NARAPrincipalLedgerV5.RechargeBlocked.selector, CommonRechargeBlockerV5.StaleTransferNonce);
            } else if (mode == 2) {
                if (caller != address(actors[0]) && caller != address(actors[1])) return;
                // P2.5 (A10): the recharge mint runs no receiver code, so a rejecting receiver no longer blocks a
                // recharge. The probe completes the recharge with the hook rejecting, then reverts with this sentinel,
                // which rolls the recharge back; any receiver call would surface as "receiver rejection" instead.
                expectedError = abi.encodeWithSelector(RechargeProbeCompleted.selector, p.generation + 1);
            } else {
                caller = p.owner != p.dormantOwner ? p.owner : _differentOwner(p.dormantOwner, 1);
                expectedError = abi.encodeWithSelector(NARAPrincipalLedgerV5.RechargeBlocked.selector, CommonRechargeBlockerV5.NotDormantOwner);
            }
        }
        uint256 upper = _fundingUpper(caller);
        if (upper == 0) return;
        if (mode == 3) {
            (bool approved,) = _invoke(p.dormantOwner, address(nft), abi.encodeCall(nft.approve, (caller, p.dormantTokenId)));
            if (!approved) { _fail("RECHARGE_OPERATOR_APPROVAL"); return; }
            p.approved = caller;
        }
        CommonRechargeRequestV5 memory request = _rechargeRequest(p, _min(upper, 2 ether + 1), 96);
        if (mode == 0) request.expectedTransferNonce = p.replayDormantNonce;
        bytes32 beforeState = _rechargeRollbackHash(p, caller);
        if (mode == 2) ModularFuzzActor(payable(caller)).rejectNft(true);
        (bool ok, bytes memory data) = mode == 2 ? address(this).call(abi.encodeCall(this.probeRecharge, (caller, request)))
            : _invoke(caller, address(principal), abi.encodeCall(principal.rechargeCommon, (request)));
        if (mode == 2) ModularFuzzActor(payable(caller)).rejectNft(false);
        if (ok || keccak256(data) != keccak256(expectedError)) { _fail("RECHARGE_REJECTION"); return; }
        if (_rechargeRollbackHash(p, caller) != beforeState) { _fail("RECHARGE_ROLLBACK"); return; }
        ++rejectedRechargeModes[mode];
        if ((coverageMask & (1 << 23)) == 0 && rejectedRechargeModes[0] != 0 && rejectedRechargeModes[1] != 0
            && rejectedRechargeModes[2] != 0 && rejectedRechargeModes[3] != 0) {
            _cover(23, mode);
            emit PathRechargeFailureRolledBack(mode); // COVERAGE_MARKER: all four recharge rejection modes restore funding and receipts
        }
    }

    function _appendGeneration(uint256 frame, uint64 generation, address owner, uint256 amount, uint32 duration, uint64 wall) private {
        _positions.push(); PositionOracle storage p = _positions[_positions.length - 1];
        p.frameId = frame; p.generation = generation; p.duration = duration; p.owner = owner;
        p.amount = amount; p.created = wall; p.activation = wall + 1; p.end = p.activation + duration;
        p.withdrawalBoundary = type(uint64).max;
        // Independent V4Quadratic rendition (P2.9; NARAPrincipalPreviewV5.sol:103-105): 1 + 0.5 r + 2.5 r^2, r = d / 35,040.
        uint256 ratio = uint256(duration) * 1e18 / 35_040;
        p.weight = amount * (1e18 + (1e18 / 2) * ratio / 1e18 + (5 * 1e18 / 2) * (ratio * ratio / 1e18) / 1e18) / 1e18;
        p.baseWeight = p.weight; // Common only; keep the two denominators explicit.
        p.activeTokenId = ++_minted;
        if (nft.tokenIdOf(frame, generation) != p.activeTokenId) _fail("GENERATION_RECEIPT_ID");
        _frames[frame].headIndexPlusOne = _positions.length;
        if (generation == 1) _frames[frame].originTokenId = p.activeTokenId;
        PositionState memory birth;
        birth.generationOwner = owner; birth.generation = generation; birth.createdEpoch = wall;
        birth.activation = p.activation; birth.maturity = p.end; birth.effectiveEnd = p.end; birth.duration = duration;
        birth.principal = amount; birth.modelWeight = p.baseWeight; birth.rewardWeight = p.weight;
        // Predict the initial binding from request/clock/independent Common weight.
        // Future owner/withdrawal changes must not rewrite this birth commitment.
        p.birthTermsHash = keccak256(abi.encode(keccak256("NARA_V5_MODULAR_PRINCIPAL_TERMS_V1"),
            block.chainid, address(principal), principal.policy().policyHash, frame, birth));
        _principalInventory += amount;
    }
    function _duration(uint8 entropy) private pure returns (uint32) {
        return entropy % 4 == 0 ? 96 : entropy % 4 == 1 ? 97 : entropy % 4 == 2 ? 192 : 35_040;
    }
    function _fundingUpper(address owner) private view returns (uint256) {
        return _min(token.balanceOf(owner), _min(10_000 ether, SUPPLY - _principalInventory));
    }
    function _isCurrent(uint256 i) private view returns (bool) { return _frames[_positions[i].frameId].headIndexPlusOne == i + 1; }
    function _rechargeReady(uint256 i, EpochClock memory c) private view returns (bool) {
        PositionOracle storage p = _positions[i];
        // P2.4 (R1): a frame that holds an award recharges as Common too; the award-preserving path is
        // actionEntropyRechargeAwarded.
        return _isCurrent(i) && p.withdrawn && p.dormantTokenId != 0 && !p.dormantConsumed
            && lifecycle.pendingAttempt(p.frameId, p.generation) == bytes32(0)
            && c.started && c.backlog == 0 && _next >= p.end;
    }
    function _rechargeRequest(PositionOracle storage p, uint256 amount, uint32 duration)
        private view returns (CommonRechargeRequestV5 memory)
    {
        return CommonRechargeRequestV5(p.frameId, p.generation, p.dormantTokenId, p.dormantTransferNonce,
            CreateRequest(amount, duration, principal.policy().policyHash, type(uint64).max));
    }
    function _assetBalance(uint8 asset, address owner) private view returns (uint256) {
        return asset == 0 ? token.balanceOf(owner) : asset == 1 ? owner.balance : usdc.balanceOf(owner);
    }
    function _termsMatch(PositionOracle storage p, PositionState memory s) private view returns (bool) {
        return s.generationOwner == p.owner && s.generation == p.generation && s.principal == p.amount
            && s.modelWeight == p.baseWeight && s.rewardWeight == _weightAt(p, _next) && s.createdEpoch == p.created
            && s.activation == p.activation && s.maturity == p.activation + p.duration && s.effectiveEnd == p.end && s.duration == p.duration
            && s.withdrawn == p.withdrawn && !s.earlyExitEnabled && s.earlyExitBps == 0
            && s.penalty == 0 && s.penaltyCapacityReserved == 0 && s.termsHash == p.birthTermsHash;
    }
    function _archivedStateHash(PositionOracle storage p) private view returns (bytes32) {
        return keccak256(abi.encode(principal.position(p.frameId, p.generation),
            rewards.claimAnchor(p.frameId, p.generation, RewardAsset.NARA),
            rewards.claimAnchor(p.frameId, p.generation, RewardAsset.ETH),
            rewards.claimAnchor(p.frameId, p.generation, RewardAsset.USDC)));
    }
    function _rechargeRollbackHash(PositionOracle storage p, address payer) private view returns (bytes32) {
        bytes32 financial = keccak256(abi.encode(_archivedStateHash(p), principal.positionHead(p.frameId),
            principal.principalAccounting(), rewards.rewardState(),
            rewards.rewardAccounting(RewardAsset.NARA), rewards.rewardAccounting(RewardAsset.ETH), rewards.rewardAccounting(RewardAsset.USDC)));
        bytes32 receipts = keccak256(abi.encode(nft.mintedCount(), nft.tokenIdOf(p.frameId, p.generation + 1),
            _receiptStateHash(p.activeTokenId), _receiptStateHash(p.dormantTokenId)));
        return keccak256(abi.encode(financial, receipts, token.balanceOf(payer), token.balanceOf(address(principal)),
            token.allowance(payer, address(principal)), token.totalSupply()));
    }
    function _receiptStateHash(uint256 id) private view returns (bytes32) {
        if (id == 0) return bytes32(0);
        address owner; address approved;
        try nft.ownerOf(id) returns (address found) { owner = found; approved = nft.getApproved(id); } catch {}
        return keccak256(abi.encode(nft.receiptInfo(id), nft.receiptTransferNonce(id), owner, approved));
    }
    function _frameMatches(uint256 tokenId, uint256 expectedFrame) private view returns (bool) {
        (uint256 frame, uint256 origin, uint256 version, bytes32 seed) = nft.frameInfo(tokenId);
        bytes32 domain = keccak256(abi.encode(keccak256("NARA_V5_COSMETIC_FRAME_V1"), block.chainid, address(nft)));
        return frame == expectedFrame && origin == _frames[expectedFrame].originTokenId && version == 1
            && seed == keccak256(abi.encode(domain, expectedFrame, origin));
    }
    function _nonexistent(bytes memory result, uint256 id) private pure returns (bool) {
        return keccak256(result) == keccak256(abi.encodeWithSignature("ERC721NonexistentToken(uint256)", id));
    }
    function _burned(uint256 id) private view returns (bool) {
        try nft.ownerOf(id) returns (address) { return false; } catch (bytes memory data) { if (!_nonexistent(data, id)) return false; }
        try nft.tokenURI(id) returns (string memory) { return false; } catch (bytes memory data) { if (!_nonexistent(data, id)) return false; }
        try positionLens.snapshot(address(nft), id) returns (PositionViewV5 memory) { return false; } catch {}
        return true;
    }

    function _historicalPrincipal(uint64 epoch) private view returns (uint256 capital, uint256 baseWeight, uint256 rarityWeight) {
        for (uint256 i; i < _positions.length; ++i) {
            PositionOracle storage p = _positions[i];
            if (p.created + 1 <= epoch && epoch < p.withdrawalBoundary) capital += p.amount;
            if (p.activation <= epoch && epoch < p.end) { baseWeight += p.baseWeight; rarityWeight += _weightAt(p, epoch); }
        }
    }
    function _recordFunding(uint256 amount, uint256 sequence, uint64 epoch, uint64 wall, uint256 expected) private {
        if (amount != expected || sequence != _sequence + 1 || epoch != wall + 1) _fail("FUNDING_RECEIPT");
        _sequence += 1; _recognized += expected; _future += expected; _fundingAt[wall + 1] += expected;
    }
    function _scheduleReward(uint64 epoch, int256 delta) private { _rewardChanges[epoch] += delta; _rewardPending += delta; }
    function _owner(uint8 entropy) private view returns (address) { return entropy % 3 == 0 ? address(this) : address(actors[entropy % 3 - 1]); }
    function _differentOwner(address current, uint8 entropy) private view returns (address next) {
        next = _owner(entropy);
        if (next == current) next = current == address(actors[0]) ? address(actors[1]) : address(actors[0]);
    }
    function _invoke(address owner, address target, bytes memory data) private returns (bool, bytes memory) {
        return owner == address(this) ? target.call(data) : ModularFuzzActor(payable(owner)).invoke(target, data);
    }
    /// @dev P2.5 (A10) probe for actionRejectedRecharge mode 2: this harness only. It runs the recharge as `caller` and
    /// always reverts, so it never changes state; RechargeProbeCompleted proves the recharge reached its end.
    error RechargeProbeCompleted(uint64 generation);
    function probeRecharge(address caller, CommonRechargeRequestV5 calldata request) external {
        require(msg.sender == address(this), "harness probe only");
        (bool ok, bytes memory data) = _invoke(caller, address(principal), abi.encodeCall(principal.rechargeCommon, (request)));
        if (!ok) assembly ("memory-safe") { revert(add(data, 32), mload(data)) }
        revert RechargeProbeCompleted(abi.decode(data, (uint64)));
    }
    function oracleSaleOffer(uint256 tokenId) external view returns (SaleOfferOracle memory) { return _saleOffers[tokenId]; }

    function echidna_sale_listings_and_bindings() external view returns (bool) {
        if (address(sale.nft()) != address(nft) || address(sale.principal()) != address(principal)
            || address(sale.rewards()) != address(rewards) || address(sale.creditLens()).code.length == 0
            || address(sale.ingress()) != address(ingress) || address(ingress.rewards()) != address(rewards)
            || sale.maxListingLifetime() != SALE_LIFETIME || sale.FEE_BPS() != SALE_FEE_BPS
            || sale.outstandingProceeds() != saleProceedsTotal
            || sale.lastListingId() != saleLastId) return false;
        for (uint8 o; o < 3; ++o) {
            address owner = _owner(o);
            if (sale.sellerNonce(owner) != _sellerNonce[owner] || sale.proceeds(owner) != _proceeds[owner]) return false;
        }
        for (uint256 i; i < _positions.length; ++i) {
            PositionOracle storage p = _positions[i];
            if (keccak256(abi.encode(sale.listing(p.activeTokenId))) != keccak256(abi.encode(_saleOffers[p.activeTokenId]))) return false;
            if (p.dormantTokenId != 0 && sale.listing(p.dormantTokenId).listingId != 0) return false;
        }
        return true;
    }

    function echidna_sale_native_balances() external view returns (bool) {
        return address(this).balance == nativeExpected[0] && address(actors[0]).balance == nativeExpected[1]
            && address(actors[1]).balance == nativeExpected[2] && address(sale).balance == saleSurplus + saleProceedsTotal
            && address(ingress).balance == ingressFees
            && address(rewards).balance == _assets[1].custody
            && nativeExpected[0] + nativeExpected[1] + nativeExpected[2] + saleSurplus + saleProceedsTotal + ingressFees
                + _assets[1].custody == initialNative;
    }

    function actionSaleApprove(uint8 entropy, uint8 allowed) external {
        if (_positions.length == 0) return;
        uint256 i = entropy % _positions.length; if (!_saleLive(i)) return;
        _approveSale(_positions[i], allowed % 2 == 1);
    }
    function actionSaleList(uint8 entropy, uint96 priceEntropy, uint8 expiryEntropy) external {
        if (_positions.length == 0) return;
        uint256 i = entropy % _positions.length; if (!_saleLive(i)) return;
        _listSale(_positions[i], uint256(priceEntropy) % 1e12 + 1, uint64(block.timestamp + 1 + uint256(expiryEntropy) * 900));
    }
    function actionSaleCancel(uint8 entropy) external {
        if (_positions.length == 0) return;
        _cancelSale(_positions[entropy % _positions.length]);
    }
    function actionSalePurchase(uint8 entropy, uint8 buyerEntropy, uint8 selfEntropy) external {
        if (_positions.length == 0) return;
        uint256 i = entropy % _positions.length; if (!_saleReady(i)) return;
        address buyer = selfEntropy % 2 == 1 ? _positions[i].owner : _differentOwner(_positions[i].owner, buyerEntropy);
        _purchaseSale(i, buyer);
    }

    // 0 replaced ID; 1 cancelled ID; 2 consumed ID; 3 self nonce;
    // 4 round-trip nonce; 5 withdrawn; 6 burned; 7 burned after recharge;
    // 8 seller-wide cancelAll counter.
    function actionSaleStale(uint8 entropy, uint8 modeEntropy) external {
        if (_positions.length == 0) return;
        uint256 i = entropy % _positions.length; uint8 mode = modeEntropy % 9;
        PositionOracle storage p = _positions[i];
        address buyer = _differentOwner(p.owner, 1);
        if (mode == 6 || mode == 7) {
            if (p.dormantTokenId == 0 || _saleOffers[p.activeTokenId].listingId == 0
                || _saleOffers[p.activeTokenId].expiry < block.timestamp
                || (mode == 6 ? !_isCurrent(i) : !p.dormantConsumed)) return;
            SaleOfferOracle memory burnedOffer = _saleOffers[p.activeTokenId];
            if (!_purchaseRejected(p, buyer, _bounds(p, burnedOffer.listingId), burnedOffer.price,
                abi.encodeWithSignature("ERC721NonexistentToken(uint256)", p.activeTokenId))) return;
        } else {
            if (!_saleLive(i) || (mode == 5 && engine.clock().wallEpoch < p.end)) return;
            if (!_setupSale(p)) return;
            SaleOfferOracle memory offer = _saleOffers[p.activeTokenId];
            NARAPositionSaleV5.BuyerBounds memory bounds = _bounds(p, offer.listingId);
            bytes memory expected = abi.encodeWithSelector(NARAPositionSaleV5.InvalidListing.selector);
            if (mode == 0) {
                if (!_listSale(p, offer.price + 1, _expiry())) return;
                if (!_saleRejected(p, offer.seller, abi.encodeCall(sale.cancel, (p.activeTokenId, offer.listingId)), 0,
                    abi.encodeWithSelector(NARAPositionSaleV5.InvalidListing.selector))) return;
            }
            else if (mode == 1) { if (!_cancelSale(p)) return; }
            else if (mode == 2) { if (!_purchaseSale(i, buyer)) return; }
            else if (mode == 3) { if (!_saleTransfer(p, p.owner)) return; }
            else if (mode == 4) {
                address seller = p.owner;
                if (!_saleTransfer(p, buyer) || !_saleTransfer(p, seller)) return;
            } else if (mode == 8) {
                // One seller-wide cancelAll voids the live record without touching it.
                (bool ok,) = _invoke(p.owner, address(sale), abi.encodeCall(sale.cancelAll, ()));
                if (!ok) { _fail("SALE_CANCEL_ALL_REVERT"); return; }
                ++_sellerNonce[p.owner];
            } else { this.actionWithdraw(uint8(i)); if (!p.withdrawn) { _fail("SALE_WITHDRAW_SETUP"); return; } }
            if (mode >= 3 && mode <= 7) expected = abi.encodeWithSelector(NARAPositionSaleV5.InvalidBacking.selector);
            if (!_purchaseRejected(p, buyer, bounds, offer.price, expected)) return;
            if ((mode < 5 && mode != 2) || mode == 8) {
                if (!_setupSale(p) || !_purchaseSale(i, buyer)) return;
            }
        }
        ++saleStaleModes[mode]; _saleGroups(mode);
    }

    // 0 underpay; 1 overpay; 2 expired offer; 3 expired deadline;
    // 4 principal floor; 5 checkpoint floor; 6..8 stale selected-asset credit;
    // 9 approval; 10 unauthorized list; 11 unauthorized cancel;
    // 12 zero listing price; 13 nonfuture listing expiry; 14 expiry beyond the lifetime cap.
    function actionSaleInput(uint8 entropy, uint8 modeEntropy) external {
        if (_positions.length == 0) return;
        uint256 i = entropy % _positions.length; uint8 mode = modeEntropy % 15;
        if (!_saleLive(i)) return;
        PositionOracle storage p = _positions[i]; address buyer = _differentOwner(p.owner, 1);
        if (mode >= 6 && mode <= 8 && (p.credits[mode - 6] < RAY || p.credits[mode - 6] % RAY == 0)) return;
        if (mode == 2) {
            SaleOfferOracle storage expired = _saleOffers[p.activeTokenId];
            if (expired.listingId == 0 || expired.expiry >= block.timestamp || expired.seller != p.owner
                || expired.transferNonce != p.activeTransferNonce) return;
            if (!_approveSale(p, true)) return;
        } else if (!_setupSale(p)) return;
        SaleOfferOracle memory offer = _saleOffers[p.activeTokenId];
        NARAPositionSaleV5.BuyerBounds memory bounds = _bounds(p, offer.listingId);
        uint256 value = offer.price; bytes memory expected;
        if (mode <= 1) { value = mode == 0 ? value - 1 : value + 1; expected = abi.encodeWithSelector(NARAPositionSaleV5.InvalidPayment.selector); }
        else if (mode <= 3) {
            if (mode == 3) bounds.deadline = uint64(block.timestamp - 1);
            expected = abi.encodeWithSelector(NARAPositionSaleV5.Expired.selector);
        } else if (mode <= 8) {
            if (mode == 4) ++bounds.minPrincipal;
            else if (mode == 5) ++bounds.minRewardCheckpoint;
            else this.actionClaim(uint8(i), mode - 6);
            expected = abi.encodeWithSelector(NARAPositionSaleV5.InvalidBacking.selector);
        } else if (mode == 9) {
            if (!_approveSale(p, false)) return;
            expected = abi.encodeWithSignature("ERC721InsufficientApproval(address,uint256)", address(sale), p.activeTokenId);
        }
        if (mode < 10) {
            if (!_purchaseRejected(p, buyer, bounds, value, expected)) return;
        } else {
            bytes memory input; address caller = p.owner;
            if (mode == 10) { caller = buyer; input = abi.encodeCall(sale.list, (p.activeTokenId, offer.price, _expiry())); }
            else if (mode == 11) { caller = buyer; input = abi.encodeCall(sale.cancel, (p.activeTokenId, offer.listingId)); }
            else input = abi.encodeCall(sale.list, (p.activeTokenId, mode == 12 ? 0 : offer.price,
                mode == 13 ? uint64(block.timestamp) : mode == 14 ? uint64(block.timestamp + SALE_LIFETIME + 1) : _expiry()));
            expected = mode <= 11 ? abi.encodeWithSelector(NARAPositionSaleV5.Unauthorized.selector)
                : mode == 12 ? abi.encodeWithSelector(NARAPositionSaleV5.InvalidPayment.selector)
                : mode == 13 ? abi.encodeWithSelector(NARAPositionSaleV5.Expired.selector)
                : abi.encodeWithSelector(NARAPositionSaleV5.InvalidExpiry.selector);
            if (!_saleRejected(p, caller, input, 0, expected)) return;
        }
        if (mode == 2) { if (!_listSale(p, offer.price, _expiry())) return; }
        if (mode == 9 && !_approveSale(p, true)) return;
        if (!_purchaseSale(i, buyer)) return;
        ++saleInputModes[mode]; _saleGroups(mode);
    }

    // 0 rejecting buyer; 1 rejecting seller; 2 buyer onward; 3 buyer self;
    // 4 seller take/claim/return; 5..7 buyer and 8..10 seller Sale reentry.
    function actionSaleCallback(uint8 entropy, uint8 modeEntropy) external {
        if (_positions.length == 0) return;
        uint256 i = entropy % _positions.length; uint8 mode = modeEntropy % 11;
        if (!_saleLive(i)) return;
        PositionOracle storage p = _positions[i];
        if (mode == 4 && p.credits[0] < RAY) return;
        uint256 other = type(uint256).max;
        if (mode >= 5) {
            for (uint256 j; j < _positions.length; ++j) if (j != i && _saleLive(j)) { other = j; break; }
            if (other == type(uint256).max) return;
        }
        address seller = address(actors[0]); address buyer = address(actors[1]);
        if (p.owner != seller && !_saleTransfer(p, seller)) return;
        if (!_setupSale(p)) return;
        SaleOfferOracle memory offer = _saleOffers[p.activeTokenId];
        NARAPositionSaleV5.BuyerBounds memory bounds = _bounds(p, offer.listingId);
        if (mode == 0) actors[1].configureNFT(address(0), "", 0, true);
        else if (mode == 1) actors[0].configureETH(address(0), "", 0, true);
        else if (mode <= 3) actors[1].configureNFT(address(nft), abi.encodeCall(nft.transferFrom,
            (buyer, mode == 2 ? address(this) : buyer, p.activeTokenId)), 0, false);
        else if (mode == 4) {
            (bool approved,) = _invoke(buyer, address(nft), abi.encodeCall(nft.setApprovalForAll, (seller, true)));
            if (!approved) { _fail("SALE_CALLBACK_APPROVAL"); return; }
            address[] memory targets = new address[](3); bytes[] memory payloads = new bytes[](3);
            targets[0] = address(nft); targets[1] = address(rewards); targets[2] = address(nft);
            payloads[0] = abi.encodeCall(nft.transferFrom, (buyer, seller, p.activeTokenId));
            payloads[1] = abi.encodeCall(rewards.claim, (p.frameId, p.generation, RewardAsset.NARA, seller));
            payloads[2] = abi.encodeCall(nft.transferFrom, (seller, buyer, p.activeTokenId));
            actors[0].configureETH(seller, abi.encodeCall(actors[0].batch, (targets, payloads)), 0, false);
        } else {
            uint8 actorIndex = mode < 8 ? 1 : 0; address caller = address(actors[actorIndex]);
            PositionOracle storage secondary = _positions[other];
            if (secondary.owner != caller && !_saleTransfer(secondary, caller)) return;
            if (!_setupSale(secondary)) return;
            SaleOfferOracle memory secondOffer = _saleOffers[secondary.activeTokenId];
            uint8 method = (mode - 5) % 3; bytes memory payload;
            if (method == 0) payload = abi.encodeCall(sale.list, (secondary.activeTokenId, secondOffer.price, _expiry()));
            else if (method == 1) payload = abi.encodeCall(sale.cancel, (secondary.activeTokenId, secondOffer.listingId));
            else payload = abi.encodeCall(sale.purchase, (secondary.activeTokenId, _bounds(secondary, secondOffer.listingId)));
            if (actorIndex == 1) actors[1].configureNFT(address(sale), payload, method == 2 ? secondOffer.price : 0, false);
            else actors[0].configureETH(address(sale), payload, method == 2 ? secondOffer.price : 0, false);
        }
        bytes32 secondaryBefore;
        if (mode >= 5) secondaryBefore = _salePositionHash(_positions[other]);
        bool accepted;
        if (mode == 1) {
            // Pull payout (P3.4): an ETH-rejecting seller cannot pause its listing. The sale fills,
            // its own withdrawal fails exactly, and the credit still leaves to a recipient it names.
            accepted = _purchaseOnly(i, buyer) && _saleRejected(p, seller, abi.encodeCall(sale.withdrawProceeds, (seller)), 0,
                abi.encodeWithSelector(NARAPositionSaleV5.PaymentFailed.selector)) && _withdrawProceeds(seller, address(this));
        } else if (mode == 4) {
            // The seller runs no code inside a purchase, so there is no take/claim/return window.
            accepted = _purchaseOnly(i, buyer);
            if (accepted && (actors[0].ethCallbackSucceeded() || actors[0].ethCallbackResult().length != 0)) { _fail("SALE_SELLER_CALLBACK"); accepted = false; }
        } else if (mode < 5) {
            bytes memory expected = mode == 0 ? abi.encodeWithSignature("ERC721InvalidReceiver(address)", buyer)
                : abi.encodeWithSelector(NARAPositionSaleV5.InvalidAcquisition.selector);
            accepted = _purchaseRejected(p, buyer, bounds, offer.price, expected);
        } else {
            // Buyer reentry fires inside the purchase; seller reentry fires inside its own withdrawal.
            accepted = mode < 8 ? _purchaseSale(i, buyer) : (_purchaseOnly(i, buyer) && _withdrawProceeds(seller, seller));
            bytes memory expected = abi.encodeWithSignature("ReentrancyGuardReentrantCall()");
            bool nested = mode < 8 ? actors[1].nftCallbackSucceeded() : actors[0].ethCallbackSucceeded();
            bytes memory result = mode < 8 ? actors[1].nftCallbackResult() : actors[0].ethCallbackResult();
            if (nested || keccak256(result) != keccak256(expected)) { _fail("SALE_REENTRY_RESULT"); accepted = false; }
            if (_salePositionHash(_positions[other]) != secondaryBefore) { _fail("SALE_REENTRY_OTHER"); accepted = false; }
        }
        _resetSaleCallbacks();
        if (mode == 4) {
            (bool reset,) = _invoke(buyer, address(nft), abi.encodeCall(nft.setApprovalForAll, (seller, false)));
            if (!reset || nft.isApprovedForAll(buyer, seller)) { _fail("SALE_CALLBACK_RESET"); return; }
        }
        if (!accepted) return;
        if ((mode == 0 || mode == 2 || mode == 3) && !_purchaseSale(i, buyer)) return;
        if (mode == 4 && !_withdrawProceeds(seller, seller)) return;
        // Normal owner listing after completion proves transient guard cleanup.
        if (!_listSale(p, offer.price, _expiry())) return;
        ++saleCallbackModes[mode]; _saleGroups(mode);
    }

    function actionSaleSurplus(uint8 entropy, uint96 amountEntropy) external {
        if (_positions.length == 0 || nativeExpected[0] == 0) return;
        uint256 i = entropy % _positions.length; if (!_saleLive(i)) return;
        PositionOracle storage p = _positions[i]; address buyer = _differentOwner(p.owner, 1);
        if (!_setupSale(p)) return;
        uint256 amount = uint256(amountEntropy) % _min(nativeExpected[0], 1e12) + 1;
        new ModularSaleForceETH{value: amount}(payable(address(sale)));
        nativeExpected[0] -= amount; saleSurplus += amount;
        SaleOfferOracle memory offer = _saleOffers[p.activeTokenId];
        if (!_purchaseRejected(p, buyer, _bounds(p, offer.listingId), offer.price - 1,
            abi.encodeWithSelector(NARAPositionSaleV5.InvalidPayment.selector)) || !_purchaseSale(i, buyer)) return;
        if (address(sale).balance != saleSurplus) { _fail("SALE_SURPLUS_SPENT"); return; }
        ++saleSurplusChecks; _saleGroups(amount);
    }

    function _saleLive(uint256 i) private view returns (bool) { return _isCurrent(i) && !_positions[i].withdrawn && !_positions[i].fusionConsumed
        && lifecycle.pendingAttempt(_positions[i].frameId, _positions[i].generation) == bytes32(0); }
    function _saleReady(uint256 i) private view returns (bool) {
        if (!_saleLive(i)) return false;
        PositionOracle storage p = _positions[i]; SaleOfferOracle storage offer = _saleOffers[p.activeTokenId];
        return offer.listingId != 0 && offer.seller == p.owner && offer.transferNonce == p.activeTransferNonce
            && offer.sellerNonce == _sellerNonce[offer.seller]
            && offer.expiry >= block.timestamp && p.approved == address(sale);
    }
    function _expiry() private view returns (uint64) { return uint64(block.timestamp + 1 days); }
    function _setupSale(PositionOracle storage p) private returns (bool) {
        return _approveSale(p, true) && _listSale(p, 1_000_003, _expiry());
    }
    function _approveSale(PositionOracle storage p, bool allowed) private returns (bool) {
        (bool ok,) = _invoke(p.owner, address(nft), abi.encodeCall(nft.approve, (allowed ? address(sale) : address(0), p.activeTokenId)));
        if (!ok) { _fail("SALE_APPROVAL_REVERT"); return false; }
        p.approved = allowed ? address(sale) : address(0); ++saleLifecycleModes[allowed ? 0 : 1]; _saleGroups(p.activeTokenId); return true;
    }
    function _listSale(PositionOracle storage p, uint256 price, uint64 expiry) private returns (bool) {
        bool replacement = _saleOffers[p.activeTokenId].listingId != 0;
        (bool ok, bytes memory data) = _invoke(p.owner, address(sale), abi.encodeCall(sale.list, (p.activeTokenId, price, expiry)));
        if (!ok) { _fail("SALE_LIST_REVERT"); return false; }
        ++saleLastId;
        if (abi.decode(data, (uint256)) != saleLastId) { _fail("SALE_LIST_ID"); return false; }
        _saleOffers[p.activeTokenId] = SaleOfferOracle(saleLastId, p.owner, p.activeTokenId, p.activeTransferNonce,
            p.frameId, p.generation, p.birthTermsHash, price, expiry, _sellerNonce[p.owner]);
        ++saleLifecycleModes[2]; if (replacement) ++saleLifecycleModes[3]; _saleGroups(p.activeTokenId); return true;
    }
    function _cancelSale(PositionOracle storage p) private returns (bool) {
        SaleOfferOracle memory offer = _saleOffers[p.activeTokenId]; if (offer.listingId == 0) return false;
        (bool ok,) = _invoke(offer.seller, address(sale), abi.encodeCall(sale.cancel, (p.activeTokenId, offer.listingId)));
        if (!ok) { _fail("SALE_CANCEL_REVERT"); return false; }
        delete _saleOffers[p.activeTokenId]; ++saleLifecycleModes[4]; _saleGroups(p.activeTokenId); return true;
    }
    function _bounds(PositionOracle storage p, uint256 id) private view returns (NARAPositionSaleV5.BuyerBounds memory) {
        // Native-unit minima (P3.5): whole claimable units of the oracle's exact scaled credit.
        uint256[3] memory minima = [p.credits[0] / RAY, p.credits[1] / RAY, p.credits[2] / RAY];
        return NARAPositionSaleV5.BuyerBounds(id, p.amount, minima, _next, type(uint64).max, principal.rarityTier(p.frameId, p.generation));
    }
    /// @dev A complete sale: purchase, then the seller collects its net credit.
    function _purchaseSale(uint256 i, address buyer) private returns (bool) {
        PositionOracle storage p = _positions[i]; address seller = p.owner;
        if (buyer == seller) {
            // P3.6: a self-purchase is rejected exactly, with the listing, nonce and balances untouched.
            SaleOfferOracle memory offer = _saleOffers[p.activeTokenId];
            if (!_saleReady(i) || !_purchaseRejected(p, buyer, _bounds(p, offer.listingId), offer.price,
                abi.encodeWithSelector(NARAPositionSaleV5.SelfPurchase.selector))) return false;
            ++selfSalePurchases; _saleGroups(p.activeTokenId); return true;
        }
        return _purchaseOnly(i, buyer) && _withdrawProceeds(seller, seller);
    }
    function _withdrawProceeds(address seller, address recipient) private returns (bool) {
        uint256 amount = _proceeds[seller]; if (amount == 0) return true;
        (bool ok, bytes memory data) = _invoke(seller, address(sale), abi.encodeCall(sale.withdrawProceeds, (recipient)));
        if (!ok || data.length != 32 || abi.decode(data, (uint256)) != amount) { _fail("SALE_WITHDRAW"); return false; }
        _proceeds[seller] = 0; saleProceedsTotal -= amount; nativeExpected[_nativeIndex(recipient)] += amount;
        if (sale.proceeds(seller) != 0) { _fail("SALE_WITHDRAW_RESIDUE"); return false; }
        return true;
    }
    function _purchaseOnly(uint256 i, address buyer) private returns (bool) {
        PositionOracle storage p = _positions[i]; SaleOfferOracle memory offer = _saleOffers[p.activeTokenId];
        if (!_saleReady(i) || nativeExpected[_nativeIndex(buyer)] < offer.price) return false;
        address seller = p.owner; require(buyer != seller, "self purchase path");
        (bool ok,) = _invokeValue(buyer, address(sale), abi.encodeCall(sale.purchase, (p.activeTokenId, _bounds(p, offer.listingId))), offer.price);
        if (!ok) { _fail("SALE_BUY_REVERT"); return false; }
        uint256 fee = offer.price * SALE_FEE_BPS / 10_000; uint256 net = offer.price - fee;
        nativeExpected[_nativeIndex(buyer)] -= offer.price; _proceeds[seller] += net; saleProceedsTotal += net; ingressFees += fee;
        delete _saleOffers[p.activeTokenId]; p.owner = buyer; p.approved = address(0); ++p.activeTransferNonce;
        if (nft.ownerOf(p.activeTokenId) != buyer || nft.receiptTransferNonce(p.activeTokenId) != p.activeTransferNonce
            || sale.proceeds(seller) != _proceeds[seller]) { _fail("SALE_ACQUISITION"); return false; }
        {
            ++distinctSalePurchases;
            uint64 wall = engine.clock().wallEpoch;
            ++salePurchaseContexts[wall < p.activation ? 0 : wall < p.end ? 1 : 2];
            if (wall > _next) ++salePurchaseContexts[3];
            if (p.generation >= 2) for (uint256 j; j < _positions.length; ++j) {
                PositionOracle storage old = _positions[j];
                if (old.frameId == p.frameId && old.generation < p.generation && old.withdrawn && old.owner != buyer
                    && old.credits[0] != 0 && old.credits[1] != 0 && old.credits[2] != 0) { ++salePurchaseContexts[4]; break; }
            }
            _clearSaleClaim(p.activeTokenId); uint8 mask;
            for (uint8 a; a < 3; ++a) if (p.credits[a] / RAY > 0 && p.credits[a] % RAY > 0) mask |= uint8(1 << a);
            if (mask == 7) { _saleClaimOwner[p.activeTokenId] = buyer; _saleFractionMask[p.activeTokenId] = 7; }
        }
        _saleGroups(p.activeTokenId); return true;
    }
    function _saleTransfer(PositionOracle storage p, address recipient) private returns (bool) {
        (bool ok,) = _invoke(p.owner, address(nft), abi.encodeCall(nft.transferFrom, (p.owner, recipient, p.activeTokenId)));
        if (!ok) { _fail("SALE_PROBE_TRANSFER"); return false; }
        p.owner = recipient; p.approved = address(0); ++p.activeTransferNonce; _clearSaleClaim(p.activeTokenId); return true;
    }
    function _purchaseRejected(PositionOracle storage p, address buyer, NARAPositionSaleV5.BuyerBounds memory bounds,
        uint256 value, bytes memory expected) private returns (bool)
    {
        return _saleRejected(p, buyer, abi.encodeCall(sale.purchase, (p.activeTokenId, bounds)), value, expected);
    }
    function _saleRejected(PositionOracle storage p, address caller, bytes memory input, uint256 value,
        bytes memory expected) private returns (bool)
    {
        if (nativeExpected[_nativeIndex(caller)] < value) return false;
        bytes32 beforeState = _saleRollbackHash(p);
        (bool ok, bytes memory data) = _invokeValue(caller, address(sale), input, value);
        if (ok || keccak256(data) != keccak256(expected)) { _fail("SALE_REJECTION_REASON"); return false; }
        if (_saleRollbackHash(p) != beforeState) { _fail("SALE_ROLLBACK"); return false; }
        return true;
    }
    function _saleRollbackHash(PositionOracle storage p) private view returns (bytes32) {
        uint256[9] memory balances;
        for (uint8 i; i < 3; ++i) {
            address owner = _owner(i); balances[i] = owner.balance;
            balances[3 + i] = token.balanceOf(owner); balances[6 + i] = usdc.balanceOf(owner);
        }
        bool[9] memory operators;
        for (uint8 owner; owner < 3; ++owner)
            for (uint8 operator; operator < 3; ++operator)
                operators[owner * 3 + operator] = nft.isApprovedForAll(_owner(owner), _owner(operator));
        bytes32 books = keccak256(abi.encode(_salePositionHash(p),
            principal.principalAccounting(), rewards.rewardState(),
            rewards.rewardAccounting(RewardAsset.NARA), rewards.rewardAccounting(RewardAsset.ETH), rewards.rewardAccounting(RewardAsset.USDC)));
        return keccak256(abi.encode(books, sale.lastListingId(), sale.outstandingProceeds(), operators,
            balances, address(sale).balance, address(ingress).balance, token.balanceOf(address(principal)), token.balanceOf(address(rewards)),
            usdc.balanceOf(address(rewards)), address(rewards).balance));
    }
    function _salePositionHash(PositionOracle storage p) private view returns (bytes32) {
        return keccak256(abi.encode(principal.position(p.frameId, p.generation), principal.positionHead(p.frameId),
            _archivedStateHash(p), _receiptStateHash(p.activeTokenId), sale.listing(p.activeTokenId)));
    }
    function _nativeIndex(address owner) private view returns (uint256) {
        if (owner == address(this)) return 0; if (owner == address(actors[0])) return 1;
        require(owner == address(actors[1]), "native owner universe"); return 2;
    }
    function _invokeValue(address owner, address target, bytes memory input, uint256 value) private returns (bool, bytes memory) {
        return owner == address(this) ? target.call{value: value}(input) : ModularFuzzActor(payable(owner)).invokeValue(target, input, value);
    }
    function _resetSaleCallbacks() private {
        for (uint8 i; i < 2; ++i) { actors[i].configureNFT(address(0), "", 0, false); actors[i].configureETH(address(0), "", 0, false); }
    }
    function _recordSaleClaim(uint256 i, uint8 asset, uint256 amount) private {
        uint256 tokenId = _positions[i].activeTokenId;
        if (_saleClaimOwner[tokenId] != _positions[i].owner || (_saleFractionMask[tokenId] & uint8(1 << asset)) == 0) return;
        _saleFractionMask[tokenId] &= ~uint8(1 << asset); _saleClaimedMask[tokenId] |= uint8(1 << asset);
        saleBuyerAssetClaims[asset] += amount;
        if (_saleClaimedMask[tokenId] == 7) ++completedSaleClaimCycles;
        _saleGroups(tokenId);
    }
    function _clearSaleClaim(uint256 tokenId) private {
        delete _saleClaimOwner[tokenId]; delete _saleFractionMask[tokenId]; delete _saleClaimedMask[tokenId];
    }
    function _saleGroups(uint256 value) private {
        bool complete = true;
        for (uint8 i; i < 5; ++i) if (saleLifecycleModes[i] == 0) complete = false;
        if (complete && coverageCounters[24] == 0) {
            _cover(24, value);
            emit PathSaleOfferLifecycle(value); // COVERAGE_MARKER: Sale approvals listing replacement and cancellation all execute
        }
        complete = distinctSalePurchases != 0;
        for (uint8 i; i < 5; ++i) if (salePurchaseContexts[i] == 0) complete = false;
        if (complete && coverageCounters[25] == 0) {
            _cover(25, value);
            emit PathSalePurchased(value); // COVERAGE_MARKER: actual distinct buyer purchases span pending active maturity backlog and recharge
        }
        if (selfSalePurchases != 0 && coverageCounters[26] == 0) {
            _cover(26, value);
            emit PathSaleSelfPurchased(value); // COVERAGE_MARKER: actual self purchase is rejected exactly with zero native movement
        }
        complete = completedSaleClaimCycles != 0;
        for (uint8 i; i < 3; ++i) if (saleBuyerAssetClaims[i] == 0) complete = false;
        if (complete && coverageCounters[27] == 0) {
            _cover(27, value);
            emit PathSaleBuyerAssetsClaimed(value); // COVERAGE_MARKER: all three positive fractional reward rights are claimed by actual purchasers
        }
        complete = true;
        for (uint8 i; i < 9; ++i) if (saleStaleModes[i] == 0) complete = false;
        if (complete && coverageCounters[28] == 0) {
            _cover(28, value);
            emit PathSaleStaleOfferRejected(value); // COVERAGE_MARKER: all nine stale Sale identity nonce and cancelAll modes reject exactly
        }
        complete = true;
        for (uint8 i; i < 15; ++i) if (saleInputModes[i] == 0) complete = false;
        if (complete && coverageCounters[29] == 0) {
            _cover(29, value);
            emit PathSaleInputsRejected(value); // COVERAGE_MARKER: all fifteen Sale payment time lifetime floor approval and authority modes reject exactly
        }
        complete = true;
        for (uint8 i; i < 11; ++i) if (saleCallbackModes[i] == 0) complete = false;
        if (complete && coverageCounters[30] == 0) {
            _cover(30, value);
            emit PathSaleCallbacksChecked(value); // COVERAGE_MARKER: all eleven Sale receiver payment acquisition and reentry callback modes checked
        }
        if (saleSurplusChecks != 0 && coverageCounters[31] == 0) {
            _cover(31, value);
            emit PathSaleSurplusPreserved(value); // COVERAGE_MARKER: forced Sale surplus never replaces exact buyer consideration
        }
    }
    function _min(uint256 a, uint256 b) private pure returns (uint256) { return a < b ? a : b; }
    function _cover(uint8 action, uint256 amount) private { coverageMask |= 1 << action; ++coverageCounters[action]; emit CampaignCoverage(action, engine.clock().wallEpoch, _next, amount); }
    function _fail(bytes32 code) private { _violation = true; lastViolation = code; }
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) { return IERC721Receiver.onERC721Received.selector; }
    receive() external payable {}
}
