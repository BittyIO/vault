// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {DeployScript} from "./BaseDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {BittyV1Vault} from "../src/BittyV1Vault.sol";
import {BittyV1SubVault} from "../src/subvault/BittyV1SubVault.sol";
import {BittyV1VaultDeFiFacet} from "../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1VaultFactory} from "../src/BittyV1VaultFactory.sol";
import {BittyV1VaultForwarder} from "../src/BittyV1VaultForwarder.sol";
import {BittyV1AutoYieldKeeper} from "../src/BittyV1AutoYieldKeeper.sol";
import {BITTY_FORWARDER} from "../src/logic/Constants.sol";
import {PaymentLogic} from "../src/logic/PaymentLogic.sol";
import {DeFiLogic} from "../src/logic/DeFiLogic.sol";
import {SubVaultRegistryLogic} from "../src/logic/SubVaultRegistryLogic.sol";

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
    bytes32 constant FORWARDER_SALT = 0x12ee2de7bf086388b1d560eb95e7191edfab9823f81fb600688d6000a43d75f0;
    bytes32 constant FACTORY_SALT = 0x12ee2de7bf086388b1d560eb95e7191edfab98230b0822a4ede42c0145a1e0ab;
    bytes32 constant IMPLEMENTATION_SALT = 0x12ee2de7bf086388b1d560eb95e7191edfab982389b154b0ba1204002d5beccd;

    function deploy() public virtual override {
        _deployLogicLibraries();
        address forwarder = _deployForwarder();
        address defiFacet = _deployFacet();
        _deployKeeper(forwarder);
        address subImpl = _deploySubImplementation(defiFacet);
        address vaultImpl = _deployImplementation(defiFacet, subImpl);
        _deployFactory(vaultImpl);
    }

    function _deployLogicLibraries() private {
        _deployLibrary("PaymentLogic", address(PaymentLogic), type(PaymentLogic).creationCode);
        _deployLibrary("DeFiLogic", address(DeFiLogic), type(DeFiLogic).creationCode);
        _deployLibrary(
            "SubVaultRegistryLogic", address(SubVaultRegistryLogic), type(SubVaultRegistryLogic).creationCode
        );
        saveAddress("PAYMENT_LOGIC", address(PaymentLogic));
        saveAddress("DEFI_LOGIC", address(DeFiLogic));
        saveAddress("SUB_VAULT_REGISTRY_LOGIC", address(SubVaultRegistryLogic));
    }

    function _deployLibrary(string memory name, address linked, bytes memory initCode) private {
        if (linked.code.length > 0) {
            console2.log(string.concat(name, " already at"), linked);
            return;
        }
        address deployed = _create2(name, initCode);
        require(deployed == linked, string.concat(name, " pin is stale: re-pin foundry.toml and re-mine"));
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
        if (deployed.code.length > 0) {
            console2.log(string.concat(name, " already at"), deployed);
            return deployed;
        }
        (bool ok, bytes memory ret) = SIMPLE_CREATE2.call(abi.encodePacked(bytes32(0), initCode));
        require(ok && ret.length == 20 && address(bytes20(ret)) == deployed, "CREATE2 deploy failed");
        console2.log(string.concat(name, " deployed at"), deployed);
    }

    function _deployForwarder() private returns (address forwarder) {
        bytes memory initCode = type(BittyV1VaultForwarder).creationCode;
        console2.log("forwarder initCode hash (mine against this):");
        console2.logBytes32(keccak256(initCode));
        forwarder = _create2Address(FORWARDER_SALT, initCode);
        require(forwarder == BITTY_FORWARDER, "BITTY_FORWARDER constant is stale: re-mine and update Constants.sol");
        if (forwarder.code.length == 0) {
            IMMUTABLE_CREATE2.safeCreate2(FORWARDER_SALT, initCode);
            console2.log("BittyV1VaultForwarder deployed at     ", forwarder);
        } else {
            console2.log("BittyV1VaultForwarder already at      ", forwarder);
            return forwarder;
        }

        BittyV1VaultForwarder fwd = BittyV1VaultForwarder(forwarder);
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
        saveAddress("DEFI_FACET", facet);
    }

    function _deployKeeper(address forwarder) private returns (address keeper) {
        keeper = _create2(
            "BittyV1AutoYieldKeeper",
            abi.encodePacked(type(BittyV1AutoYieldKeeper).creationCode, abi.encode(getAddress("BITTY_FORWARDER_OWNER")))
        );
        saveAddress("BITTY_AUTO_YIELD_KEEPER", keeper);

        // No constant to pin any more, and so nothing here can go stale. The auto-yield gate reads a
        // STORAGE slot the owner sets with setAutoYieldTrigger, which is why a placeholder could reach
        // Sepolia under the old shape and cannot now: a wrong address is fixable on the vault instead of
        // welded into a facet nobody can replace. A vault starts with no trigger, so auto-yield is
        // owner-only until this address is named on it.
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
        // Not initialized: BittyV1Vault._disableInitializers() locks the logic contract at construction.
        saveAddress("VAULT_IMPLEMENTATION", vaultImpl);
    }

    function _deployFactory(address vaultImpl) private {
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
            BittyV1VaultFactory(factory).initialize(vaultImpl, getAddress("WETH"));
        }
        saveAddress("BITTY_VAULT_FACTORY", factory);
        console2.log("BittyV1VaultFactory            ", factory);
    }
}
