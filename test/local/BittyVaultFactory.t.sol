// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {BittyVaultFactory} from "../../src/BittyVaultFactory.sol";
import {BittyVault} from "../../src/BittyVault.sol";
import {AddressZero} from "../../src/interfaces/IVault.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {VaultAlreadyDeployed} from "../../src/interfaces/IVaultFactory.sol";
import {BittyGuard} from "guard-contracts/src/BittyGuard.sol";
import {IGuard, NotRegistered} from "guard-contracts/src/interfaces/IGuard.sol";

contract BittyVaultFactoryTest is Test {
    BittyVaultFactory public factory;
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
    address[] public lendingProtocols;
    address[] public stakingProtocols;
    address[] public ammProtocols;
    address public guardAddress;
    address public assetManagerAddress;

    function setUp() public {
        wethAddress = makeAddr("wethAddress");
        guardAddress = address(new BittyGuard());
        vaultImplementation = address(new BittyVault());
        factory = new BittyVaultFactory();
        owner1 = makeAddr("owner1");
        owner2 = makeAddr("owner2");
        assetManagerAddress = makeAddr("assetManager");
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
        lendingProtocols = new address[](0);
        stakingProtocols = new address[](0);
        ammProtocols = new address[](1);
        ammProtocols[0] = uniswapV4RouterAddress;
        vm.startPrank(tx.origin);
        BittyGuard wl = BittyGuard(guardAddress);
        wl.grantRole(wl.ASSET_MANAGER_ROLE(), tx.origin);
        wl.grantRole(wl.STABLE_COIN_MANAGER_ROLE(), tx.origin);
        wl.grantRole(wl.LENDING_MANAGER_ROLE(), tx.origin);
        wl.grantRole(wl.STAKING_MANAGER_ROLE(), tx.origin);
        wl.grantRole(wl.AMM_MANAGER_ROLE(), tx.origin);
        IGuard(guardAddress).addAssets(assetAddresses);
        IGuard(guardAddress).addStableCoins(stableCoinAddresses);
        IGuard(guardAddress).addLendingProtocols(lendingProtocols);
        IGuard(guardAddress).addAMMProtocols(ammProtocols);
        IGuard(guardAddress).addStakingProtocols(stakingProtocols);
        vm.stopPrank();
    }

    function _deployVault(address owner, string memory name, address assetManager) internal returns (address) {
        return factory.deployVault(
            owner,
            name,
            assetManager,
            assetAddresses,
            stableCoinAddresses,
            lendingProtocols,
            stakingProtocols,
            ammProtocols
        );
    }

    function _newVault() internal returns (address) {
        return _deployVault(tx.origin, "main", assetManagerAddress);
    }

    function _newVaultFor(address owner) internal returns (address) {
        return _deployVault(owner, "main", assetManagerAddress);
    }

    function _initFactory() internal {
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
    }

    function test_factoryRevertsIfAddressZero() public {
        vm.expectRevert(AddressZero.selector);
        factory.initialize(address(0), guardAddress, wethAddress);

        vm.expectRevert(AddressZero.selector);
        factory.initialize(vaultImplementation, address(0), wethAddress);

        vm.expectRevert(AddressZero.selector);
        factory.initialize(vaultImplementation, guardAddress, address(0));
    }

    function test_DeployVaultRevertsIfAddressNotRegistered() public {
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
        address[] memory invalidAddressArray = new address[](1);
        invalidAddressArray[0] = makeAddr("invalidAddress");
        vm.expectRevert(NotRegistered.selector);
        factory.deployVault(
            owner1,
            "main",
            assetManagerAddress,
            invalidAddressArray,
            stableCoinAddresses,
            lendingProtocols,
            stakingProtocols,
            ammProtocols
        );
    }

    function test_DeployVaultForDifferentowners() public {
        _initFactory();
        address vault1 = _newVaultFor(owner1);
        address vault2 = _newVaultFor(owner2);
        assertTrue(vault1 != vault2, "Different owners should get different vault addresses");
        assertTrue(vault1 != address(0), "Vault1 should not be zero address");
        assertTrue(vault2 != address(0), "Vault2 should not be zero address");
    }

    function test_ComputeVaultAddress() public {
        _initFactory();
        address computedAddress = factory.computeVaultAddress(owner1, "main");
        assertTrue(computedAddress != address(0), "Computed address should not be zero");

        address deployedAddress = _newVaultFor(owner1);
        assertTrue(deployedAddress != address(0), "Deployed address should not be zero");
        assertEq(computedAddress, deployedAddress, "Computed address should match deployment");
    }

    function test_SameOwnerAlreadDeployed() public {
        _initFactory();
        _newVaultFor(owner1);

        vm.expectRevert(VaultAlreadyDeployed.selector);
        _newVaultFor(owner1);
    }

    function test_SameownerSameSaltRevertsIfVaultExists() public {
        _initFactory();
        address vault1 = _newVaultFor(owner1);

        assertTrue(vault1 != address(0), "First vault should be deployed");

        vm.expectRevert(VaultAlreadyDeployed.selector);
        _newVaultFor(owner1);
    }

    function test_DeployedVaultCanBeInitialized() public {
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
        address vaultAddress = _newVault();
        BittyVault vault = BittyVault(payable(vaultAddress));

        assertTrue(
            BittyVault(payable(vaultAddress))
                .hasRole(BittyVault(payable(vaultAddress)).DEFAULT_ADMIN_ROLE(), tx.origin),
            "Owner should hold DEFAULT_ADMIN_ROLE"
        );

        address[] memory assets = vault.getAssets();
        assertEq(assets[0], wbtcAddress, "WBTC address should be set");
        assertEq(assets[1], wethAddress, "WETH address should be set");
        address[] memory stableCoins = vault.getStableCoins();
        assertEq(stableCoins[0], usdtAddress, "USDT address should be set");
        assertEq(stableCoins[1], usdcAddress, "USDC address should be set");
    }

    function test_DeployVaultRevertsIfVaultAlreadyExistsAtComputedAddress() public {
        factory.initialize(vaultImplementation, guardAddress, wethAddress);

        bytes32 salt = keccak256(abi.encodePacked(owner1, "main"));
        address computedAddr = Clones.predictDeterministicAddress(vaultImplementation, salt, address(factory));

        bytes memory minimalBytecode =
            hex"6080604052348015600f57600080fd5b50603f80601d6000396000f3fe6080604052600080fdfea2646970667358221220";
        address deployedAddr;
        assembly {
            deployedAddr := create2(0, add(minimalBytecode, 0x20), mload(minimalBytecode), salt)
        }

        if (deployedAddr == computedAddr && deployedAddr.code.length > 0) {
            vm.expectRevert(VaultAlreadyDeployed.selector);
            _newVaultFor(owner1);
        }
    }

    function test_InitializeSuccess() public {
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
        assertEq(factory.guardAddress(), guardAddress, "BittyGuard address should be set");
    }

    function test_DeployVaultRevertsIfStableCoinNotRegistered() public {
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
        address[] memory invalidStableCoinArray = new address[](1);
        invalidStableCoinArray[0] = makeAddr("invalidStableCoin");
        vm.expectRevert(NotRegistered.selector);
        factory.deployVault(
            owner1,
            "main",
            assetManagerAddress,
            assetAddresses,
            stableCoinAddresses,
            invalidStableCoinArray,
            stakingProtocols,
            ammProtocols
        );
    }

    function test_DeployVaultRevertsIfLendingProtocolNotRegistered() public {
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
        address[] memory invalidLendingProviderArray = new address[](1);
        invalidLendingProviderArray[0] = makeAddr("invalidLendingProtocol");
        vm.expectRevert(NotRegistered.selector);
        factory.deployVault(
            owner1,
            "main",
            assetManagerAddress,
            assetAddresses,
            stableCoinAddresses,
            invalidLendingProviderArray,
            stakingProtocols,
            ammProtocols
        );
    }

    function test_DeployVaultRevertsIfAMMProtocolNotRegistered() public {
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
        address[] memory invalidAMMProviderArray = new address[](1);
        invalidAMMProviderArray[0] = makeAddr("invalidAMMProtocol");
        vm.expectRevert(NotRegistered.selector);
        factory.deployVault(
            owner1,
            "main",
            assetManagerAddress,
            assetAddresses,
            stableCoinAddresses,
            lendingProtocols,
            stakingProtocols,
            invalidAMMProviderArray
        );
    }

    function test_DeployVaultWithEmptyArrays() public {
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
        address[] memory emptyAssets = new address[](0);
        address[] memory emptyStableCoins = new address[](0);
        address[] memory emptyLendingProtocols = new address[](0);
        address[] memory emptyAMMProtocols = new address[](0);

        address vault = factory.deployVault(
            owner1,
            "main",
            assetManagerAddress,
            emptyAssets,
            emptyStableCoins,
            emptyLendingProtocols,
            stakingProtocols,
            emptyAMMProtocols
        );

        assertTrue(vault != address(0), "Vault should be deployed");
    }

    function test_DeployVaultEmitsEvent() public {
        factory.initialize(vaultImplementation, guardAddress, wethAddress);

        address vault = _newVault();

        assertTrue(vault != address(0), "Vault should be deployed");

        BittyVault vaultInstance = BittyVault(payable(vault));
        assertTrue(
            vaultInstance.hasRole(vaultInstance.DEFAULT_ADMIN_ROLE(), tx.origin), "Owner should hold DEFAULT_ADMIN_ROLE"
        );
    }

    function test_ComputeVaultAddressForDifferentowners() public {
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
        address computed1 = factory.computeVaultAddress(owner1, "main");
        address computed2 = factory.computeVaultAddress(owner2, "main");

        assertTrue(computed1 != computed2, "Different owners should compute to different addresses");
        assertTrue(computed1 != address(0), "Computed address should not be zero");
        assertTrue(computed2 != address(0), "Computed address should not be zero");
    }

    function test_DeployVaultWithMultipleAssets() public {
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
        address[] memory multipleAssets = new address[](3);
        multipleAssets[0] = wbtcAddress;
        multipleAssets[1] = wethAddress;
        multipleAssets[2] = makeAddr("asset3");

        address[] memory newAsset = new address[](1);
        newAsset[0] = multipleAssets[2];
        vm.prank(tx.origin);
        IGuard(guardAddress).addAssets(newAsset);

        address vault = factory.deployVault(
            owner1,
            "main",
            assetManagerAddress,
            multipleAssets,
            stableCoinAddresses,
            lendingProtocols,
            stakingProtocols,
            ammProtocols
        );

        assertTrue(vault != address(0), "Vault should be deployed");
    }

    function test_DeployVaultWithMultipleStableCoins() public {
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
        address[] memory multipleStableCoins = new address[](3);
        multipleStableCoins[0] = usdtAddress;
        multipleStableCoins[1] = usdcAddress;
        multipleStableCoins[2] = makeAddr("stableCoin3");

        address[] memory newStableCoin = new address[](1);
        newStableCoin[0] = multipleStableCoins[2];
        vm.prank(tx.origin);
        IGuard(guardAddress).addStableCoins(newStableCoin);

        address vault = factory.deployVault(
            owner1,
            "main",
            assetManagerAddress,
            assetAddresses,
            multipleStableCoins,
            lendingProtocols,
            stakingProtocols,
            ammProtocols
        );

        assertTrue(vault != address(0), "Vault should be deployed");
    }

    function test_DeployVaultWithMultipleLendingProtocols() public {
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
        address LendingProtocol1 = makeAddr("LendingProtocol1");
        address LendingProtocol2 = makeAddr("LendingProtocol2");
        address[] memory multipleLendingProtocols = new address[](2);
        multipleLendingProtocols[0] = LendingProtocol1;
        multipleLendingProtocols[1] = LendingProtocol2;

        vm.prank(tx.origin);
        IGuard(guardAddress).addLendingProtocols(multipleLendingProtocols);

        address vault = _newVaultFor(owner1);

        assertTrue(vault != address(0), "Vault should be deployed");
    }

    function test_DeployVaultWithMultipleAMMProtocols() public {
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
        address swapProtocol1 = makeAddr("swapProtocol1");
        address swapProtocol2 = makeAddr("swapProtocol2");
        address[] memory multipleAMMProtocols = new address[](2);
        multipleAMMProtocols[0] = swapProtocol1;
        multipleAMMProtocols[1] = swapProtocol2;

        vm.prank(tx.origin);
        IGuard(guardAddress).addAMMProtocols(multipleAMMProtocols);

        address vault = factory.deployVault(
            owner1,
            "main",
            assetManagerAddress,
            assetAddresses,
            stableCoinAddresses,
            lendingProtocols,
            stakingProtocols,
            multipleAMMProtocols
        );

        assertTrue(vault != address(0), "Vault should be deployed");
    }

    function test_DeployVaultRevertsIfMultipleAssetsOneNotRegistered() public {
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
        address[] memory mixedAssets = new address[](3);
        mixedAssets[0] = wbtcAddress;
        mixedAssets[1] = wethAddress;
        mixedAssets[2] = makeAddr("invalidAsset");

        vm.expectRevert(NotRegistered.selector);
        factory.deployVault(
            owner1,
            "main",
            assetManagerAddress,
            mixedAssets,
            stableCoinAddresses,
            lendingProtocols,
            stakingProtocols,
            ammProtocols
        );
    }

    function test_DeployVaultRevertsIfMultipleStableCoinsOneNotRegistered() public {
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
        address[] memory mixedStableCoins = new address[](3);
        mixedStableCoins[0] = usdtAddress;
        mixedStableCoins[1] = usdcAddress;
        mixedStableCoins[2] = makeAddr("invalidStableCoin");

        vm.expectRevert(NotRegistered.selector);
        factory.deployVault(
            owner1,
            "main",
            assetManagerAddress,
            assetAddresses,
            mixedStableCoins,
            lendingProtocols,
            stakingProtocols,
            ammProtocols
        );
    }

    function test_DeployVaultRevertsIfMultipleLendingProtocolsOneNotRegistered() public {
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
        address LendingProtocol1 = makeAddr("LendingProtocol1");
        address[] memory mixedLendingProtocols = new address[](2);
        mixedLendingProtocols[0] = LendingProtocol1;
        mixedLendingProtocols[1] = makeAddr("invalidLendingProtocol");

        address[] memory validProtocol = new address[](1);
        validProtocol[0] = LendingProtocol1;
        vm.prank(tx.origin);
        IGuard(guardAddress).addLendingProtocols(validProtocol);

        vm.expectRevert(NotRegistered.selector);
        factory.deployVault(
            owner1,
            "main",
            assetManagerAddress,
            assetAddresses,
            stableCoinAddresses,
            mixedLendingProtocols,
            stakingProtocols,
            ammProtocols
        );
    }

    function test_DeployVaultRevertsIfMultipleAMMProtocolsOneNotRegistered() public {
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
        address swapProtocol1 = makeAddr("swapProtocol1");
        address[] memory mixedAMMProtocols = new address[](2);
        mixedAMMProtocols[0] = swapProtocol1;
        mixedAMMProtocols[1] = makeAddr("invalidAMMProtocol");

        address[] memory validProtocol = new address[](1);
        validProtocol[0] = swapProtocol1;
        vm.prank(tx.origin);
        IGuard(guardAddress).addAMMProtocols(validProtocol);

        vm.expectRevert(NotRegistered.selector);
        factory.deployVault(
            owner1,
            "main",
            assetManagerAddress,
            assetAddresses,
            stableCoinAddresses,
            lendingProtocols,
            stakingProtocols,
            mixedAMMProtocols
        );
    }

    function test_DeployVaultRevertsIfVaultAlreadyExistsAtComputedAddressForced() public {
        factory.initialize(vaultImplementation, guardAddress, wethAddress);

        bytes32 salt = keccak256(abi.encodePacked(owner1, "main"));
        address computedAddr = Clones.predictDeterministicAddress(vaultImplementation, salt, address(factory));

        bytes memory minimalBytecode =
            hex"6080604052348015600f57600080fd5b50603f80601d6000396000f3fe6080604052600080fdfea2646970667358221220";

        address deployedAddr;
        assembly {
            deployedAddr := create2(0, add(minimalBytecode, 0x20), mload(minimalBytecode), salt)
        }

        if (deployedAddr == computedAddr && deployedAddr.code.length > 0) {
            vm.expectRevert(VaultAlreadyDeployed.selector);
            _newVaultFor(owner1);
        } else {
            vm.etch(computedAddr, minimalBytecode);
            if (computedAddr.code.length > 0) {
                vm.expectRevert(VaultAlreadyDeployed.selector);
                _newVaultFor(owner1);
            }
        }
    }

    function test_ComputeAddressInternalFunction() public {
        factory.initialize(vaultImplementation, guardAddress, wethAddress);

        address addr1 = factory.computeVaultAddress(owner1, "main");
        address addr2 = factory.computeVaultAddress(owner2, "main");

        assertTrue(addr1 != address(0), "Computed address should not be zero");
        assertTrue(addr2 != address(0), "Computed address should not be zero");
        assertTrue(addr1 != addr2, "Different owners should produce different addresses");

        address addr1Again = factory.computeVaultAddress(owner1, "main");
        assertEq(addr1, addr1Again, "Same owner should produce same computed address");
    }

    function test_DeployVaultSuccessWithAllValidParameters() public {
        factory.initialize(vaultImplementation, guardAddress, wethAddress);

        address vault = _newVault();

        assertTrue(vault != address(0), "Vault should be deployed");
        BittyVault vaultInstance = BittyVault(payable(vault));
        assertTrue(
            vaultInstance.hasRole(vaultInstance.DEFAULT_ADMIN_ROLE(), tx.origin), "Owner should hold DEFAULT_ADMIN_ROLE"
        );
    }

    function test_InitializeSetsStateVariables() public {
        factory.initialize(vaultImplementation, guardAddress, wethAddress);
        assertEq(factory.guardAddress(), guardAddress, "BittyGuard address should be set");
    }

    function test_DeployVaultEmitsVaultDeployedEvent() public {
        factory.initialize(vaultImplementation, guardAddress, wethAddress);

        address vault = _newVault();

        assertTrue(vault != address(0), "Vault should be deployed");

        BittyVault vaultInstance = BittyVault(payable(vault));
        assertTrue(
            vaultInstance.hasRole(vaultInstance.DEFAULT_ADMIN_ROLE(), tx.origin), "Owner should hold DEFAULT_ADMIN_ROLE"
        );
    }

    function test_Factory_initCode() public {
        bytes memory bytecode = type(BittyVaultFactory).creationCode;
        console.logBytes32(keccak256(bytecode));
    }

    function test_DeployVaultFor_setsOwner() public {
        _initFactory();
        address vault = _newVaultFor(owner1);
        assertTrue(BittyVault(payable(vault)).hasRole(BittyVault(payable(vault)).DEFAULT_ADMIN_ROLE(), owner1));
    }

    function test_DeployVaultFor_revertOwnerZero() public {
        _initFactory();
        vm.expectRevert(AddressZero.selector);
        factory.deployVault(
            address(0),
            "main",
            assetManagerAddress,
            assetAddresses,
            stableCoinAddresses,
            lendingProtocols,
            stakingProtocols,
            ammProtocols
        );
    }

    function test_DeployVaultFor_revertVaultAlreadyDeployed() public {
        _initFactory();
        _newVaultFor(owner1);
        vm.expectRevert(VaultAlreadyDeployed.selector);
        _newVaultFor(owner1);
    }

    function test_DeployVaultFor_emitsVaultDeployedEvent() public {
        _initFactory();
        address expectedVault = factory.computeVaultAddress(owner1, "main");

        vm.expectEmit(true, true, false, true);
        emit BittyVaultFactory.VaultDeployed(expectedVault, owner1, "main");

        address vault = _newVaultFor(owner1);
        assertEq(vault, expectedVault);
    }

    function test_DeployVaultFor_initializesVaultConfig() public {
        _initFactory();
        BittyVault vault = BittyVault(payable(_newVaultFor(owner1)));

        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), owner1));
        assertEq(vault.getAssets()[0], wbtcAddress);
        assertEq(vault.getAssets()[1], wethAddress);
        assertEq(vault.getStableCoins()[0], usdtAddress);
        assertEq(vault.getStableCoins()[1], usdcAddress);
    }

    function test_DeployVault_setsRolesAtInit() public {
        _initFactory();
        BittyVault vault = BittyVault(payable(_newVaultFor(owner1)));
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), owner1));
        assertTrue(vault.hasRole(vault.ASSET_MANAGER_ROLE(), assetManagerAddress));
    }

    function test_DeployVaultFor_nonOwnerCannotGrantRoles() public {
        _initFactory();
        BittyVault vault = BittyVault(payable(_newVaultFor(owner1)));

        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();
        vm.prank(owner2);
        vm.expectRevert(
            bytes(
                string.concat(
                    "AccessControl: account ",
                    Strings.toHexString(uint160(owner2), 20),
                    " is missing role ",
                    Strings.toHexString(uint256(adminRole), 32)
                )
            )
        );
        vault.grantRole(adminRole, owner2);
    }

    function test_DeployVault_withTxOriginOwner() public {
        _initFactory();
        address expected = factory.computeVaultAddress(tx.origin, "main");
        address vault = _newVault();
        assertEq(vault, expected);
        assertTrue(BittyVault(payable(vault)).hasRole(BittyVault(payable(vault)).DEFAULT_ADMIN_ROLE(), tx.origin));
        assertTrue(
            BittyVault(payable(vault)).hasRole(BittyVault(payable(vault)).ASSET_MANAGER_ROLE(), assetManagerAddress)
        );
    }

    function test_DeployVault_multisigOwnerAddress() public {
        _initFactory();
        address multisigOwner = makeAddr("gnosisSafe");
        address vault = _deployVault(multisigOwner, "main", assetManagerAddress);

        assertEq(factory.computeVaultAddress(multisigOwner, "main"), vault);
        assertTrue(BittyVault(payable(vault)).hasRole(BittyVault(payable(vault)).DEFAULT_ADMIN_ROLE(), multisigOwner));

        bytes32 adminRole = BittyVault(payable(vault)).DEFAULT_ADMIN_ROLE();
        vm.prank(owner1);
        vm.expectRevert(
            bytes(
                string.concat(
                    "AccessControl: account ",
                    Strings.toHexString(uint160(owner1), 20),
                    " is missing role ",
                    Strings.toHexString(uint256(adminRole), 32)
                )
            )
        );
        BittyVault(payable(vault)).grantRole(adminRole, makeAddr("other"));
    }

    // ============ Multi-vault per owner ============

    function test_sameOwnerCanDeployMultipleVaultsWithDifferentNames() public {
        _initFactory();
        address vault1 = _deployVault(owner1, "savings", assetManagerAddress);
        address vault2 = _deployVault(owner1, "trading", assetManagerAddress);

        assertTrue(vault1 != vault2, "Different names produce different vault addresses");
        assertEq(BittyVault(payable(vault1)).vaultName(), "savings");
        assertEq(BittyVault(payable(vault2)).vaultName(), "trading");
        assertTrue(BittyVault(payable(vault1)).hasRole(BittyVault(payable(vault1)).DEFAULT_ADMIN_ROLE(), owner1));
        assertTrue(BittyVault(payable(vault2)).hasRole(BittyVault(payable(vault2)).DEFAULT_ADMIN_ROLE(), owner1));
    }

    function test_sameNameDifferentOwnerProducesDifferentVault() public {
        _initFactory();
        address vault1 = _deployVault(owner1, "main", assetManagerAddress);
        address vault2 = _deployVault(owner2, "main", assetManagerAddress);

        assertTrue(vault1 != vault2);
        assertEq(BittyVault(payable(vault1)).vaultName(), "main");
        assertEq(BittyVault(payable(vault2)).vaultName(), "main");
    }

    function test_deployVault_sameOwnerSameNameReverts() public {
        _initFactory();
        _deployVault(owner1, "savings", assetManagerAddress);

        vm.expectRevert(VaultAlreadyDeployed.selector);
        _deployVault(owner1, "savings", assetManagerAddress);
    }

    function test_computeVaultAddress_matchesDeployForMultipleNames() public {
        _initFactory();
        address predicted1 = factory.computeVaultAddress(owner1, "savings");
        address predicted2 = factory.computeVaultAddress(owner1, "trading");

        address actual1 = _deployVault(owner1, "savings", assetManagerAddress);
        address actual2 = _deployVault(owner1, "trading", assetManagerAddress);

        assertEq(predicted1, actual1);
        assertEq(predicted2, actual2);
        assertTrue(predicted1 != predicted2);
    }

    function test_deployedVault_storesVaultName() public {
        _initFactory();
        address vault = _deployVault(owner1, "my savings", assetManagerAddress);
        assertEq(BittyVault(payable(vault)).vaultName(), "my savings");
    }

    function test_DeployVault_simpleOverload_noAssetManager() public {
        _initFactory();
        address vault = factory.deployVault(tx.origin, "simple");
        assertTrue(vault != address(0));
        assertTrue(BittyVault(payable(vault)).hasRole(BittyVault(payable(vault)).DEFAULT_ADMIN_ROLE(), tx.origin));
        assertFalse(BittyVault(payable(vault)).hasRole(BittyVault(payable(vault)).ASSET_MANAGER_ROLE(), address(0)));
        assertEq(BittyVault(payable(vault)).vaultName(), "simple");
        assertEq(factory.computeVaultAddress(tx.origin, "simple"), vault);
    }
}

