// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {NARATokenV5} from "../NARATokenV5.sol";
import {NARAEmissionModelV5} from "../engine/NARAEmissionModelV5.sol";
import {INARAEmissionReserveV5} from "../interfaces/INARAEmissionReserveV5.sol";
import {AccountingPolicy, CoreBindings, EpochClock, ReserveState, ReserveDelivery}
    from "../interfaces/NARAAccountingTypesV5.sol";

struct CoreFundingState {
    bool initialFundingRecognized;
    uint256 eligibleReserve;
    uint256 futureReserve;
    uint256 lastFundingSequence;
    uint256 cumulativeRecognized;
    uint256 cumulativeReleased;
    uint32 releaseGasLimit;
    uint32 minimumGasBeforeRelease;
}

struct FundingClose {
    uint64 epoch;
    uint256 eligibleBefore;
    uint256 requested;
    uint256 delivered;
    ReserveDelivery status;
}

/// @title Core chronology and Reserve funding boundary
/// @notice Abstract Core component; cannot be deployed without explicit economic hooks.
/// @dev One cursor, one guard, private funding ledger. The final Core must use this
///      guard for every financial mutation and preserve the read exceptions below.
///      No placeholder position, reward or model accounting is supplied here.
abstract contract NARACoreFundingV5 is ReentrancyGuard {
    uint256 private constant SUPPLY = 1_000_000 ether;
    uint256 private constant EPOCH_SECONDS = 900;
    // Candidate technical budgets, to be remeasured with the final Core hooks.
    uint32 private constant RELEASE_GAS_LIMIT = 400_000;
    uint32 private constant MINIMUM_GAS_BEFORE_RELEASE = 600_000;

    NARATokenV5 private immutable _nara;
    INARAEmissionReserveV5 private immutable _reserve;
    address private immutable _model;
    uint256 private immutable _expectedGenesisFunding;
    address private _bootstrapAuthority;
    address private _positionNFT;
    bool private _bindingsSealed;
    bool private _activated;
    bool private _initialFundingRecognized;
    uint64 private _genesisTimestamp;
    uint64 private _nextEpochToClose;
    uint256 private _eligibleReserve;
    uint256 private _futureReserve;
    uint256 private _lastFundingSequence;
    uint256 private _cumulativeRecognized;
    uint256 private _cumulativeReleased;
    mapping(uint64 epoch => uint256 amount) private _reserveFunding;
    bool private _closeActive;
    bool private _releaseActive;
    uint64 private _releaseEpoch;
    uint256 private _releaseMaximum;

    error Unauthorized();
    error InvalidState();
    error InvalidEpoch();
    error InvalidFundingSequence();
    error AccountingInProgress();
    error FlashActive();
    error InvalidReserveDelivery();
    error InsufficientReleaseGas();

    event PositionNFTBound(address indexed positionNFT);
    event CoreBindingsSealed(address indexed reserve, address indexed positionNFT);
    event CoreActivated(uint64 genesisTimestamp);
    event ReserveFundingRecorded(uint256 indexed sequence, uint64 indexed eligibleEpoch, uint256 amount);
    event FundingEpochClosed(uint64 indexed epoch, uint256 requested, uint256 delivered, ReserveDelivery status);

    /// @dev Bootstrap selects immutable counterparties. Getter checks are not code
    ///      authentication; verified bytecode and a complete graph rehearsal are required.
    constructor(address authority, address nara, address reserve, address model, uint256 genesisFunding) {
        if (authority == address(0)) revert Unauthorized();
        if (nara.code.length == 0 || reserve.code.length == 0 || model.code.length == 0
            || nara == reserve || nara == model || reserve == model
            || genesisFunding == 0 || genesisFunding > SUPPLY) revert InvalidState();
        _nara = NARATokenV5(nara);
        _reserve = INARAEmissionReserveV5(reserve);
        _model = model;
        _expectedGenesisFunding = genesisFunding;
        _bootstrapAuthority = authority;
        if (_nara.MAX_SUPPLY() != SUPPLY || _nara.FLASH_FEE_SINK() != reserve
            || NARAEmissionModelV5(model).MODEL_VERSION() != 1
            || NARAEmissionModelV5(model).FIXED_SUPPLY() != SUPPLY) revert InvalidState();
        _requireSettledSupply();
        ReserveState memory s = _reserve.state();
        if (s.schemaVersion != 1 || s.nara != nara || s.core != address(0)
            || s.bootstrapAuthority != authority || s.bindingsSealed || s.initialFundingRecognized
            || s.genesisFunding != genesisFunding || s.fundingSequence != 0
            || s.cumulativeRecognized != 0 || s.cumulativeReleased != 0) revert InvalidState();
    }

    modifier onlyBootstrap() {
        if (msg.sender != _bootstrapAuthority) revert Unauthorized();
        _;
    }

    modifier coherentFundingRead() {
        if (_reentrancyGuardEntered()) revert AccountingInProgress();
        _;
    }

    /// @dev The final Core supplies its immutable prototype policy; this base
    ///      neither selects coefficients nor fabricates fields for unimplemented policy.
    function policy() public view virtual returns (AccountingPolicy memory);

    /// @dev Bootstrap may select the wrong NFT permanently; validate its actual
    ///      reciprocal identity before setting it, and verify provenance before funding.
    function bindPositionNFT(address nft) external onlyBootstrap nonReentrant {
        if (_positionNFT != address(0) || nft.code.length == 0 || nft == address(this)
            || nft == address(_nara) || nft == address(_reserve) || nft == _model) revert InvalidState();
        _validatePositionNFT(nft);
        _positionNFT = nft;
        emit PositionNFTBound(nft);
    }

    /// @dev Core seals first against bound, unsealed Reserve identities, then retires
    ///      its bootstrap authority. Reserve seals second. No recovery/rebind role remains.
    function sealBindings() external onlyBootstrap nonReentrant {
        if (_positionNFT == address(0) || policy().epochSeconds != EPOCH_SECONDS) revert InvalidState();
        _validatePositionNFT(_positionNFT);
        _requireSettledSupply();
        ReserveState memory s = _reserve.state();
        _validateReserveIdentity(s);
        if (s.bindingsSealed || s.bootstrapAuthority != _bootstrapAuthority
            || s.initialFundingRecognized || s.fundingSequence != 0
            || s.cumulativeRecognized != 0 || s.cumulativeReleased != 0) revert InvalidState();
        _bindingsSealed = true;
        _bootstrapAuthority = address(0);
        emit CoreBindingsSealed(address(_reserve), _positionNFT);
    }

    function bindings() public view returns (CoreBindings memory) {
        return CoreBindings(1, address(_nara), address(_reserve), _model, _positionNFT,
            _bootstrapAuthority, _bindingsSealed, _activated, _expectedGenesisFunding);
    }

    /// @notice Wall time plus the settlement cursor; readable during callbacks.
    /// @dev Clock metadata does not certify a coherent financial snapshot mid-mutation.
    function clock() public view returns (EpochClock memory c) {
        if (!_activated) return c;
        c.genesisTimestamp = _genesisTimestamp;
        if (block.timestamp < _genesisTimestamp) {
            c.nextBoundaryTimestamp = _genesisTimestamp;
            return c;
        }
        uint256 wall = (block.timestamp - _genesisTimestamp) / EPOCH_SECONDS;
        if (wall > type(uint64).max) revert InvalidEpoch();
        c.started = true;
        c.wallEpoch = uint64(wall);
        c.nextEpochToClose = _nextEpochToClose;
        c.backlog = c.wallEpoch - _nextEpochToClose;
        c.nextBoundaryTimestamp = uint256(_genesisTimestamp) + (wall + 1) * EPOCH_SECONDS;
    }

    function accountingInProgress() public view returns (bool) { return _reentrancyGuardEntered(); }

    function reserveReleaseContext() public view returns (bool active, uint64 epoch, uint256 maximum) {
        if (msg.sender != address(_reserve)) revert Unauthorized();
        return (_releaseActive, _releaseEpoch, _releaseMaximum);
    }

    function fundingState() external view coherentFundingRead returns (CoreFundingState memory) {
        return _fundingView();
    }

    /// @dev Current/future pending funding only; promoted/pruned historical epochs revert.
    function reserveFundingAt(uint64 eligibleEpoch) external view coherentFundingRead returns (uint256) {
        if (eligibleEpoch < _nextEpochToClose) revert InvalidEpoch();
        return _reserveFunding[eligibleEpoch];
    }

    function recordInitialReserveFunding(uint256 sequence, uint256 amount) external nonReentrant {
        if (msg.sender != address(_reserve)) revert Unauthorized();
        if (!_bindingsSealed || _activated || _initialFundingRecognized) revert InvalidState();
        if (sequence != 1 || _lastFundingSequence != 0 || amount != _expectedGenesisFunding) {
            revert InvalidFundingSequence();
        }
        _requireSettledSupply();
        // Reserve is guarded while issuing this callback. Validate cached bindings,
        // not Reserve.state()/custody(), and rely on its authenticated exact receipt.
        _initialFundingRecognized = true;
        _eligibleReserve = amount;
        _cumulativeRecognized = amount;
        _lastFundingSequence = sequence;
        emit ReserveFundingRecorded(sequence, 0, amount);
    }

    function activate() external nonReentrant {
        if (!_bindingsSealed || _activated || !_initialFundingRecognized) revert InvalidState();
        _requireSettledSupply();
        ReserveState memory s = _reserve.state();
        _validateReserveIdentity(s);
        if (!s.bindingsSealed || s.bootstrapAuthority != address(0) || !s.initialFundingRecognized
            || s.fundingSequence != 1 || _lastFundingSequence != 1
            || s.cumulativeRecognized != _cumulativeRecognized || s.cumulativeReleased != 0
            || _nara.balanceOf(address(_reserve)) < _expectedGenesisFunding) revert InvalidState();
        uint256 genesis = (block.timestamp / EPOCH_SECONDS + 1) * EPOCH_SECONDS;
        if (genesis > type(uint64).max) revert InvalidEpoch();
        _genesisTimestamp = uint64(genesis);
        _activated = true;
        _openFundingEpoch(0);
        emit CoreActivated(_genesisTimestamp);
    }

    function recordReserveFunding(uint256 sequence, uint64 eligibleEpoch, uint256 amount) external nonReentrant {
        if (msg.sender != address(_reserve)) revert Unauthorized();
        EpochClock memory c = _startedClock();
        if (!_initialFundingRecognized || amount == 0 || sequence != _lastFundingSequence + 1) {
            revert InvalidFundingSequence();
        }
        if (eligibleEpoch != c.wallEpoch + 1) revert InvalidEpoch();
        _requireSettledSupply();
        _reserveFunding[eligibleEpoch] += amount;
        _futureReserve += amount;
        _cumulativeRecognized += amount;
        _lastFundingSequence = sequence;
        emit ReserveFundingRecorded(sequence, eligibleEpoch, amount);
    }

    /// @dev Mandatory atomic close primitive. The final external advance function
    ///      must hold this inherited guard and enforce its reviewed work bound.
    function _closeFundingEpoch() internal returns (FundingClose memory result) {
        if (!_reentrancyGuardEntered() || _closeActive || _releaseActive) revert InvalidState();
        _closeActive = true;
        EpochClock memory c = _startedClock();
        if (_nextEpochToClose >= c.wallEpoch) revert InvalidEpoch();
        _requireSettledSupply();
        result.epoch = _nextEpochToClose;
        result.eligibleBefore = _eligibleReserve;
        (uint256 target, uint256 headroom) = _fundingDemand(result.epoch);
        uint256 maximum = headroom < _eligibleReserve ? headroom : _eligibleReserve;
        result.requested = target < maximum ? target : maximum;
        if (result.requested != 0) {
            (result.delivered, result.status) = _receiveReserve(result.epoch, result.requested, maximum);
            _eligibleReserve -= result.delivered;
            _cumulativeReleased += result.delivered;
        }
        // Must protect actual receipt as reward custody and settle the current
        // model/reward state, including an unfunded close. No default implementation.
        // Scalar hook arguments cannot alias and rewrite the receipt emitted below.
        _settleFundingEpoch(result.epoch, result.eligibleBefore, result.requested, result.delivered, result.status);
        _nextEpochToClose += 1;
        uint256 promoted = _reserveFunding[_nextEpochToClose];
        delete _reserveFunding[_nextEpochToClose];
        _futureReserve -= promoted;
        _eligibleReserve += promoted;
        // Must apply all next-boundary principal/reward/weight/penalty changes
        // before that epoch's later quote. Reserve promotion alone is not enough.
        _openFundingEpoch(_nextEpochToClose);
        emit FundingEpochClosed(result.epoch, result.requested, result.delivered, result.status);
        _closeActive = false;
    }

    function _receiveReserve(uint64 epoch, uint256 requested, uint256 maximum)
        private returns (uint256 delivered, ReserveDelivery status)
    {
        uint256 beforeBalance = _nara.balanceOf(address(this));
        _releaseActive = true;
        _releaseEpoch = epoch;
        _releaseMaximum = maximum;
        bytes memory payload = abi.encodeCall(INARAEmissionReserveV5.releaseForEpoch, (epoch, requested));
        address reserve = address(_reserve);
        uint256 limit = RELEASE_GAS_LIMIT;
        if (gasleft() < MINIMUM_GAS_BEFORE_RELEASE) revert InsufficientReleaseGas();
        bool success;
        uint256 returnSize;
        // Bound both forwarded gas and copied returndata. A revert/return bomb must
        // not consume the caller's cleanup budget. A valid uint256 return is 32 bytes.
        assembly ("memory-safe") {
            let output := mload(0x40)
            mstore(output, 0)
            success := call(limit, reserve, 0, add(payload, 32), mload(payload), output, 32)
            returnSize := returndatasize()
            delivered := mload(output)
        }
        _releaseActive = false;
        _releaseEpoch = 0;
        _releaseMaximum = 0;
        uint256 afterBalance = _nara.balanceOf(address(this));
        if (!success) {
            if (afterBalance != beforeBalance) revert InvalidReserveDelivery();
            return (0, ReserveDelivery.Failed);
        }
        if (returnSize != 32 || delivered > requested || afterBalance < beforeBalance
            || afterBalance - beforeBalance != delivered) revert InvalidReserveDelivery();
        return (delivered, ReserveDelivery.Succeeded);
    }

    function _fundingView() internal view returns (CoreFundingState memory) {
        return CoreFundingState(_initialFundingRecognized, _eligibleReserve, _futureReserve,
            _lastFundingSequence, _cumulativeRecognized, _cumulativeReleased,
            RELEASE_GAS_LIMIT, MINIMUM_GAS_BEFORE_RELEASE);
    }

    function _startedClock() private view returns (EpochClock memory c) {
        c = clock();
        if (!c.started) revert InvalidState();
    }

    function _requireSettledSupply() private view {
        if (_nara.totalSupply() != SUPPLY) revert FlashActive();
    }

    function _validateReserveIdentity(ReserveState memory s) private view {
        if (s.schemaVersion != 1 || s.nara != address(_nara) || s.core != address(this)
            || s.genesisFunding != _expectedGenesisFunding) revert InvalidState();
    }

    function _validatePositionNFT(address nft) internal view virtual;
    function _fundingDemand(uint64 epoch) internal view virtual returns (uint256 target, uint256 headroom);
    function _settleFundingEpoch(uint64 epoch, uint256 eligibleBefore, uint256 requested,
        uint256 delivered, ReserveDelivery status) internal virtual;
    function _openFundingEpoch(uint64 epoch) internal virtual;
}
