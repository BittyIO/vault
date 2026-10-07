// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ASSET_CRYPTO} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {MockLendingProtocol} from "../helpers/MockLendingProtocol.sol";
import {MockAsyncProtocol} from "../helpers/MockAsyncProtocol.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {IBittyV1Vault, InsufficientBalance} from "../../src/interfaces/IBittyV1Vault.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";

interface IVaultDeFi {
    function deposit(address protocol, address asset, uint256 amount) external;
    function getClone(address protocol) external view returns (address);
}

/**
 * The native-ETH payout path: a scheduled payment whose asset is address(0) is funded from the vault's
 * WETH and unwrapped so the payee receives real ETH — never WETH.
 */
contract VaultNativePaymentTest is Test {
    BittyV1VaultDeFiFacet facet;
    BittyV1Vault vault;
    WETH gasWrapped;

    address owner = makeAddr("owner");
    address payee = makeAddr("payee");

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        facet = new BittyV1VaultDeFiFacet();
        gasWrapped = new WETH();
        BittyV1Vault impl = new BittyV1Vault(address(facet), address(0));
        vault = BittyV1Vault(
            payable(new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(
                        BittyV1Vault.initialize, (owner, address(gasWrapped), false, address(0), 0, new bytes[](0))
                    )
                ))
        );
        // Back the vault with real WETH (WETH contract holds the ETH, so it can be unwrapped later).
        vm.deal(address(this), 5 ether);
        gasWrapped.deposit{value: 5 ether}();
        gasWrapped.transfer(address(vault), 5 ether);
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
        assertEq(gasWrapped.balanceOf(payee), 0, "no WETH landed on the payee");
        assertEq(gasWrapped.balanceOf(address(vault)), 4 ether, "vault WETH reduced by the payout");
    }

    // ── shortfall funding from positions ──────────────────────────────────────

    function _investedVaultWithDuePayment()
        private
        returns (MockAsyncProtocol asyncImpl, MockLendingProtocol lendingImpl, uint256 id)
    {
        MockGuard(BITTY_GUARD).setAsset(address(gasWrapped), ASSET_CRYPTO);
        asyncImpl = new MockAsyncProtocol();
        lendingImpl = new MockLendingProtocol();
        MockGuard(BITTY_GUARD).setProtocol(address(asyncImpl), 2);
        MockGuard(BITTY_GUARD).setProtocol(address(lendingImpl), 2);

        vm.startPrank(owner);
        IVaultDeFi(address(vault)).deposit(address(asyncImpl), address(gasWrapped), 3 ether);
        IVaultDeFi(address(vault)).deposit(address(lendingImpl), address(gasWrapped), 2 ether);
        id = vault.addScheduledPayment(
            IBittyV1Vault.ScheduledPayment({
                recipient: payee,
                remainingPaymentCount: 3,
                isImmutable: false,
                payWithInsufficientBalance: false,
                trigger: address(0), // trigger-less: anyone may poke it, with any list
                assetAddress: address(0), // native
                amount: 1 ether,
                startTimestamp: block.timestamp,
                paymentInterval: 7 days
            })
        );
        vm.stopPrank();
        assertEq(gasWrapped.balanceOf(address(vault)), 0, "fully invested: the payment must top up");
    }

    /**
     * A stranger must not be able to unstake the vault's asynchronous position by listing it as a
     * payout source: an async exit consumes the position, returns 0 and funds nothing in this call,
     * so every such entry must revert the payment — unwinding the queue request — rather than
     * silently queueing stake while a later synchronous entry pays the payee.
     */
    function test_strangerCannotForceAnAsyncExitThroughAPayment() public {
        (MockAsyncProtocol asyncImpl, MockLendingProtocol lendingImpl, uint256 id) = _investedVaultWithDuePayment();

        address[] memory list = new address[](3);
        list[0] = address(asyncImpl);
        list[1] = address(asyncImpl);
        list[2] = address(lendingImpl);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(InsufficientBalance.selector);
        vault.payScheduled(id, list);

        address asyncClone = IVaultDeFi(address(vault)).getClone(address(asyncImpl));
        assertEq(MockAsyncProtocol(asyncClone).queued(), 0, "revert unwound the queue request");
        assertEq(MockAsyncProtocol(asyncClone).getBalance(address(gasWrapped)), 3 ether, "stake untouched");
        assertEq(payee.balance, 0, "no payment went out");
    }

    /// The honest path is unchanged: a synchronous source funds the shortfall and the payee gets ETH.
    function test_synchronousListStillFundsTheShortfall() public {
        (MockAsyncProtocol asyncImpl, MockLendingProtocol lendingImpl, uint256 id) = _investedVaultWithDuePayment();

        address[] memory list = new address[](1);
        list[0] = address(lendingImpl);
        vm.prank(makeAddr("keeper"));
        vault.payScheduled(id, list);

        assertEq(payee.balance, 1 ether, "payee received real ETH from the position top-up");
        address asyncClone = IVaultDeFi(address(vault)).getClone(address(asyncImpl));
        assertEq(MockAsyncProtocol(asyncClone).getBalance(address(gasWrapped)), 3 ether, "async stake untouched");
        assertEq(MockAsyncProtocol(asyncClone).queued(), 0, "nothing queued");
    }
}
