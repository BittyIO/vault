// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {MockLendingProtocol} from "../helpers/MockLendingProtocol.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {IBittyV1Vault} from "../../src/interfaces/IBittyV1Vault.sol";
import {BITTY_GUARD, STABLE_COIN_CATEGORY} from "../../src/logic/Constants.sol";

interface IVaultDeFi {
    function deposit(address protocol, address asset, uint256 amount) external;
}

/**
 * Payments on the new contracts: the PaymentLogic port on ERC-7201 storage — owner send, a scheduled
 * payment from the vault balance, and the reworked `payScheduled` shortfall top-up sourcing from the
 * vault's OWN position straight to the payee.
 */
contract VaultPaymentsTest is Test {
    BittyV1VaultDeFiFacet facet;
    BittyV1Vault vault;
    MockERC20 usdc;

    address owner = makeAddr("owner");
    address payee = makeAddr("payee");
    address weth = makeAddr("weth");

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        facet = new BittyV1VaultDeFiFacet();
        BittyV1Vault vaultImpl = new BittyV1Vault(address(facet), address(0));
        vault = BittyV1Vault(
            payable(new ERC1967Proxy(
                    address(vaultImpl), abi.encodeCall(BittyV1Vault.initialize, (owner, weth, false, address(0), 0))
                ))
        );
        usdc = new MockERC20("USD Coin", "USDC", 6);
        MockGuard(BITTY_GUARD).setAsset(address(usdc), STABLE_COIN_CATEGORY);
    }

    function _sp(uint256 amount, uint256 count, uint256 interval)
        internal
        view
        returns (IBittyV1Vault.ScheduledPayment memory)
    {
        return IBittyV1Vault.ScheduledPayment({
            recipient: payee,
            remainingPaymentCount: count,
            isImmutable: false,
            payWithInsufficientBalance: false,
            trigger: address(0),
            assetAddress: address(usdc),
            amount: amount,
            startTimestamp: block.timestamp,
            paymentInterval: interval
        });
    }

    function test_ownerSendErc20() public {
        usdc.mint(address(vault), 1_000e6);
        vm.prank(owner);
        vault.send(payee, address(usdc), 300e6, new address[](0), new uint256[](0));
        assertEq(usdc.balanceOf(payee), 300e6, "payee paid");
        assertEq(usdc.balanceOf(address(vault)), 700e6, "vault debited");
    }

    function test_scheduledPaymentFromBalance() public {
        usdc.mint(address(vault), 1_000e6);
        vm.prank(owner);
        uint256 id = vault.addScheduledPayment(_sp(120e6, 2, 0));

        // Triggerless → anyone can poke it; funded from the vault's on-hand balance.
        vault.payScheduled(id, new address[](0));
        assertEq(usdc.balanceOf(payee), 120e6, "payee paid from balance");
    }

    function test_payScheduledToppedUpFromPosition() public {
        // The vault is fully invested: all USDC supplied into a lending position, none free.
        MockLendingProtocol impl = new MockLendingProtocol();
        MockGuard(BITTY_GUARD).setProtocol(address(impl), 2); // any non-zero category → registered
        usdc.mint(address(vault), 500e6);
        vm.prank(owner);
        IVaultDeFi(address(vault)).deposit(address(impl), address(usdc), 500e6);
        assertEq(usdc.balanceOf(address(vault)), 0, "no free balance");

        vm.prank(owner);
        uint256 id = vault.addScheduledPayment(_sp(100e6, 3, 7 days));

        // The shortfall is withdrawn from the position straight to the payee — capped at the amount owed.
        vault.payScheduled(id, _arr(address(impl)));
        assertEq(usdc.balanceOf(payee), 100e6, "payee paid from the position");
        assertEq(usdc.balanceOf(address(vault)), 0, "nothing stranded in the vault");
    }

    function _arr(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }
}
