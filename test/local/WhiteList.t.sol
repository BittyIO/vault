// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import "forge-std/console.sol";
import {Test} from "lib/forge-std/src/Test.sol";
import {WhiteList} from "../../src/WhiteList.sol";
import {MockAMMProvider} from "../mock/MockAMMProvider.sol";
import {MockLendingProvider} from "../mock/MockLendingProvider.sol";
import {MockStakingProvider} from "../mock/MockStakingProvider.sol";
import {MockERC20} from "lib/solmate/src/test/utils/mocks/MockERC20.sol";
import {SwapProviderShouldNotBeAllRemoved} from "../../src/interfaces/IWhiteList.sol";

contract WhiteListTest is Test {
    WhiteList public whiteList;
    address public protocolOwner;
    MockAMMProvider public mockSwapProvider;
    MockLendingProvider public mockLendingProvider;
    MockStakingProvider public mockStakingProvider;
    MockERC20 public mockWETH;
    MockERC20 public mockWBTC;
    MockERC20 public mockUSDT;
    MockERC20 public mockUSDC;
    address[] public assets;
    address[] public stableCoins;
    address[] public lendingProviders;
    address[] public stakingProviders;
    address[] public swapProviders;

    function setUp() public {
        protocolOwner = makeAddr("protocolOwner");
        mockSwapProvider = new MockAMMProvider();
        mockLendingProvider = new MockLendingProvider();
        mockStakingProvider = new MockStakingProvider();
        mockWETH = new MockERC20("WETH", "WETH", 18);
        mockWBTC = new MockERC20("WBTC", "WBTC", 8);
        mockUSDT = new MockERC20("USDT", "USDT", 6);
        mockUSDC = new MockERC20("USDC", "USDC", 6);
        whiteList = new WhiteList();
        vm.prank(tx.origin);
        whiteList.transferOwnership(protocolOwner);
        assets = new address[](2);
        assets[0] = address(mockWETH);
        assets[1] = address(mockWBTC);
        stableCoins = new address[](2);
        stableCoins[0] = address(mockUSDT);
        stableCoins[1] = address(mockUSDC);
        lendingProviders = new address[](1);
        lendingProviders[0] = address(mockLendingProvider);
        stakingProviders = new address[](1);
        stakingProviders[0] = address(mockStakingProvider);
        swapProviders = new address[](1);
        swapProviders[0] = address(mockSwapProvider);
    }

    function test_AddWhiteListedAssets() public {
        vm.prank(protocolOwner);
        whiteList.addAssets(assets);
        assertTrue(whiteList.isAssetWhiteListed(address(mockWETH)));
        assertTrue(whiteList.isAssetWhiteListed(address(mockWBTC)));
    }

    function test_RemoveAssets() public {
        vm.prank(protocolOwner);
        whiteList.removeAssets(assets);
        assertFalse(whiteList.isAssetWhiteListed(address(mockWETH)));
        assertFalse(whiteList.isAssetWhiteListed(address(mockWBTC)));
    }

    function test_AddStableCoins() public {
        vm.prank(protocolOwner);
        whiteList.addStableCoins(stableCoins);
        assertTrue(whiteList.isStableCoinWhiteListed(address(mockUSDT)));
        assertTrue(whiteList.isStableCoinWhiteListed(address(mockUSDC)));
    }

    function test_RemoveStableCoins() public {
        vm.prank(protocolOwner);
        whiteList.removeStableCoins(stableCoins);
        assertFalse(whiteList.isStableCoinWhiteListed(address(mockUSDT)));
        assertFalse(whiteList.isStableCoinWhiteListed(address(mockUSDC)));
    }

    function test_AddLendingProviders() public {
        vm.prank(protocolOwner);
        whiteList.addLendingProviders(lendingProviders);
        assertTrue(whiteList.isLendingProviderWhiteListed(address(mockLendingProvider)));
    }

    function test_DeprecateLendingProviders() public {
        vm.prank(protocolOwner);
        whiteList.deprecateLendingProviders(lendingProviders);
        assertFalse(whiteList.isLendingProviderWhiteListed(address(mockLendingProvider)));
        assertTrue(whiteList.isLendingProviderDeprecated(address(mockLendingProvider)));
    }

    function test_AddStakingProviders() public {
        vm.prank(protocolOwner);
        whiteList.addStakingProviders(stakingProviders);
        assertTrue(whiteList.isStakingProviderWhiteListed(address(mockStakingProvider)));
        assertFalse(whiteList.isStakingProviderDeprecated(address(mockStakingProvider)));
    }

    function test_DeprecateStakingProviders() public {
        vm.prank(protocolOwner);
        whiteList.deprecateStakingProviders(stakingProviders);
        assertFalse(whiteList.isStakingProviderWhiteListed(address(mockStakingProvider)));
        assertTrue(whiteList.isStakingProviderDeprecated(address(mockStakingProvider)));
    }

    function test_AddSwapProviders() public {
        vm.prank(protocolOwner);
        whiteList.addSwapProviders(swapProviders);
        assertTrue(whiteList.isSwapProviderWhiteListed(address(mockSwapProvider)));
    }

    function test_RemoveSwapProvidersFailedWhenAllRemoved() public {
        address[] memory swapProviderAddresses = new address[](1);
        swapProviderAddresses[0] = address(mockSwapProvider);
        vm.prank(protocolOwner);
        vm.expectRevert(SwapProviderShouldNotBeAllRemoved.selector);
        whiteList.removeSwapProviders(swapProviderAddresses);
    }

    function test_RemoveSwapProvidersShouldBeFine() public {
        address[] memory swapProviderAddresses = new address[](1);
        swapProviderAddresses[0] = address(mockSwapProvider);
        address[] memory invalidSwapProviders = new address[](1);
        address invalidSwapProvider = makeAddr("InvalidSwapProvider");
        invalidSwapProviders[0] = invalidSwapProvider;
        vm.prank(protocolOwner);
        whiteList.addSwapProviders(invalidSwapProviders);
        vm.prank(protocolOwner);
        whiteList.addSwapProviders(swapProviderAddresses);
        vm.prank(protocolOwner);
        whiteList.removeSwapProviders(invalidSwapProviders);
        assertTrue(whiteList.isSwapProviderWhiteListed(address(mockSwapProvider)));
        assertFalse(whiteList.isSwapProviderWhiteListed(invalidSwapProvider));
    }

    function test_AddWhiteListedNeedToRemoveDeprecated() public {
        vm.prank(protocolOwner);
        whiteList.addLendingProviders(lendingProviders);
        assertTrue(whiteList.isLendingProviderWhiteListed(address(mockLendingProvider)));
        vm.prank(protocolOwner);
        whiteList.deprecateLendingProviders(lendingProviders);
        assertFalse(whiteList.isLendingProviderWhiteListed(address(mockLendingProvider)));
        assertTrue(whiteList.isLendingProviderDeprecated(address(mockLendingProvider)));
        vm.prank(protocolOwner);
        whiteList.addLendingProviders(lendingProviders);
        assertTrue(whiteList.isLendingProviderWhiteListed(address(mockLendingProvider)));
        assertFalse(whiteList.isLendingProviderDeprecated(address(mockLendingProvider)));
    }

    function test_GetWhiteListInitCode() public pure {
        bytes memory bytecode = type(WhiteList).creationCode;
        console.logBytes32(keccak256(bytecode));
    }
}
