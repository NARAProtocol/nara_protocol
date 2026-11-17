// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NARAPrincipalLedgerV5} from "../modular/NARAPrincipalLedgerV5.sol";
import {AccountingPolicy, CoreBindings, EpochClock, CreateRequest} from "../interfaces/NARAAccountingTypesV5.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {NARARewardLensV5} from "../modular/NARARewardLensV5.sol";
import {NARARewardLedgerV5} from "../modular/NARARewardLedgerV5.sol";
import {RewardAsset, RewardCredit} from "../interfaces/NARAAccountingTypesV5.sol";
import {NARAPositionLensV5} from "../modular/NARAPositionLensV5.sol";
import {PositionViewV5, PositionStatusV5} from "../modular/NARAPositionViewTypesV5.sol";

/// @dev All peers in this file are deliberately controllable adversarial fixtures.
/// Their unrestricted calls must never enter deployment inventory.
contract ModularReserveStub {}

contract ModularEngineStub {
    CoreBindings private _bindings;
    AccountingPolicy private _policy;
    uint64 private _genesis;
    uint64 private _cursor;
    address public principal;
    address public rewards;
    bool public failReads;
    bytes32 public principalBindingHash;
    constructor(address authority, address nara, address reserve, AccountingPolicy memory p) {
        _bindings = CoreBindings(1, nara, reserve, address(0), address(0), authority, false, false, 700_000 ether);
        p.policyHash = keccak256(abi.encode("TEST_POLICY", address(this), p)); _policy = p;
    }
    function bindings() external view returns (CoreBindings memory) { require(!failReads, "engine unavailable"); return _bindings; }
    function policy() external view returns (AccountingPolicy memory) { require(!failReads, "engine unavailable"); return _policy; }
    function financialModules() external view returns (address, address) { require(!failReads, "engine unavailable"); return (principal, rewards); }
    function setFailReads(bool value) external { failReads = value; }
    function setBindingHashForTest(bytes32 value) external { principalBindingHash = value; }
    function bind(address p, address r, address nft) external { principal = p; rewards = r; _bindings.positionNFT = nft; }
    function seal() external {
        _bindings.bindingsSealed = true; _bindings.bootstrapAuthority = address(0);
        // P2.2: binding V3 carries the Principal's precomputed Forge peer.
        principalBindingHash = keccak256(abi.encode(keccak256("NARA_V5_PRINCIPAL_BINDING_V3"), block.chainid,
            address(this), principal, _bindings.nara, _bindings.reserve, rewards, _bindings.positionNFT,
            NARAPrincipalLedgerV5(principal).forge(), _policy.policyHash));
    }
    function principalEpoch() external view returns (uint64, uint64) {
        require(!failReads, "engine unavailable"); return (_genesis, _cursor);
    }
    function clock() external view returns (EpochClock memory c) {
        require(!failReads, "engine unavailable"); c.genesisTimestamp = _genesis;
        if (!_bindings.activated || block.timestamp < _genesis) return c;
        c.started = true; c.wallEpoch = uint64((block.timestamp - _genesis) / 900);
        c.nextEpochToClose = _cursor; c.backlog = c.wallEpoch - _cursor;
        c.nextBoundaryTimestamp = uint256(_genesis) + (uint256(c.wallEpoch) + 1) * 900;
    }
    function activate() external {
        NARAPrincipalLedgerV5 p = NARAPrincipalLedgerV5(principal); p.beginModuleAction();
        _genesis = uint64((block.timestamp / 900 + 1) * 900); _bindings.activated = true;
        p.initialize(_genesis); p.endModuleAction();
    }
    function advance(uint64 steps) external {
        NARAPrincipalLedgerV5 p = NARAPrincipalLedgerV5(principal); p.beginModuleAction();
        for (uint64 i; i < steps; ++i) { ++_cursor; p.openBoundary(_cursor); }
        p.endModuleAction();
    }
    function callPrincipal(bytes calldata payload, bool acquire, bool release) external returns (bytes memory result) {
        NARAPrincipalLedgerV5 p = NARAPrincipalLedgerV5(principal);
        if (acquire) p.beginModuleAction();
        (bool ok, bytes memory data) = principal.call(payload);
        if (!ok) assembly ("memory-safe") { revert(add(data, 32), mload(data)) }
        if (release) p.endModuleAction(); return data;
    }
}

contract ModularRewardsStub {
    address public immutable engine;
    address public immutable principal;
    address public immutable nara;
    /// @dev P2.2: the Principal's initialize stores the Rewards-side deny-list pair; the stub has neither (zero).
    address public constant usdc = address(0);
    address public constant creditLedger = address(0);
    constructor(address e, address p, address n) { engine = e; principal = p; nara = n; }
    function attempt(address target, bytes calldata payload) external returns (bool ok, bytes memory result) {
        NARAPrincipalLedgerV5(principal).beginModuleAction();
        (ok, result) = target.call(payload);
        NARAPrincipalLedgerV5(principal).endModuleAction();
    }
    function failWhileLocked() external {
        NARAPrincipalLedgerV5(principal).beginModuleAction(); revert("test reward failure");
    }
    /// @dev P2.1: the harness Principal's weight replacement checkpoints the old terms through this peer; the stub
    /// records nothing (the real ledger's checkpoint is covered by ProspectiveRewardWeight.test.ts).
    function checkpointPosition(uint256, uint64) external {
        if (msg.sender != principal || NARAPrincipalLedgerV5(principal).moduleLockHolder() != principal) revert("test checkpoint caller");
    }
}

contract ModularNFTStub {
    address public immutable core;
    uint256 public constant financialSchemaVersion = 2;
    bool public failMint;
    mapping(uint256 => address) public ownerOf;
    constructor(address p) { core = p; }
    function setFailMint(bool value) external { failMint = value; }
    function renderer() external view returns (address) { return address(this); }
    function art() external view returns (address) { return address(this); }
    function statsReader() external view returns (address) { return address(this); }
    function activeOwnerOf(uint256 id, uint64) external view returns (address) { return ownerOf[id]; }
    function mint(address owner, uint256 id, uint64) external {
        require(msg.sender == core && !failMint, "test mint rejected"); ownerOf[id] = owner;
        if (owner.code.length != 0) require(IERC721Receiver(owner).onERC721Received(msg.sender, address(0), id, "")
            == IERC721Receiver.onERC721Received.selector, "test receiver rejected");
    }
}

contract ModularPrincipalActor is IERC721Receiver {
    address public target;
    bytes public payload;
    bool public callbackSucceeded;
    function configure(address t, bytes calldata p) external { target = t; payload = p; }
    function create(address p, address token, CreateRequest calldata request) external {
        IERC20(token).approve(p, request.amount); NARAPrincipalLedgerV5(p).create(request);
    }
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        (callbackSucceeded,) = target.call(payload);
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @dev Unrestricted callback actor, never a production custody component.
contract ModularNFTReceiver is IERC721Receiver {
    address public target;
    bytes public payload;
    bool public reject;
    bool public callbackSucceeded;
    bytes public callbackResult;
    function configure(address t, bytes calldata p, bool r) external { target = t; payload = p; reject = r; }
    function execute(address t, bytes calldata p) external returns (bytes memory result) {
        (bool ok, bytes memory data) = t.call(p);
        if (!ok) assembly ("memory-safe") { revert(add(data, 32), mload(data)) }
        return data;
    }
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (target != address(0)) (callbackSucceeded, callbackResult) = target.call(payload);
        return reject ? bytes4(0) : IERC721Receiver.onERC721Received.selector;
    }
}

/// @dev Deliberately hostile presentation fixture; never deployment inventory.
contract ModularMetadataFault {
    uint256 public constant SCHEMA_VERSION = 2;
    uint256 public mode;
    function configure(uint256 value) external { mode = value; }
    function tokenURI(address, uint256) external view returns (string memory) {
        uint256 m = mode;
        if (m == 1) revert("renderer unavailable");
        if (m == 2) assembly ("memory-safe") { for {} 1 {} {} }
        if (m == 3) assembly ("memory-safe") { return(mload(64), 65536) }
        if (m == 4) assembly ("memory-safe") { let p := mload(64) mstore(p, 64) mstore(add(p, 32), 1) mstore(add(p, 64), 65) return(p, 96) }
        if (m == 5) assembly ("memory-safe") { let p := mload(64) mstore(p, 32) mstore(add(p, 32), not(0)) return(p, 96) }
        if (m == 6) assembly ("memory-safe") { mstore(0, 32) return(0, 32) }
        if (m == 7) return "";
        if (m == 8) assembly ("memory-safe") { let p := mload(64) mstore(p, 32) mstore(add(p, 32), 1) mstore(add(p, 64), 65) return(p, 128) }
        return "data:application/json;base64,e30=";
    }
}

/// @dev Arbitrary hostile typed presentation. Never a financial source or deployment component.
contract ModularPositionViewFault {
    uint256 public constant SCHEMA_VERSION = 2;
    NARAPositionLensV5 public immutable source;
    uint256 public mode;
    uint256 public burnKeepGas;
    uint256[] private _words;
    uint256[] private _values;
    address public callbackTarget;
    bytes public callbackPayload;
    constructor(address source_) { source = NARAPositionLensV5(source_); }
    function configure(uint256 mode_) external { mode = mode_; burnKeepGas = 0; }
    function configureBurn(uint256 keepGas_) external { mode = 12; burnKeepGas = keepGas_; }
    function configureWord(uint256 word, uint256 value) external {
        delete _words; delete _values; _words.push(word); _values.push(value); mode = 8;
    }
    function configureWords(uint256[] calldata words, uint256[] calldata values) external {
        require(words.length == values.length, "test word shape"); _words = words; _values = values; mode = 8;
    }
    function configureCallback(address target, bytes calldata payload) external {
        callbackTarget = target; callbackPayload = payload; mode = 9;
    }
    // Deliberately non-view ABI: the compositor must still use STATICCALL.
    function snapshot(address nft, uint256 tokenId) external returns (PositionViewV5 memory v) {
        uint256 m = mode;
        if (m == 1) revert("test statistics unavailable");
        if (m == 2) assembly ("memory-safe") { for {} 1 {} {} }
        if (m == 3) assembly ("memory-safe") { return(0, 0) }
        if (m == 6) assembly ("memory-safe") { return(mload(64), 65536) }
        if (m == 9) {
            (bool ok,) = callbackTarget.call(callbackPayload);
            require(ok, "test static mutation rejected");
        }
        if (m == 10) {
            (bool ok,) = nft.staticcall(abi.encodeWithSignature("tokenURI(uint256)", tokenId));
            require(ok, "test recursive read exhausted");
            assembly ("memory-safe") { return(0, 0) }
        }
        v = source.snapshot(nft, tokenId);
        if (m == 11 || m == 12) {
            // Maximum string widths without conflating formatting with dozens
            // of cold fixture-configuration SLOADs. Not financially admissible.
            // P2.7 (ACC-05 / UPG-101): StatsReader cross-checks v.financial, v.award,
            // v.lifecycle, v.lineage, and v.rarityTier against canonical Principal and
            // LifecycleLedger reads, so preserve them from source.
            uint256 maximum = type(uint256).max;
            bool detached = v.status == PositionStatusV5.Withdrawn || v.status == PositionStatusV5.Dormant || v.lifecycle.consumed;
            v.attachedPrincipal = detached ? 0 : v.financial.principal;
            v.eligibleRewardWeight = detached ? 0 : maximum; v.totalRewardWeight = maximum; v.rewardShareWad = detached ? 0 : 1e18;
            v.eligibleModelWeight = detached ? 0 : maximum; v.totalModelWeight = maximum;
            v.naraRewardRatioWad = maximum; v.historicalNaraRateWad = maximum;
            v.historicalNaraRateAvailable = true; v.observedClosedPulses = type(uint64).max;
            v.unlockTimestamp = maximum;
            v.wallEpoch = type(uint64).max;
            v.weightEpoch = type(uint64).max - 1; v.weightSnapshotCurrent = false;
            v.currentPulseEligible = !detached;
            for (uint8 i; i < 3; ++i) {
                v.rewardReadSuccess[i] = true;
                v.rewards[i].generation = v.generation; v.rewards[i].generationOwner = v.financial.generationOwner;
                v.rewards[i].claimable = maximum; v.rewards[i].closedCreditScaled = maximum;
                v.rewards[i].cumulativePaid = 0;
                v.attachedClaimable[i] = detached ? 0 : maximum;
                v.archivedClaimable[i] = detached ? maximum : 0;
                v.positionRewardsEarned[i] = maximum;
            }
        }
        bytes memory data = abi.encode(v);
        require(data.length == 3424, "test snapshot ABI drift");
        // A successful provider can still consume almost all forwarded gas.
        // Its valid worst-width data must not make outer composition lose art.
        if (m == 12) {
            uint256 keep = burnKeepGas == 0 ? 10000 : burnKeepGas;
            assembly ("memory-safe") {
                for {} gt(gas(), keep) {} {} return(add(data, 32), mload(data))
            }
        }
        if (m == 4) assembly ("memory-safe") { return(add(data, 32), 3423) }
        if (m == 5) assembly ("memory-safe") { return(add(data, 32), 3456) }
        if (m == 7) {
            data = abi.encodePacked(uint256(32), data);
            assembly ("memory-safe") { return(add(data, 32), mload(data)) }
        }
        if (m == 8) {
            for (uint256 i; i < _words.length; ++i) {
                uint256 word = _words[i]; uint256 value = _values[i];
                require(word < 107, "test word index");
                assembly ("memory-safe") { mstore(add(add(data, 32), mul(word, 32)), value) }
            }
            assembly ("memory-safe") { return(add(data, 32), mload(data)) }
        }
    }
}

/// @dev Schema probe faults are separate from snapshots and must be rejected atomically.
contract ModularPositionSchemaFault {
    uint256 public mode;
    function configure(uint256 mode_) external { mode = mode_; }
    function SCHEMA_VERSION() external view returns (uint256) {
        uint256 m = mode;
        if (m == 1) revert("test schema unavailable");
        if (m == 2) assembly ("memory-safe") { for {} 1 {} {} }
        if (m == 3) assembly ("memory-safe") { return(0, 0) }
        if (m == 4) assembly ("memory-safe") { mstore(0, 2) return(0, 31) }
        if (m == 5) assembly ("memory-safe") { mstore(0, 2) return(0, 64) }
        if (m == 6) return 1;
        if (m == 7) return type(uint256).max;
        return 2;
    }
}

contract ModularRewardViewFault {
    address public immutable realLens;
    uint8 public mode;
    constructor(address source) { realLens = source; }
    function configure(uint8 value) external { mode = value; }
    function credit(NARARewardLedgerV5 rewards, uint256 id, uint64 generation, RewardAsset asset)
        external view returns (RewardCredit memory c) {
        if (mode == 1 && asset == RewardAsset(2)) revert("USDC read unavailable");
        if (mode >= 3 && mode <= 5 && uint8(asset) == mode - 3) revert("selected asset read unavailable");
        if ((mode >= 6 && mode <= 8 && uint8(asset) == mode - 6) || mode == 9)
            assembly ("memory-safe") { for {} 1 {} {} }
        c = NARARewardLensV5(realLens).credit(rewards, id, generation, asset);
        if (mode == 2) c.generationOwner = address(0x1234);
    }
}

/// @dev Unrestricted sale callback actor. Never production custody or inventory.
contract ModularSaleActor is IERC721Receiver {
    uint256 public constant SCHEMA_VERSION = 2;
    address public nftTarget;
    bytes public nftPayload;
    address public ethTarget;
    bytes public ethPayload;
    bool public rejectNFT;
    bool public rejectETH;
    bool public nftCallbackSucceeded;
    bool public ethCallbackSucceeded;
    bytes public nftCallbackResult;
    bytes public ethCallbackResult;
    function configureNFT(address target, bytes calldata payload, bool reject) external {
        nftTarget = target; nftPayload = payload; rejectNFT = reject;
    }
    function configureETH(address target, bytes calldata payload, bool reject) external {
        ethTarget = target; ethPayload = payload; rejectETH = reject;
    }
    function execute(address target, bytes calldata payload) external payable returns (bytes memory result) {
        (bool ok, bytes memory data) = target.call{value: msg.value}(payload);
        if (!ok) assembly ("memory-safe") { revert(add(data, 32), mload(data)) }
        return data;
    }
    function batch(address[] calldata targets, bytes[] calldata payloads) external {
        require(targets.length == payloads.length && targets.length <= 5, "test batch shape");
        for (uint256 i; i < targets.length; ++i) {
            (bool ok, bytes memory data) = targets[i].call(payloads[i]);
            if (!ok) assembly ("memory-safe") { revert(add(data, 32), mload(data)) }
        }
    }
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (nftTarget != address(0)) (nftCallbackSucceeded, nftCallbackResult) = nftTarget.call(nftPayload);
        return rejectNFT ? bytes4(0) : IERC721Receiver.onERC721Received.selector;
    }
    receive() external payable {
        require(!rejectETH, "test seller rejected ETH");
        if (ethTarget != address(0)) (ethCallbackSucceeded, ethCallbackResult) = ethTarget.call(ethPayload);
    }
}

// Append to contracts/v5/modular-test/ModularPrincipalTestHelpers.sol.
// Existing IERC721Receiver import is sufficient. Test-only; no production role.
contract ModularNestedRechargeReceiver is IERC721Receiver {
    // Distinct from ERC721InvalidReceiver: an outer-rejection test cannot pass
    // merely because its inner recharge also failed.
    error NestedRechargeFailed(bytes reason);
    address public target;
    bytes public payload;
    bool public rejectOuter;
    bool public callbackSucceeded;
    bytes public callbackResult;
    uint256 public callbackCount;
    uint256 private _depth;

    function configure(address target_, bytes calldata payload_, bool rejectOuter_) external {
        target = target_; payload = payload_; rejectOuter = rejectOuter_;
        callbackSucceeded = false; delete callbackResult; callbackCount = 0;
    }

    function execute(address target_, bytes calldata payload_) external returns (bytes memory result) {
        (bool ok, bytes memory data) = target_.call(payload_);
        if (!ok) assembly ("memory-safe") { revert(add(data, 32), mload(data)) }
        return data;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        ++_depth; ++callbackCount;
        bool outer = _depth == 1;
        if (outer && target != address(0)) {
            (callbackSucceeded, callbackResult) = target.call(payload);
            if (!callbackSucceeded) revert NestedRechargeFailed(callbackResult);
        }
        --_depth;
        return outer && rejectOuter ? bytes4(0) : IERC721Receiver.onERC721Received.selector;
    }
}

/// @dev TEST ONLY (LIFECYCLE_DESIGN.md §8.4 P2.5, AR3-04): a position-holding contract that also answers the two
/// reads the Forge's proposeAdapter checks (`forge()` and `SCHEMA_VERSION()`), so a governor can install it as an
/// adapter through the real 7-day path: the "governance-made sink". It holds receipts, rolls, fuses, materializes,
/// recharges and takes refunds through one unrestricted call. Never an adapter that serves requests; never
/// deployment inventory.
contract ModularAdapterShapedHolder is IERC721Receiver {
    uint256 public constant SCHEMA_VERSION = 1;
    address public immutable forge;
    constructor(address forge_) { forge = forge_; }
    function execute(address target, bytes calldata payload) external payable returns (bytes memory result) {
        bool ok; (ok, result) = target.call{value: msg.value}(payload);
        if (!ok) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
    }
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
    receive() external payable {}
}
