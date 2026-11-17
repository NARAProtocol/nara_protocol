// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-periphery/lib/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-periphery/lib/v4-core/src/types/Currency.sol";
import {TransientStateLibrary} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {FullMath} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/FullMath.sol";
import {RewardAsset} from "../interfaces/NARAAccountingTypesV5.sol";
import {NARAFeeIngressBindingV5} from "./NARAFeeIngressBindingV5.sol";

interface IFeeHookV5 {
    function token() external view returns (address);
    function base() external view returns (address);
    function collector() external view returns (address);
    function poolManager() external view returns (address);
}
interface IFeePOLControllerV5 {
    function nara() external view returns (address);
    function usdc() external view returns (address);
    function feeVault() external view returns (address);
    function poolManager() external view returns (address);
    function canRetire() external view returns (bool);
}

/// @notice Fixed-asset fee custody. Holder liabilities are inaccessible to POL powers.
/// @dev Candidate: final Hook/controller identity, recovery, deployment and independent
/// acceptance remain separate gates. Direct unsolicited balances stay quarantined.
contract NARAFeeVaultV5 is ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;

    struct Ledger {
        uint256 holderClaims;
        uint256 polClaims;
        uint256 holderRaw;
        uint256 polRaw;
        uint256 hookFees;
        uint256 lpFees;
        uint256 claimsRedeemed;
        uint256 holdersForwarded;
        uint256 polDonations;
        uint256 polReturned;
        uint256 polSpent;
    }
    struct Inventory {
        Ledger booked;
        uint256 rawBalance;
        uint256 claimBalance;
        uint256 rawSurplus;
        uint256 claimSurplus;
        bool solvent;
    }

    uint256 public constant SCHEMA_VERSION = 1;
    uint256 public constant CAPABILITY_DELAY = 7 days;
    IPoolManager public immutable poolManager;
    NARAFeeIngressBindingV5 public immutable ingressBinding;
    address public immutable nara;
    address public immutable usdc;
    address public immutable governor;
    address public immutable guardian;
    /// @notice Deployment-selected ceiling; zero permanently disables holder fees.
    uint16 public immutable maxHolderFeeBps;
    uint16 private _holderFeeBps;
    uint16 public pendingHolderFeeBps;
    uint256 public feeSplitReadyAt;
    uint256 public feeSplitProposalNonce;
    uint256 private _feeSplitVersion = 1;
    address public initializer;
    address public hook;
    address public polController;
    bool public bindingsSealed;
    bool public polPaused;
    address public pendingController;
    uint256 public controllerReadyAt;
    uint256 public controllerProposalNonce;
    Ledger[3] private _ledgers;
    uint16[3] private _feeRemainders;
    bytes32 transient private _redemption;
    address transient private _preparedCurrency;
    uint256 transient private _preparedClaims;

    error Unauthorized();
    error InvalidBinding();
    error InvalidAmount();
    error InvalidReceipt();
    error InvalidState();
    error ManagerUnlocked();
    error CustodyDeficit();
    error POLPaused();
    event BindingsSealed(address indexed hook, address indexed controller);
    event FeeRecorded(RewardAsset indexed asset, bool indexed lpFee, uint256 amount, uint256 holders, uint256 pol);
    event ClaimsRedeemed(RewardAsset indexed asset, uint256 holders, uint256 pol);
    event HoldersForwarded(RewardAsset indexed asset, uint256 amount);
    event POLFunded(RewardAsset indexed asset, address indexed payer, uint256 amount, bool returnedCapital);
    event POLSpent(RewardAsset indexed asset, address indexed controller, uint256 amount);
    event POLPauseChanged(bool paused, bytes32 indexed evidence);
    event ControllerProposed(address indexed controller, uint256 indexed nonce, uint256 readyAt);
    event ControllerCancelled(uint256 indexed nonce);
    event ControllerChanged(address indexed previous, address indexed current, uint256 indexed nonce);
    event HolderFeeSplitProposed(uint16 holderFeeBps, uint256 indexed nonce, uint256 readyAt);
    event HolderFeeSplitCancelled(uint256 indexed nonce);
    /// @dev Retained numerators are fractions of 10,000 raw units, NOT liabilities.
    /// Their already-booked whole-unit rounding belongs to POL and is not reassigned.
    event HolderFeeSplitChanged(uint16 previous, uint16 current, uint256 indexed nonce,
        uint256 indexed version, uint256 effectiveAt, uint16[3] polRetainedRemainders);

    constructor(address initializer_, IPoolManager manager_, address nara_, address usdc_, address initialIngress_, address governor_, address guardian_,
        uint16 maxHolderFeeBps_) {
        if (maxHolderFeeBps_ > 10_000) revert InvalidAmount();
        if (initializer_ == address(0) || address(manager_).code.length == 0
            || governor_.code.length == 0 || guardian_ == address(0) || governor_ == address(this)
            || guardian_ == address(this)
            || governor_ == address(manager_)) revert InvalidBinding();
        if (nara_.code.length == 0 || usdc_.code.length == 0 || nara_ == usdc_
            || nara_ == address(manager_) || usdc_ == address(manager_)
            || nara_ == governor_ || usdc_ == governor_) revert InvalidBinding();
        initializer = initializer_; poolManager = manager_; nara = nara_; usdc = usdc_;
        governor = governor_; guardian = guardian_;
        maxHolderFeeBps = maxHolderFeeBps_;
        ingressBinding = new NARAFeeIngressBindingV5(address(this), address(manager_), nara_, usdc_, governor_, initialIngress_);
    }

    modifier ready() { if (!bindingsSealed) revert InvalidState(); _; }
    modifier managerLocked() { if (poolManager.isUnlocked()) revert ManagerUnlocked(); _; }
    modifier onlyGovernor() { if (msg.sender != governor) revert Unauthorized(); _; }
    modifier onlyController() { if (msg.sender != polController) revert Unauthorized(); _; }

    /// @notice One immutable Hook and one governed POL capability. Retire initializer.
    function sealBindings(address hook_, address controller_) external nonReentrant managerLocked {
        if (msg.sender != initializer || bindingsSealed) revert Unauthorized();
        if (!_peer(hook_) || hook_ == controller_) revert InvalidBinding();
        IFeeHookV5 h = IFeeHookV5(hook_);
        if (h.token() != nara || h.base() != usdc || h.collector() != address(this)
            || h.poolManager() != address(poolManager)) revert InvalidBinding();
        _validateController(controller_);
        hook = hook_; polController = controller_; bindingsSealed = true; initializer = address(0);
        emit BindingsSealed(hook_, controller_);
    }

    /// @notice Snapshot before the Hook mints; old unsolicited claims cannot mask a
    /// missing mint or be reclassified as swap fees. No call lies between mint/record.
    function prepareFee(Currency currency) external nonReentrant ready {
        if (msg.sender != hook || !poolManager.isUnlocked()) revert Unauthorized();
        _asset(currency);
        if (_preparedCurrency != address(0)) revert InvalidState();
        _preparedCurrency = Currency.unwrap(currency);
        _preparedClaims = poolManager.balanceOf(address(this), currency.toId());
    }

    /// @notice The bound Hook prepares, mints canonical claims, then records once.
    /// No underlying asset is taken while the swap caller still owes settlement.
    function record(Currency currency, uint256 amount) external nonReentrant ready {
        if (msg.sender != hook || !poolManager.isUnlocked()) revert Unauthorized();
        RewardAsset asset = _asset(currency);
        if (asset == RewardAsset.ETH || amount == 0) revert InvalidAmount();
        if (_preparedCurrency != Currency.unwrap(currency)
            || poolManager.balanceOf(address(this), currency.toId()) != _preparedClaims + amount) revert InvalidReceipt();
        _preparedCurrency = address(0); _preparedClaims = 0;
        Ledger storage b = _ledgers[uint8(asset)];
        uint256 holders = _holderPortion(asset, amount);
        b.holderClaims += holders; b.polClaims += amount - holders; b.hookFees += amount;
        _assertSolvent(asset);
        emit FeeRecorded(asset, false, amount, holders, amount - holders);
    }

    /// @notice Anyone can redeem either beneficiary's claims to this Vault only.
    /// Selecting a bucket cannot transfer its ownership to the other beneficiary.
    function redeem(RewardAsset asset, uint256 holders, uint256 pol) external nonReentrant ready managerLocked {
        Ledger storage b = _ledgers[uint8(asset)];
        uint256 amount = holders + pol;
        if (asset == RewardAsset.ETH || amount == 0 || holders > b.holderClaims || pol > b.polClaims) revert InvalidAmount();
        _assertSolvent(asset);
        Currency currency = _currency(asset);
        uint256 rawBefore = currency.balanceOfSelf();
        uint256 claimsBefore = poolManager.balanceOf(address(this), currency.toId());
        b.holderClaims -= holders; b.polClaims -= pol;
        b.holderRaw += holders; b.polRaw += pol; b.claimsRedeemed += amount;
        bytes memory data = abi.encode(currency, amount);
        _redemption = keccak256(data);
        poolManager.unlock(data);
        if (_redemption != bytes32(0) || currency.balanceOfSelf() != rawBefore + amount
            || poolManager.balanceOf(address(this), currency.toId()) != claimsBefore - amount) revert InvalidReceipt();
        _assertSolvent(asset);
        emit ClaimsRedeemed(asset, holders, pol);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || _redemption == bytes32(0) || keccak256(data) != _redemption) revert Unauthorized();
        _redemption = bytes32(0); // consume before any external asset transfer
        (Currency currency, uint256 amount) = abi.decode(data, (Currency, uint256));
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, address(this), amount);
        return "";
    }

    /// @notice Transfer only holder inventory to the once-bound ingress. Its separate
    /// forward call dates RewardLedger admission; receipt here is not distribution.
    function forwardHolders(RewardAsset asset, uint256 amount) external nonReentrant ready managerLocked {
        _assertSolvent(asset);
        Ledger storage b = _ledgers[uint8(asset)];
        if (amount == 0 || amount > b.holderRaw) revert InvalidAmount();
        b.holderRaw -= amount; b.holdersForwarded += amount;
        _pay(asset, ingress(), amount);
        _assertSolvent(asset);
        emit HoldersForwarded(asset, amount);
    }

    /// @dev Only the pinned LP controller may label newly delivered funds earned
    /// fees. Its LP accounting must prove these exclude principal and buffer returns.
    function receiveLPFees(RewardAsset asset, uint256 amount) external payable nonReentrant ready managerLocked onlyController {
        _receiveExact(asset, amount);
        Ledger storage b = _ledgers[uint8(asset)];
        uint256 holders = _holderPortion(asset, amount);
        b.holderRaw += holders; b.polRaw += amount - holders; b.lpFees += amount;
        _assertSolvent(asset);
        emit FeeRecorded(asset, true, amount, holders, amount - holders);
    }

    function fundPOL(RewardAsset asset, uint256 amount) external payable nonReentrant ready managerLocked {
        _receiveExact(asset, amount);
        Ledger storage b = _ledgers[uint8(asset)];
        b.polRaw += amount; b.polDonations += amount;
        _assertSolvent(asset);
        emit POLFunded(asset, msg.sender, amount, false);
    }

    function returnPOL(RewardAsset asset, uint256 amount) external payable nonReentrant ready managerLocked onlyController {
        _receiveExact(asset, amount);
        Ledger storage b = _ledgers[uint8(asset)];
        b.polRaw += amount; b.polReturned += amount;
        _assertSolvent(asset);
        emit POLFunded(asset, msg.sender, amount, true);
    }

    function takePOL(RewardAsset asset, uint256 amount) external nonReentrant ready managerLocked onlyController {
        if (polPaused) revert POLPaused();
        _assertSolvent(asset);
        Ledger storage b = _ledgers[uint8(asset)];
        if (amount == 0 || amount > b.polRaw) revert InvalidAmount();
        b.polRaw -= amount; b.polSpent += amount;
        _pay(asset, polController, amount);
        _assertSolvent(asset);
        emit POLSpent(asset, polController, amount);
    }

    function pausePOL(bytes32 evidence) external nonReentrant ready managerLocked {
        if (msg.sender != guardian && msg.sender != governor) revert Unauthorized();
        if (polPaused || evidence == bytes32(0)) revert InvalidState();
        polPaused = true; emit POLPauseChanged(true, evidence);
    }
    function unpausePOL(bytes32 evidence) external nonReentrant ready managerLocked onlyGovernor {
        if (!polPaused || evidence == bytes32(0)) revert InvalidState();
        polPaused = false; emit POLPauseChanged(false, evidence);
    }
    function proposeController(address next) external nonReentrant ready managerLocked onlyGovernor {
        if (pendingController != address(0) || next == polController || next == hook) revert InvalidState();
        _validateController(next);
        // Bind and finish incoming initialization before its notice period starts.
        if (!IFeePOLControllerV5(next).canRetire()) revert InvalidState();
        pendingController = next; controllerReadyAt = block.timestamp + CAPABILITY_DELAY;
        ++controllerProposalNonce;
        emit ControllerProposed(next, controllerProposalNonce, controllerReadyAt);
    }
    function cancelController(uint256 nonce) external nonReentrant ready managerLocked onlyGovernor {
        if (pendingController == address(0) || nonce != controllerProposalNonce) revert InvalidState();
        pendingController = address(0); controllerReadyAt = 0;
        emit ControllerCancelled(nonce);
    }
    function executeController(address next, uint256 nonce) external nonReentrant ready managerLocked {
        if (next == address(0) || next != pendingController || nonce != controllerProposalNonce
            || block.timestamp < controllerReadyAt) revert InvalidState();
        // The actual controller must include LP ownership, buffers and pending
        // jobs in this predicate. Replacing it cannot silently strand that state.
        if (!IFeePOLControllerV5(polController).canRetire()) revert InvalidState();
        _validateController(next);
        if (!IFeePOLControllerV5(next).canRetire()) revert InvalidState();
        address previous = polController;
        polController = next; pendingController = address(0); controllerReadyAt = 0;
        emit ControllerChanged(previous, next, nonce);
    }

    /// @notice Queue one prospective split at a UTC 900-second epoch boundary,
    /// at least seven days ahead, bounded by the immutable deployment cap.
    /// Activation does not depend on a keeper transaction. LP fees use their
    /// Vault receipt time, not their earlier PoolManager accrual time.
    function proposeHolderFeeSplit(uint16 next) external nonReentrant ready managerLocked onlyGovernor {
        if (next > maxHolderFeeBps) revert InvalidAmount();
        if (next != 0 && ingress() == address(0)) revert InvalidState();
        _applyMaturedSplit();
        if (feeSplitReadyAt != 0 || next == _holderFeeBps) revert InvalidState();
        pendingHolderFeeBps = next; feeSplitReadyAt = (block.timestamp + CAPABILITY_DELAY + 899) / 900 * 900;
        ++feeSplitProposalNonce;
        emit HolderFeeSplitProposed(next, feeSplitProposalNonce, feeSplitReadyAt);
    }
    function cancelHolderFeeSplit(uint256 nonce) external nonReentrant ready managerLocked onlyGovernor {
        if (feeSplitReadyAt == 0 || nonce != feeSplitProposalNonce || block.timestamp >= feeSplitReadyAt) revert InvalidState();
        pendingHolderFeeBps = 0; feeSplitReadyAt = 0;
        emit HolderFeeSplitCancelled(nonce);
    }
    /// @notice Materialize only the exact queued value/nonce after its effective
    /// epoch. This call never selects or delays the policy's activation time.
    /// No old claims, raw balances, lifetime totals or ownership are changed.
    /// The previous version's final fraction stays with POL; new receipts start
    /// independent cumulative rounding, never borrowing that old remainder.
    function executeHolderFeeSplit(uint16 next, uint256 nonce) external nonReentrant ready managerLocked {
        if (feeSplitReadyAt == 0 || next != pendingHolderFeeBps || nonce != feeSplitProposalNonce
            || block.timestamp < feeSplitReadyAt) revert InvalidState();
        _applyMaturedSplit();
    }

    /// @notice Effective share/version, including a matured but unmaterialized proposal.
    function holderFeeBps() public view returns (uint16) {
        return _splitMatured() ? pendingHolderFeeBps : _holderFeeBps;
    }
    /// @notice Zero until an initialized financial graph is bound exactly once.
    /// The fixed non-custodial child cannot replace a completed binding.
    function ingress() public view returns (address) { return ingressBinding.ingress(); }
    function feeSplitVersion() external view returns (uint256) {
        return _feeSplitVersion + (_splitMatured() ? 1 : 0);
    }
    /// @notice Current version's fractional numerator (denominator 10,000).
    /// This is a rounding carry for future receipts, not a holder liability.
    function feeRemainder(RewardAsset asset) external view returns (uint16) {
        if (_reentrancyGuardEntered() || poolManager.isUnlocked()) revert InvalidState();
        return _splitMatured() ? 0 : _feeRemainders[uint8(asset)];
    }

    /// @notice Coherent native-unit books plus quarantined raw/claim surplus.
    /// No invented zero during a callback or partially settled manager transaction.
    function inventory(RewardAsset asset) external view returns (Inventory memory s) {
        if (_reentrancyGuardEntered() || poolManager.isUnlocked()) revert InvalidState();
        s.booked = _ledgers[uint8(asset)];
        Currency currency = _currency(asset);
        s.rawBalance = currency.balanceOfSelf();
        s.claimBalance = poolManager.balanceOf(address(this), currency.toId());
        uint256 raw = s.booked.holderRaw + s.booked.polRaw;
        uint256 claims = s.booked.holderClaims + s.booked.polClaims;
        s.solvent = s.rawBalance >= raw && s.claimBalance >= claims;
        if (s.rawBalance >= raw) s.rawSurplus = s.rawBalance - raw;
        if (s.claimBalance >= claims) s.claimSurplus = s.claimBalance - claims;
    }

    function _assertSolvent(RewardAsset asset) private view {
        Ledger storage b = _ledgers[uint8(asset)];
        Currency currency = _currency(asset);
        if (currency.balanceOfSelf() < b.holderRaw + b.polRaw
            || poolManager.balanceOf(address(this), currency.toId()) < b.holderClaims + b.polClaims) revert CustodyDeficit();
    }
    /// @dev Exact cumulative floor per asset/version across claims and raw fees.
    /// FullMath/mulmod avoid overflowing amount*bps or summing lifetime fees.
    /// Only this receipt funds its allocation: 0 <= holders <= amount, even if
    /// earlier POL was spent. Other cash flows never consume or reset the carry.
    function _holderPortion(RewardAsset asset, uint256 amount) private returns (uint256 holders) {
        _applyMaturedSplit();
        uint256 bps = _holderFeeBps;
        uint256 remainder = mulmod(amount, bps, 10_000) + _feeRemainders[uint8(asset)];
        holders = FullMath.mulDiv(amount, bps, 10_000) + remainder / 10_000;
        _feeRemainders[uint8(asset)] = uint16(remainder % 10_000);
    }
    function _splitMatured() private view returns (bool) {
        return feeSplitReadyAt != 0 && block.timestamp >= feeSplitReadyAt;
    }
    function _applyMaturedSplit() private {
        if (!_splitMatured()) return;
        uint16 previous = _holderFeeBps;
        uint16[3] memory retained = _feeRemainders;
        uint256 effectiveAt = feeSplitReadyAt;
        delete _feeRemainders;
        _holderFeeBps = pendingHolderFeeBps; pendingHolderFeeBps = 0; feeSplitReadyAt = 0;
        ++_feeSplitVersion;
        emit HolderFeeSplitChanged(previous, _holderFeeBps, feeSplitProposalNonce, _feeSplitVersion, effectiveAt, retained);
    }
    function _receiveExact(RewardAsset asset, uint256 amount) private {
        if (amount == 0) revert InvalidAmount();
        if (asset == RewardAsset.ETH) { if (msg.value != amount) revert InvalidReceipt(); }
        else {
            if (msg.value != 0) revert InvalidReceipt();
            IERC20 token = IERC20(Currency.unwrap(_currency(asset)));
            uint256 beforeBalance = token.balanceOf(address(this));
            uint256 payerBefore = token.balanceOf(msg.sender);
            token.safeTransferFrom(msg.sender, address(this), amount);
            if (token.balanceOf(address(this)) != beforeBalance + amount
                || payerBefore < amount || token.balanceOf(msg.sender) != payerBefore - amount) revert InvalidReceipt();
        }
    }
    function _pay(RewardAsset asset, address recipient, uint256 amount) private {
        Currency currency = _currency(asset);
        uint256 beforeBalance = currency.balanceOfSelf();
        uint256 recipientBefore = currency.balanceOf(recipient);
        currency.transfer(recipient, amount);
        if (currency.balanceOfSelf() != beforeBalance - amount || currency.balanceOf(recipient) != recipientBefore + amount) revert InvalidReceipt();
    }
    function _currency(RewardAsset asset) private view returns (Currency) {
        return Currency.wrap(asset == RewardAsset.NARA ? nara : asset == RewardAsset.USDC ? usdc : address(0));
    }
    function _asset(Currency currency) private view returns (RewardAsset) {
        address a = Currency.unwrap(currency);
        if (a == nara) return RewardAsset.NARA;
        if (a == usdc) return RewardAsset.USDC;
        revert InvalidBinding();
    }
    function _peer(address a) private view returns (bool) {
        return a.code.length != 0 && a != address(this) && a != nara && a != usdc
            && a != ingress() && a != address(ingressBinding) && a != address(poolManager) && a != governor;
    }
    function _validateController(address a) private view {
        if (!_peer(a)) revert InvalidBinding();
        IFeePOLControllerV5 c = IFeePOLControllerV5(a);
        if (c.feeVault() != address(this) || c.poolManager() != address(poolManager)
            || c.nara() != nara || c.usdc() != usdc) revert InvalidBinding();
    }
}
