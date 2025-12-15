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
        address[] memory yieldProviders,
        address[] memory swapProviders
    ) external view {
        FactoryHelper.checkWhiteList(whiteList, assetAddresses, stableCoinAddresses, yieldProviders, swapProviders);
    }

    function computeAddress(bytes32 salt, bytes32 bytecodeHash, address deployer) external pure returns (address) {
        return FactoryHelper.computeAddress(salt, bytecodeHash, deployer);
    }
}

contract FactoryHelperTest is Test {
    FactoryHelperWrapper public wrapper;
    WhiteList public whiteList;
    address public poolManagerAddress;

    function setUp() public {
        wrapper = new FactoryHelperWrapper();
        poolManagerAddress = makeAddr("poolManagerAddress");
        whiteList = new WhiteList(poolManagerAddress);
    }

    function test_CheckWhiteList_AllValid() public {
        address asset1 = makeAddr("asset1");
        address asset2 = makeAddr("asset2");
        address stableCoin1 = makeAddr("stableCoin1");
        address stableCoin2 = makeAddr("stableCoin2");
        address yieldProvider1 = makeAddr("yieldProvider1");
        address swapProvider1 = makeAddr("swapProvider1");

        address[] memory assets = new address[](2);
        assets[0] = asset1;
        assets[1] = asset2;
        whiteList.addAssets(assets);

        address[] memory stableCoins = new address[](2);
        stableCoins[0] = stableCoin1;
        stableCoins[1] = stableCoin2;
        whiteList.addStableCoins(stableCoins);

        address[] memory yieldProviders = new address[](1);
        yieldProviders[0] = yieldProvider1;
        whiteList.addYieldProviders(yieldProviders);

        address[] memory swapProviders = new address[](1);
        swapProviders[0] = swapProvider1;
        whiteList.addSwapProviders(swapProviders);

        address[] memory testAssets = new address[](2);
        testAssets[0] = asset1;
        testAssets[1] = asset2;

        address[] memory testStableCoins = new address[](2);
        testStableCoins[0] = stableCoin1;
        testStableCoins[1] = stableCoin2;

        address[] memory testYieldProviders = new address[](1);
        testYieldProviders[0] = yieldProvider1;

        address[] memory testSwapProviders = new address[](1);
        testSwapProviders[0] = swapProvider1;

        wrapper.checkWhiteList(
            IWhiteList(address(whiteList)), testAssets, testStableCoins, testYieldProviders, testSwapProviders
        );
    }

    function test_CheckWhiteList_InvalidAsset() public {
        address asset1 = makeAddr("asset1");
        address invalidAsset = makeAddr("invalidAsset");

        address[] memory assets = new address[](1);
        assets[0] = asset1;
        whiteList.addAssets(assets);

        address[] memory testAssets = new address[](1);
        testAssets[0] = invalidAsset;
        address[] memory empty = new address[](0);

        vm.expectRevert(NotWhiteListed.selector);
        wrapper.checkWhiteList(IWhiteList(address(whiteList)), testAssets, empty, empty, empty);
    }

    function test_CheckWhiteList_InvalidStableCoin() public {
        address stableCoin1 = makeAddr("stableCoin1");
        address invalidStableCoin = makeAddr("invalidStableCoin");

        address[] memory stableCoins = new address[](1);
        stableCoins[0] = stableCoin1;
        whiteList.addStableCoins(stableCoins);

        address[] memory testStableCoins = new address[](1);
        testStableCoins[0] = invalidStableCoin;
        address[] memory empty = new address[](0);

        vm.expectRevert(NotWhiteListed.selector);
        wrapper.checkWhiteList(IWhiteList(address(whiteList)), empty, testStableCoins, empty, empty);
    }

    function test_CheckWhiteList_InvalidYieldProvider() public {
        address yieldProvider1 = makeAddr("yieldProvider1");
        address invalidYieldProvider = makeAddr("invalidYieldProvider");

        address[] memory yieldProviders = new address[](1);
        yieldProviders[0] = yieldProvider1;
        whiteList.addYieldProviders(yieldProviders);

        address[] memory testYieldProviders = new address[](1);
        testYieldProviders[0] = invalidYieldProvider;
        address[] memory empty = new address[](0);

        vm.expectRevert(NotWhiteListed.selector);
        wrapper.checkWhiteList(IWhiteList(address(whiteList)), empty, empty, testYieldProviders, empty);
    }

    function test_CheckWhiteList_InvalidSwapProvider() public {
        address swapProvider1 = makeAddr("swapProvider1");
        address invalidSwapProvider = makeAddr("invalidSwapProvider");

        address[] memory swapProviders = new address[](1);
        swapProviders[0] = swapProvider1;
        whiteList.addSwapProviders(swapProviders);

        address[] memory testSwapProviders = new address[](1);
        testSwapProviders[0] = invalidSwapProvider;
        address[] memory empty = new address[](0);

        vm.expectRevert(NotWhiteListed.selector);
        wrapper.checkWhiteList(IWhiteList(address(whiteList)), empty, empty, empty, testSwapProviders);
    }

    function test_CheckWhiteList_EmptyArrays() public view {
        address[] memory empty = new address[](0);

        wrapper.checkWhiteList(IWhiteList(address(whiteList)), empty, empty, empty, empty);
    }

    function test_CheckWhiteList_MultipleInvalid() public {
        address asset1 = makeAddr("asset1");
        address invalidAsset = makeAddr("invalidAsset");

        address[] memory assets = new address[](1);
        assets[0] = asset1;
        whiteList.addAssets(assets);

        address[] memory testAssets = new address[](2);
        testAssets[0] = asset1;
        testAssets[1] = invalidAsset;

        address[] memory empty = new address[](0);

        vm.expectRevert(NotWhiteListed.selector);
        wrapper.checkWhiteList(IWhiteList(address(whiteList)), testAssets, empty, empty, empty);
    }

    function test_ComputeAddress_Deterministic() public {
        bytes32 salt = keccak256("testSalt");
        bytes32 bytecodeHash = keccak256("testBytecode");
        address deployer = makeAddr("deployer");

        address addr1 = wrapper.computeAddress(salt, bytecodeHash, deployer);
        address addr2 = wrapper.computeAddress(salt, bytecodeHash, deployer);

        assertEq(addr1, addr2, "Same inputs should produce same address");
        assertTrue(addr1 != address(0), "Address should not be zero");
    }

    function test_ComputeAddress_DifferentSalt() public {
        bytes32 salt1 = keccak256("salt1");
        bytes32 salt2 = keccak256("salt2");
        bytes32 bytecodeHash = keccak256("testBytecode");
        address deployer = makeAddr("deployer");

        address addr1 = wrapper.computeAddress(salt1, bytecodeHash, deployer);
        address addr2 = wrapper.computeAddress(salt2, bytecodeHash, deployer);

        assertTrue(addr1 != addr2, "Different salts should produce different addresses");
    }

    function test_ComputeAddress_DifferentDeployer() public {
        bytes32 salt = keccak256("testSalt");
        bytes32 bytecodeHash = keccak256("testBytecode");
        address deployer1 = makeAddr("deployer1");
        address deployer2 = makeAddr("deployer2");

        address addr1 = wrapper.computeAddress(salt, bytecodeHash, deployer1);
        address addr2 = wrapper.computeAddress(salt, bytecodeHash, deployer2);

        assertTrue(addr1 != addr2, "Different deployers should produce different addresses");
    }

    function test_ComputeAddress_DifferentBytecodeHash() public {
        bytes32 salt = keccak256("testSalt");
        bytes32 bytecodeHash1 = keccak256("bytecode1");
        bytes32 bytecodeHash2 = keccak256("bytecode2");
        address deployer = makeAddr("deployer");

        address addr1 = wrapper.computeAddress(salt, bytecodeHash1, deployer);
        address addr2 = wrapper.computeAddress(salt, bytecodeHash2, deployer);

        assertTrue(addr1 != addr2, "Different bytecode hashes should produce different addresses");
    }
}

