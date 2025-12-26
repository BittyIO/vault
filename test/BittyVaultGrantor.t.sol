// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {BittyVault} from "../src/BittyVault.sol";
import {
    AddressZero,
    NotWhiteListed,
    AlreadyInitialized,
    StartDistributionTimestampAlreadySet,
    TimestampIsZero,
    TimestampNotFound,
    AutoIrrevocableAfterNoPingNotSet
} from "../src/interfaces/Errors.sol";
import {WhiteList} from "../src/WhiteList.sol";
import {WETH} from "lib/solmate/src/tokens/WETH.sol";
import {IAssetManager} from "../src/interfaces/IAssetManager.sol";
import {IWhiteList} from "../src/interfaces/IWhiteList.sol";
import {MockERC20} from "lib/solmate/src/test/utils/mocks/MockERC20.sol";
import {InsufficientBalance} from "../src/interfaces/Errors.sol";

// Mock ERC20 token that can fail transfers for testing
contract MockERC20FailingTransfer is MockERC20 {
    bool public shouldFailTransfer;

    constructor(string memory name, string memory symbol, uint8 decimals) MockERC20(name, symbol, decimals) {}

    function setShouldFailTransfer(bool _shouldFail) external {
        shouldFailTransfer = _shouldFail;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (shouldFailTransfer) {
            return false;
        }
        return super.transfer(to, amount);
    }
}

contract BittyVaultGrantorTest is Test {
    BittyVault public bittyVault;
    WETH public mockWETH;
    address public whiteListAddress;

    receive() external payable {}

    function setUp() public {
        mockWETH = new WETH();
        bittyVault = new BittyVault();
        WhiteList whiteList = new WhiteList();
        whiteListAddress = address(whiteList);
        bittyVault.initialize(
            address(this),
            address(whiteList),
            address(mockWETH),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
    }

    function test_InitErrorWithAlreadyInitialized() public {
        BittyVault newVault = new BittyVault();
        newVault.initialize(
            address(this),
            whiteListAddress,
            address(mockWETH),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
        vm.expectRevert();
        newVault.initialize(
            address(this),
            whiteListAddress,
            address(mockWETH),
            new address[](0),
            new address[](0),
            new address[](0),
            new address[](0)
        );
    }

    function test_ChangeGrantorAddress_SameAddressDoesNothing() public {
        address currentGrantor = address(this);
        uint256 balanceBefore = address(bittyVault).balance;
        bittyVault.changeGrantorAddress(currentGrantor);
        assertEq(bittyVault.grantor(), currentGrantor);
        assertEq(address(bittyVault).balance, balanceBefore);
    }

    function test_ChangeGrantorAddress_Success() public {
        address newGrantor = makeAddr("newGrantor");
        bittyVault.changeGrantorAddress(newGrantor);
        assertEq(bittyVault.grantor(), newGrantor);
    }
}
