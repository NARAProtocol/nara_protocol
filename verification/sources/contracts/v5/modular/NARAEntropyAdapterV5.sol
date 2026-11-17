// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {VRFV2PlusWrapperConsumerBase} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFV2PlusWrapperConsumerBase.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/// @notice Direct-funded VRF v2.5 adapter. The authenticated callback stores provenance only.
contract NARAEntropyAdapterV5 is VRFV2PlusWrapperConsumerBase {
    uint256 public constant SCHEMA_VERSION = 1;
    uint32 public constant MIN_CALLBACK_GAS = 80_000;
    // Pinned Base wrapper forwards g + floor(g / 63) + 1 + 13,400 gas.
    // Largest g under the measured coordinator ceiling of 2,500,000 (P2.3 erratum).
    uint32 public constant MAX_CALLBACK_GAS = 2_447_746;
    address public immutable forge;
    address public immutable expectedCoordinator;
    uint32 public immutable callbackGasLimit;
    uint16 public immutable requestConfirmations;
    struct ResultV5 { bool delivered; uint64 deliveredAt; uint64 deliveredAtBlock; uint256 word; }
    mapping(uint256 => ResultV5) private _results;
    mapping(uint256 => bytes32) public attemptOf;
    mapping(bytes32 => uint256) public requestOf;
    error InvalidConfiguration(); error Unauthorized(); error InvalidAttempt();
    error OracleFeeMismatch(); error CoordinatorMismatch();
    event RandomnessRequested(uint256 indexed requestId, bytes32 indexed attemptId, uint256 paid, uint32 callbackGasLimit, uint16 confirmations);
    event FulfilmentIgnored(uint256 indexed requestId, uint8 reason);
    event RandomnessStored(uint256 indexed requestId, bytes32 indexed attemptId, uint256 word, uint64 deliveredAt);

    constructor(address forge_, address wrapper_, address coordinator_, uint32 callbackGas_, uint16 confirmations_)
        VRFV2PlusWrapperConsumerBase(wrapper_)
    {
        if (forge_ == address(0) || !_contractPeer(wrapper_) || !_contractPeer(coordinator_)
            || callbackGas_ < MIN_CALLBACK_GAS || callbackGas_ > MAX_CALLBACK_GAS
            || confirmations_ == 0 || confirmations_ > 200) revert InvalidConfiguration();
        forge = forge_; expectedCoordinator = coordinator_; callbackGasLimit = callbackGas_; requestConfirmations = confirmations_;
        if (_coordinator() != coordinator_) revert CoordinatorMismatch();
    }
    function wrapper() external view returns (address) { return address(i_vrfV2PlusWrapper); }
    function quote() external view returns (uint256) { return i_vrfV2PlusWrapper.calculateRequestPriceNative(callbackGasLimit, 1); }
    function request(bytes32 attemptId) external payable returns (uint256 requestId) {
        if (msg.sender != forge) revert Unauthorized();
        if (attemptId == bytes32(0) || requestOf[attemptId] != 0) revert InvalidAttempt();
        if (msg.value != i_vrfV2PlusWrapper.calculateRequestPriceNative(callbackGasLimit, 1)) revert OracleFeeMismatch();
        if (_coordinator() != expectedCoordinator) revert CoordinatorMismatch();
        (requestId,) = requestRandomnessPayInNative(callbackGasLimit, requestConfirmations, 1,
            VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: true})));
        if (requestId == 0 || attemptOf[requestId] != bytes32(0)) revert InvalidAttempt();
        attemptOf[requestId] = attemptId; requestOf[attemptId] = requestId;
        emit RandomnessRequested(requestId, attemptId, msg.value, callbackGasLimit, requestConfirmations);
    }
    function result(uint256 requestId) external view returns (bool, uint64, uint64, uint256) {
        ResultV5 memory r = _results[requestId]; return (r.delivered, r.deliveredAt, r.deliveredAtBlock, r.word);
    }
    function fulfillRandomWords(uint256 requestId, uint256[] memory words) internal override {
        bytes32 attemptId = attemptOf[requestId];
        if (attemptId == bytes32(0)) { emit FulfilmentIgnored(requestId, 1); return; }
        if (_results[requestId].delivered) { emit FulfilmentIgnored(requestId, 2); return; }
        if (words.length != 1) { emit FulfilmentIgnored(requestId, 3); return; }
        if (_coordinator() != expectedCoordinator) { emit FulfilmentIgnored(requestId, 4); return; }
        _results[requestId] = ResultV5(true, uint64(block.timestamp), uint64(block.number), words[0]);
        emit RandomnessStored(requestId, attemptId, words[0], uint64(block.timestamp));
    }
    function _coordinator() private view returns (address result_) {
        address target = address(i_vrfV2PlusWrapper); bytes4 selector = bytes4(keccak256("s_vrfCoordinator()"));
        assembly ("memory-safe") {
            let ptr := mload(0x40) mstore(ptr, selector)
            let ok := staticcall(10000, target, ptr, 4, 0, 0)
            if and(ok, eq(returndatasize(), 32)) {
                returndatacopy(ptr, 0, 32)
                let value := mload(ptr)
                if iszero(shr(160, value)) { result_ := value }
            }
        }
    }
    function _contractPeer(address a) private view returns (bool) {
        if (a.code.length == 0) return false;
        bytes3 prefix; assembly ("memory-safe") { let ptr := mload(0x40) extcodecopy(a, ptr, 0, 3) prefix := mload(ptr) }
        return prefix != bytes3(0xef0100);
    }
}
