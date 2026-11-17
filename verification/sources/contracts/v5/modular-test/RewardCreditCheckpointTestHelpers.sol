// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NARARewardLedgerV5} from "../modular/NARARewardLedgerV5.sol";
import {NARAPrincipalLedgerV5} from "../modular/NARAPrincipalLedgerV5.sol";
import {NARARewardCreditLedgerV5, RewardCreditStateV5} from "../modular/NARARewardCreditLedgerV5.sol";
import {RewardTermsV5, RewardWeightStateV5, PrincipalLedgerStateV5} from "../modular/NARAModuleInterfacesV5.sol";
import {AccountingPolicy, PositionState, RewardAsset} from "../interfaces/NARAAccountingTypesV5.sol";

interface IRewardCheckpointActionsTest {
    function checkpointPosition(uint256 id, uint64 generation) external;
}

/// @dev TEST ONLY. Synthetic fixed Principal peer, not principal custody, NFT
/// authorization, an emission model, or an implemented financial transition.
/// Weight changes deliberately checkpoint the old closed interval first.
contract RewardCheckpointPrincipalPeer {
    uint256 public constant SCHEMA_VERSION = 3;
    address public immutable engine;
    address public immutable rewards;
    address public immutable nara;
    address public immutable reserve;
    address public immutable positionNFT;
    address public immutable admissionHelper;
    bytes32 public constant bindingHash = keccak256("SYNTHETIC_REWARD_CHECKPOINT_PRINCIPAL");
    bool public bindingsSealed;
    uint64 public genesisTimestamp;
    uint64 public openedEpoch;
    address transient public moduleLockHolder;
    uint256 private _count;
    mapping(uint256 => PositionState) private _positions;
    bool private _forceZeroBase;
    bool private _forceZeroRarity;

    error UnknownGeneration();
    error Unauthorized();

    constructor(address engine_, address rewards_, address nara_, address reserve_, address nft_) {
        engine = engine_; rewards = rewards_; nara = nara_; reserve = reserve_;
        positionNFT = nft_; admissionHelper = address(0xF005);
    }

    function policy() external pure returns (AccountingPolicy memory p) {
        p.rewardAdmissionCap = type(uint256).max / 1e27;
    }

    /// @dev Schema-2 synthetic peer has no lifecycleLedger, forge, model or quote peers; checks the 10 bound reward/principal sinks.
    function isProtocolSink(address a) external view returns (bool) {
        return a == address(0) || a == address(this) || a == positionNFT || a == engine || a == rewards
            || a == reserve || a == nara || a == admissionHelper || a == NARARewardLedgerV5(rewards).usdc()
            || a == address(NARARewardLedgerV5(rewards).creditLedger());
    }

    function definePosition(uint256 id, address owner, uint256 weight, uint64 activation, uint64 end) external {
        _definePosition(id, owner, weight, weight, activation, end);
    }

    /// @dev TEST ONLY. Duration-one positions with independently specified rarity.
    /// The ordinary path always derives both totals from these same positions.
    function definePositionWithWeights(uint256 id, address owner, uint256 baseWeight, uint256 rarityWeight,
        uint64 activation, uint64 end) external
    {
        _definePosition(id, owner, baseWeight, rarityWeight, activation, end);
    }

    function _definePosition(uint256 id, address owner, uint256 baseWeight, uint256 rarityWeight,
        uint64 activation, uint64 end) private
    {
        require(!bindingsSealed && id == _count + 1 && owner != address(0), "test setup only");
        require(baseWeight != 0 && rarityWeight != 0 && activation < end, "test positive position");
        _count = id;
        PositionState storage p = _positions[id];
        p.generationOwner = owner; p.generation = 1; p.activation = activation;
        p.maturity = end; p.effectiveEnd = end; p.principal = baseWeight;
        p.modelWeight = baseWeight; p.rewardWeight = rarityWeight;
    }

    /// @dev Deliberately corrupt the synthetic peer's denominator report only.
    /// This is fault injection, never a coherent Principal or production path.
    function setDenominatorFault(bool zeroBase, bool zeroRarity) external {
        require(moduleLockHolder == address(0), "test lock");
        _forceZeroBase = zeroBase; _forceZeroRarity = zeroRarity;
    }

    function initialize(uint64 genesis) external {
        require(msg.sender == engine && !bindingsSealed, "test engine only");
        genesisTimestamp = genesis; bindingsSealed = true;
    }

    function beginModuleAction() external {
        require((msg.sender == engine || msg.sender == rewards) && moduleLockHolder == address(0), "test lock");
        moduleLockHolder = msg.sender;
    }

    function endModuleAction() external {
        require(moduleLockHolder == msg.sender, "test lock owner");
        moduleLockHolder = address(0);
    }

    function openBoundary(uint64 epoch) external {
        require(msg.sender == engine && moduleLockHolder == engine && epoch == openedEpoch + 1, "test boundary");
        openedEpoch = epoch;
    }

    function settlementState() external view returns (PrincipalLedgerStateV5 memory s) {
        if ((msg.sender != engine && msg.sender != rewards) || moduleLockHolder != engine) revert Unauthorized();
        s.initialized = bindingsSealed; s.openedEpoch = openedEpoch; s.positionCount = _count;
        for (uint256 id = 1; id <= _count; ++id) {
            PositionState storage p = _positions[id];
            if (p.activation <= openedEpoch && openedEpoch < p.effectiveEnd) {
                s.activeRewardWeight += p.rewardWeight; s.activeModelWeight += p.modelWeight;
            }
        }
        if (_forceZeroBase) s.activeModelWeight = 0;
        if (_forceZeroRarity) s.activeRewardWeight = 0;
    }

    function rewardTerms(uint256 id, uint64 generation) external view returns (RewardTermsV5 memory) {
        if (msg.sender != rewards || (moduleLockHolder != address(0) && moduleLockHolder != rewards
            && moduleLockHolder != address(this))) revert Unauthorized();
        PositionState memory p = _position(id, generation);
        return RewardTermsV5(p.generationOwner, p.activation, p.effectiveEnd, p.rewardWeight, 0, p.rewardWeight, p.modelWeight);
    }

    function rewardWeightState(uint256 id, uint64 generation) external view returns (RewardWeightStateV5 memory) {
        require(moduleLockHolder == address(0), "test coherent read");
        PositionState memory p = _position(id, generation);
        return RewardWeightStateV5(0, p.rewardWeight, p.rewardWeight);
    }

    function position(uint256 id, uint64 generation) external view returns (PositionState memory) {
        require(moduleLockHolder == address(0), "test coherent read");
        return _position(id, generation);
    }

    function checkpoint(uint256 id, uint64 generation) external { _checkpoint(id, generation); }

    function checkpointAndSetWeight(uint256 id, uint64 generation, uint256 nextWeight) external {
        _checkpoint(id, generation);
        _positions[id].rewardWeight = nextWeight;
    }

    function setOwner(uint256 id, uint64 generation, address owner) external {
        _position(id, generation); require(owner != address(0), "test owner");
        _positions[id].generationOwner = owner;
    }

    function checkpointWithoutLock(uint256 id, uint64 generation) external {
        IRewardCheckpointActionsTest(rewards).checkpointPosition(id, generation);
    }

    function checkpointWithWrongLock(uint256 id, uint64 generation) external {
        moduleLockHolder = engine;
        IRewardCheckpointActionsTest(rewards).checkpointPosition(id, generation);
        moduleLockHolder = address(0);
    }

    function _checkpoint(uint256 id, uint64 generation) private {
        require(moduleLockHolder == address(0), "test lock");
        moduleLockHolder = address(this);
        IRewardCheckpointActionsTest(rewards).checkpointPosition(id, generation);
        moduleLockHolder = address(0);
    }

    function _position(uint256 id, uint64 generation) private view returns (PositionState memory p) {
        p = _positions[id];
        if (p.generationOwner == address(0) || generation != p.generation) revert UnknownGeneration();
    }
}

/// @dev TEST ONLY. Uses the actual Rewards receipt/close/open path with zero
/// emissions. Synthetic Principal schedules are not actual Engine integration.
contract RewardCheckpointEnginePeer {
    RewardCheckpointPrincipalPeer public immutable principal;
    NARARewardLedgerV5 public immutable rewards;
    uint64 private _genesis;
    uint64 private _cursor;

    constructor(address principal_, address rewards_) {
        principal = RewardCheckpointPrincipalPeer(principal_); rewards = NARARewardLedgerV5(rewards_);
    }

    function principalEpoch() external view returns (uint64, uint64) { return (_genesis, _cursor); }
    function rewardBindingHash() external view returns (bytes32) { return rewards.bindingHash(); }

    function initialize(uint64 genesis) external {
        require(_genesis == 0, "test initialized"); _genesis = genesis;
        principal.initialize(genesis); principal.beginModuleAction();
        rewards.initialize(genesis); principal.endModuleAction();
    }

    function advance() external {
        principal.beginModuleAction(); rewards.prepareEpoch(_cursor); rewards.closeEpoch(_cursor, 0);
        ++_cursor; principal.openBoundary(_cursor); rewards.openBoundary(_cursor); principal.endModuleAction();
    }
}

/// @dev TEST ONLY. Arbitrary recorded indices isolate the actual fixed child's
/// arithmetic. This parent is not RewardLedger custody or a reachable live graph.
contract RewardCheckpointCreditParentProbe {
    NARARewardCreditLedgerV5 public immutable ledger = new NARARewardCreditLedgerV5();
    mapping(uint8 => mapping(uint64 => uint256)) private _baseIndices;
    mapping(uint8 => mapping(uint64 => uint256)) private _rarityIndices;
    mapping(uint8 => mapping(uint64 => bool)) private _exists;

    function setIndices(RewardAsset asset, uint64 boundary, uint256 base, uint256 rarity) external {
        _baseIndices[uint8(asset)][boundary] = base;
        _rarityIndices[uint8(asset)][boundary] = rarity;
        _exists[uint8(asset)][boundary] = true;
    }

    function creditIndices(RewardAsset asset, uint64 start, uint64 end) external view
        returns (uint256, uint256, uint256, uint256)
    {
        require(msg.sender == address(ledger) && start <= end
            && _exists[uint8(asset)][start] && _exists[uint8(asset)][end], "test index unavailable");
        return (_baseIndices[uint8(asset)][start], _baseIndices[uint8(asset)][end],
            _rarityIndices[uint8(asset)][start], _rarityIndices[uint8(asset)][end]);
    }

    function checkpoint(uint256 id, uint64 generation, RewardAsset asset, RewardTermsV5 calldata terms, uint64 next) external {
        ledger.checkpoint(id, generation, asset, terms, next);
    }

    function consumeClaim(uint256 id, uint64 generation, RewardAsset asset, RewardTermsV5 calldata terms, uint64 next)
        external returns (uint256)
    {
        return ledger.consumeClaim(id, generation, asset, terms, next);
    }

    function credit(uint256 id, uint64 generation, RewardAsset asset) external view returns (RewardCreditStateV5 memory) {
        return ledger.credit(id, generation, asset);
    }
}

/// @dev TEST ONLY. Exercises the actual Principal's internal scheduling seam.
/// This wrapper is not part of the production ABI and is not a rarity oracle,
/// financial Forge entry point, governance action, or accepted economic policy.
contract ProspectiveRewardWeightPrincipalTest is NARAPrincipalLedgerV5 {
    error TestForcedRollback();

    constructor(address authority, address nara_, address engine_, address rewards_, address nft_, address forge_)
        NARAPrincipalLedgerV5(authority, nara_, engine_, rewards_, nft_, forge_) {}

    function replaceRewardWeightForTest(uint256 id, uint64 generation, address expectedOwner,
        bytes32 expectedTermsHash, uint256 newWeight) external financialAction
    {
        if (msg.sender != expectedOwner) revert Unauthorized();
        _replaceRewardWeight(id, generation, expectedOwner, expectedTermsHash, newWeight);
    }

    function replaceRewardWeightAndRevertForTest(uint256 id, uint64 generation, address expectedOwner,
        bytes32 expectedTermsHash, uint256 newWeight) external financialAction
    {
        if (msg.sender != expectedOwner) revert Unauthorized();
        _replaceRewardWeight(id, generation, expectedOwner, expectedTermsHash, newWeight);
        revert TestForcedRollback();
    }
}
