// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {BittyV1VaultFactoryTest} from "./BittyV1VaultFactory.t.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {effectiveAssetManager} from "../helpers/AssetManagerView.sol";

/**
 * @notice Batching must grant nothing. Each entry is self-delegatecalled, so msg.sender and the
 *         ERC-2771 sender both resolve exactly as they would for the same call sent on its own.
 */
contract MulticallTest is BittyV1VaultFactoryTest {
    address internal batchOwner = address(0xBA7C4);

    function _vault() internal returns (BittyV1Vault v) {
        _initFactory();
        vm.prank(batchOwner);
        factory.activateVault();
        v = BittyV1Vault(payable(factory.vaultAddress(batchOwner)));
    }

    function _one(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    /**
     * The ordinary path: owner pays gas from their own wallet, no forwarder involved.
     */
    function test_ownerBatchesFromTheirOwnWallet() public {
        BittyV1Vault v = _vault();
        address mgr = makeAddr("mgr");

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IBittyV1Owner.updateAssets, (_one(wethAddress), new address[](0)));
        calls[1] = abi.encodeCall(IBittyV1Owner.setAssetManager, (mgr, type(uint64).max));

        vm.prank(batchOwner);
        v.multicall(calls);

        assertTrue(v.isAssetAllowed(wethAddress), "asset added");
        assertEq(effectiveAssetManager(address(v)), mgr, "manager set, in the same transaction");
    }

    /**
     * Batching cannot be used to act as someone else: a stranger's batch is refused per call.
     */
    function test_batchDoesNotEscalate() public {
        BittyV1Vault v = _vault();
        address stranger = makeAddr("stranger");

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(IBittyV1Owner.setAssetManager, (stranger, type(uint64).max));

        vm.prank(stranger);
        vm.expectRevert();
        v.multicall(calls);

        assertEq(effectiveAssetManager(address(v)), batchOwner, "unchanged");
    }

    /**
     * A failing entry reverts the whole batch — no partial application.
     */
    function test_batchIsAllOrNothing() public {
        BittyV1Vault v = _vault();

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IBittyV1Owner.updateAssets, (_one(wethAddress), new address[](0)));
        // Not guard-registered, so _addAsset reverts NotRegistered.
        calls[1] = abi.encodeCall(IBittyV1Owner.updateAssets, (_one(address(0xDEAD)), new address[](0)));

        vm.prank(batchOwner);
        vm.expectRevert();
        v.multicall(calls);

        assertFalse(v.isAssetAllowed(wethAddress), "the first call was rolled back too");
    }
}
