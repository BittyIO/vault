// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ASSET_STABLE_COIN} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {LENDING_ID, STAKING_ID} from "../helpers/CategoryIds.sol";
import {IBittyV1Protocol} from "protocol-contracts/src/interfaces/IBittyV1Protocol.sol";
import {IBittyV1Yield} from "protocol-contracts/src/interfaces/IBittyV1Yield.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1SubVault} from "../../src/subvault/BittyV1SubVault.sol";
import {NotRegistered} from "../../src/interfaces/IBittyV1Vault.sol";
import {
    ProtocolNotInstantiated,
    ProtocolLineageMismatch,
    ProtocolNotNewer
} from "../../src/interfaces/IBittyV1DeFi.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";

/// A UUPS lending adapter, mirroring protocol-store's BittyV1ProtocolBase.
contract UpgradeableLendingV1 is IBittyV1Protocol, IBittyV1Yield, Ownable, Initializable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    uint256 public depositCount;

    function protocolLineage() external pure virtual returns (bytes32) {
        return keccak256("bitty.mock.upgradeable-lending");
    }

    function protocolVersion() external pure virtual returns (uint256) {
        return 1_000_000;
    }

    function versionName() external pure virtual returns (string memory) {
        return "1.0.0";
    }

    constructor() Ownable(msg.sender) {
        _disableInitializers();
    }

    function initialize(address newOwner) external override initializer {
        _transferOwnership(newOwner);
    }

    function _authorizeUpgrade(address) internal view override {
        _checkOwner();
    }

    function adapterVersion() external pure virtual returns (string memory) {
        return "1.0.0";
    }

    function deposit(address asset, uint256 amount) external override onlyOwner {
        depositCount++;
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdraw(address asset, uint256 amount, address recipient) external override onlyOwner returns (uint256) {
        uint256 amt = amount == type(uint256).max ? IERC20(asset).balanceOf(address(this)) : amount;
        IERC20(asset).safeTransfer(recipient, amt);
        return amt;
    }

    function getBalance(address asset) external view override returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function getPendingWithdrawalIds() external pure override returns (uint256[] memory) {
        return new uint256[](0);
    }

    function claimWithdrawals(uint256[] memory) external override onlyOwner {}
}

/// Lending like the others, so the category check passes - but a different code line.
contract ForeignLendingAdapter is UpgradeableLendingV1 {
    function protocolLineage() external pure override returns (bytes32) {
        return keccak256("bitty.mock.foreign-lending");
    }
}

contract UpgradeableLendingV2 is UpgradeableLendingV1 {
    function adapterVersion() external pure override returns (string memory) {
        return "2.0.0";
    }

    function protocolVersion() external pure override returns (uint256) {
        return 1_001_002;
    }

    function versionName() external pure override returns (string memory) {
        return "1.1.2";
    }
}

interface IFacet {
    function deposit(address protocol, address asset, uint256 amount) external;
    function updateProtocols(address[] calldata add, address[] calldata remove) external;
    function upgradeProtocol(address protocol, address newImplementation) external;
    function getClone(address protocol) external view returns (address);
    function getBalances(address[] calldata protocols, address[] calldata assets)
        external
        view
        returns (uint256[] memory);
}

/**
 * An adapter instance is an ERC-1967 proxy the vault owns, so the owner can repoint it at newer
 * adapter code the same way they upgrade the vault itself — keeping the instance address, its token
 * balances and any state it holds, which swapping the adapter out via updateProtocols would strand.
 */
contract ProtocolUpgradeTest is Test {
    BittyV1Vault vault;
    MockGuard guard;
    MockERC20 usdc;
    UpgradeableLendingV1 v1;
    UpgradeableLendingV2 v2;

    address owner = makeAddr("owner");
    address stranger = makeAddr("stranger");
    address weth = makeAddr("weth");

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);

        BittyV1VaultDeFiFacet facet = new BittyV1VaultDeFiFacet();
        BittyV1SubVault subImpl = new BittyV1SubVault(address(facet));
        BittyV1Vault impl = new BittyV1Vault(address(facet), address(subImpl));
        vault = BittyV1Vault(
            payable(new ERC1967Proxy(
                    address(impl), abi.encodeCall(BittyV1Vault.initialize, (owner, weth, false, address(0), 0))
                ))
        );

        usdc = new MockERC20("USD Coin", "USDC", 6);
        v1 = new UpgradeableLendingV1();
        v2 = new UpgradeableLendingV2();
        guard.setAsset(address(usdc), ASSET_STABLE_COIN);
        guard.setProtocol(address(v1), LENDING_ID);
        guard.setProtocol(address(v2), LENDING_ID);
        usdc.mint(address(vault), 1_000e6);

        vm.prank(owner);
        _f().deposit(address(v1), address(usdc), 100e6);
    }

    function _f() internal view returns (IFacet) {
        return IFacet(address(vault));
    }

    function _one(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function test_upgradeKeepsInstanceAddressBalanceAndState() public {
        address instance = _f().getClone(address(v1));
        assertEq(UpgradeableLendingV1(instance).adapterVersion(), "1.0.0");
        assertEq(UpgradeableLendingV1(instance).depositCount(), 1);

        vm.prank(owner);
        _f().upgradeProtocol(address(v1), address(v2));

        assertEq(_f().getClone(address(v1)), instance, "instance address moved");
        assertEq(UpgradeableLendingV1(instance).adapterVersion(), "2.0.0", "code not upgraded");
        assertEq(UpgradeableLendingV1(instance).depositCount(), 1, "state lost");
        assertEq(usdc.balanceOf(instance), 100e6, "funds lost");
        assertEq(_f().getBalances(_one(address(v1)), _one(address(usdc)))[0], 100e6);
    }

    function test_vaultStillOwnsUpgradedInstance() public {
        vm.prank(owner);
        _f().upgradeProtocol(address(v1), address(v2));
        assertEq(UpgradeableLendingV1(_f().getClone(address(v1))).owner(), address(vault));

        vm.prank(owner);
        _f().deposit(address(v1), address(usdc), 50e6);
        assertEq(usdc.balanceOf(_f().getClone(address(v1))), 150e6);
    }

    function test_nonOwnerCannotUpgrade() public {
        vm.prank(stranger);
        vm.expectRevert();
        _f().upgradeProtocol(address(v1), address(v2));
    }

    /// The guard stays the curation boundary: an owner cannot repoint an adapter at unblessed code.
    function test_unregisteredImplementationRejected() public {
        UpgradeableLendingV2 rogue = new UpgradeableLendingV2();
        vm.prank(owner);
        vm.expectRevert(NotRegistered.selector);
        _f().upgradeProtocol(address(v1), address(rogue));
    }

    function test_upgradingNeverUsedProtocolReverts() public {
        vm.prank(owner);
        vm.expectRevert(ProtocolNotInstantiated.selector);
        _f().upgradeProtocol(address(v2), address(v2));
    }

    /// Adapter instances are only ever reachable through the vault that owns them.
    function test_strangerCannotUpgradeInstanceDirectly() public {
        address instance = _f().getClone(address(v1));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        UUPSUpgradeable(instance).upgradeToAndCall(address(v2), "");
    }

    /**
     * Lineage decides this, not the guard's category. A different code line is refused however it is
     * categorised - so registering it as staking, where the old category check would have caught it,
     * changes nothing about why it is rejected.
     */
    function test_differentLineageRejectedWhateverTheCategory() public {
        ForeignLendingAdapter foreign = new ForeignLendingAdapter();
        guard.setProtocol(address(foreign), STAKING_ID);
        vm.prank(owner);
        vm.expectRevert(ProtocolLineageMismatch.selector);
        _f().upgradeProtocol(address(v1), address(foreign));
    }

    /// Repointing off a DEPRECATED adapter is the case upgrades exist for, so it must still work.
    function test_upgradeAwayFromDeprecatedAdapter() public {
        guard.setDeprecated(address(v1), true);
        vm.prank(owner);
        _f().upgradeProtocol(address(v1), address(v2));
        assertEq(UpgradeableLendingV1(_f().getClone(address(v1))).adapterVersion(), "2.0.0");
    }

    /**
     * Same category, same storage layout, different protocol. This is the swap the category check
     * cannot see - in production it is Aave's instance repointed at Sky, which would then read
     * Aave's cached receipt tokens as its own without ever reverting.
     */
    function test_sameCategoryDifferentLineageRejected() public {
        ForeignLendingAdapter foreign = new ForeignLendingAdapter();
        guard.setProtocol(address(foreign), LENDING_ID);
        vm.prank(owner);
        vm.expectRevert(ProtocolLineageMismatch.selector);
        _f().upgradeProtocol(address(v1), address(foreign));
    }

    /**
     * Upgrades are one-way. Rolling back to the adapter an instance was upgraded away from passes
     * every other check - same lineage, same category, still guard-registered - so a bug that was
     * already patched could otherwise be put straight back in place.
     */
    function test_downgradeRejected() public {
        vm.prank(owner);
        _f().upgradeProtocol(address(v1), address(v2));
        assertEq(UpgradeableLendingV1(_f().getClone(address(v1))).versionName(), "1.1.2");

        vm.prank(owner);
        vm.expectRevert(ProtocolNotNewer.selector);
        _f().upgradeProtocol(address(v1), address(v1));
    }

    /// Re-applying the version already running is only ever a wasted transaction.
    function test_sameVersionRejected() public {
        vm.prank(owner);
        vm.expectRevert(ProtocolNotNewer.selector);
        _f().upgradeProtocol(address(v1), address(v1));
    }
}
