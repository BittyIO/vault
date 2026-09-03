// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {DeployScript} from "./BaseDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {BittyV1Vault} from "../src/BittyV1Vault.sol";
import {BittyV1VaultBootstrap} from "../src/BittyV1VaultBootstrap.sol";
import {BittyV1ForwarderBootstrap} from "../src/BittyV1ForwarderBootstrap.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {BittyV1SubVault} from "../src/subvault/BittyV1SubVault.sol";
import {BittyV1VaultDeFiFacet} from "../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1VaultFactory} from "../src/BittyV1VaultFactory.sol";
import {BittyV1VaultForwarder} from "../src/BittyV1VaultForwarder.sol";
import {BittyV1AutoYieldKeeper} from "../src/BittyV1AutoYieldKeeper.sol";
import {BITTY_FORWARDER} from "../src/logic/Constants.sol";
import {PaymentLogic} from "../src/logic/PaymentLogic.sol";
import {DeFiLogic} from "../src/logic/DeFiLogic.sol";
import {SubVaultRegistryLogic} from "../src/logic/SubVaultRegistryLogic.sol";
import {GaslessLogic} from "../src/logic/GaslessLogic.sol";
import {RiskLogic} from "../src/logic/RiskLogic.sol";
import {ScheduledPaymentLogic} from "../src/logic/ScheduledPaymentLogic.sol";
import {WhitelistLogic} from "../src/logic/WhitelistLogic.sol";

interface ImmutableCreate2Factory {
    function safeCreate2(bytes32 salt, bytes calldata initCode) external payable returns (address);
    function findCreate2Address(bytes32 salt, bytes calldata initCode) external view returns (address);
}

/**
 * @title Deploy
 * @notice One generation of the subaccount vault stack: logic libraries, forwarder, shared DeFi facet,
 *         auto-yield keeper, sub-vault implementation, main-vault implementation (wired to facet + sub
 *         impl), and the factory.
 * @dev Deterministic throughout. Libraries, facet, sub impl and keeper go through the standard CREATE2
 *      deployer (salt 0); the forwarder, main impl and factory go through the {ImmutableCreate2Factory}
 *      with vanity salts pinned to the canonical addresses. Implementations are NOT initialized here —
 *      the contracts `_disableInitializers()` in their constructors, so the logic contracts are already
 *      locked. Idempotent: every step checks for existing code first.
 *
 *      NOTE: the main-impl init code now embeds (defiFacet, subVaultImpl), so IMPLEMENTATION_SALT must
 *      be re-mined against the hash this logs. The keeper is NOT pinned anywhere in the vault — each
 *      account names its own trigger in storage via setAutoYieldTrigger — so this address is a
 *      deployment record for whoever configures accounts, not a value the contracts check.
 */
contract Deploy is DeployScript {
    ImmutableCreate2Factory constant IMMUTABLE_CREATE2 =
        ImmutableCreate2Factory(0x0000000000FFe8B47B3e2130213B802212439497);
    address constant DEPLOYER = 0x12EE2de7BF086388B1D560eb95e7191Edfab9823;

    address constant SIMPLE_CREATE2 = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 constant FORWARDER_SALT = 0x12ee2de7bf086388b1d560eb95e7191edfab98236f5534bc8159e4001b2cc6ba;
    bytes32 constant FACTORY_SALT = 0x12ee2de7bf086388b1d560eb95e7191edfab98230715e18fc32e70001a6ebc1a;
    bytes32 constant IMPLEMENTATION_SALT = 0x12ee2de7bf086388b1d560eb95e7191edfab9823b41efcf6cabd0600b902d066;

    function deploy() public virtual override {
        _deployLogicLibraries();
        address forwarder = _deployForwarder();
        _deployKeeper(forwarder);
        address defiFacet = _deployFacet();
        address subImpl = _deploySubImplementation(defiFacet);
        address vaultImpl = _deployImplementation(defiFacet, subImpl);
        address bootstrap = _deployBootstrap();
        _deployFactory(vaultImpl, bootstrap);
    }

    /**
     * @dev Salt 0, like the facet and the sub implementation: the address is a pure function of the
     *      bytecode, and this one must never move - it is in the init code of every vault proxy, so a
     *      different bootstrap would relocate every owner's vault. See BittyV1VaultBootstrap.
     */
    function _deployBootstrap() private returns (address bootstrap) {
        bootstrap = _create2("BittyV1VaultBootstrap", type(BittyV1VaultBootstrap).creationCode);
        _reportIfMoved("VAULT_BOOTSTRAP", bootstrap);
        saveAddress("VAULT_BOOTSTRAP", bootstrap);
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

    function _create2Address(bytes32 salt, bytes memory initCode) private pure returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), address(IMMUTABLE_CREATE2), salt, keccak256(initCode)))
                )
            )
        );
    }

    function _create2(string memory name, bytes memory initCode) private returns (address deployed) {
        deployed = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), SIMPLE_CREATE2, bytes32(0), keccak256(initCode)))))
        );
        // Code at a CREATE2 address proves it was deployed from THIS init code - the address is a
        // hash of it - so presence here means "already this exact build", not merely "something is
        // there". That is what makes skipping safe.
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
        console2.log("forwarder PROXY initCode hash (mine against this):");
        console2.logBytes32(keccak256(initCode));

        forwarder = _create2Address(FORWARDER_SALT, initCode);
        require(forwarder == BITTY_FORWARDER, "BITTY_FORWARDER constant is stale: re-mine and update Constants.sol");
        if (forwarder.code.length == 0) {
            IMMUTABLE_CREATE2.safeCreate2(FORWARDER_SALT, initCode);
            console2.log("forwarder proxy deployed at           ", forwarder);
        }

        address build = _create2("BittyV1VaultForwarder", type(BittyV1VaultForwarder).creationCode);
        if (address(uint160(uint256(vm.load(forwarder, ERC1967Utils.IMPLEMENTATION_SLOT)))) != build) {
            UUPSUpgradeable(forwarder).upgradeToAndCall(build, "");
            console2.log("forwarder moved to implementation     ", build);
        }

        BittyV1VaultForwarder fwd = BittyV1VaultForwarder(payable(forwarder));
        if (fwd.owner() == address(0)) {
            address forwarderOwner = getAddress("BITTY_FORWARDER_OWNER");
            fwd.initialize(forwarderOwner);
            console2.log("forwarder owner set                   ", forwarderOwner);
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
        keeper = _create2(
            "BittyV1AutoYieldKeeper",
            abi.encodePacked(type(BittyV1AutoYieldKeeper).creationCode, abi.encode(getAddress("BITTY_FORWARDER_OWNER")))
        );
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
        console2.log("implementation initCode hash (mine against this):");
        console2.logBytes32(keccak256(initCode));

        vaultImpl = _create2Address(IMPLEMENTATION_SALT, initCode);
        if (vaultImpl.code.length == 0) {
            IMMUTABLE_CREATE2.safeCreate2(IMPLEMENTATION_SALT, initCode);
            console2.log("BittyV1Vault implementation deployed at", vaultImpl);
        } else {
            console2.log("BittyV1Vault implementation already at ", vaultImpl);
        }
        _reportIfMoved("VAULT_IMPLEMENTATION", vaultImpl);
        saveAddress("VAULT_IMPLEMENTATION", vaultImpl);
    }

    function _deployFactory(address vaultImpl, address bootstrap) private {
        bytes memory initCode = type(BittyV1VaultFactory).creationCode;
        console2.log("factory initCode hash (mine against this):");
        console2.logBytes32(keccak256(initCode));

        address factory = _create2Address(FACTORY_SALT, initCode);
        if (factory.code.length == 0) {
            IMMUTABLE_CREATE2.safeCreate2(FACTORY_SALT, initCode);
            console2.log("BittyV1VaultFactory deployed at       ", factory);
        } else {
            console2.log("BittyV1VaultFactory already deployed at", factory);
        }

        if (BittyV1VaultFactory(factory).vaultImplementation() == address(0)) {
            BittyV1VaultFactory(factory).initialize(vaultImpl, getAddress("WETH"), bootstrap);
        }
        _reportIfMoved("BITTY_VAULT_FACTORY", factory);
        saveAddress("BITTY_VAULT_FACTORY", factory);
        console2.log("BittyV1VaultFactory            ", factory);
    }
}
