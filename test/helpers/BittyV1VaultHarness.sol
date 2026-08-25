// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1VaultBase} from "../../src/BittyV1VaultBase.sol";

abstract contract BittyV1VaultHarness is BittyV1Vault, BittyV1VaultDeFiFacet {
    /// The harness IS the vault, so it is its own facet — the fallback never fires here.
    constructor(address autoYieldKeeper) BittyV1Vault(address(0), autoYieldKeeper) {}

    // Inheriting both halves means each context hook has two bases again. Resolved to the vault's,
    // which are the ERC-2771 ones — the same resolution production gets.
    function _msgSender() internal view override(BittyV1Vault, BittyV1VaultBase) returns (address) {
        return BittyV1Vault._msgSender();
    }

    function _msgData() internal view override(BittyV1Vault, BittyV1VaultBase) returns (bytes calldata) {
        return BittyV1Vault._msgData();
    }

    function _contextSuffixLength() internal view override(BittyV1Vault, BittyV1VaultBase) returns (uint256) {
        return BittyV1Vault._contextSuffixLength();
    }
}
