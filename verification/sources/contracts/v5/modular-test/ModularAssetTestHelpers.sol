// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NARATokenV5} from "../NARATokenV5.sol";
import {EmissionConfig, EmissionInputs, EmissionQuote, EmissionState} from "../engine/NARAEmissionTypesV5.sol";

/// @dev Test-only ACC-E02 double (P2.8). Every getter the Engine constructor reads and the
/// discarded E:122 probe match the reviewed model, but every quote targets the whole genesis
/// funding, so one 1-NARA staker would be quoted the entire Reserve at the first close with
/// reward weight. The Engine must reject it at construction by runtime codehash.
contract ModularDrainModelDouble {
    uint256 public constant MODEL_VERSION = 1;
    uint256 public constant FIXED_SUPPLY = 1_000_000 ether;
    uint256 private constant DRAIN = 700_000 ether;
    function calculateNext(EmissionConfig calldata, EmissionState calldata previous, EmissionInputs calldata)
        external pure returns (EmissionQuote memory quote)
    {
        quote.nextState = previous; quote.emission = DRAIN; quote.admittedNara = DRAIN; quote.targetNara = DRAIN;
    }
}

/// @dev Test-only ACC-E02 double (P2.8). An Engine under construction has no code yet, so the
/// E:122 probe passes; every later call from the deployed Engine reverts, so no epoch could
/// ever close. The Engine must reject it at construction by runtime codehash.
contract ModularHaltingModelDouble {
    uint256 public constant MODEL_VERSION = 1;
    uint256 public constant FIXED_SUPPLY = 1_000_000 ether;
    error ModelHalted();
    function calculateNext(EmissionConfig calldata, EmissionState calldata previous, EmissionInputs calldata)
        external view returns (EmissionQuote memory quote)
    {
        if (msg.sender.code.length != 0) revert ModelHalted();
        quote.nextState = previous;
    }
}

/// @dev Test-only fault injection after a real transfer into Rewards. A read
/// failure at close must roll back the earlier Reserve -> Engine -> Rewards flow.
contract ModularReceiptFaultToken is NARATokenV5 {
    // Additional pull faults are test-only. Default mode/target preserve all
    // existing receipt-forwarding tests and the real NARA behavior.
    uint8 public pullMode;
    address public pullCallbackTarget;
    bytes public pullCallbackPayload;
    bool public pullCallbackSucceeded;
    bytes public pullCallbackResult;
    address public faultRecipient;
    bool private _transferredToFaultRecipient;
    constructor(address owner, address sink, string memory name_, string memory symbol_)
        NARATokenV5(owner, sink, name_, symbol_) {}
    function configurePullFault(uint8 mode, address target, bytes calldata payload) external {
        pullMode = mode; pullCallbackTarget = target; pullCallbackPayload = payload;
        pullCallbackSucceeded = false; delete pullCallbackResult;
    }
    function transferFrom(address from, address to, uint256 amount) public override(ERC20, IERC20) returns (bool) {
        if (pullMode == 1) revert("test principal pull rejected");
        if (pullMode == 2) return false;
        bool ok = super.transferFrom(from, to, pullMode == 3 && amount != 0 ? amount - 1 : amount);
        if (pullCallbackTarget != address(0))
            (pullCallbackSucceeded, pullCallbackResult) = pullCallbackTarget.call(pullCallbackPayload);
        return ok;
    }
    function configureReceiptFault(address recipient) external { faultRecipient = recipient; _transferredToFaultRecipient = false; }
    function transfer(address to, uint256 amount) public override(ERC20, IERC20) returns (bool) {
        bool ok = super.transfer(to, amount);
        if (to == faultRecipient && amount != 0) _transferredToFaultRecipient = true;
        return ok;
    }
    function balanceOf(address owner) public view override(ERC20, IERC20) returns (uint256) {
        require(!(_transferredToFaultRecipient && msg.sender == faultRecipient && owner == faultRecipient), "test receipt read failed");
        return super.balanceOf(owner);
    }
}

contract ModularUSDC is ERC20 {
    uint8 public mode;
    constructor() ERC20("Test USDC", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address owner, uint256 amount) external { _mint(owner, amount); }
    function seize(address owner, uint256 amount) external { _burn(owner, amount); }
    function setMode(uint8 value) external { mode = value; }
    function transfer(address to, uint256 amount) public override returns (bool) {
        if (mode == 1) revert("test transfer failure"); if (mode == 2) return false;
        return super.transfer(to, mode == 3 && amount > 0 ? amount - 1 : amount);
    }
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (mode == 1) revert("test pull failure"); if (mode == 2) return false;
        return super.transferFrom(from, to, mode == 3 && amount > 0 ? amount - 1 : amount);
    }
}

contract ModularETHRecipient {
    bool public reject;
    address public target;
    bytes public payload;
    bool public callbackSucceeded;
    function configure(bool reject_, address target_, bytes calldata payload_) external {
        reject = reject_; target = target_; payload = payload_;
    }
    receive() external payable {
        require(!reject, "test ETH rejected");
        if (target != address(0)) (callbackSucceeded,) = target.call(payload);
    }
}
