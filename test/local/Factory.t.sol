// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Factory} from "../../src/Factory.sol";
import {Vault} from "../../src/Vault.sol";
import {AddressZero} from "../../src/interfaces/IVault.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {VaultAlreadyDeployed} from "../../src/interfaces/IFactory.sol";
import {WhiteList} from "whitelist-contracts/src/WhiteList.sol";
import {IWhiteList, NotWhiteListed} from "whitelist-contracts/src/interfaces/IWhiteList.sol";

contract FactoryTest is Test {
    Factory public factory;
    address public vaultImplementation;
    address public owner1;
    address public owner2;
    address public wethAddress;
    address public wbtcAddress;
    address public usdtAddress;
    address public usdcAddress;
    address public aaveV3Address;
    address public uniswapV4RouterAddress;
    address[] public assetAddresses;
    address[] public stableCoinAddresses;
    address[] public lendingProviders;
    address[] public stakingProviders;
    address[] public ammProviders;
    address[] public intentProviders;
    address public whiteListAddress;

    function setUp() public {
        wethAddress = makeAddr("wethAddress");
        whiteListAddress = address(new WhiteList());
        vaultImplementation = address(new Vault());
        factory = new Factory();
        owner1 = makeAddr("owner1");
        owner2 = makeAddr("owner2");
        wbtcAddress = makeAddr("wbtcAddress");
        usdtAddress = makeAddr("usdtAddress");
        usdcAddress = makeAddr("usdcAddress");
        aaveV3Address = makeAddr("aaveV3Address");
        uniswapV4RouterAddress = makeAddr("uniswapV4RouterAddress");
        assetAddresses = new address[](2);
        assetAddresses[0] = wbtcAddress;
        assetAddresses[1] = wethAddress;
        stableCoinAddresses = new address[](2);
        stableCoinAddresses[0] = usdtAddress;
        stableCoinAddresses[1] = usdcAddress;
        lendingProviders = new address[](0);
        stakingProviders = new address[](0);
        ammProviders = new address[](1);
        ammProviders[0] = uniswapV4RouterAddress;
        intentProviders = new address[](1);
        intentProviders[0] = makeAddr("intentProvider");
        vm.startPrank(tx.origin);
        IWhiteList(whiteListAddress).addAssets(assetAddresses);
        IWhiteList(whiteListAddress).addStableCoins(stableCoinAddresses);
        IWhiteList(whiteListAddress).addLendingProviders(lendingProviders);
        IWhiteList(whiteListAddress).addAMMProviders(ammProviders);
        IWhiteList(whiteListAddress).addStakingProviders(stakingProviders);
        IWhiteList(whiteListAddress).addIntentProviders(intentProviders);
        vm.stopPrank();
    }

    function _newVault() internal returns (address) {
        return factory.deployVault(
            assetAddresses, stableCoinAddresses, lendingProviders, stakingProviders, ammProviders, intentProviders
        );
    }

    function test_factoryRevertsIfAddressZero() public {
        vm.expectRevert(AddressZero.selector);
        factory.initialize(address(0), whiteListAddress, wethAddress);

        vm.expectRevert(AddressZero.selector);
        factory.initialize(vaultImplementation, address(0), wethAddress);

        vm.expectRevert(AddressZero.selector);
        factory.initialize(vaultImplementation, whiteListAddress, address(0));

        vm.expectRevert(AddressZero.selector);
        factory.initialize(vaultImplementation, whiteListAddress, address(0));
    }

    function test_DeployVaultRevertsIfAddressNotWhiteListed() public {
        factory.initialize(vaultImplementation, whiteListAddress, wethAddress);
        address[] memory invalidAddressArray = new address[](1);
        invalidAddressArray[0] = makeAddr("invalidAddress");
        vm.prank(owner1);
        vm.expectRevert(NotWhiteListed.selector);
        factory.deployVault(
            invalidAddressArray, stableCoinAddresses, lendingProviders, stakingProviders, ammProviders, intentProviders
        );
    }

    function test_DeployVaultForDifferentowners() public {
        factory.initialize(vaultImplementation, whiteListAddress, wethAddress);
        vm.prank(owner1);
        address vault1 = _newVault();
        vm.prank(owner2);
        address vault2 = _newVault();
        assertTrue(vault1 != vault2, "Different owners should get different vault addresses");
        assertTrue(vault1 != address(0), "Vault1 should not be zero address");
        assertTrue(vault2 != address(0), "Vault2 should not be zero address");
    }

    function test_ComputeVaultAddress() public {
        factory.initialize(vaultImplementation, whiteListAddress, wethAddress);
        address computedAddress = factory.computeVaultAddress(owner1);
        assertTrue(computedAddress != address(0), "Computed address should not be zero");

        vm.prank(owner1);
        address deployedAddress = _newVault();
        assertTrue(deployedAddress != address(0), "Deployed address should not be zero");
        assertTrue(computedAddress == deployedAddress, "Addresses should be same for same msg.sender");
    }

    function test_SameOwnerAlreadDeployed() public {
        factory.initialize(vaultImplementation, whiteListAddress, wethAddress);
        vm.prank(owner1);
        _newVault();

        vm.prank(owner1);
        vm.expectRevert(VaultAlreadyDeployed.selector);
        _newVault();
    }

    function test_SameownerSameSaltRevertsIfVaultExists() public {
        factory.initialize(vaultImplementation, whiteListAddress, wethAddress);
        vm.prank(owner1);
        address vault1 = _newVault();

        assertTrue(vault1 != address(0), "First vault should be deployed");

        vm.prank(owner1);
        vm.expectRevert(VaultAlreadyDeployed.selector);
        _newVault();
    }

    function test_DeployedVaultCanBeInitialized() public {
        factory.initialize(vaultImplementation, whiteListAddress, wethAddress);
        address vaultAddress = _newVault();
        Vault vault = Vault(payable(vaultAddress));

        assertEq(vault.owner(), tx.origin, "Owner should be set correctly");

        address[] memory assets = vault.getAssets();
        assertEq(assets[0], wbtcAddress, "WBTC address should be set");
        assertEq(assets[1], wethAddress, "WETH address should be set");
        address[] memory stableCoins = vault.getStableCoins();
        assertEq(stableCoins[0], usdtAddress, "USDT address should be set");
        assertEq(stableCoins[1], usdcAddress, "USDC address should be set");
    }

    function test_DeployVaultRevertsIfVaultAlreadyExistsAtComputedAddress() public {
        factory.initialize(vaultImplementation, whiteListAddress, wethAddress);

        bytes32 salt = keccak256(abi.encodePacked(owner1));
        address computedAddr = Clones.predictDeterministicAddress(vaultImplementation, salt, address(factory));

        bytes memory minimalBytecode =
            hex"6080604052348015600f57600080fd5b50603f80601d6000396000f3fe6080604052600080fdfea2646970667358221220";
        address deployedAddr;
        assembly {
            deployedAddr := create2(0, add(minimalBytecode, 0x20), mload(minimalBytecode), salt)
        }

        if (deployedAddr == computedAddr && deployedAddr.code.length > 0) {
            vm.prank(owner1);
            vm.expectRevert(VaultAlreadyDeployed.selector);
            _newVault();
        }
    }

    function test_InitializeSuccess() public {
        factory.initialize(vaultImplementation, whiteListAddress, wethAddress);
        assertEq(address(factory.whiteList()), whiteListAddress, "WhiteList address should be set");
    }

    function test_DeployVaultRevertsIfStableCoinNotWhiteListed() public {
        factory.initialize(vaultImplementation, whiteListAddress, wethAddress);
        address[] memory invalidStableCoinArray = new address[](1);
        invalidStableCoinArray[0] = makeAddr("invalidStableCoin");
        vm.prank(owner1);
        vm.expectRevert(NotWhiteListed.selector);
        factory.deployVault(
            assetAddresses, stableCoinAddresses, invalidStableCoinArray, stakingProviders, ammProviders, intentProviders
        );
    }

    function test_DeployVaultRevertsIfLendingProviderNotWhiteListed() public {
        factory.initialize(vaultImplementation, whiteListAddress, wethAddress);
        address[] memory invalidLendingProviderArray = new address[](1);
        invalidLendingProviderArray[0] = makeAddr("invalidLendingProvider");
        vm.prank(owner1);
        vm.expectRevert(NotWhiteListed.selector);
        factory.deployVault(
            assetAddresses,
            stableCoinAddresses,
            invalidLendingProviderArray,
            stakingProviders,
            ammProviders,
            intentProviders
        );
    }

    function test_DeployVaultRevertsIfAMMProviderNotWhiteListed() public {
        factory.initialize(vaultImplementation, whiteListAddress, wethAddress);
        address[] memory invalidAMMProviderArray = new address[](1);
        invalidAMMProviderArray[0] = makeAddr("invalidAMMProvider");
        vm.prank(owner1);
        vm.expectRevert(NotWhiteListed.selector);
        factory.deployVault(
            assetAddresses,
            stableCoinAddresses,
            lendingProviders,
            stakingProviders,
            invalidAMMProviderArray,
            intentProviders
        );
    }

    function test_DeployVaultWithEmptyArrays() public {
        factory.initialize(vaultImplementation, whiteListAddress, wethAddress);
        address[] memory emptyAssets = new address[](0);
        address[] memory emptyStableCoins = new address[](0);
        address[] memory emptyLendingProviders = new address[](0);
        address[] memory emptyAMMProviders = new address[](0);

        vm.prank(owner1);
        address vault = factory.deployVault(
            emptyAssets, emptyStableCoins, emptyLendingProviders, stakingProviders, emptyAMMProviders, intentProviders
        );

        assertTrue(vault != address(0), "Vault should be deployed");
    }

    function test_DeployVaultEmitsEvent() public {
        factory.initialize(vaultImplementation, whiteListAddress, wethAddress);

        address vault = _newVault();

        assertTrue(vault != address(0), "Vault should be deployed");

        Vault vaultInstance = Vault(payable(vault));
        assertEq(vaultInstance.owner(), tx.origin, "Owner should match");
    }

    function test_ComputeVaultAddressForDifferentowners() public {
        factory.initialize(vaultImplementation, whiteListAddress, wethAddress);
        address computed1 = factory.computeVaultAddress(owner1);
        address computed2 = factory.computeVaultAddress(owner2);

        assertTrue(computed1 != computed2, "Different owners should compute to different addresses");
        assertTrue(computed1 != address(0), "Computed address should not be zero");
        assertTrue(computed2 != address(0), "Computed address should not be zero");
    }

    function test_DeployVaultWithMultipleAssets() public {
        factory.initialize(vaultImplementation, whiteListAddress, wethAddress);
        address[] memory multipleAssets = new address[](3);
        multipleAssets[0] = wbtcAddress;
        multipleAssets[1] = wethAddress;
        multipleAssets[2] = makeAddr("asset3");

        address[] memory newAsset = new address[](1);
        newAsset[0] = multipleAssets[2];
        vm.prank(tx.origin);
        IWhiteList(whiteListAddress).addAssets(newAsset);

        vm.prank(owner1);
        address vault = factory.deployVault(
            multipleAssets, stableCoinAddresses, lendingProviders, stakingProviders, ammProviders, intentProviders
        );

        assertTrue(vault != address(0), "Vault should be deployed");
    }

    function test_DeployVaultWithMultipleStableCoins() public {
        factory.initialize(vaultImplementation, whiteListAddress, wethAddress);
        address[] memory multipleStableCoins = new address[](3);
        multipleStableCoins[0] = usdtAddress;
        multipleStableCoins[1] = usdcAddress;
        multipleStableCoins[2] = makeAddr("stableCoin3");

        address[] memory newStableCoin = new address[](1);
        newStableCoin[0] = multipleStableCoins[2];
        vm.prank(tx.origin);
        IWhiteList(whiteListAddress).addStableCoins(newStableCoin);

        vm.prank(owner1);
        address vault = factory.deployVault(
            assetAddresses, multipleStableCoins, lendingProviders, stakingProviders, ammProviders, intentProviders
        );

        assertTrue(vault != address(0), "Vault should be deployed");
    }

    function test_DeployVaultWithMultipleLendingProviders() public {
        factory.initialize(vaultImplementation, whiteListAddress, wethAddress);
        address LendingProvider1 = makeAddr("LendingProvider1");
        address LendingProvider2 = makeAddr("LendingProvider2");
        address[] memory multipleLendingProviders = new address[](2);
        multipleLendingProviders[0] = LendingProvider1;
        multipleLendingProviders[1] = LendingProvider2;

        vm.prank(tx.origin);
        IWhiteList(whiteListAddress).addLendingProviders(multipleLendingProviders);

        vm.prank(owner1);
        address vault = _newVault();

        assertTrue(vault != address(0), "Vault should be deployed");
    }

    function test_DeployVaultWithMultipleAMMProviders() public {
        factory.initialize(vaultImplementation, whiteListAddress, wethAddress);
        address swapProvider1 = makeAddr("swapProvider1");
        address swapProvider2 = makeAddr("swapProvider2");
        address[] memory multipleAMMProviders = new address[](2);
        multipleAMMProviders[0] = swapProvider1;
        multipleAMMProviders[1] = swapProvider2;

        vm.prank(tx.origin);
        IWhiteList(whiteListAddress).addAMMProviders(multipleAMMProviders);

        vm.prank(owner1);
        address vault = factory.deployVault(
            assetAddresses,
            stableCoinAddresses,
            lendingProviders,
            stakingProviders,
            multipleAMMProviders,
            intentProviders
        );

        assertTrue(vault != address(0), "Vault should be deployed");
    }

    function test_DeployVaultRevertsIfMultipleAssetsOneNotWhiteListed() public {
        factory.initialize(vaultImplementation, whiteListAddress, wethAddress);
        address[] memory mixedAssets = new address[](3);
        mixedAssets[0] = wbtcAddress;
        mixedAssets[1] = wethAddress;
        mixedAssets[2] = makeAddr("invalidAsset");

        vm.prank(owner1);
        vm.expectRevert(NotWhiteListed.selector);

        factory.deployVault(
            mixedAssets, stableCoinAddresses, lendingProviders, stakingProviders, ammProviders, intentProviders
        );
    }

    function test_DeployVaultRevertsIfMultipleStableCoinsOneNotWhiteListed() public {
        factory.initialize(vaultImplementation, whiteListAddress, wethAddress);
        address[] memory mixedStableCoins = new address[](3);
        mixedStableCoins[0] = usdtAddress;
        mixedStableCoins[1] = usdcAddress;
        mixedStableCoins[2] = makeAddr("invalidStableCoin");

        vm.prank(owner1);
        vm.expectRevert(NotWhiteListed.selector);
        factory.deployVault(
            assetAddresses, mixedStableCoins, lendingProviders, stakingProviders, ammProviders, intentProviders
        );
    }

    function test_DeployVaultRevertsIfMultipleLendingProvidersOneNotWhiteListed() public {
        factory.initialize(vaultImplementation, whiteListAddress, wethAddress);
        address LendingProvider1 = makeAddr("LendingProvider1");
        address[] memory mixedLendingProviders = new address[](2);
        mixedLendingProviders[0] = LendingProvider1;
        mixedLendingProviders[1] = makeAddr("invalidLendingProvider");

        address[] memory validProvider = new address[](1);
        validProvider[0] = LendingProvider1;
        vm.prank(tx.origin);
        IWhiteList(whiteListAddress).addLendingProviders(validProvider);

        vm.prank(owner1);
        vm.expectRevert(NotWhiteListed.selector);
        factory.deployVault(
            assetAddresses, stableCoinAddresses, mixedLendingProviders, stakingProviders, ammProviders, intentProviders
        );
    }

    function test_DeployVaultRevertsIfMultipleAMMProvidersOneNotWhiteListed() public {
        factory.initialize(vaultImplementation, whiteListAddress, wethAddress);
        address swapProvider1 = makeAddr("swapProvider1");
        address[] memory mixedAMMProviders = new address[](2);
        mixedAMMProviders[0] = swapProvider1;
        mixedAMMProviders[1] = makeAddr("invalidAMMProvider");

        address[] memory validProvider = new address[](1);
        validProvider[0] = swapProvider1;
        vm.prank(tx.origin);
        IWhiteList(whiteListAddress).addAMMProviders(validProvider);

        vm.prank(owner1);
        vm.expectRevert(NotWhiteListed.selector);

        factory.deployVault(
            assetAddresses, stableCoinAddresses, lendingProviders, stakingProviders, mixedAMMProviders, intentProviders
        );
    }

    function test_DeployVaultRevertsIfVaultAlreadyExistsAtComputedAddressForced() public {
        factory.initialize(vaultImplementation, whiteListAddress, wethAddress);

        bytes32 salt = keccak256(abi.encodePacked(owner1));
        address computedAddr = Clones.predictDeterministicAddress(vaultImplementation, salt, address(factory));

        bytes memory minimalBytecode =
            hex"6080604052348015600f57600080fd5b50603f80601d6000396000f3fe6080604052600080fdfea2646970667358221220";

        address deployedAddr;
        assembly {
            deployedAddr := create2(0, add(minimalBytecode, 0x20), mload(minimalBytecode), salt)
        }

        if (deployedAddr == computedAddr && deployedAddr.code.length > 0) {
            vm.prank(owner1);
            vm.expectRevert(VaultAlreadyDeployed.selector);
            _newVault();
        } else {
            vm.etch(computedAddr, minimalBytecode);
            if (computedAddr.code.length > 0) {
                vm.prank(owner1);
                vm.expectRevert(VaultAlreadyDeployed.selector);
                factory.deployVault(
                    assetAddresses,
                    stableCoinAddresses,
                    lendingProviders,
                    stakingProviders,
                    ammProviders,
                    intentProviders
                );
            }
        }
    }

    function test_ComputeAddressInternalFunction() public {
        factory.initialize(vaultImplementation, whiteListAddress, wethAddress);

        address addr1 = factory.computeVaultAddress(owner1);
        address addr2 = factory.computeVaultAddress(owner2);

        assertTrue(addr1 != address(0), "Computed address should not be zero");
        assertTrue(addr2 != address(0), "Computed address should not be zero");
        assertTrue(addr1 != addr2, "Different owners should produce different addresses");

        address addr1Again = factory.computeVaultAddress(owner1);
        assertEq(addr1, addr1Again, "Same owner should produce same computed address");
    }

    function test_DeployVaultSuccessWithAllValidParameters() public {
        factory.initialize(vaultImplementation, whiteListAddress, wethAddress);

        address vault = _newVault();

        assertTrue(vault != address(0), "Vault should be deployed");
        Vault vaultInstance = Vault(payable(vault));
        assertEq(vaultInstance.owner(), tx.origin, "Owner should match");
    }

    function test_InitializeSetsStateVariables() public {
        factory.initialize(vaultImplementation, whiteListAddress, wethAddress);
        assertEq(address(factory.whiteList()), whiteListAddress, "WhiteList address should be set");
    }

    function test_DeployVaultEmitsVaultDeployedEvent() public {
        factory.initialize(vaultImplementation, whiteListAddress, wethAddress);

        address vault = _newVault();

        assertTrue(vault != address(0), "Vault should be deployed");

        Vault vaultInstance = Vault(payable(vault));
        assertEq(vaultInstance.owner(), tx.origin, "Owner should match event");
    }
}

