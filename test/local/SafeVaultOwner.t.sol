// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Factory} from "../../src/Factory.sol";
import {Vault} from "../../src/Vault.sol";
import {IVault, ReceiverNameAlreadyExists} from "../../src/interfaces/IVault.sol";
import {WhiteList} from "whitelist-contracts/src/WhiteList.sol";
import {IWhiteList} from "whitelist-contracts/src/interfaces/IWhiteList.sol";
import {MockSafe} from "../mock/MockSafe.sol";
import {MockSafeProxyFactory} from "../mock/MockSafeProxyFactory.sol";

/// @title SafeVaultOwnerTest
/// @notice Examples of how a Gnosis Safe (vault owner) interacts with Vault.
/// @dev
///  Vault `owner()` is the Safe address. `onlyOwner` checks `msg.sender == owner()`, so
///  owner EOAs must not call Vault directly — they execute via the Safe (on mainnet:
///  `execTransaction`; in these unit tests: `MockSafe.exec`, which sets `msg.sender` to the Safe).
///
///  The asset manager remains a separate hot wallet; it cannot replace the Safe for admin calls.
contract SafeVaultOwnerTest is Test {
    Factory public factory;
    address public vaultImplementation;
    address public whiteListAddress;
    address public subscriptionAddress;
    address public wethAddress;
    address public safeProxyFactory;
    address public safeSingleton;

    address public safeOwner1;
    address public safeOwner2;

    address[] public assetAddresses;
    address[] public stableCoinAddresses;
    address[] public lendingProviders;
    address[] public stakingProviders;
    address[] public ammProviders;

    function setUp() public {
        wethAddress = makeAddr("weth");
        subscriptionAddress = makeAddr("subscription");
        safeSingleton = makeAddr("safeSingleton");
        safeProxyFactory = address(new MockSafeProxyFactory());
        whiteListAddress = address(new WhiteList());
        vaultImplementation = address(new Vault());
        factory = new Factory();

        safeOwner1 = makeAddr("safeOwner1");
        safeOwner2 = makeAddr("safeOwner2");

        address wbtc = makeAddr("wbtc");
        address usdc = makeAddr("usdc");
        assetAddresses = new address[](2);
        assetAddresses[0] = wbtc;
        assetAddresses[1] = wethAddress;
        stableCoinAddresses = new address[](1);
        stableCoinAddresses[0] = usdc;
        lendingProviders = new address[](0);
        stakingProviders = new address[](0);
        ammProviders = new address[](0);

        vm.startPrank(tx.origin);
        WhiteList wl = WhiteList(whiteListAddress);
        wl.grantRole(wl.ASSET_MANAGER_ROLE(), tx.origin);
        wl.grantRole(wl.STABLE_COIN_MANAGER_ROLE(), tx.origin);
        IWhiteList(whiteListAddress).addAssets(assetAddresses);
        IWhiteList(whiteListAddress).addStableCoins(stableCoinAddresses);
        factory.initialize(
            vaultImplementation, whiteListAddress, subscriptionAddress, wethAddress, safeProxyFactory, safeSingleton
        );
        vm.stopPrank();
    }

    function _deploySafeOwnedVault(address[] memory owners, uint256 threshold, uint256 saltNonce)
        internal
        returns (MockSafe safe, Vault vault)
    {
        (address safeAddr, address vaultAddr) = factory.deployVaultMultiSig(
            owners,
            threshold,
            saltNonce,
            assetAddresses,
            stableCoinAddresses,
            lendingProviders,
            stakingProviders,
            ammProviders
        );
        safe = MockSafe(safeAddr);
        vault = Vault(payable(vaultAddr));
        assertEq(vault.owner(), safeAddr, "vault owner must be the Safe");
    }

    /// @dev Stand-in for an executed Safe transaction (`msg.sender` becomes the Safe).
    function _execViaSafe(MockSafe safe, address owner, address target, bytes memory data) internal {
        vm.prank(owner);
        safe.exec(target, data);
    }

    function test_safeOwnerEOA_cannotCallVaultDirectly() public {
        address[] memory owners = new address[](2);
        owners[0] = safeOwner1;
        owners[1] = safeOwner2;

        (, Vault vault) = _deploySafeOwnedVault(owners, 2, 1);

        address assetManager = makeAddr("assetManager");
        vm.prank(safeOwner1);
        vm.expectRevert("Ownable: caller is not the owner");
        vault.setAssetManager(assetManager);

        vm.prank(safeOwner2);
        vm.expectRevert("Ownable: caller is not the owner");
        vault.setAssetManager(assetManager);
    }

    /// @notice Configure the hot-wallet asset manager through the Safe.
    function test_safeExec_setAssetManager() public {
        address[] memory owners = new address[](1);
        owners[0] = safeOwner1;

        (MockSafe safe, Vault vault) = _deploySafeOwnedVault(owners, 1, 100);

        address assetManager = makeAddr("assetManager");
        _execViaSafe(safe, safeOwner1, address(vault), abi.encodeCall(Vault.setAssetManager, (assetManager)));

        assertEq(vault.assetManager(), assetManager);
    }

    /// @notice Add a payment receiver — owner-only; must go through the Safe.
    function test_safeExec_addReceiver() public {
        address[] memory owners = new address[](1);
        owners[0] = safeOwner1;

        (MockSafe safe, Vault vault) = _deploySafeOwnedVault(owners, 1, 101);

        address beneficiary = makeAddr("beneficiary");
        IVault.Receiver memory receiver = IVault.Receiver({
            receiverAddress: beneficiary,
            trigger: address(0),
            assetAddress: wethAddress,
            amount: 1 ether,
            paymentCount: 1,
            startTimestamp: block.timestamp,
            durationTimestamp: 1 days,
            isImmutable: false
        });

        _execViaSafe(safe, safeOwner1, address(vault), abi.encodeCall(Vault.addReceiver, ("payroll", receiver)));

        vm.expectRevert(ReceiverNameAlreadyExists.selector);
        _execViaSafe(safe, safeOwner1, address(vault), abi.encodeCall(Vault.addReceiver, ("payroll", receiver)));
    }

    /// @notice Typical bootstrap: Safe sets asset manager, then adds receivers / policy.
    function test_safeExec_bootstrapVault_adminSequence() public {
        address[] memory owners = new address[](1);
        owners[0] = safeOwner1;

        (MockSafe safe, Vault vault) = _deploySafeOwnedVault(owners, 1, 102);

        address assetManager = makeAddr("assetManager");
        _execViaSafe(safe, safeOwner1, address(vault), abi.encodeCall(Vault.setAssetManager, (assetManager)));

        _execViaSafe(safe, safeOwner1, address(vault), abi.encodeCall(Vault.setNewReceiverProtection, (3 days)));

        address beneficiary = makeAddr("beneficiary");
        IVault.Receiver memory receiver = IVault.Receiver({
            receiverAddress: beneficiary,
            trigger: address(0),
            assetAddress: wethAddress,
            amount: 0.1 ether,
            paymentCount: 1,
            startTimestamp: block.timestamp,
            durationTimestamp: 0,
            isImmutable: false
        });
        _execViaSafe(safe, safeOwner1, address(vault), abi.encodeCall(Vault.addReceiver, ("ops", receiver)));

        assertEq(vault.assetManager(), assetManager);

        vm.expectRevert(ReceiverNameAlreadyExists.selector);
        _execViaSafe(safe, safeOwner1, address(vault), abi.encodeCall(Vault.addReceiver, ("ops", receiver)));
    }

    /// @notice Asset manager operates funds; Safe retains admin control.
    function test_assetManager_cannotReplaceSafeForOwnerActions() public {
        address[] memory owners = new address[](1);
        owners[0] = safeOwner1;

        (MockSafe safe, Vault vault) = _deploySafeOwnedVault(owners, 1, 103);

        address assetManager = makeAddr("assetManager");
        _execViaSafe(safe, safeOwner1, address(vault), abi.encodeCall(Vault.setAssetManager, (assetManager)));

        IVault.Receiver memory receiver = IVault.Receiver({
            receiverAddress: makeAddr("beneficiary"),
            trigger: address(0),
            assetAddress: wethAddress,
            amount: 1,
            paymentCount: 1,
            startTimestamp: block.timestamp,
            durationTimestamp: 0,
            isImmutable: false
        });

        vm.prank(assetManager);
        vm.expectRevert("Ownable: caller is not the owner");
        vault.addReceiver("blocked", receiver);

        vm.prank(assetManager);
        vm.expectRevert("Ownable: caller is not the owner");
        vault.setAssetManager(makeAddr("otherManager"));
    }

    function test_stranger_cannotExecThroughSafe() public {
        address[] memory owners = new address[](1);
        owners[0] = safeOwner1;

        (MockSafe safe, Vault vault) = _deploySafeOwnedVault(owners, 1, 104);

        bytes memory data = abi.encodeCall(Vault.setAssetManager, (makeAddr("attacker")));

        vm.prank(makeAddr("stranger"));
        vm.expectRevert("MockSafe: not owner");
        safe.exec(address(vault), data);
    }
}
