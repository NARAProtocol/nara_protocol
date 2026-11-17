// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NARACoreRewardsV5} from "../core/NARACoreRewardsV5.sol";
import {AccountingPolicy} from "../interfaces/NARAAccountingTypesV5.sol";
import {EmissionConfig, EmissionState} from "../engine/NARAEmissionTypesV5.sol";
import {CorePrincipalNFTStub} from "../principal-test/CorePrincipalTestHelpers.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Test realization only. Its NFT schema is a fixture, not the final ERC721.
contract CoreRewardsHarness is NARACoreRewardsV5 {
    constructor(address authority, address nara, address reserve, address model, uint256 genesisFunding,
        AccountingPolicy memory policy_, address usdc, EmissionConfig memory config, EmissionState memory initial)
        NARACoreRewardsV5(authority, nara, reserve, model, genesisFunding, policy_, usdc, config, initial) {}
    function _validatePrincipalNFT(address nft) internal view override {
        require(CorePrincipalNFTStub(nft).TEST_SCHEMA_VERSION() == 1, "invalid test NFT schema");
    }
}

/// @dev Token failures are adversarial fixtures only; no deployed USDC is modified.
contract CoreRewardsUSDC is ERC20 {
    uint8 public mode;
    constructor() ERC20("Test USDC", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address owner, uint256 amount) external { _mint(owner, amount); }
    function seize(address owner, uint256 amount) external { _burn(owner, amount); }
    function setMode(uint8 value) external { mode = value; }
    function transfer(address to, uint256 amount) public override returns (bool) {
        if (mode == 1) revert("test transfer failure");
        if (mode == 2) return false;
        return super.transfer(to, mode == 3 && amount > 0 ? amount - 1 : amount);
    }
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (mode == 1) revert("test pull failure");
        if (mode == 2) return false;
        return super.transferFrom(from, to, mode == 3 && amount > 0 ? amount - 1 : amount);
    }
}

contract CoreRewardsRecipient {
    address public target;
    bytes public payload;
    bool public reject;
    bool public callbackSucceeded;
    function configure(address target_, bytes calldata payload_, bool reject_) external {
        target = target_; payload = payload_; reject = reject_;
    }
    receive() external payable {
        require(!reject, "test receiver rejected");
        if (target != address(0)) (callbackSucceeded,) = target.call(payload);
    }
}
