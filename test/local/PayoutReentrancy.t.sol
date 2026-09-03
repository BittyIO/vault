// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ASSET_STABLE_COIN} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1SubVault} from "../../src/subvault/BittyV1SubVault.sol";
import {IBittyV1Vault} from "../../src/interfaces/IBittyV1Vault.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {PaymentNotStableCoin, ReentrantCall, TransferFailed} from "../../src/interfaces/IBittyV1Vault.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";

interface IFacet {
    function enableAllowlist() external;
    function updateAssets(address[] calldata add, address[] calldata remove) external;
}

contract WETHStub {
    mapping(address => uint256) public balanceOf;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "eth back");
    }

    receive() external payable {}
}

/// Re-enters the vault while being paid, aiming a second native payout at the same lock. It records
/// what came back rather than rethrowing, so a test can see the lock itself and not just its symptom.
contract ReentrantPayee {
    BittyV1Vault public vault;
    uint256 public secondId;
    bool public armed;
    bool public reentered;
    bytes4 public innerRevert;

    function arm(BittyV1Vault v, uint256 id) external {
        vault = v;
        secondId = id;
        armed = true;
    }

    receive() external payable {
        if (!armed) return;
        armed = false;
        try vault.payScheduled(secondId, new address[](0)) {
            reentered = true;
        } catch (bytes memory err) {
            innerRevert = bytes4(err);
        }
    }
}

/// Same re-entry, but lets the lock's revert propagate.
contract RethrowingPayee {
    BittyV1Vault public vault;
    uint256 public secondId;
    bool public armed;

    function arm(BittyV1Vault v, uint256 id) external {
        vault = v;
        secondId = id;
        armed = true;
    }

    receive() external payable {
        if (!armed) return;
        armed = false;
        vault.payScheduled(secondId, new address[](0));
    }
}

/**
 * The native-payout reentrancy lock, and the one place it can actually be reached.
 *
 * Paying ETH means unwrapping WETH and handing control to the recipient mid-payout. Everything else
 * that moves money is owner- or operator-gated, so a recipient could not call back in — but
 * `payScheduled` is deliberately permissionless, which is exactly what makes a hostile recipient able
 * to re-enter and drain a second schedule inside the first one's payout. The transient lock is what
 * stops that.
 */
contract PayoutReentrancyTest is Test {
    BittyV1Vault vault;
    MockGuard guard;
    MockERC20 usdc;
    WETHStub weth;
    ReentrantPayee payee;

    address owner = makeAddr("owner");

    uint256 constant UNCHANGED = type(uint256).max;

    function setUp() public {
        vm.warp(1_000_000);
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);

        weth = new WETHStub();
        BittyV1VaultDeFiFacet facet = new BittyV1VaultDeFiFacet();
        BittyV1SubVault subImpl = new BittyV1SubVault(address(facet));
        BittyV1Vault impl = new BittyV1Vault(address(facet), address(subImpl));
        bytes memory init = abi.encodeCall(BittyV1Vault.initialize, (owner, address(weth), false, address(0), 0));
        vault = BittyV1Vault(payable(new ERC1967Proxy(address(impl), init)));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        guard.setAsset(address(usdc), ASSET_STABLE_COIN);
        usdc.mint(address(vault), 100_000e6);

        payee = new ReentrantPayee();

        // The vault holds wrapped ETH; the stub holds the real ETH it will hand back on withdraw.
        vm.deal(address(vault), 10 ether);
        vm.prank(address(vault));
        weth.deposit{value: 10 ether}();
    }

    function _nativeSchedule(uint256 amount) internal returns (uint256 id) {
        return _scheduleFor(address(payee), amount);
    }

    function _scheduleFor(address to, uint256 amount) internal returns (uint256 id) {
        IBittyV1Vault.ScheduledPayment memory sp = IBittyV1Vault.ScheduledPayment({
            recipient: to,
            remainingPaymentCount: 5,
            isImmutable: false,
            payWithInsufficientBalance: false,
            trigger: address(0),
            assetAddress: address(0),
            amount: amount,
            startTimestamp: block.timestamp,
            paymentInterval: 0
        });
        vm.prank(owner);
        id = vault.addScheduledPayment(sp);
    }

    function test_aNativePayoutDeliversRealEth() public {
        uint256 id = _nativeSchedule(1 ether);
        vault.payScheduled(id, new address[](0));
        assertEq(address(payee).balance, 1 ether, "the payee got ETH");
    }

    function test_aHostileRecipientCannotReenterASecondNativePayout() public {
        uint256 first = _nativeSchedule(1 ether);
        uint256 second = _nativeSchedule(2 ether);
        payee.arm(vault, second);

        vault.payScheduled(first, new address[](0));

        assertFalse(payee.reentered(), "the second payout never happened");
        assertEq(payee.innerRevert(), ReentrantCall.selector, "it was the lock that stopped it");
        assertEq(address(payee).balance, 1 ether, "only the payout already in flight was delivered");
    }

    /// And if the recipient lets the lock's revert escape, the whole payout unwinds instead.
    function test_aReentrancyThatIsNotSwallowedFailsTheOuterPayout() public {
        uint256 second = _nativeSchedule(2 ether);

        RethrowingPayee hostile = new RethrowingPayee();
        uint256 third = _scheduleFor(address(hostile), 1 ether);
        hostile.arm(vault, second);

        vm.expectRevert(TransferFailed.selector);
        vault.payScheduled(third, new address[](0));
        assertEq(address(hostile).balance, 0, "nothing left the vault");
    }

    function test_theLockIsReleasedSoLaterPayoutsStillWork() public {
        uint256 first = _nativeSchedule(1 ether);
        uint256 second = _nativeSchedule(2 ether);

        vault.payScheduled(first, new address[](0));
        vault.payScheduled(second, new address[](0));
        assertEq(address(payee).balance, 3 ether, "both paid, one after the other");
    }

    // ── the local allowlist narrows what a capped send may pay in ─────────────

    function _cap(uint64 maxSendValue) internal {
        vm.prank(owner);
        vault.updatePaymentRisk(
            IBittyV1Owner.PaymentRisk({
                maxSendValue: maxSendValue,
                maxSendInterval: UNCHANGED,
                newPaymentProtection: UNCHANGED,
                changeTimelock: UNCHANGED
            })
        );
    }

    function test_underACapAnUnnamedCoinIsNotASpendableStablecoin() public {
        _cap(1_000);
        vm.startPrank(owner);
        IFacet(address(vault)).enableAllowlist();

        vm.expectRevert(PaymentNotStableCoin.selector);
        vault.send(makeAddr("someone"), address(usdc), 1e6, new address[](0), new uint256[](0));
        vm.stopPrank();
    }

    function test_namingTheCoinMakesItSpendableAgain() public {
        _cap(1_000);
        address[] memory one = new address[](1);
        one[0] = address(usdc);

        vm.startPrank(owner);
        IFacet(address(vault)).enableAllowlist();
        IFacet(address(vault)).updateAssets(one, new address[](0));

        address to = makeAddr("someone");
        vault.send(to, address(usdc), 1e6, new address[](0), new uint256[](0));
        vm.stopPrank();
        assertEq(usdc.balanceOf(to), 1e6, "named, so payable");
    }
}
