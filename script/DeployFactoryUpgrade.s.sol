// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Deploy} from "./Deploy.s.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Create2} from "openzeppelin-contracts/contracts/utils/Create2.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IBittyV1Guard} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {BittyV1VaultFactory} from "../src/BittyV1VaultFactory.sol";
import {BITTY_GUARD, BITTY_VAULT_BOOTSTRAP, CFG_OWNER} from "../src/logic/Constants.sol";

/**
 * @title DeployFactoryUpgrade
 * @notice Ship a NEW factory logic build and point the factory proxy at it - and nothing else. The
 *         proxy stays where it is (every vault address is CREATE2'd off it), so this is an upgrade,
 *         never a redeploy. Use it when the factory's OWN logic changes, such as the shape of the
 *         vault `initialize` it encodes; a vault version bump alone does not need it.
 * @dev Deploys the build unconditionally (idempotent CREATE2: an unchanged build is already at its
 *      address and is skipped). The UPGRADE is the factory owner's action, and that owner is the guard's
 *      configured Bitty owner - on production a Safe, not a deploy key. When the broadcasting key IS
 *      the owner the upgrade is sent; otherwise the exact transaction is printed for the Safe to
 *      submit, the same way {DeployNewVersion} hands over guard registration.
 *
 *      Ordering: a factory build that encodes a new `initialize` shape only works against a vault
 *      implementation that has it. Register that implementation on the guard first, or submit both
 *      from the Safe in one multisend, so activation never lands on a mismatched pair.
 *
 *      Run:  forge script script/DeployFactoryUpgrade.s.sol:DeployFactoryUpgrade --broadcast -vvvv
 */
contract DeployFactoryUpgrade is Deploy {
    function deploy() public override {
        (address factory, address build) = _deployFactoryBuild();
        saveAddress("BITTY_VAULT_FACTORY", factory);
        _assertVaultAddressesDoNotMove(factory);

        console2.log("----------------------------------------");
        console2.log("factory proxy                 ", factory);
        console2.log("factory build                 ", build);

        address current = _implementationOf(factory);
        if (current == build) {
            console2.log("factory: already on this build (nothing to submit)");
            return;
        }
        console2.log("factory currently on          ", current);

        address owner = IBittyV1Guard(BITTY_GUARD).getAddress(CFG_OWNER);
        if (tx.origin == owner) {
            _upgradeFactory(factory, build);
            return;
        }

        console2.log("FACTORY UPGRADE - submit from the factory owner (the guard's configured owner):");
        console2.log("  owner      ", owner);
        console2.log("  to (proxy) ", factory);
        console2.log("  function   upgradeToAndCall(address,bytes)");
        console2.log("  args       ", build, "0x");
        console2.log("  calldata:");
        console2.logBytes(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (build, "")));
    }

    /**
     * @dev The new build's constructor already pins the vault-proxy init-code hash, but that constant
     *      is updatable by hand; this is the independent end-to-end check. It asks the LIVE factory for
     *      a probe owner's counterfactual address and recomputes the same prediction from THIS
     *      compilation's {ERC1967Proxy} bytes — if they differ, the upgrade would silently relocate
     *      every un-activated vault address, so the script stops before anything is submitted.
     */
    function _assertVaultAddressesDoNotMove(address factory) private view {
        address probe = address(1);
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(BITTY_VAULT_BOOTSTRAP, bytes(""))));
        address expected = Create2.computeAddress(keccak256(abi.encodePacked(probe)), initCodeHash, factory);
        try BittyV1VaultFactory(factory).vaultAddress(probe) returns (address live) {
            require(live == expected, "DeployFactoryUpgrade: vaultAddress would move (proxy init-code drift)");
        } catch {
            console2.log("vaultAddress probe skipped (factory proxy not on a live build yet)");
        }
    }
}
