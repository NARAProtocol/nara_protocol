// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

// TEST-ONLY helpers. This file is excluded from every production deployment inventory.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";

import {NARACoreFundingV5, FundingClose}
    from "../core/NARACoreFundingV5.sol";
import {INARAEmissionReserveV5} from "../interfaces/INARAEmissionReserveV5.sol";
import {
    AccountingPolicy,
    CoreBindings,
    DurationCurve,
    EpochClock,
    ReserveDelivery,
    ReserveState
} from "../interfaces/NARAAccountingTypesV5.sol";

interface ICoreFundingNFTIdentity {
    function core() external view returns (address);
}

interface ICoreFundingNotice {
    function recordInitialReserveFunding(uint256 sequence, uint256 amount) external;
    function recordReserveFunding(uint256 sequence, uint64 eligibleEpoch, uint256 amount) external;
    function reserveReleaseContext() external view returns (bool active, uint64 epoch, uint256 maximum);
}

/// @notice Minimal reciprocal NFT identity used only by the Core funding tests.
contract CoreFundingPositionNFTStub {
    address public immutable core;

    constructor(address core_) {
        core = core_;
    }
}

/// @notice Deployable test realization of the abstract funding boundary.
/// @dev Its economic hooks only record deterministic inputs and receipts; they
///      do not represent the eventual position, reward, or emission accounting.
contract CoreFundingHarness is NARACoreFundingV5 {
    uint32 public constant TEST_MAX_ADVANCE = 96;

    struct Demand {
        uint256 target;
        uint256 headroom;
    }

    mapping(uint64 epoch => Demand demand) private _demands;
    mapping(uint64 epoch => FundingClose result) private _settlements;
    mapping(uint64 epoch => bool opened) public epochOpened;
    uint32 private _policyEpochSeconds = 900;

    uint256 public accountedNara;
    uint256 public settlementCount;
    uint256 public openCount;
    uint64 public lastOpenedEpoch;
    bool public failDemand;
    bool public failSettlement;
    bool public failOpen;

    address public hookCallbackTarget;
    bytes public hookCallbackData;
    bool public hookCallbackOnSettlement;
    bool public hookCallbackOnOpen;
    bool public bubbleHookCallbackFailure;
    bool public lastHookCallbackSuccess;
    bytes public lastHookCallbackReturn;

    error InvalidTestNFT();
    error InvalidAdvanceCount();
    error ForcedDemandFailure();
    error ForcedSettlementFailure();
    error ForcedOpenFailure();
    error HookCallbackFailed(bytes reason);

    constructor(address authority, address nara, address reserve, address model, uint256 genesisFunding)
        NARACoreFundingV5(authority, nara, reserve, model, genesisFunding)
    {}

    function policy() public view override returns (AccountingPolicy memory p) {
        p.policyHash = keccak256("NARA_V5_CORE_FUNDING_TEST_POLICY");
        p.version = 1;
        p.epochSeconds = _policyEpochSeconds;
        p.rewardIndexScale = 1e27;
        p.activationDelay = 8;
        p.minDuration = 96;
        p.maxDuration = 35_040;
        p.durationCurve = DurationCurve.Linear;
        p.earlyExitEnabled = true;
        p.earlyExitBps = 1_000;
        p.minimumPrincipal = 1 ether;
        p.maxAdvance = TEST_MAX_ADVANCE;
        p.rewardAdmissionCap = 1_000_000 ether;
    }

    function setPolicyEpochSeconds(uint32 value) external {
        _policyEpochSeconds = value;
    }

    function setDemand(uint64 epoch, uint256 target, uint256 headroom) external {
        _demands[epoch] = Demand(target, headroom);
    }

    function demandAt(uint64 epoch) external view returns (Demand memory) {
        return _demands[epoch];
    }

    function settlementAt(uint64 epoch) external view returns (FundingClose memory) {
        return _settlements[epoch];
    }

    function setHookFailures(bool demandFailure, bool settlementFailure, bool openFailure) external {
        failDemand = demandFailure;
        failSettlement = settlementFailure;
        failOpen = openFailure;
    }

    function configureHookCallback(
        address target,
        bytes calldata data,
        bool onSettlement,
        bool onOpen,
        bool bubbleFailure
    ) external {
        hookCallbackTarget = target;
        hookCallbackData = data;
        hookCallbackOnSettlement = onSettlement;
        hookCallbackOnOpen = onOpen;
        bubbleHookCallbackFailure = bubbleFailure;
        delete lastHookCallbackReturn;
        lastHookCallbackSuccess = false;
    }

    /// @notice Test-only bounded driver proving the base close primitive is used
    ///         under the inherited guard. The production Core must define its own ABI.
    function advanceForTest(uint32 epochs) external nonReentrant returns (uint32 closed) {
        if (epochs == 0 || epochs > TEST_MAX_ADVANCE) revert InvalidAdvanceCount();
        for (uint32 i = 0; i < epochs; ++i) {
            _closeFundingEpoch();
            ++closed;
        }
    }

    /// @dev Deliberately lacks `nonReentrant`: callbacks use this entry point to
    ///      prove the base close-phase latch rejects recursive internal closes.
    function unguardedCloseForTest() external returns (FundingClose memory) {
        return _closeFundingEpoch();
    }

    function _validatePositionNFT(address nft) internal view override {
        try ICoreFundingNFTIdentity(nft).core() returns (address reciprocalCore) {
            if (reciprocalCore != address(this)) revert InvalidTestNFT();
        } catch {
            revert InvalidTestNFT();
        }
    }

    function _fundingDemand(uint64 epoch) internal view override returns (uint256 target, uint256 headroom) {
        if (failDemand) revert ForcedDemandFailure();
        Demand memory d = _demands[epoch];
        return (d.target, d.headroom);
    }

    function _settleFundingEpoch(
        uint64 epoch,
        uint256 eligibleBefore,
        uint256 requested,
        uint256 delivered,
        ReserveDelivery status
    ) internal override {
        if (failSettlement) revert ForcedSettlementFailure();
        _settlements[epoch] = FundingClose(epoch, eligibleBefore, requested, delivered, status);
        accountedNara += delivered;
        ++settlementCount;
        if (hookCallbackOnSettlement) _runHookCallback();
    }

    function _openFundingEpoch(uint64 epoch) internal override {
        if (failOpen) revert ForcedOpenFailure();
        epochOpened[epoch] = true;
        lastOpenedEpoch = epoch;
        ++openCount;
        if (hookCallbackOnOpen) _runHookCallback();
    }

    function _runHookCallback() private {
        (lastHookCallbackSuccess, lastHookCallbackReturn) =
            hookCallbackTarget.call(hookCallbackData);
        if (!lastHookCallbackSuccess && bubbleHookCallbackFailure) {
            revert HookCallbackFailed(lastHookCallbackReturn);
        }
    }
}

/// @notice Fault-controlled Reserve used to exercise Core receipt validation and gas isolation.
contract CoreFundingFaultReserve is INARAEmissionReserveV5 {
    enum ReleaseMode {
        Normal,
        RevertPlain,
        OutOfGas,
        LargeRevert,
        LargeReturn,
        EmptyReturn,
        ShortReturn,
        LongReturn,
        ReportWithoutTransfer,
        TransferWrongReport,
        ShortSuccess
    }

    uint256 private constant SUPPLY = 1_000_000 ether;
    uint256 private immutable _genesisFunding;
    address private _bootstrapAuthority;
    IERC20 private _nara;
    address private _core;
    bool private _bindingsSealed;
    bool private _initialFundingRecognized;
    uint256 private _cumulativeRecognized;
    uint256 private _cumulativeReleased;
    uint256 private _fundingSequence;
    bool private _hasReleasedEpoch;
    uint64 private _lastReleasedEpoch;

    ReleaseMode public releaseMode;
    uint256 public shortDelivery;
    bool public lastContextActive;
    uint64 public lastContextEpoch;
    uint256 public lastContextMaximum;
    address public callbackTarget;
    bytes public callbackData;
    bool public bubbleCallbackFailure;
    bool public lastCallbackSuccess;
    bytes public lastCallbackReturn;

    error ForcedReleaseFailure();
    error CallbackFailed(bytes reason);

    constructor(address authority, uint256 genesisFunding) {
        if (authority == address(0) || genesisFunding == 0 || genesisFunding > SUPPLY) {
            revert InvalidAmount();
        }
        _bootstrapAuthority = authority;
        _genesisFunding = genesisFunding;
    }

    modifier onlyBootstrap() {
        if (msg.sender != _bootstrapAuthority) revert Unauthorized();
        _;
    }

    function bindToken(address token) external onlyBootstrap {
        if (address(_nara) != address(0) || token.code.length == 0) revert InvalidState();
        _nara = IERC20(token);
    }

    function bindCore(address core) external onlyBootstrap {
        if (_core != address(0) || core.code.length == 0) revert InvalidState();
        _core = core;
    }

    function sealBindings() external onlyBootstrap {
        if (address(_nara) == address(0) || _core == address(0)) revert InvalidState();
        _bindingsSealed = true;
        _bootstrapAuthority = address(0);
    }

    function state() external view override returns (ReserveState memory) {
        uint64 genesis;
        if (_core != address(0)) {
            genesis = ICoreClock(_core).clock().genesisTimestamp;
        }
        return ReserveState({
            schemaVersion: 1,
            nara: address(_nara),
            core: _core,
            bootstrapAuthority: _bootstrapAuthority,
            bindingsSealed: _bindingsSealed,
            initialFundingRecognized: _initialFundingRecognized,
            genesisTimestamp: genesis,
            genesisFunding: _genesisFunding,
            cumulativeRecognized: _cumulativeRecognized,
            cumulativeReleased: _cumulativeReleased,
            fundingSequence: _fundingSequence,
            hasReleasedEpoch: _hasReleasedEpoch,
            lastReleasedEpoch: _lastReleasedEpoch
        });
    }

    function custody() external view override returns (
        uint256 observedBalance,
        uint256 recognizedUnreleased,
        uint256 unsynced,
        uint256 deficit
    ) {
        observedBalance = _nara.balanceOf(address(this));
        recognizedUnreleased = _cumulativeRecognized - _cumulativeReleased;
        if (observedBalance >= recognizedUnreleased) unsynced = observedBalance - recognizedUnreleased;
        else deficit = recognizedUnreleased - observedBalance;
    }

    function recognizeInitialFunding() external override {
        if (!_bindingsSealed || _initialFundingRecognized || _nara.balanceOf(address(this)) < _genesisFunding) {
            revert InvalidState();
        }
        _initialFundingRecognized = true;
        _cumulativeRecognized = _genesisFunding;
        _fundingSequence = 1;
        ICoreFundingNotice(_core).recordInitialReserveFunding(1, _genesisFunding);
    }

    /// @dev Malformed authenticated notice probe; it intentionally does not
    ///      update the Reserve journal.
    function notifyInitialRaw(uint256 sequence, uint256 amount) external {
        ICoreFundingNotice(_core).recordInitialReserveFunding(sequence, amount);
    }

    /// @dev Malformed authenticated ordinary notice probe.
    function notifyFundingRaw(uint256 sequence, uint64 eligibleEpoch, uint256 amount) external {
        ICoreFundingNotice(_core).recordReserveFunding(sequence, eligibleEpoch, amount);
    }

    function fund(uint256 amount) external override returns (uint256 received, uint256 sequence, uint64 eligibleEpoch) {
        if (amount == 0) revert InvalidAmount();
        require(_nara.transferFrom(msg.sender, address(this), amount));
        EpochClock memory c = ICoreClock(_core).clock();
        if (!c.started) revert InvalidState();
        received = amount;
        sequence = ++_fundingSequence;
        eligibleEpoch = c.wallEpoch + 1;
        _cumulativeRecognized += amount;
        ICoreFundingNotice(_core).recordReserveFunding(sequence, eligibleEpoch, amount);
    }

    function syncFunding() external override returns (uint256 received, uint256 sequence, uint64 eligibleEpoch) {
        uint256 balance = _nara.balanceOf(address(this));
        uint256 recognized = _cumulativeRecognized - _cumulativeReleased;
        if (balance <= recognized) return (0, _fundingSequence, 0);
        received = balance - recognized;
        EpochClock memory c = ICoreClock(_core).clock();
        if (!c.started) revert InvalidState();
        sequence = ++_fundingSequence;
        eligibleEpoch = c.wallEpoch + 1;
        _cumulativeRecognized += received;
        ICoreFundingNotice(_core).recordReserveFunding(sequence, eligibleEpoch, received);
    }

    function configureRelease(ReleaseMode mode, uint256 shortDelivery_) external {
        releaseMode = mode;
        shortDelivery = shortDelivery_;
    }

    function configureCallback(address target, bytes calldata data, bool bubbleFailure) external {
        callbackTarget = target;
        callbackData = data;
        bubbleCallbackFailure = bubbleFailure;
        delete lastCallbackReturn;
        lastCallbackSuccess = false;
    }

    function releaseForEpoch(uint64 epoch, uint256 requested)
        external
        override
        returns (uint256 delivered)
    {
        if (msg.sender != _core) revert Unauthorized();
        (lastContextActive, lastContextEpoch, lastContextMaximum) =
            ICoreFundingNotice(_core).reserveReleaseContext();

        if (callbackTarget != address(0)) {
            (lastCallbackSuccess, lastCallbackReturn) = callbackTarget.call(callbackData);
            if (!lastCallbackSuccess && bubbleCallbackFailure) revert CallbackFailed(lastCallbackReturn);
        }

        if (releaseMode == ReleaseMode.RevertPlain) revert ForcedReleaseFailure();
        if (releaseMode == ReleaseMode.OutOfGas) {
            assembly ("memory-safe") { for {} 1 {} {} }
        }
        if (releaseMode == ReleaseMode.LargeRevert) {
            assembly ("memory-safe") {
                let pointer := mload(0x40)
                let size := 98304
                mstore(0x40, add(pointer, size))
                mstore(add(pointer, sub(size, 32)), 0)
                revert(pointer, size)
            }
        }
        if (releaseMode == ReleaseMode.LargeReturn) {
            assembly ("memory-safe") {
                let pointer := mload(0x40)
                let size := 98304
                mstore(0x40, add(pointer, size))
                mstore(pointer, 0)
                mstore(add(pointer, sub(size, 32)), 0)
                return(pointer, size)
            }
        }
        if (releaseMode == ReleaseMode.EmptyReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        if (releaseMode == ReleaseMode.ShortReturn) {
            assembly ("memory-safe") { mstore(0, 0) return(0, 31) }
        }
        if (releaseMode == ReleaseMode.LongReturn) {
            assembly ("memory-safe") { mstore(0, 0) mstore(32, 0) return(0, 64) }
        }
        if (releaseMode == ReleaseMode.ReportWithoutTransfer) return requested;

        uint256 available = _cumulativeRecognized - _cumulativeReleased;
        uint256 balance = _nara.balanceOf(address(this));
        delivered = requested < available ? requested : available;
        if (delivered > balance) delivered = balance;
        if (releaseMode == ReleaseMode.ShortSuccess && shortDelivery < delivered) {
            delivered = shortDelivery;
        }
        if (delivered != 0) require(_nara.transfer(_core, delivered));
        _hasReleasedEpoch = true;
        _lastReleasedEpoch = epoch;
        _cumulativeReleased += delivered;

        if (releaseMode == ReleaseMode.TransferWrongReport) {
            return delivered == 0 ? 1 : delivered - 1;
        }
        return delivered;
    }
}

interface ICoreClock {
    function clock() external view returns (EpochClock memory);
}

/// @notice Actual-token flash borrower that probes one permissionless Core entry point.
contract CoreFundingFlashProbe is IERC3156FlashBorrower {
    bytes32 private constant FLASH_CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    address public immutable lender;
    address public immutable core;
    bool public lastCoreCallSuccess;
    bytes public lastCoreCallReturn;

    error InvalidLender();

    constructor(address lender_, address core_) {
        lender = lender_;
        core = core_;
    }

    function borrow(uint256 amount, bytes calldata coreCallData) external returns (bool) {
        delete lastCoreCallReturn;
        lastCoreCallSuccess = false;
        return IERC3156FlashLender(lender).flashLoan(this, lender, amount, coreCallData);
    }

    function onFlashLoan(address, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        override
        returns (bytes32)
    {
        if (msg.sender != lender || token != lender) revert InvalidLender();
        (lastCoreCallSuccess, lastCoreCallReturn) = core.call(data);
        IERC20(token).approve(lender, amount + fee);
        return FLASH_CALLBACK_SUCCESS;
    }
}
