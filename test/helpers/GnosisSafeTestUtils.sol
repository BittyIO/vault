// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {GnosisSafe} from "safe-smart-account/contracts/GnosisSafe.sol";
import {Enum} from "safe-smart-account/contracts/common/Enum.sol";

/// @dev Signs and executes a Gnosis Safe v1.3 `execTransaction` (1-of-1 or single-signer tests).
abstract contract GnosisSafeTestUtils is Test {
    function _signSafeTransaction(address safeAddress, uint256 ownerPrivateKey, address to, bytes memory data)
        internal
        returns (bytes memory signatures)
    {
        GnosisSafe safe = GnosisSafe(payable(safeAddress));

        bytes32 txHash = safe.getTransactionHash(
            to, 0, data, Enum.Operation.Call, 0, 0, 0, address(0), payable(address(0)), safe.nonce()
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, txHash);
        signatures = abi.encodePacked(r, s, v);
    }

    function _gnosisSafeExecTransaction(address safeAddress, uint256 ownerPrivateKey, address to, bytes memory data)
        internal
    {
        GnosisSafe safe = GnosisSafe(payable(safeAddress));
        bytes memory signatures = _signSafeTransaction(safeAddress, ownerPrivateKey, to, data);

        bool success = safe.execTransaction(
            to, 0, data, Enum.Operation.Call, 0, 0, 0, address(0), payable(address(0)), signatures
        );
        assertTrue(success, "Gnosis Safe execTransaction failed");
    }
}
