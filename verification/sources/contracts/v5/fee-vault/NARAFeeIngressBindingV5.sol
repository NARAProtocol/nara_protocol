// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "@uniswap/v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {CoreBindings, ReserveState, RewardAsset} from "../interfaces/NARAAccountingTypesV5.sol";

interface IFeeBindingVaultV5 {
    function bindingsSealed() external view returns (bool);
    function hook() external view returns (address);
    function polController() external view returns (address);
    function feeRemainder(RewardAsset asset) external view returns (uint16);
}
interface IFeeBindingIngressV5 {
    function SCHEMA_VERSION() external view returns (uint256);
    function nara() external view returns (address);
    function usdc() external view returns (address);
    function rewards() external view returns (address);
}
interface IFeeBindingRewardsV5 {
    function SCHEMA_VERSION() external view returns (uint256);
    function initialized() external view returns (bool);
    function nara() external view returns (address);
    function usdc() external view returns (address);
    function engine() external view returns (address);
    function principal() external view returns (address);
    function reserve() external view returns (address);
    function genesisTimestamp() external view returns (uint64);
    function bindingHash() external view returns (bytes32);
}
interface IFeeBindingPrincipalV5 {
    function SCHEMA_VERSION() external view returns (uint256);
    function bindingsSealed() external view returns (bool);
    function nara() external view returns (address);
    function engine() external view returns (address);
    function rewards() external view returns (address);
    function reserve() external view returns (address);
    function positionNFT() external view returns (address);
    function moduleLockHolder() external view returns (address);
    function genesisTimestamp() external view returns (uint64);
    function bindingHash() external view returns (bytes32);
}
interface IFeeBindingEngineV5 {
    function bindings() external view returns (CoreBindings memory);
    function financialModules() external view returns (address principal, address rewards);
    function principalEpoch() external view returns (uint64 genesis, uint64 nextEpochToClose);
    function principalBindingHash() external view returns (bytes32);
    function rewardBindingHash() external view returns (bytes32);
    function graphHash() external view returns (bytes32);
}
interface IFeeBindingReserveV5 {
    function state() external view returns (ReserveState memory);
}
interface IFeeBindingNFTV5 {
    function financialSchemaVersion() external view returns (uint256);
    function core() external view returns (address);
    function rewards() external view returns (address);
}
interface IFeeBindingTokenV5 {
    function decimals() external view returns (uint8);
    function FLASH_FEE_SINK() external view returns (address);
}

/// @notice Fixed, non-custodial, once-only selection of the Vault's future ingress.
/// @dev A commitment authenticates the governor's exact choice, not code honesty.
/// Reviewed non-proxy deployment provenance remains a separate acceptance gate.
/// This contract cannot transfer fees, change allocations or reclassify LP accruals.
contract NARAFeeIngressBindingV5 {
    using TransientStateLibrary for IPoolManager;

    uint256 public constant SCHEMA_VERSION = 1;
    uint256 public constant CAPABILITY_DELAY = 7 days;
    address public immutable vault;
    address public immutable poolManager;
    address public immutable nara;
    address public immutable usdc;
    address public immutable governor;

    address public ingress;
    address public pendingIngress;
    bytes32 public pendingCommitment;
    uint256 public readyAt;
    uint256 public proposalNonce;
    bytes32 public boundCommitment;

    error Unauthorized();
    error InvalidBinding();
    error InvalidState();
    error InvalidCommitment();

    event IngressProposed(address indexed ingress, bytes32 indexed commitment, uint256 indexed nonce, uint256 readyAt);
    event IngressCancelled(uint256 indexed nonce);
    event IngressBound(address indexed ingress, bytes32 indexed commitment, uint256 indexed nonce);

    constructor(address vault_, address manager_, address nara_, address usdc_, address governor_, address initialIngress_) {
        // Vault constructs this exact child; its runtime does not exist yet.
        if (vault_ != msg.sender || vault_ == address(0) || manager_.code.length == 0
            || nara_.code.length == 0 || usdc_.code.length == 0 || governor_.code.length == 0
            || vault_ == address(this) || manager_ == vault_ || nara_ == vault_ || usdc_ == vault_ || governor_ == vault_
            || nara_ == usdc_ || nara_ == manager_ || usdc_ == manager_
            || governor_ == manager_ || governor_ == nara_ || governor_ == usdc_) revert InvalidBinding();
        if (IFeeBindingTokenV5(nara_).decimals() != 18 || IFeeBindingTokenV5(usdc_).decimals() != 6) revert InvalidBinding();
        vault = vault_; poolManager = manager_; nara = nara_; usdc = usdc_; governor = governor_;
        if (initialIngress_ != address(0)) {
            bytes32 commitment = _commitment(initialIngress_, false);
            ingress = initialIngress_; boundCommitment = commitment;
            emit IngressBound(initialIngress_, commitment, 0);
        }
    }

    modifier onlyGovernor() { if (msg.sender != governor) revert Unauthorized(); _; }
    modifier coherentContext() { _requireContext(); _; }

    /// @notice Queue one complete, already-initialized financial graph for review.
    function propose(address next, bytes32 expectedCommitment) external onlyGovernor coherentContext {
        if (ingress != address(0) || pendingIngress != address(0)) revert InvalidState();
        bytes32 commitment = _commitment(next, true);
        if (commitment != expectedCommitment) revert InvalidCommitment();
        pendingIngress = next; pendingCommitment = commitment;
        readyAt = block.timestamp + CAPABILITY_DELAY;
        ++proposalNonce;
        emit IngressProposed(next, commitment, proposalNonce, readyAt);
    }

    /// @notice Cancellation never preserves elapsed notice for a later proposal.
    function cancel(uint256 nonce) external onlyGovernor coherentContext {
        if (ingress != address(0) || pendingIngress == address(0) || nonce != proposalNonce) revert InvalidState();
        pendingIngress = address(0); pendingCommitment = bytes32(0); readyAt = 0;
        emit IngressCancelled(nonce);
    }

    /// @notice Anyone may finalize only the exact mature, unchanged proposal once.
    function finalize(address next, bytes32 expectedCommitment, uint256 nonce) external coherentContext {
        if (ingress != address(0) || next == address(0) || next != pendingIngress
            || nonce != proposalNonce || block.timestamp < readyAt) revert InvalidState();
        if (expectedCommitment != pendingCommitment || _commitment(next, true) != expectedCommitment) revert InvalidCommitment();
        ingress = next; boundCommitment = expectedCommitment;
        pendingIngress = address(0); pendingCommitment = bytes32(0); readyAt = 0;
        emit IngressBound(next, expectedCommitment, nonce);
    }

    /// @notice Recompute validated identity/code commitment, excluding mutable clocks/balances.
    function commitmentOf(address next) external view coherentContext returns (bytes32) {
        return _commitment(next, true);
    }

    function _requireContext() private view {
        if (IPoolManager(poolManager).isUnlocked() || !IFeeBindingVaultV5(vault).bindingsSealed()) revert InvalidState();
        // The existing Vault read rejects its in-flight action and manager unlock.
        // Every external interaction in this module is a typed STATICCALL.
        IFeeBindingVaultV5(vault).feeRemainder(RewardAsset.NARA);
    }

    function _commitment(address next, bool liveVault) private view returns (bytes32) {
        address hook; address controller;
        if (liveVault) {
            hook = IFeeBindingVaultV5(vault).hook();
            controller = IFeeBindingVaultV5(vault).polController();
        }
        if (!_peer(next, hook, controller)) revert InvalidBinding();
        IFeeBindingIngressV5 i = IFeeBindingIngressV5(next);
        address rewards = i.rewards();
        if (i.SCHEMA_VERSION() != 1 || i.nara() != nara || i.usdc() != usdc
            || !_peer(rewards, hook, controller) || rewards == next) revert InvalidBinding();
        IFeeBindingRewardsV5 r = IFeeBindingRewardsV5(rewards);
        address principal = r.principal(); address engine = r.engine();
        if (r.SCHEMA_VERSION() != 2 || !r.initialized() || r.nara() != nara || r.usdc() != usdc
            || !_peer(principal, hook, controller) || !_peer(engine, hook, controller)
            || principal == engine || principal == rewards || principal == next
            || engine == rewards || engine == next) revert InvalidBinding();
        IFeeBindingPrincipalV5 p = IFeeBindingPrincipalV5(principal);
        IFeeBindingEngineV5 e = IFeeBindingEngineV5(engine);
        CoreBindings memory b = e.bindings();
        if (p.SCHEMA_VERSION() != 3 || !p.bindingsSealed() || p.moduleLockHolder() != address(0)
            || p.rewards() != rewards || p.engine() != engine || p.nara() != nara
            || p.reserve() != b.reserve || r.reserve() != b.reserve
            || b.schemaVersion != 1 || b.nara != nara || !b.bindingsSealed || !b.activated
            || b.bootstrapAuthority != address(0) || p.positionNFT() != b.positionNFT) revert InvalidBinding();
        (address boundPrincipal, address boundRewards) = e.financialModules();
        bytes32 principalHash = p.bindingHash(); bytes32 rewardHash = r.bindingHash(); bytes32 graphHash = e.graphHash();
        (uint64 genesis,) = e.principalEpoch();
        if (boundPrincipal != principal || boundRewards != rewards || principalHash == bytes32(0)
            || rewardHash == bytes32(0) || graphHash == bytes32(0)
            || e.principalBindingHash() != principalHash || e.rewardBindingHash() != rewardHash
            || genesis == 0 || genesis % 900 != 0 || p.genesisTimestamp() != genesis || r.genesisTimestamp() != genesis)
            revert InvalidBinding();
        _validateRemainingPeers(b, next, rewards, principal, engine, hook, controller, genesis);

        bytes32 identities = keccak256(abi.encode(next, rewards, principal, engine, b.reserve, b.emissionModel, b.positionNFT));
        bytes32 runtimes = keccak256(abi.encode(next.codehash, rewards.codehash, principal.codehash, engine.codehash,
            b.reserve.codehash, b.emissionModel.codehash, b.positionNFT.codehash));
        return keccak256(abi.encode(keccak256("NARA_V5_FEE_INGRESS_BINDING_V1"), block.chainid, address(this),
            vault, poolManager, nara, usdc, governor, identities, runtimes, principalHash, rewardHash, graphHash, genesis));
    }

    function _validateRemainingPeers(CoreBindings memory b, address next, address rewards, address principal,
        address engine, address hook, address controller, uint64 genesis) private view {
        address[3] memory peers = [b.reserve, b.emissionModel, b.positionNFT];
        for (uint256 k; k < peers.length; ++k) {
            address peer = peers[k];
            if (!_peer(peer, hook, controller) || peer == next || peer == rewards || peer == principal || peer == engine)
                revert InvalidBinding();
            for (uint256 j; j < k; ++j) if (peer == peers[j]) revert InvalidBinding();
        }
        IFeeBindingNFTV5 nft = IFeeBindingNFTV5(b.positionNFT);
        if (nft.financialSchemaVersion() != 2 || nft.core() != principal || nft.rewards() != rewards
            || IFeeBindingTokenV5(nara).FLASH_FEE_SINK() != b.reserve) revert InvalidBinding();
        ReserveState memory s = IFeeBindingReserveV5(b.reserve).state();
        if (s.schemaVersion != 1 || s.nara != nara || s.core != engine || !s.bindingsSealed
            || s.bootstrapAuthority != address(0) || !s.initialFundingRecognized || s.genesisTimestamp != genesis
            || s.genesisFunding != b.expectedGenesisFunding) revert InvalidBinding();
    }

    function _peer(address peer, address hook, address controller) private view returns (bool) {
        return peer.code.length != 0 && peer != address(this) && peer != vault && peer != poolManager
            && peer != nara && peer != usdc && peer != governor && peer != hook && peer != controller;
    }
}
