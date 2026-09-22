// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {DeployScript} from "./BaseDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {BittyV1Vault} from "../src/BittyV1Vault.sol";
import {BittyV1ForwarderBootstrap} from "../src/BittyV1ForwarderBootstrap.sol";
import {BittyV1VaultFactoryBootstrap} from "../src/BittyV1VaultFactoryBootstrap.sol";
import {BittyV1VaultBootstrap} from "../src/BittyV1VaultBootstrap.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {BittyV1SubVault} from "../src/subvault/BittyV1SubVault.sol";
import {BittyV1VaultDeFiFacet} from "../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1VaultFactory} from "../src/BittyV1VaultFactory.sol";
import {BittyV1VaultForwarder} from "../src/BittyV1VaultForwarder.sol";
import {BittyV1AutoYieldKeeper} from "../src/BittyV1AutoYieldKeeper.sol";
import {
    BITTY_FEE_COLLECTOR,
    BITTY_FORWARDER,
    BITTY_GUARD,
    BITTY_VAULT_BOOTSTRAP,
    BITTY_VAULT_FACTORY_BOOTSTRAP,
    CFG_GAS_WRAPPED,
    CFG_OWNER
} from "../src/logic/Constants.sol";
import {IBittyV1Guard, IMPLEMENTATION_VAULT} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {PaymentLogic} from "../src/logic/PaymentLogic.sol";
import {DeFiLogic} from "../src/logic/DeFiLogic.sol";
import {SubVaultRegistryLogic} from "../src/logic/SubVaultRegistryLogic.sol";
import {GaslessLogic} from "../src/logic/GaslessLogic.sol";
import {RiskLogic} from "../src/logic/RiskLogic.sol";
import {ScheduledPaymentLogic} from "../src/logic/ScheduledPaymentLogic.sol";
import {WhitelistLogic} from "../src/logic/WhitelistLogic.sol";

/**
 * @title Deploy
 * @notice One generation of the subaccount vault stack: logic libraries, forwarder, shared DeFi facet,
 *         auto-yield keeper, sub-vault implementation, main-vault implementation (wired to facet + sub
 *         impl), and the factory.
 * @dev Deterministic throughout, and NO vanity mining: everything goes through the standard salt-0
 *      CREATE2 deployer, so each address is a plain function of its init code and identical on every
 *      chain. The forwarder and factory sit at fixed addresses because they are proxies born on constant
 *      bootstraps, not because their salts were mined. Implementations are NOT initialized here — the
 *      contracts `_disableInitializers()` in their constructors, so the logic contracts are already
 *      locked. Idempotent: every step checks for existing code first.
 *
 *      NOTE: the keeper is NOT pinned anywhere in the vault — each account names its own trigger in
 *      storage via setAutoYieldTrigger — so its address is a deployment record for whoever configures
 *      accounts, not a value the contracts check.
 */
contract Deploy is DeployScript {
    address constant SIMPLE_CREATE2 = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function deploy() public virtual override {
        require(
            IBittyV1Guard(BITTY_GUARD).getAddress(CFG_OWNER) != address(0),
            "CFG_OWNER not set in guard - configure it before deploy"
        );
        require(
            IBittyV1Guard(BITTY_GUARD).getAddress(CFG_GAS_WRAPPED) != address(0),
            "CFG_GAS_WRAPPED not set in guard - configure it before deploy"
        );

        address forwarder = _deployForwarder();
        _deployKeeper(forwarder);
        address vaultImpl = deployImplementationChain();

        if (IBittyV1Guard(BITTY_GUARD).latestImplementation(IMPLEMENTATION_VAULT) != vaultImpl) {
            IBittyV1Guard(BITTY_GUARD).setImplementation(vaultImpl, IMPLEMENTATION_VAULT);
        }

        _deployBootstrap();
        _deployFactory();
    }

    /**
     * @notice Deploy ONLY the version-bearing implementation chain — logic libraries, shared DeFi
     *         facet, sub-vault implementation and main-vault implementation — and return the new main
     *         implementation address. This is what {DeployNewVersion} runs for an upgrade.
     * @dev Every step is deterministic CREATE2 and idempotent: a piece whose bytecode has not changed
     *      is already at its address (the address IS a hash of the init code), so {_create2} finds code
     *      there and skips it. Only what actually changed gets deployed. Changing a linked logic library
     *      relocates the facet and the implementation too, so those redeploy in step.
     */
    function deployImplementationChain() internal returns (address vaultImpl) {
        _deployLogicLibraries();
        address defiFacet = _deployFacet();
        address subImpl = _deploySubImplementation(defiFacet);
        vaultImpl = _deployImplementation(defiFacet, subImpl);
    }

    /**
     * @dev Salt 0, like the facet and the sub implementation: the address is a pure function of the
     *      bytecode, and this one must never move - it is in the init code of every vault proxy, so a
     *      different bootstrap would relocate every owner's vault. See BittyV1VaultBootstrap.
     */
    function _deployBootstrap() private {
        address bootstrap = _create2("BittyV1VaultBootstrap", type(BittyV1VaultBootstrap).creationCode);
        require(bootstrap == BITTY_VAULT_BOOTSTRAP, "BITTY_VAULT_BOOTSTRAP constant is stale: update Constants.sol");
    }

    /**
     * @dev ALL SEVEN, not the three that used to be listed here. Every one of them is delegatecalled by
     *      the vault at an address solc baked in at compile time, so a library that is linked but never
     *      deployed leaves the implementation calling into empty code - which does not revert at deploy
     *      time, only later, on the first call that touches it.
     */
    function _deployLogicLibraries() private {
        _deployLibrary("PaymentLogic", address(PaymentLogic), type(PaymentLogic).creationCode);
        _deployLibrary("DeFiLogic", address(DeFiLogic), type(DeFiLogic).creationCode);
        _deployLibrary(
            "SubVaultRegistryLogic", address(SubVaultRegistryLogic), type(SubVaultRegistryLogic).creationCode
        );
        _deployLibrary("GaslessLogic", address(GaslessLogic), type(GaslessLogic).creationCode);
        _deployLibrary("RiskLogic", address(RiskLogic), type(RiskLogic).creationCode);
        _deployLibrary(
            "ScheduledPaymentLogic", address(ScheduledPaymentLogic), type(ScheduledPaymentLogic).creationCode
        );
        _deployLibrary("WhitelistLogic", address(WhitelistLogic), type(WhitelistLogic).creationCode);
        saveAddress("PAYMENT_LOGIC", address(PaymentLogic));
        saveAddress("DEFI_LOGIC", address(DeFiLogic));
        saveAddress("SUB_VAULT_REGISTRY_LOGIC", address(SubVaultRegistryLogic));
        saveAddress("GASLESS_LOGIC", address(GaslessLogic));
        saveAddress("RISK_LOGIC", address(RiskLogic));
        saveAddress("SCHEDULED_PAYMENT_LOGIC", address(ScheduledPaymentLogic));
        saveAddress("WHITELIST_LOGIC", address(WhitelistLogic));
    }

    /**
     * @dev Decided on the address the CURRENT init code hashes to, never on `linked` having code.
     *      `linked` is what solc baked into every contract that calls this library, so asking whether
     *      IT has code answers "was a library ever deployed here", not "is that library this build" -
     *      and after a source change the old one is still sitting there, so the deploy is skipped and
     *      the new facet and implementation are linked against stale logic. Nothing reverts; the
     *      wrong code just runs.
     *
     *      A CREATE2 address IS a hash of the init code, so equality here is code equality: if the
     *      derived address differs from `linked`, this build is not what the callers were compiled
     *      against, and the only safe move is to stop.
     */
    function _deployLibrary(string memory name, address linked, bytes memory initCode) private {
        address expected = _simpleCreate2Address(initCode);
        if (expected != linked) {
            console2.log(string.concat(name, " linked at    "), linked);
            console2.log(string.concat(name, " this build is"), expected);
            revert(
                string.concat(
                    name, " changed: callers were compiled against the old address. Rebuild, then re-mine the salts."
                )
            );
        }
        _create2(name, initCode);
    }

    function _simpleCreate2Address(bytes memory initCode) private pure returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), SIMPLE_CREATE2, bytes32(0), keccak256(initCode)))))
        );
    }

    /**
     * @dev Whether the recorded deployment is still the build in this working tree. Every address
     *      here is CREATE2-derived, so a changed contract lands somewhere new and the recorded one
     *      keeps its old code - which is exactly the case the deployments file cannot tell you about,
     *      because it only ever holds an address. Logged rather than reverted: moving is legitimate,
     *      silently carrying the old address into the guard or the web config is not.
     */
    function _reportIfMoved(string memory name, address deployedNow) private view {
        address recorded = getAddressOr(name, address(0));
        if (recorded != address(0) && recorded != deployedNow) {
            console2.log(string.concat("!! ", name, " MOVED. was"), recorded);
            console2.log(string.concat("!! ", name, " now       "), deployedNow);
            console2.log("!! update the guard registration and the web config for this address");
        }
    }

    function _create2(string memory name, bytes memory initCode) private returns (address deployed) {
        deployed = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), SIMPLE_CREATE2, bytes32(0), keccak256(initCode)))))
        );
        if (deployed.code.length > 0) {
            console2.log(string.concat(name, " already at"), deployed);
            return deployed;
        }
        (bool ok, bytes memory ret) = SIMPLE_CREATE2.call(abi.encodePacked(bytes32(0), initCode));
        require(ok && ret.length == 20 && address(bytes20(ret)) == deployed, "CREATE2 deploy failed");
        console2.log(string.concat(name, " deployed at"), deployed);
    }

    /**
     * @dev Born on the BOOTSTRAP, never on the build - see BittyV1ForwarderBootstrap. The forwarder is
     *      a compile-time constant in every vault, so tying its address to the build meant a new vault
     *      implementation, a new factory and two fresh vanity mines every time the relay logic changed.
     *      With a constant here the address survives every future forwarder release.
     */
    function _deployForwarder() private returns (address forwarder) {
        address bootstrap = _create2("BittyV1ForwarderBootstrap", type(BittyV1ForwarderBootstrap).creationCode);
        bytes memory initCode = abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(bootstrap, bytes("")));
        forwarder = _create2("BittyV1VaultForwarderProxy", initCode);
        require(forwarder == BITTY_FORWARDER, "BITTY_FORWARDER constant is stale: update Constants.sol");

        address build = _create2("BittyV1VaultForwarder", type(BittyV1VaultForwarder).creationCode);
        if (address(uint160(uint256(vm.load(forwarder, ERC1967Utils.IMPLEMENTATION_SLOT)))) != build) {
            UUPSUpgradeable(forwarder).upgradeToAndCall(build, "");
            console2.log("forwarder moved to implementation     ", build);
        }
        BittyV1VaultForwarder fwd = BittyV1VaultForwarder(payable(forwarder));
        if (!fwd.approvedRelayers(BITTY_FEE_COLLECTOR)) {
            fwd.setRelayerApproval(BITTY_FEE_COLLECTOR, true);
            console2.log("fee collector approved as relayer     ", BITTY_FEE_COLLECTOR);
        }
        address relayer = getAddressOr("BITTY_RELAYER", address(0));
        if (relayer != address(0) && !fwd.approvedRelayers(relayer)) {
            fwd.setRelayerApproval(relayer, true);
            console2.log("relayer approved                      ", relayer);
        }
    }

    function _deployFacet() private returns (address facet) {
        facet = _create2("BittyV1VaultDeFiFacet", type(BittyV1VaultDeFiFacet).creationCode);
        _reportIfMoved("DEFI_FACET", facet);
        saveAddress("DEFI_FACET", facet);
    }

    function _deployKeeper(address forwarder) private returns (address keeper) {
        keeper = _create2("BittyV1AutoYieldKeeper", type(BittyV1AutoYieldKeeper).creationCode);
        saveAddress("BITTY_AUTO_YIELD_KEEPER", keeper);

        console2.log("BittyV1AutoYieldKeeper at              ", keeper);

        BittyV1AutoYieldKeeper k = BittyV1AutoYieldKeeper(keeper);
        if (k.trustedForwarders(forwarder)) return keeper;
        if (k.owner() != tx.origin) {
            console2.log("ACTION REQUIRED - keeper owner must call setForwarder(forwarder, true)");
            console2.log("  keeper                       ", keeper);
            console2.log("  forwarder                    ", forwarder);
            return keeper;
        }
        k.setForwarder(forwarder, true);
        console2.log("keeper trusts forwarder        ", forwarder);
    }

    function _deploySubImplementation(address defiFacet) private returns (address subImpl) {
        bytes memory initCode = abi.encodePacked(type(BittyV1SubVault).creationCode, abi.encode(defiFacet));
        subImpl = _create2("BittyV1SubVault", initCode);
        saveAddress("SUB_VAULT_IMPLEMENTATION", subImpl);
    }

    function _deployImplementation(address defiFacet, address subImpl) private returns (address vaultImpl) {
        bytes memory initCode = abi.encodePacked(type(BittyV1Vault).creationCode, abi.encode(defiFacet, subImpl));
        vaultImpl = _create2("BittyV1Vault", initCode);
        _reportIfMoved("VAULT_IMPLEMENTATION", vaultImpl);
        saveAddress("VAULT_IMPLEMENTATION", vaultImpl);
    }

    function _deployFactory() private {
        (address factory, address build) = _deployFactoryBuild();
        if (_implementationOf(factory) != build) _upgradeFactory(factory, build);
        _reportIfMoved("BITTY_VAULT_FACTORY", factory);
        saveAddress("BITTY_VAULT_FACTORY", factory);
        console2.log("BittyV1VaultFactory            ", factory);
    }

    /**
     * @dev The three CREATE2 pieces of the factory, each skipped when already there: the constant
     *      bootstrap, the proxy born on it (the address every vault is CREATE2'd off, so it never
     *      moves), and the current logic build. Deploying the build does NOT point the proxy at it -
     *      that is {_upgradeFactory}, an owner action, kept separate so {DeployFactoryUpgrade} can
     *      hand it to a Safe when the deploy key is not the owner.
     */
    function _deployFactoryBuild() internal returns (address factory, address build) {
        address bootstrap = _create2("BittyV1VaultFactoryBootstrap", type(BittyV1VaultFactoryBootstrap).creationCode);
        require(
            bootstrap == BITTY_VAULT_FACTORY_BOOTSTRAP,
            "BITTY_VAULT_FACTORY_BOOTSTRAP constant is stale: update Constants.sol"
        );
        bytes memory initCode = abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(bootstrap, bytes("")));
        factory = _create2("BittyV1VaultFactoryProxy", initCode);
        build = _create2("BittyV1VaultFactory", type(BittyV1VaultFactory).creationCode);
    }

    function _upgradeFactory(address factory, address build) internal {
        UUPSUpgradeable(factory).upgradeToAndCall(build, "");
        console2.log("factory moved to implementation       ", build);
    }

    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
    }
}
