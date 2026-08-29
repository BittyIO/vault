// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1SubVault} from "../../src/subvault/BittyV1SubVault.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";

/// The off-chain auth callbacks an intent adapter asks the host, reached through the host's fallback.
interface IOffchainAuth {
    function isOffchainOrderAuthorized(address signer, address sellToken, address buyToken, uint256 sellAmount)
        external
        view
        returns (bool);
    function isOffchainCancellationAuthorized(address signer) external view returns (bool);
    function disableTradeUntilTimestamp(uint256 ts) external;
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
    BittyV1SubVault subImpl;

    address owner = makeAddr("owner");
    address subOwner = makeAddr("subOwner");
    address stranger = makeAddr("stranger");
    address weth = makeAddr("weth");
    address sell = makeAddr("sell");
    address buy = makeAddr("buy");

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        facet = new BittyV1VaultDeFiFacet();
        subImpl = new BittyV1SubVault(address(facet));
        BittyV1Vault impl = new BittyV1Vault(address(facet), address(subImpl));
        bytes memory init = abi.encodeCall(BittyV1Vault.initialize, (owner, weth, false, address(0), 0));
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

    /**
     * The reason cancellation does not reuse the order check. Pausing trading must not also trap the
     * orders already signed — otherwise pausing would be the one action that guarantees they keep
     * filling, which is the opposite of what an owner reaching for it wants.
     */
    function test_cancellationStillAuthorizedWhileTradingIsPaused() public {
        vm.prank(owner);
        _auth().disableTradeUntilTimestamp(block.timestamp + 7 days);

        assertFalse(_auth().isOffchainOrderAuthorized(owner, sell, buy, 0), "placing is refused while paused");
        assertTrue(_auth().isOffchainCancellationAuthorized(owner), "cancelling is not");
    }

    /// Each account answers for itself: a sub vault's owner cancels its orders, the main owner does not.
    function test_subVaultAnswersForItsOwnOwner() public {
        vm.prank(owner);
        (, address account) = vault.createSubVault(subOwner, false, uint64(block.timestamp) + 365 days);
        IOffchainAuth sub = IOffchainAuth(account);

        assertTrue(sub.isOffchainCancellationAuthorized(subOwner), "the sub's own owner may cancel");
        assertFalse(sub.isOffchainCancellationAuthorized(owner), "the main owner is not the sub's owner");
    }
}
