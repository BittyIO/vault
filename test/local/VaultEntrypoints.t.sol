// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ASSET_STABLE_COIN} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {MockLendingProtocol} from "../helpers/MockLendingProtocol.sol";
import {LENDING_ID} from "../helpers/CategoryIds.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1SubVault} from "../../src/subvault/BittyV1SubVault.sol";
import {IBittyV1Vault} from "../../src/interfaces/IBittyV1Vault.sol";
import {
    AddressZero,
    ArrayLengthMismatch,
    AssetNotRegistered,
    FeeExceedsPerOpCap,
    InsufficientBalance,
    InvalidAsset,
    NotPayoutOperator,
    OnlyImmutablePayableAfterRenounce
} from "../../src/interfaces/IBittyV1Vault.sol";
import {
    BITTY_GUARD,
    BITTY_FORWARDER,
    BITTY_FEE_COLLECTOR,
    SENTINEL,
    SYSTEM_MAX_FEE_PER_OP
} from "../../src/logic/Constants.sol";

interface IFacet {
    function deposit(address protocol, address asset, uint256 amount) external;
    function getClone(address protocol) external view returns (address);
}

interface IFacetView {
    function allowlistEnabled() external view returns (bool);
    function isAssetAllowed(address asset) external view returns (bool);
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

/**
 * The vault's own entry points: what it validates before delegating to a logic library.
 *
 * Two things live only here and nowhere in the libraries — the paired-array checks on the convenience
 * calls that let an owner fund a send straight out of a yield position, and the shortfall cover that
 * tops a scheduled payment up from those positions. Both take a caller-supplied list of protocols, so
 * what they refuse matters as much as what they do.
 */
contract VaultEntrypointsTest is Test {
    BittyV1VaultDeFiFacet facet;
    BittyV1Vault impl;
    BittyV1Vault vault;
    MockGuard guard;
    MockERC20 usdc;
    MockLendingProtocol proto;
    WETHStub weth;

    address owner = makeAddr("owner");
    address operator = makeAddr("operator");
    address stranger = makeAddr("stranger");
    address payee = makeAddr("payee");

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);

        weth = new WETHStub();
        facet = new BittyV1VaultDeFiFacet();
        BittyV1SubVault subImpl = new BittyV1SubVault(address(facet));
        impl = new BittyV1Vault(address(facet), address(subImpl));
        vault = _newVault(0, address(0), 0);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        proto = new MockLendingProtocol();
        guard.setAsset(address(usdc), ASSET_STABLE_COIN);
        guard.setProtocol(address(proto), LENDING_ID);
        usdc.mint(address(vault), 1_000e6);

        vm.prank(owner);
        vault.updatePayoutOperator(operator, true);
    }

    function _newVault(uint256 value, address activationAsset, uint256 activationAmount)
        internal
        returns (BittyV1Vault v)
    {
        bytes memory init = abi.encodeCall(
            BittyV1Vault.initialize, (owner, address(weth), false, activationAsset, activationAmount)
        );
        v = BittyV1Vault(payable(new ERC1967Proxy{value: value}(address(impl), init)));
    }

    function _addr(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _amt(uint256 a) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = a;
    }

    /// One send's worth of funding legs.
    function _legs(address[] memory a) internal pure returns (address[][] memory arr) {
        arr = new address[][](1);
        arr[0] = a;
    }

    function _legs(uint256[] memory a) internal pure returns (uint256[][] memory arr) {
        arr = new uint256[][](1);
        arr[0] = a;
    }

    function _pair(address a, address b) internal pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _pair(uint256 a, uint256 b) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](2);
        arr[0] = a;
        arr[1] = b;
    }

    // ── initialize ────────────────────────────────────────────────────────────

    function test_aVaultCannotBeBornOwnerless() public {
        bytes memory init = abi.encodeCall(BittyV1Vault.initialize, (address(0), address(weth), false, address(0), 0));
        vm.expectRevert(AddressZero.selector);
        new ERC1967Proxy(address(impl), init);
    }

    function test_aVaultCannotBeBornWithoutAWethToUnwrapThrough() public {
        bytes memory init = abi.encodeCall(BittyV1Vault.initialize, (owner, address(0), false, address(0), 0));
        vm.expectRevert(AddressZero.selector);
        new ERC1967Proxy(address(impl), init);
    }

    /**
     * `initialize` is not payable, so ETH cannot ride along with activation. The way a vault is born
     * holding ETH is the counterfactual one: somebody funds the deterministic address before the proxy
     * exists there, and activation sweeps whatever it finds into WETH.
     */
    function test_ethPreFundedToTheCounterfactualAddressIsWrappedAtActivation() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.deal(predicted, 2 ether);

        BittyV1Vault v = _newVault(0, address(0), 0);
        assertEq(address(v), predicted, "the vault landed where the ETH was waiting");
        assertEq(weth.balanceOf(address(v)), 2 ether, "the vault holds WETH, never loose ETH");
        assertEq(address(v).balance, 0, "and nothing was left unwrapped");
    }

    // ── activation fee ────────────────────────────────────────────────────────

    function test_activationFeeIsPaidToTheCollectorAtBirth() public {
        MockERC20 fee = new MockERC20("USD Coin", "USDC", 6);
        guard.setAsset(address(fee), ASSET_STABLE_COIN);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        fee.mint(predicted, 10e6);

        uint256 before = fee.balanceOf(BITTY_FEE_COLLECTOR);
        BittyV1Vault v = _newVault(0, address(fee), 3e6);
        assertEq(fee.balanceOf(BITTY_FEE_COLLECTOR) - before, 3e6, "the collector was paid");
        assertEq(fee.balanceOf(address(v)), 7e6, "out of the vault's own funding");
    }

    function test_anUnregisteredActivationAssetIsRefused() public {
        MockERC20 fee = new MockERC20("Random", "RND", 6);
        vm.expectRevert(AssetNotRegistered.selector);
        _newVault(0, address(fee), 1e6);
    }

    function test_anActivationFeeAboveTheSystemCapIsRefused() public {
        MockERC20 fee = new MockERC20("USD Coin", "USDC", 6);
        guard.setAsset(address(fee), ASSET_STABLE_COIN);
        vm.expectRevert(FeeExceedsPerOpCap.selector);
        _newVault(0, address(fee), (uint256(SYSTEM_MAX_FEE_PER_OP) + 1) * 1e6);
    }

    function test_anActivationFeeTheVaultCannotCoverIsRefused() public {
        MockERC20 fee = new MockERC20("USD Coin", "USDC", 6);
        guard.setAsset(address(fee), ASSET_STABLE_COIN);
        vm.expectRevert(InsufficientBalance.selector);
        _newVault(0, address(fee), 5e6);
    }

    // ── auth ──────────────────────────────────────────────────────────────────

    function test_aStrangerIsNeitherOwnerNorOperator() public {
        vm.prank(stranger);
        vm.expectRevert(NotPayoutOperator.selector);
        vault.removeScheduledPayments(new uint256[](0));
    }

    // ── paired-array checks on the convenience calls ──────────────────────────

    function test_aBatchSendWithARaggedWithdrawListIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(ArrayLengthMismatch.selector);
        vault.batchSend(_addr(payee), _addr(address(usdc)), _amt(1e6), _legs(_addr(address(proto))), new uint256[][](0));
    }

    /// Ragged INSIDE one send's funding legs is refused too — the inner pair is checked per send.
    function test_aBatchSendWithARaggedInnerLegIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(ArrayLengthMismatch.selector);
        vault.batchSend(
            _addr(payee), _addr(address(usdc)), _amt(1e6), _legs(_addr(address(proto))), _legs(new uint256[](0))
        );
    }

    function test_aSingleSendWithARaggedWithdrawListIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(ArrayLengthMismatch.selector);
        vault.send(payee, address(usdc), 1e6, _addr(address(proto)), new uint256[](0));
    }

    function test_aSendCanBeFundedStraightOutOfAPosition() public {
        vm.startPrank(owner);
        IFacet(address(vault)).deposit(address(proto), address(usdc), 900e6);
        assertEq(usdc.balanceOf(address(vault)), 100e6, "most of it is deployed");

        vault.send(payee, address(usdc), 500e6, _addr(address(proto)), _amt(500e6));
        vm.stopPrank();
        assertEq(usdc.balanceOf(payee), 500e6, "the position covered the send");
    }

    function test_aBatchSendCanBeFundedStraightOutOfAPosition() public {
        vm.startPrank(owner);
        IFacet(address(vault)).deposit(address(proto), address(usdc), 900e6);
        vault.batchSend(
            _addr(payee), _addr(address(usdc)), _amt(500e6), _legs(_addr(address(proto))), _legs(_amt(500e6))
        );
        vm.stopPrank();
        assertEq(usdc.balanceOf(payee), 500e6, "the position covered the batch");
    }

    /**
     * The case the flat signature could not express at all: ONE payment inside a batch funded from TWO
     * positions. Under the old shape the withdraw arrays were index-parallel to `assets`, so a send got
     * exactly one funding leg and a batch was strictly less capable than the `send` it batches.
     */
    function test_oneSendInABatchCanDrawOnSeveralPositions() public {
        MockLendingProtocol second = new MockLendingProtocol();
        guard.setProtocol(address(second), LENDING_ID);

        vm.startPrank(owner);
        IFacet(address(vault)).deposit(address(proto), address(usdc), 600e6);
        IFacet(address(vault)).deposit(address(second), address(usdc), 300e6);
        assertEq(usdc.balanceOf(address(vault)), 100e6, "nearly everything is deployed");

        vault.batchSend(
            _addr(payee),
            _addr(address(usdc)),
            _amt(700e6),
            _legs(_pair(address(proto), address(second))),
            _legs(_pair(400e6, 300e6))
        );
        vm.stopPrank();
        assertEq(usdc.balanceOf(payee), 700e6, "two positions covered one payment");
    }

    /// And a batch stays N independent sends: each entry draws on its own positions.
    function test_eachSendInABatchHasItsOwnFundingLegs() public {
        address other = makeAddr("other");
        vm.startPrank(owner);
        IFacet(address(vault)).deposit(address(proto), address(usdc), 900e6);

        address[] memory tos = new address[](2);
        tos[0] = payee;
        tos[1] = other;
        address[] memory assets = _pair(address(usdc), address(usdc));
        uint256[] memory amts = _pair(300e6, 200e6);

        address[][] memory protocols = new address[][](2);
        protocols[0] = _addr(address(proto));
        protocols[1] = new address[](0);
        uint256[][] memory legs = new uint256[][](2);
        legs[0] = _amt(500e6);
        legs[1] = new uint256[](0);

        vault.batchSend(tos, assets, amts, protocols, legs);
        vm.stopPrank();
        assertEq(usdc.balanceOf(payee), 300e6, "first drew on a position");
        assertEq(usdc.balanceOf(other), 200e6, "second paid from balance");
    }

    function test_aZeroProtocolEntryIsSkippedNotTreatedAsAWithdrawal() public {
        vm.startPrank(owner);
        vault.send(payee, address(usdc), 10e6, _addr(address(0)), _amt(500e6));
        vm.stopPrank();
        assertEq(usdc.balanceOf(payee), 10e6, "paid from balance, no phantom withdrawal");
    }

    function test_aZeroAmountWithdrawEntryIsSkipped() public {
        vm.startPrank(owner);
        vault.send(payee, address(usdc), 10e6, _addr(address(proto)), _amt(0));
        vm.stopPrank();
        assertEq(usdc.balanceOf(payee), 10e6, "paid from balance");
    }

    // ── sub-vault convenience ─────────────────────────────────────────────────

    function test_creatingAFundedSubWithRaggedArraysIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(ArrayLengthMismatch.selector);
        vault.createSubVaultWithDeposits(
            makeAddr("subOwner"), false, uint64(block.timestamp) + 365 days, _addr(address(usdc)), new uint256[](0)
        );
    }

    // ── scheduled-payment shortfall cover ─────────────────────────────────────

    function _immutableSchedule(uint256 amount) internal returns (uint256 id) {
        IBittyV1Vault.ScheduledPayment memory sp = IBittyV1Vault.ScheduledPayment({
            recipient: payee,
            remainingPaymentCount: 5,
            isImmutable: true,
            payWithInsufficientBalance: false,
            trigger: address(0),
            assetAddress: address(usdc),
            amount: amount,
            startTimestamp: block.timestamp,
            paymentInterval: 0
        });
        vm.prank(owner);
        id = vault.addScheduledPayment(sp);
    }

    function test_aShortfallIsToppedUpFromTheNamedPosition() public {
        vm.prank(owner);
        IFacet(address(vault)).deposit(address(proto), address(usdc), 950e6);
        uint256 id = _immutableSchedule(200e6);

        vault.payScheduled(id, _addr(address(proto)));
        assertEq(usdc.balanceOf(payee), 200e6, "balance plus position covered it");
    }

    function test_aZeroProtocolInTheCoverListIsSkipped() public {
        vm.prank(owner);
        IFacet(address(vault)).deposit(address(proto), address(usdc), 950e6);
        uint256 id = _immutableSchedule(200e6);

        address[] memory list = new address[](2);
        list[0] = address(0);
        list[1] = address(proto);
        vault.payScheduled(id, list);
        assertEq(usdc.balanceOf(payee), 200e6, "the empty slot was ignored, the real one used");
    }

    /// A protocol the vault HAS used but has since emptied is skipped without a withdraw call, so a
    /// caller cannot pad the cover list with drained positions to burn the payer's gas.
    function test_aPositionWithNothingInItIsSkipped() public {
        MockLendingProtocol empty = new MockLendingProtocol();
        guard.setProtocol(address(empty), LENDING_ID);

        vm.startPrank(owner);
        IFacet(address(vault)).deposit(address(empty), address(usdc), 10e6);
        (bool ok,) = address(vault)
            .call(abi.encodeWithSignature("withdraw(address,address,uint256)", address(empty), address(usdc), 10e6));
        assertTrue(ok, "drained again");
        IFacet(address(vault)).deposit(address(proto), address(usdc), 950e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(_f2().getClone(address(empty))), 0, "that position is empty");

        uint256 id = _immutableSchedule(200e6);
        address[] memory list = new address[](2);
        list[0] = address(empty);
        list[1] = address(proto);
        vault.payScheduled(id, list);
        assertEq(usdc.balanceOf(payee), 200e6, "the empty one contributed nothing, the real one covered it");
    }

    function _f2() internal view returns (IFacet) {
        return IFacet(address(vault));
    }

    // ── gasless config edges ──────────────────────────────────────────────────

    function test_narrowingToAnUnregisteredCoinIsRefused() public {
        MockERC20 rnd = new MockERC20("Random", "RND", 18);
        vm.prank(owner);
        vm.expectRevert(AssetNotRegistered.selector);
        vault.setGasless(_addr(address(rnd)), 50, 5);
    }

    function test_aRepeatedCoinIsStoredOnce() public {
        address[] memory two = new address[](2);
        two[0] = address(usdc);
        two[1] = address(usdc);
        vm.prank(owner);
        vault.setGasless(two, 50, 5);

        (address[] memory got,,) = vault.gaslessConfig();
        assertEq(got.length, 1, "the duplicate collapsed");
        assertEq(got[0], address(usdc), "and it is the coin named");
    }

    function test_theSentinelCannotBeSmuggledInAsACoin() public {
        guard.setAsset(SENTINEL, ASSET_STABLE_COIN);
        address[] memory list = new address[](2);
        list[0] = SENTINEL;
        list[1] = address(usdc);
        vm.prank(owner);
        vault.setGasless(list, 50, 5);

        (address[] memory got,,) = vault.gaslessConfig();
        assertEq(got.length, 1, "the list terminator is not a payable coin");
        assertEq(got[0], address(usdc));
    }

    function test_narrowingTwiceReplacesRatherThanAppends() public {
        MockERC20 dai = new MockERC20("Dai", "DAI", 18);
        guard.setAsset(address(dai), ASSET_STABLE_COIN);

        vm.startPrank(owner);
        vault.setGasless(_addr(address(usdc)), 50, 5);
        vault.setGasless(_addr(address(dai)), 50, 5);
        vm.stopPrank();

        (address[] memory got,,) = vault.gaslessConfig();
        assertEq(got.length, 1, "the old list was cleared");
        assertEq(got[0], address(dai), "only the newest narrowing stands");
    }

    function test_theZeroAssetCannotPayARelayerFee() public {
        vm.prank(BITTY_FORWARDER);
        vm.expectRevert(InvalidAsset.selector);
        vault.payRelayerFee(address(0), 1e6);
    }

    function test_theSentinelCannotPayARelayerFee() public {
        vm.prank(BITTY_FORWARDER);
        vm.expectRevert(InvalidAsset.selector);
        vault.payRelayerFee(SENTINEL, 1e6);
    }

    function test_aRenouncedVaultPaysNoMoreRelayerFees() public {
        uint256 id = _immutableSchedule(10e6);
        vm.prank(owner);
        vault.renounceVaultOwnership(id);

        vm.prank(BITTY_FORWARDER);
        vm.expectRevert(OnlyImmutablePayableAfterRenounce.selector);
        vault.payRelayerFee(address(usdc), 1e6);
    }

    /**
     * A vault activated by PAYING in an asset must be able to use that asset. Before this, the
     * allowlist came up on and empty, so the coin that funded the activation was not tradeable by
     * the vault it had just paid for - and because a CoW order is signed off chain, the refusal
     * surfaced as an opaque InvalidEip1271Signature from the orderbook rather than a failed call.
     */
    function test_activationAssetIsListedOnTheAllowlist() public {
        MockERC20 coin = new MockERC20("USD Coin", "USDC", 6);
        guard.setAsset(address(coin), ASSET_STABLE_COIN);
        // Seeding defers to the guard, so the stub has to be registered there like the real WETH is.
        guard.setAsset(address(weth), 2); // 2 = crypto asset, as the live guard categorises WETH

        // Allowlist ON, exactly as the factory activates a vault.
        bytes memory init = abi.encodeCall(BittyV1Vault.initialize, (owner, address(weth), true, address(coin), 0));
        BittyV1Vault v = BittyV1Vault(payable(new ERC1967Proxy(address(impl), init)));

        assertTrue(IFacetView(address(v)).allowlistEnabled(), "allowlist should be on");
        assertTrue(IFacetView(address(v)).isAssetAllowed(address(coin)), "activation asset not listed");
        assertTrue(IFacetView(address(v)).isAssetAllowed(address(weth)), "weth not listed");
    }

    /// Seeding is a convenience: an unreachable guard must never block vault creation.
    function test_initializeSurvivesAnUnreachableGuard() public {
        vm.etch(BITTY_GUARD, "");
        BittyV1Vault v = _newVault(0, address(0), 0);
        assertEq(v.owner(), owner, "vault must still initialize with no guard deployed");
    }

    /// With the allowlist OFF there is no list to seed: the guard's catalog is the only gate, so
    /// writing these in would change no answer.
    function test_noSeedingWhenTheAllowlistIsOff() public {
        MockERC20 coin = new MockERC20("USD Coin", "USDC", 6);
        guard.setAsset(address(coin), ASSET_STABLE_COIN);
        guard.setAsset(address(weth), 2);

        bytes memory init = abi.encodeCall(BittyV1Vault.initialize, (owner, address(weth), false, address(coin), 0));
        BittyV1Vault v = BittyV1Vault(payable(new ERC1967Proxy(address(impl), init)));

        assertFalse(IFacetView(address(v)).allowlistEnabled(), "allowlist should be off");
        // Still usable: with no allowlist the guard alone decides.
        assertTrue(IFacetView(address(v)).isAssetAllowed(address(coin)), "guard-registered asset must pass");
    }
}
