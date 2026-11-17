// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {NARATokenV5} from "../NARATokenV5.sol";
import {INARAEngineCoreV5} from "../interfaces/INARAEngineCoreV5.sol";
import {INARAEmissionReserveV5} from "../interfaces/INARAEmissionReserveV5.sol";
import {CoreBindings, EpochClock, ReserveState} from "../interfaces/NARAAccountingTypesV5.sol";

/// @title Replenishable NARA emission inventory
/// @notice Recognizes NARA funding once and releases only to the sealed Core.
/// @dev Core alone owns epoch settlement and historical funding eligibility.
///      Bootstrap getter checks detect configuration mistakes, not malicious code:
///      verified token/Core runtime provenance is a deployment prerequisite.
contract NARAEmissionReserveV5 is INARAEmissionReserveV5, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant SUPPLY = 1_000_000 ether;
    uint256 private constant SCHEMA_VERSION = 1;
    uint256 private immutable _genesisFunding;
    address private _bootstrapAuthority;
    NARATokenV5 private _nara;
    INARAEngineCoreV5 private _core;
    bool private _bindingsSealed;
    bool private _initialFundingRecognized;
    uint256 private _cumulativeRecognized;
    uint256 private _cumulativeReleased;
    uint256 private _fundingSequence;
    bool private _hasReleasedEpoch;
    uint64 private _lastReleasedEpoch;

    event TokenBound(address indexed token);
    event CoreBound(address indexed core);
    event BindingsSealed(address indexed token, address indexed core);

    /// @dev No funds should be intentionally allocated until the graph is sealed.
    ///      Direct transfers before sealing remain unsynced and do not block setup.
    constructor(address bootstrapAuthority_, uint256 expectedGenesisFunding_) {
        if (bootstrapAuthority_ == address(0)) revert Unauthorized();
        if (expectedGenesisFunding_ == 0 || expectedGenesisFunding_ > SUPPLY) revert InvalidAmount();
        _bootstrapAuthority = bootstrapAuthority_;
        _genesisFunding = expectedGenesisFunding_;
    }

    modifier onlyBootstrap() {
        if (msg.sender != _bootstrapAuthority) revert Unauthorized();
        _;
    }

    /// @notice Binds the actual newly deployed token exactly once.
    /// @dev Bootstrap can irreversibly select the wrong code; verify provenance first.
    function bindToken(address token) external onlyBootstrap nonReentrant {
        if (address(_nara) != address(0) || token == address(this) || token.code.length == 0) {
            revert InvalidState();
        }
        NARATokenV5 candidate = NARATokenV5(token);
        if (candidate.MAX_SUPPLY() != SUPPLY || candidate.MAX_FLASH_LOAN() != 100_000 ether
            || candidate.FLASH_FEE_BPS() != 10 || candidate.decimals() != 18
            || candidate.FLASH_FEE_SINK() != address(this)) revert InvalidState();
        if (candidate.totalSupply() != SUPPLY) revert FlashActive();
        _nara = candidate;
        emit TokenBound(token);
    }

    /// @notice Binds the Core exactly once, before any recognized funding.
    /// @dev Bootstrap can irreversibly select the recipient; no rebind or rescue power exists.
    function bindCore(address core) external onlyBootstrap nonReentrant {
        if (address(_nara) == address(0) || address(_core) != address(0)) revert InvalidState();
        _validateCore(core, false);
        _core = INARAEngineCoreV5(core);
        emit CoreBound(core);
    }

    /// @notice Finalizes Reserve after Core has sealed its complete graph.
    /// @dev Retires all bootstrap authority. Core sealing must accept a bound, unsealed Reserve.
    function sealBindings() external onlyBootstrap nonReentrant {
        _validateCore(address(_core), true);
        _requireSettledSupply();
        _bindingsSealed = true;
        _bootstrapAuthority = address(0);
        emit BindingsSealed(address(_nara), address(_core));
    }

    function state() external view override nonReentrantView returns (ReserveState memory) {
        // A failed bound-Core read is not an unset genesis timestamp.
        uint64 genesis = address(_core) == address(0) ? 0 : _core.clock().genesisTimestamp;
        return ReserveState({
            schemaVersion: SCHEMA_VERSION,
            nara: address(_nara),
            core: address(_core),
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

    function custody() external view override nonReentrantView returns (
        uint256 observedBalance, uint256 recognizedUnreleased, uint256 unsynced, uint256 deficit
    ) {
        if (address(_nara) == address(0)) revert InvalidState();
        observedBalance = _nara.balanceOf(address(this));
        recognizedUnreleased = _cumulativeRecognized - _cumulativeReleased;
        if (observedBalance >= recognizedUnreleased) unsynced = observedBalance - recognizedUnreleased;
        else deficit = recognizedUnreleased - observedBalance;
    }

    function recognizeInitialFunding() external override nonReentrant {
        if (!_bindingsSealed || _initialFundingRecognized) revert InvalidState();
        CoreBindings memory b = _core.bindings();
        if (b.activated || !b.bindingsSealed || _core.accountingInProgress()) revert InvalidState();
        _requireSettledSupply();
        if (_nara.balanceOf(address(this)) < _genesisFunding) revert InvalidAmount();
        _initialFundingRecognized = true;
        _cumulativeRecognized = _genesisFunding;
        _fundingSequence = 1;
        // Atomic acknowledgement; reverting rolls back this journal. The Core must
        // authenticate amount/sequence without re-entering guarded Reserve getters.
        _core.recordInitialReserveFunding(1, _genesisFunding);
        emit InitialFundingRecognized(1, _genesisFunding);
    }

    function fund(uint256 amount) external override nonReentrant returns (
        uint256 received, uint256 sequence, uint64 eligibleEpoch
    ) {
        EpochClock memory c = _requireStarted(false);
        if (amount == 0) revert InvalidAmount();
        uint256 beforeBalance = _solventBalance();
        IERC20(address(_nara)).safeTransferFrom(msg.sender, address(this), amount);
        uint256 afterBalance = _nara.balanceOf(address(this));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) revert InvalidAmount();
        received = amount;
        (sequence, eligibleEpoch) = _recordFunding(received, c.wallEpoch, false);
    }

    function syncFunding() external override nonReentrant returns (
        uint256 received, uint256 sequence, uint64 eligibleEpoch
    ) {
        EpochClock memory c = _requireStarted(false);
        uint256 balance = _solventBalance();
        received = balance - (_cumulativeRecognized - _cumulativeReleased);
        if (received == 0) return (0, _fundingSequence, 0);
        (sequence, eligibleEpoch) = _recordFunding(received, c.wallEpoch, true);
    }

    function releaseForEpoch(uint64 epoch, uint256 requested)
        external override nonReentrant returns (uint256 delivered)
    {
        if (msg.sender != address(_core)) revert Unauthorized();
        EpochClock memory c = _requireStarted(true);
        (bool active, uint64 authorizedEpoch, uint256 maximum) = _core.reserveReleaseContext();
        if (!active || authorizedEpoch != epoch || requested > maximum) revert InvalidState();
        if (epoch != c.nextEpochToClose || epoch >= c.wallEpoch
            || (_hasReleasedEpoch && epoch <= _lastReleasedEpoch)) revert InvalidEpoch();

        uint256 beforeReserve = _nara.balanceOf(address(this));
        uint256 unreleased = _cumulativeRecognized - _cumulativeReleased;
        delivered = requested < unreleased ? requested : unreleased;
        if (delivered > beforeReserve) delivered = beforeReserve;

        // Zero/short successes consume this epoch too. Ordinary transfer failure
        // rolls back all changes; Core may catch it and close an unfunded pulse.
        _hasReleasedEpoch = true;
        _lastReleasedEpoch = epoch;
        _cumulativeReleased += delivered;
        if (delivered != 0) {
            uint256 beforeCore = _nara.balanceOf(address(_core));
            IERC20(address(_nara)).safeTransfer(address(_core), delivered);
            uint256 afterReserve = _nara.balanceOf(address(this));
            uint256 afterCore = _nara.balanceOf(address(_core));
            if (afterReserve > beforeReserve || beforeReserve - afterReserve != delivered
                || afterCore < beforeCore || afterCore - beforeCore != delivered) revert InvalidAmount();
        }
        emit Released(epoch, requested, delivered);
    }

    function _recordFunding(uint256 amount, uint64 wallEpoch, bool directSync)
        private returns (uint256 sequence, uint64 eligibleEpoch)
    {
        // uint64/uint256 exhaustion reverts explicitly through checked arithmetic.
        eligibleEpoch = wallEpoch + 1;
        sequence = _fundingSequence + 1;
        _cumulativeRecognized += amount;
        _fundingSequence = sequence;
        _core.recordReserveFunding(sequence, eligibleEpoch, amount);
        emit FundingRecognized(sequence, eligibleEpoch, msg.sender, amount, directSync);
    }

    function _solventBalance() private view returns (uint256 balance) {
        balance = _nara.balanceOf(address(this));
        if (balance < _cumulativeRecognized - _cumulativeReleased) revert ReserveInsolvent();
    }

    function _requireSettledSupply() private view {
        // Positive outstanding flash principal is excluded. A zero-value flash
        // callback has settled supply and grants no extra funding authority.
        if (_nara.totalSupply() != SUPPLY) revert FlashActive();
    }

    function _requireStarted(bool releasing) private view returns (EpochClock memory c) {
        if (!_bindingsSealed || !_initialFundingRecognized) revert InvalidState();
        if (_core.accountingInProgress() != releasing) revert InvalidState();
        if (!_core.bindings().activated) revert InvalidState();
        c = _core.clock();
        if (!c.started || c.genesisTimestamp == 0 || block.timestamp < c.genesisTimestamp) revert InvalidState();
        _requireSettledSupply();
    }

    function _validateCore(address core, bool requireSealed) private view {
        if (core == address(this) || core == address(_nara) || core.code.length == 0) revert InvalidState();
        INARAEngineCoreV5 candidate = INARAEngineCoreV5(core);
        CoreBindings memory b = candidate.bindings();
        if (b.schemaVersion != SCHEMA_VERSION || b.nara != address(_nara) || b.reserve != address(this)
            || b.expectedGenesisFunding != _genesisFunding || b.activated
            || candidate.policy().epochSeconds != 900 || candidate.accountingInProgress()) revert InvalidState();
        if (requireSealed) {
            if (!b.bindingsSealed || b.bootstrapAuthority != address(0)
                || b.emissionModel.code.length == 0 || b.positionNFT.code.length == 0
                || b.emissionModel == b.positionNFT || b.emissionModel == core || b.positionNFT == core
                || b.emissionModel == address(this) || b.positionNFT == address(this)
                || b.emissionModel == address(_nara) || b.positionNFT == address(_nara)) revert InvalidState();
        }
    }
}
