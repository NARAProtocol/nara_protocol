// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

// TEST-ONLY helpers. This file is excluded from every production deployment inventory.

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";

import {INARAEmissionReserveV5} from "../interfaces/INARAEmissionReserveV5.sol";
import {
    AccountingPolicy,
    CoreBindings,
    EpochClock
} from "../interfaces/NARAAccountingTypesV5.sol";

/// @notice Independent Core double with explicit hostile-notice and flash callback controls.
contract ReserveTestCoreMock is IERC3156FlashBorrower {
    bytes32 private constant FLASH_CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    address public immutable reserve;
    CoreBindings private _bindings;
    EpochClock private _clock;
    AccountingPolicy private _policy;

    bool private _accountingInProgress;
    bool public failClockRead;
    bool private _releaseActive;
    uint64 private _releaseEpoch;
    uint256 private _releaseMaximum;

    bool public failInitialNotice;
    bool public failFundingNotice;
    bytes public noticeCallbackData;
    bool public bubbleNoticeCallbackFailure;
    bool public lastNoticeCallbackSuccess;
    bytes public lastNoticeCallbackReturn;

    uint256 public initialNoticeCount;
    uint256 public fundingNoticeCount;
    uint256 public lastInitialSequence;
    uint256 public lastInitialAmount;
    uint256 public lastFundingSequence;
    uint64 public lastFundingEligibleEpoch;
    uint256 public lastFundingAmount;

    bytes public flashActionData;
    bool public flashActionUsesReleaseContext;
    bool public lastFlashActionSuccess;
    bytes public lastFlashActionReturn;

    error UnauthorizedCaller();
    error ForcedInitialNoticeFailure();
    error ForcedFundingNoticeFailure();
    error NoticeCallbackFailed(bytes reason);
    error InvalidFlashCaller();
    error ForcedClockFailure();

    constructor(
        address token,
        address reserve_,
        uint256 expectedGenesisFunding,
        address bootstrapAuthority,
        address emissionModel,
        address positionNFT
    ) {
        reserve = reserve_;
        _bindings = CoreBindings({
            schemaVersion: 1,
            nara: token,
            reserve: reserve_,
            emissionModel: emissionModel,
            positionNFT: positionNFT,
            bootstrapAuthority: bootstrapAuthority,
            bindingsSealed: false,
            activated: false,
            expectedGenesisFunding: expectedGenesisFunding
        });
        _policy.epochSeconds = 900;
        _policy.rewardIndexScale = 1e27;
        _policy.maxAdvance = 96;
    }

    function bindings() external view returns (CoreBindings memory) {
        return _bindings;
    }

    function clock() external view returns (EpochClock memory) {
        if (failClockRead) revert ForcedClockFailure();
        return _clock;
    }

    function policy() external view returns (AccountingPolicy memory) {
        return _policy;
    }

    function accountingInProgress() external view returns (bool) {
        return _accountingInProgress;
    }

    function reserveReleaseContext() external view returns (bool active, uint64 epoch, uint256 maximum) {
        if (msg.sender != reserve) revert UnauthorizedCaller();
        return (_releaseActive, _releaseEpoch, _releaseMaximum);
    }

    function setSchemaVersion(uint256 value) external {
        _bindings.schemaVersion = value;
    }

    function setToken(address value) external {
        _bindings.nara = value;
    }

    function setReserve(address value) external {
        _bindings.reserve = value;
    }

    function setExpectedGenesisFunding(uint256 value) external {
        _bindings.expectedGenesisFunding = value;
    }

    function setEpochSeconds(uint32 value) external {
        _policy.epochSeconds = value;
    }

    function setActivated(bool value) external {
        _bindings.activated = value;
    }

    function sealBindings() external {
        _bindings.bootstrapAuthority = address(0);
        _bindings.bindingsSealed = true;
    }

    function setClock(
        bool started,
        uint64 genesisTimestamp,
        uint64 wallEpoch,
        uint64 nextEpochToClose,
        uint64 backlog,
        uint256 nextBoundaryTimestamp
    ) external {
        _clock = EpochClock({
            started: started,
            genesisTimestamp: genesisTimestamp,
            wallEpoch: wallEpoch,
            nextEpochToClose: nextEpochToClose,
            backlog: backlog,
            nextBoundaryTimestamp: nextBoundaryTimestamp
        });
        _bindings.activated = genesisTimestamp != 0;
    }

    function setAccountingInProgress(bool value) external {
        _accountingInProgress = value;
    }

    function setFailClockRead(bool value) external {
        failClockRead = value;
    }

    function configureNoticeFailure(bool initialFailure, bool fundingFailure) external {
        failInitialNotice = initialFailure;
        failFundingNotice = fundingFailure;
    }

    function configureNoticeCallback(bytes calldata data, bool bubbleFailure) external {
        noticeCallbackData = data;
        bubbleNoticeCallbackFailure = bubbleFailure;
        delete lastNoticeCallbackReturn;
        lastNoticeCallbackSuccess = false;
    }

    function recordInitialReserveFunding(uint256 sequence, uint256 amount) external {
        if (msg.sender != reserve) revert UnauthorizedCaller();
        if (failInitialNotice) revert ForcedInitialNoticeFailure();
        _runNoticeCallback();
        initialNoticeCount += 1;
        lastInitialSequence = sequence;
        lastInitialAmount = amount;
    }

    function recordReserveFunding(uint256 sequence, uint64 eligibleEpoch, uint256 amount) external {
        if (msg.sender != reserve) revert UnauthorizedCaller();
        if (failFundingNotice) revert ForcedFundingNoticeFailure();
        _runNoticeCallback();
        fundingNoticeCount += 1;
        lastFundingSequence = sequence;
        lastFundingEligibleEpoch = eligibleEpoch;
        lastFundingAmount = amount;
    }

    function invokeRelease(uint64 epoch, uint256 requested, uint256 maximum)
        external
        returns (uint256 delivered)
    {
        _accountingInProgress = true;
        _releaseActive = true;
        _releaseEpoch = epoch;
        _releaseMaximum = maximum;
        delivered = INARAEmissionReserveV5(reserve).releaseForEpoch(epoch, requested);
        _releaseActive = false;
        _releaseEpoch = 0;
        _releaseMaximum = 0;
        _accountingInProgress = false;
    }

    function invokeReleaseWithContext(
        uint64 epoch,
        uint256 requested,
        bool accounting,
        bool active,
        uint64 contextEpoch,
        uint256 maximum
    ) external returns (uint256 delivered) {
        _accountingInProgress = accounting;
        _releaseActive = active;
        _releaseEpoch = contextEpoch;
        _releaseMaximum = maximum;
        delivered = INARAEmissionReserveV5(reserve).releaseForEpoch(epoch, requested);
        _releaseActive = false;
        _releaseEpoch = 0;
        _releaseMaximum = 0;
        _accountingInProgress = false;
    }

    function returnToken(address token, address recipient, uint256 amount) external {
        IERC20(token).transfer(recipient, amount);
    }

    function startFlashAction(
        address lender,
        uint256 amount,
        bytes calldata reserveCallData,
        bool withReleaseContext,
        uint64 contextEpoch,
        uint256 contextMaximum
    ) external returns (bool) {
        flashActionData = reserveCallData;
        flashActionUsesReleaseContext = withReleaseContext;
        _releaseEpoch = contextEpoch;
        _releaseMaximum = contextMaximum;
        delete lastFlashActionReturn;
        lastFlashActionSuccess = false;
        return IERC3156FlashLender(lender).flashLoan(this, lender, amount, "");
    }

    function onFlashLoan(address, address token, uint256 amount, uint256 fee, bytes calldata)
        external
        override
        returns (bytes32)
    {
        if (msg.sender != token) revert InvalidFlashCaller();
        if (flashActionUsesReleaseContext) {
            _accountingInProgress = true;
            _releaseActive = true;
        }
        (lastFlashActionSuccess, lastFlashActionReturn) = reserve.call(flashActionData);
        _releaseActive = false;
        _releaseEpoch = 0;
        _releaseMaximum = 0;
        _accountingInProgress = false;
        IERC20(token).approve(token, amount + fee);
        return FLASH_CALLBACK_SUCCESS;
    }

    function _runNoticeCallback() private {
        if (noticeCallbackData.length == 0) return;
        (lastNoticeCallbackSuccess, lastNoticeCallbackReturn) = reserve.call(noticeCallbackData);
        if (!lastNoticeCallbackSuccess && bubbleNoticeCallbackFailure) {
            revert NoticeCallbackFailed(lastNoticeCallbackReturn);
        }
    }
}

/// @notice Minimal deployed code marker for Core binding checks.
contract ReserveTestCodeMarker {}

/// @notice Token double used only to create physical deficits and callback-bearing transfers.
contract ReserveTestCallbackToken is ERC20 {
    uint256 public constant MAX_SUPPLY = 1_000_000 ether;
    uint256 public constant MAX_FLASH_LOAN = 100_000 ether;
    uint16 public constant FLASH_FEE_BPS = 10;
    address public immutable FLASH_FEE_SINK;

    address public callbackTarget;
    bytes public callbackData;
    bool public callbackEnabled;
    bool public failReserveTransfers;
    bool public returnFalse;
    uint8 public deltaFault;
    address public faultCollector;
    bool public lastCallbackSuccess;
    bytes public lastCallbackReturn;

    error ForcedReserveTransferFailure();

    constructor(address treasury, address sink) ERC20("NARA", "NARA") {
        FLASH_FEE_SINK = sink;
        _mint(treasury, MAX_SUPPLY);
    }

    function maxFlashLoan(address token) external view returns (uint256) {
        return token == address(this) ? MAX_FLASH_LOAN : 0;
    }

    function configureCallback(address target, bytes calldata data, bool enabled) external {
        callbackTarget = target;
        callbackData = data;
        callbackEnabled = enabled;
        delete lastCallbackReturn;
        lastCallbackSuccess = false;
    }

    function setFailReserveTransfers(bool value) external {
        failReserveTransfers = value;
    }

    /// @dev deltaFault 1 diverts one unit from the recipient; 2 debits one extra
    /// unit from Reserve while crediting the requested recipient exactly.
    function configureTransferFault(uint8 deltaFault_, address collector, bool returnFalse_) external {
        deltaFault = deltaFault_;
        faultCollector = collector;
        returnFalse = returnFalse_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        super.transfer(to, amount);
        return !returnFalse;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        super.transferFrom(from, to, amount);
        return !returnFalse;
    }

    function forceMove(address from, address to, uint256 amount) external {
        bool enabled = callbackEnabled;
        callbackEnabled = false;
        _update(from, to, amount);
        callbackEnabled = enabled;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (failReserveTransfers && from == FLASH_FEE_SINK) {
            revert ForcedReserveTransferFailure();
        }
        bool reserveTransfer = from == FLASH_FEE_SINK || to == FLASH_FEE_SINK;
        if (reserveTransfer && deltaFault == 1 && amount != 0) {
            super._update(from, to, amount - 1);
            super._update(from, faultCollector, 1);
        } else if (from == FLASH_FEE_SINK && deltaFault == 2 && amount != 0) {
            super._update(from, to, amount);
            super._update(from, faultCollector, 1);
        } else {
            super._update(from, to, amount);
        }
        if (callbackEnabled && from != address(0) && to != address(0)) {
            (lastCallbackSuccess, lastCallbackReturn) = callbackTarget.call(callbackData);
        }
    }
}

/// @notice Actual-token flash borrower that probes one Reserve entry point and repays the loan.
contract ReserveTestFlashProbe is IERC3156FlashBorrower {
    bytes32 private constant FLASH_CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    address public immutable lender;
    address public immutable reserve;
    bool public lastReserveCallSuccess;
    bytes public lastReserveCallReturn;

    error InvalidLender();

    constructor(address lender_, address reserve_) {
        lender = lender_;
        reserve = reserve_;
    }

    function borrow(uint256 amount, bytes calldata reserveCallData) external returns (bool) {
        delete lastReserveCallReturn;
        lastReserveCallSuccess = false;
        return IERC3156FlashLender(lender).flashLoan(this, lender, amount, reserveCallData);
    }

    function onFlashLoan(address, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        override
        returns (bytes32)
    {
        if (msg.sender != lender || token != lender) revert InvalidLender();
        (lastReserveCallSuccess, lastReserveCallReturn) = reserve.call(data);
        IERC20(token).approve(lender, amount + fee);
        return FLASH_CALLBACK_SUCCESS;
    }
}
