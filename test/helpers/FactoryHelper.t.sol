// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {FactoryHelper} from "../../src/helpers/FactoryHelper.sol";
import {WhiteList} from "../../src/WhiteList.sol";
import {IWhiteList} from "../../src/interfaces/IWhiteList.sol";
import {NotWhiteListed} from "../../src/interfaces/Errors.sol";

contract FactoryHelperWrapper {
    function checkWhiteList(
        IWhiteList whiteList,
        address[] memory assetAddresses,
        address[] memory stableCoinAddresses,
        address[] memory lendingProviders,
        address[] memory stakingProviders,
        address[] memory swapProviders
    ) external view {
        FactoryHelper.checkWhiteList(
            whiteList, assetAddresses, stableCoinAddresses, lendingProviders, stakingProviders, swapProviders
        );
    }
}

contract FactoryHelperTest is Test {
    FactoryHelperWrapper public wrapper;
    WhiteList public whiteList;

    function setUp() public {
        wrapper = new FactoryHelperWrapper();
        whiteList = new WhiteList();
    }

    function test_CheckWhiteList_AllValid() public {
        address asset1 = makeAddr("asset1");
        address asset2 = makeAddr("asset2");
        address stableCoin1 = makeAddr("stableCoin1");
        address stableCoin2 = makeAddr("stableCoin2");
        address lendingProvider = makeAddr("lendingProvider");
        address stakingProvider = makeAddr("stakingProvider");
        address swapProvider = makeAddr("swapProvider");

        address[] memory assets = new address[](2);
        assets[0] = asset1;
        assets[1] = asset2;
        vm.prank(tx.origin);
        whiteList.addAssets(assets);

        address[] memory stableCoins = new address[](2);
        stableCoins[0] = stableCoin1;
        stableCoins[1] = stableCoin2;
        vm.prank(tx.origin);
        whiteList.addStableCoins(stableCoins);

        address[] memory lendingProviders = new address[](1);
        lendingProviders[0] = lendingProvider;
        vm.prank(tx.origin);
        whiteList.addLendingProviders(lendingProviders);

        address[] memory stakingProviders = new address[](1);
        stakingProviders[0] = stakingProvider;
        vm.prank(tx.origin);
        whiteList.addStakingProviders(stakingProviders);

        address[] memory swapProviders = new address[](1);
        swapProviders[0] = swapProvider;
        vm.prank(tx.origin);
        whiteList.addSwapProviders(swapProviders);

        address[] memory testAssets = new address[](2);
        testAssets[0] = asset1;
        testAssets[1] = asset2;

        address[] memory testStableCoins = new address[](2);
        testStableCoins[0] = stableCoin1;
        testStableCoins[1] = stableCoin2;

        address[] memory testLendingProviders = new address[](1);
        testLendingProviders[0] = lendingProvider;

        address[] memory testStakingProviders = new address[](1);
        testStakingProviders[0] = stakingProvider;

        address[] memory testSwapProviders = new address[](1);
        testSwapProviders[0] = swapProvider;

        wrapper.checkWhiteList(
            IWhiteList(address(whiteList)),
            testAssets,
            testStableCoins,
            testLendingProviders,
            testStakingProviders,
            testSwapProviders
        );
    }

    function test_CheckWhiteList_InvalidAsset() public {
        address asset1 = makeAddr("asset1");
        address invalidAsset = makeAddr("invalidAsset");

        address[] memory assets = new address[](1);
        assets[0] = asset1;
        vm.prank(tx.origin);
        whiteList.addAssets(assets);

        address[] memory testAssets = new address[](1);
        testAssets[0] = invalidAsset;
        address[] memory empty = new address[](0);

        vm.expectRevert(NotWhiteListed.selector);
        wrapper.checkWhiteList(IWhiteList(address(whiteList)), testAssets, empty, empty, empty, empty);
    }

    function test_CheckWhiteList_InvalidStableCoin() public {
        address stableCoin1 = makeAddr("stableCoin1");
        address invalidStableCoin = makeAddr("invalidStableCoin");

        address[] memory stableCoins = new address[](1);
        stableCoins[0] = stableCoin1;
        vm.prank(tx.origin);
        whiteList.addStableCoins(stableCoins);

        address[] memory testStableCoins = new address[](1);
        testStableCoins[0] = invalidStableCoin;
        address[] memory empty = new address[](0);

        vm.expectRevert(NotWhiteListed.selector);
        wrapper.checkWhiteList(IWhiteList(address(whiteList)), empty, testStableCoins, empty, empty, empty);
    }

    function test_CheckWhiteList_InvalidLendingProvider() public {
        address lendingProvider = makeAddr("lendingProvider");
        address invalidLendingProvider = makeAddr("invalidLendingProvider");

        address[] memory LendingProviders = new address[](1);
        LendingProviders[0] = lendingProvider;
        vm.prank(tx.origin);
        whiteList.addLendingProviders(LendingProviders);

        address[] memory testLendingProviders = new address[](1);
        testLendingProviders[0] = invalidLendingProvider;
        address[] memory empty = new address[](0);

        vm.expectRevert(NotWhiteListed.selector);
        wrapper.checkWhiteList(IWhiteList(address(whiteList)), empty, empty, testLendingProviders, empty, empty);
    }

    function test_CheckWhiteList_InvalidSwapProvider() public {
        address swapProvider = makeAddr("swapProvider");
        address invalidSwapProvider = makeAddr("invalidSwapProvider");

        address[] memory swapProviders = new address[](1);
        swapProviders[0] = swapProvider;
        vm.prank(tx.origin);
        whiteList.addSwapProviders(swapProviders);

        address[] memory testSwapProviders = new address[](1);
        testSwapProviders[0] = invalidSwapProvider;
        address[] memory empty = new address[](0);

        vm.expectRevert(NotWhiteListed.selector);
        wrapper.checkWhiteList(IWhiteList(address(whiteList)), empty, empty, empty, empty, testSwapProviders);
    }

    function test_CheckWhiteList_EmptyArrays() public view {
        address[] memory empty = new address[](0);

        wrapper.checkWhiteList(IWhiteList(address(whiteList)), empty, empty, empty, empty, empty);
    }

    function test_CheckWhiteList_MultipleInvalid() public {
        address asset1 = makeAddr("asset1");
        address invalidAsset = makeAddr("invalidAsset");

        address[] memory assets = new address[](1);
        assets[0] = asset1;
        vm.prank(tx.origin);
        whiteList.addAssets(assets);

        address[] memory testAssets = new address[](2);
        testAssets[0] = asset1;
        testAssets[1] = invalidAsset;

        address[] memory empty = new address[](0);

        vm.expectRevert(NotWhiteListed.selector);
        wrapper.checkWhiteList(IWhiteList(address(whiteList)), testAssets, empty, empty, empty, empty);
    }
}

