// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

// TEST ONLY. No contract in this file belongs in a deployment manifest.
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {NARATokenV5} from "../NARATokenV5.sol";
import {NARACorePrincipalV5, PrincipalAccounting} from "../core/NARACorePrincipalV5.sol";
import {FundingClose} from "../core/NARACoreFundingV5.sol";
import {AccountingPolicy, ReserveDelivery} from "../interfaces/NARAAccountingTypesV5.sol";

contract CorePrincipalHarness is NARACorePrincipalV5 {
    uint256 public fixtureTarget;
    uint256 public fixtureHeadroom;
    uint256 public accountedRewards;
    mapping(uint64 => PrincipalAccounting) private _principalSettlements;
    mapping(uint64 => FundingClose) private _fundingCloses;
    mapping(uint64 => bool) public failOpen;
    mapping(uint64 => bool) public failSettlement;
    error ForcedOpenFailure();
    error ForcedSettlementFailure();

    constructor(address authority, address nara, address reserve, address model, uint256 genesisFunding,
        AccountingPolicy memory initialPolicy)
        NARACorePrincipalV5(authority, nara, reserve, model, genesisFunding, initialPolicy) {}

    function setDemand(uint256 target, uint256 headroom) external { fixtureTarget = target; fixtureHeadroom = headroom; }
    function setFailOpen(uint64 epoch, bool fail) external { failOpen[epoch] = fail; }
    function setFailSettlement(uint64 epoch, bool fail) external { failSettlement[epoch] = fail; }
    function principalSettlementAt(uint64 epoch) external view coherentFundingRead returns (PrincipalAccounting memory) {
        return _principalSettlements[epoch];
    }
    function fundingCloseAt(uint64 epoch) external view coherentFundingRead returns (FundingClose memory) {
        return _fundingCloses[epoch];
    }
    function _fundingDemand(uint64) internal view override returns (uint256, uint256) {
        return (fixtureTarget, fixtureHeadroom);
    }
    function _settleFundingEpoch(uint64 epoch, uint256 eligibleBefore, uint256 requested,
        uint256 delivered, ReserveDelivery status) internal override {
        if (failSettlement[epoch]) revert ForcedSettlementFailure();
        _principalSettlements[epoch] = _principalView();
        _fundingCloses[epoch] = FundingClose(epoch, eligibleBefore, requested, delivered, status);
        accountedRewards += delivered; // Receipt fixture only, no real reward allocation/index.
    }
    function _afterPrincipalOpen(uint64 epoch) internal view override {
        if (failOpen[epoch]) revert ForcedOpenFailure();
    }
    function _validatePrincipalNFT(address nft) internal view override {
        require(CorePrincipalNFTStub(nft).TEST_SCHEMA_VERSION() == 1, "invalid test NFT schema");
    }
}

/// @dev Minimal receiver-capable identity fixture, not a complete ERC721 contract.
contract CorePrincipalNFTStub {
    uint256 public constant TEST_SCHEMA_VERSION = 1;
    address private immutable _core;
    mapping(uint256 => address) public owners;
    uint256 public mintCount;
    bool private _failMint;
    bool private _failIdentity;
    error ForcedMintFailure();
    error ForcedIdentityFailure();
    constructor(address core_) { _core = core_; }
    function core() external view returns (address) {
        if (_failIdentity) revert ForcedIdentityFailure();
        return _core;
    }
    function setMintFailure(bool value) external { _failMint = value; }
    function setIdentityFailure(bool value) external { _failIdentity = value; }
    function setOwnerForTest(uint256 id, address owner) external { owners[id] = owner; }
    function mint(address owner, uint256 id) external {
        require(msg.sender == _core && owners[id] == address(0), "invalid test mint");
        if (_failMint) revert ForcedMintFailure();
        owners[id] = owner; ++mintCount;
        if (owner.code.length != 0) {
            require(IERC721Receiver(owner).onERC721Received(msg.sender, address(0), id, "")
                == IERC721Receiver.onERC721Received.selector, "receiver rejected");
        }
    }
}

contract CorePrincipalActor is IERC721Receiver, IERC3156FlashBorrower {
    address public callbackTarget;
    bytes public callbackData;
    bool public rejectMint;
    bool public bubbleFailure;
    bool public lastCallbackSuccess;
    bytes public lastCallbackReturn;
    address private _flashLender;

    function configureCallback(address target, bytes calldata data, bool reject, bool bubble) external {
        callbackTarget = target; callbackData = data; rejectMint = reject; bubbleFailure = bubble;
    }
    function execute(address target, bytes calldata data) external returns (bytes memory result) {
        bool ok; (ok, result) = target.call(data);
        if (!ok) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
    }
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        require(!rejectMint, "receiver rejected");
        if (callbackTarget != address(0)) {
            (lastCallbackSuccess, lastCallbackReturn) = callbackTarget.call(callbackData);
            require(!bubbleFailure || lastCallbackSuccess, "callback failed");
        }
        return IERC721Receiver.onERC721Received.selector;
    }
    function borrow(address lender, uint256 amount, address target, bytes calldata data) external {
        _flashLender = lender;
        IERC3156FlashLender(lender).flashLoan(this, lender, amount, abi.encode(target, data));
        _flashLender = address(0);
    }
    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data)
        external returns (bytes32) {
        require(msg.sender == _flashLender && token == _flashLender && initiator == address(this), "invalid flash callback");
        (address target, bytes memory payload) = abi.decode(data, (address, bytes));
        (lastCallbackSuccess, lastCallbackReturn) = target.call(payload);
        IERC20(token).approve(msg.sender, amount + fee);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}

/// @dev Only for proving exact receipt/payment rejection. Never a token candidate.
contract CorePrincipalFaultToken is NARATokenV5 {
    uint8 public transferMode;
    uint8 public pullMode;
    constructor(address treasury, address sink) NARATokenV5(treasury, sink, "Fault NARA", "FNARA") {}
    function setModes(uint8 transferMode_, uint8 pullMode_) external { transferMode = transferMode_; pullMode = pullMode_; }
    function transfer(address to, uint256 amount) public override(ERC20, IERC20) returns (bool) {
        if (transferMode == 1) return true;
        if (transferMode == 2) return false;
        if (transferMode == 3) return super.transfer(to, amount - 1);
        return super.transfer(to, amount);
    }
    function transferFrom(address from, address to, uint256 amount) public override(ERC20, IERC20) returns (bool) {
        if (pullMode == 1) return true;
        if (pullMode == 2) return false;
        if (pullMode == 3) return super.transferFrom(from, to, amount - 1);
        return super.transferFrom(from, to, amount);
    }
}
