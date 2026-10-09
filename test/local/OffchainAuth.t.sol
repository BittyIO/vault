// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";

/// The off-chain auth callbacks an intent adapter asks the host, reached through the host's fallback.
interface IOffchainAuth {
    function isOffchainOrderAuthorized(address signer, address sellToken, address buyToken, uint256 sellAmount)
        external
        view
        returns (bool);
    function isOffchainCancellationAuthorized(address signer) external view returns (bool);
}

/**
 * What a CoW clone asks its host before honouring an off-chain signature.
 *
 * Placing and cancelling are deliberately NOT the same question, and the gap is the interesting part:
 * a paused account must still be able to withdraw the orders it already signed.
 */
contract OffchainAuthTest is Test {
    BittyV1VaultDeFiFacet facet;
    BittyV1Vault vault;

    address owner = makeAddr("owner");
    address subOwner = makeAddr("subOwner");
    address stranger = makeAddr("stranger");
    address gasWrapped = makeAddr("gasWrapped");
    address sell = makeAddr("sell");
    address buy = makeAddr("buy");

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        facet = new BittyV1VaultDeFiFacet();
        BittyV1Vault impl = new BittyV1Vault(address(facet));
        bytes memory init =
            abi.encodeCall(BittyV1Vault.initialize, (owner, gasWrapped, false, address(0), 0, new bytes[](0)));
        vault = BittyV1Vault(payable(new ERC1967Proxy(address(impl), init)));
    }

    function _auth() internal view returns (IOffchainAuth) {
        return IOffchainAuth(address(vault));
    }

    function test_ownerMayCancel() public view {
        assertTrue(_auth().isOffchainCancellationAuthorized(owner), "the account's owner may cancel");
    }

    function test_strangerMayNotCancel() public view {
        assertFalse(_auth().isOffchainCancellationAuthorized(stranger), "nobody else may");
    }
}
