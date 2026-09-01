// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {IBittyV1Vault} from "../../src/interfaces/IBittyV1Vault.sol";

/**
 * The native-ETH payout path: a scheduled payment whose asset is address(0) is funded from the vault's
 * WETH and unwrapped so the payee receives real ETH — never WETH.
 */
contract VaultNativePaymentTest is Test {
    BittyV1VaultDeFiFacet facet;
    BittyV1Vault vault;
    WETH weth;

    address owner = makeAddr("owner");
    address payee = makeAddr("payee");

    function setUp() public {
        facet = new BittyV1VaultDeFiFacet();
        weth = new WETH();
        BittyV1Vault impl = new BittyV1Vault(address(facet), address(0));
        vault = BittyV1Vault(
            payable(new ERC1967Proxy(
                    address(impl), abi.encodeCall(BittyV1Vault.initialize, (owner, address(weth), false, address(0), 0))
                ))
        );
        // Back the vault with real WETH (WETH contract holds the ETH, so it can be unwrapped later).
        vm.deal(address(this), 5 ether);
        weth.deposit{value: 5 ether}();
        weth.transfer(address(vault), 5 ether);
    }

    function test_nativeScheduledPaymentDeliversRealEth() public {
        vm.prank(owner);
        uint256 id = vault.addScheduledPayment(
            IBittyV1Vault.ScheduledPayment({
                recipient: payee,
                remainingPaymentCount: 3,
                isImmutable: false,
                payWithInsufficientBalance: false,
                trigger: address(0),
                assetAddress: address(0), // native
                amount: 1 ether,
                startTimestamp: block.timestamp,
                paymentInterval: 7 days
            })
        );

        uint256 balBefore = payee.balance;
        vault.payScheduled(id, new address[](0));

        assertEq(payee.balance - balBefore, 1 ether, "payee received real ETH, not WETH");
        assertEq(weth.balanceOf(payee), 0, "no WETH landed on the payee");
        assertEq(weth.balanceOf(address(vault)), 4 ether, "vault WETH reduced by the payout");
    }
}
