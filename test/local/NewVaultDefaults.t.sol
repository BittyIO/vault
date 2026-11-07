// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ASSET_STABLE_COIN} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockERC721} from "solmate/test/utils/mocks/MockERC721.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {
    PaymentExceedsRiskCap,
    RiskAllowanceOutOfRange,
    ProtectionPeriodNotEnded,
    VaultLocked,
    WhitelistedRecipientNotFound
} from "../../src/interfaces/IBittyV1Vault.sol";
import {
    BITTY_GUARD,
    MIN_RISK_TIMELOCK,
    DEFAULT_MARKET_TRADE_DAILY_LOSS_ALLOWANCE,
    MAX_MARKET_TRADE_DAILY_LOSS_ALLOWANCE
} from "../../src/logic/Constants.sol";

/**
 * What a new vault starts with. Regular sends are off, and turning them on waits out the timelock.
 * The market-trade loss allowance starts at a default below its ceiling: lowered at once, raised only
 * after the timelock. An NFT leaves only to a whitelisted recipient the owner can pay.
 */
contract NewVaultDefaultsTest is Test {
    BittyV1Vault vault;
    MockERC20 usdc;
    MockERC721 nft;

    address owner = makeAddr("owner");
    address thief = makeAddr("thief");
    address payee = makeAddr("payee");
    address gasWrapped = makeAddr("gasWrapped");

    uint256 constant UNCHANGED = type(uint256).max;

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        BittyV1VaultDeFiFacet facet = new BittyV1VaultDeFiFacet();
        BittyV1Vault impl = new BittyV1Vault(address(facet));
        bytes memory init =
            abi.encodeCall(BittyV1Vault.initialize, (owner, gasWrapped, false, address(0), 0, new bytes[](0)));
        vault = BittyV1Vault(payable(new ERC1967Proxy(address(impl), init)));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        MockGuard(BITTY_GUARD).setAsset(address(usdc), ASSET_STABLE_COIN);
        usdc.mint(address(vault), 100_000e6);
        nft = new MockERC721("Stray", "NFT");
        nft.mint(address(vault), 1);
    }

    function _send(address to, uint256 amount) internal {
        vm.prank(owner);
        vault.send(to, address(usdc), amount, new address[](0), new uint256[](0));
    }

    function _setSendAllowance(uint256 allowance) internal {
        vm.prank(owner);
        vault.updateRisk(IBittyV1Owner.RiskSettings(UNCHANGED, allowance, UNCHANGED));
    }

    function _addPayee(address recipient) internal returns (uint256 id) {
        vm.prank(owner);
        id = vault.addWhitelistedRecipient(recipient);
    }

    // ── sends start off ───────────────────────────────────────────────────────

    function test_aNewVaultStartsWithSendsOff() public view {
        (, uint64 sendAllowance,) = vault.riskSettings();
        assertEq(sendAllowance, 0, "nothing may leave to an address nobody vetted");
    }

    function test_aNewVaultRefusesEvenTheSmallestSend() public {
        vm.expectRevert(PaymentExceedsRiskCap.selector);
        _send(thief, 1);
    }

    function test_turningSendsOnWaitsOutTheTimelock() public {
        _setSendAllowance(1_000);
        (, uint64 sendAllowance,) = vault.riskSettings();
        assertEq(sendAllowance, 0, "still off: a loosening is only scheduled");
        vm.expectRevert(PaymentExceedsRiskCap.selector);
        _send(thief, 1e6);

        vm.warp(block.timestamp + MIN_RISK_TIMELOCK);
        _send(payee, 1e6);
        assertEq(usdc.balanceOf(payee), 1e6, "on, a timelock later");
    }

    /**
     * The one window a stolen key has: the owner sees the scheduled change, and a lock voids it.
     */
    function test_aLockVoidsSendsBeingTurnedOn() public {
        _setSendAllowance(1_000);
        vm.prank(owner);
        vault.emergencyLock();
        vm.prank(owner);
        vault.unlock();
        vm.warp(block.timestamp + MIN_RISK_TIMELOCK);
        (, uint64 sendAllowance,) = vault.riskSettings();
        assertEq(sendAllowance, 0, "the lock dropped it");
    }

    // ── the loss allowance starts at the default ──────────────────────────────

    function _setLossAllowance(uint256 allowance) internal {
        vm.prank(owner);
        vault.updateRisk(IBittyV1Owner.RiskSettings(UNCHANGED, UNCHANGED, allowance));
    }

    function _lossAllowance() internal view returns (uint64 allowance) {
        (,, allowance) = vault.riskSettings();
    }

    function test_aNewVaultStartsAtTheDefaultLossAllowance() public view {
        assertEq(_lossAllowance(), DEFAULT_MARKET_TRADE_DAILY_LOSS_ALLOWANCE);
        assertLt(DEFAULT_MARKET_TRADE_DAILY_LOSS_ALLOWANCE, MAX_MARKET_TRADE_DAILY_LOSS_ALLOWANCE, "below the ceiling");
    }

    /**
     * A starting value, not a floor: going below it, to 0 if need be, is a tightening.
     */
    function test_theDefaultCanBeLoweredAtOnceEvenToZero() public {
        _setLossAllowance(100);
        assertEq(_lossAllowance(), 100);
        _setLossAllowance(0);
        assertEq(_lossAllowance(), 0, "market trading off");
    }

    function test_raisingTheDefaultWaitsOutTheTimelock() public {
        _setLossAllowance(MAX_MARKET_TRADE_DAILY_LOSS_ALLOWANCE);
        assertEq(_lossAllowance(), DEFAULT_MARKET_TRADE_DAILY_LOSS_ALLOWANCE, "only scheduled");
        vm.warp(block.timestamp + MIN_RISK_TIMELOCK);
        assertEq(_lossAllowance(), MAX_MARKET_TRADE_DAILY_LOSS_ALLOWANCE, "a timelock later");
    }

    function test_theCeilingStillHolds() public {
        vm.prank(owner);
        vm.expectRevert(RiskAllowanceOutOfRange.selector);
        vault.updateRisk(IBittyV1Owner.RiskSettings(UNCHANGED, UNCHANGED, MAX_MARKET_TRADE_DAILY_LOSS_ALLOWANCE + 1));
    }

    // ── an NFT leaves only to a payable whitelisted recipient ────────────────

    function test_anNftGoesToAMaturedRecipient() public {
        uint256 id = _addPayee(payee);
        vm.warp(block.timestamp + MIN_RISK_TIMELOCK);
        vm.prank(owner);
        vault.retrieve721(address(nft), 1, id);
        assertEq(nft.ownerOf(1), payee);
    }

    function test_anNftWaitsForTheRecipientToMature() public {
        uint256 id = _addPayee(thief);
        vm.prank(owner);
        vm.expectRevert(ProtectionPeriodNotEnded.selector);
        vault.retrieve721(address(nft), 1, id);
    }

    function test_anNftCannotGoToAnUnknownRecipient() public {
        vm.prank(owner);
        vm.expectRevert(WhitelistedRecipientNotFound.selector);
        vault.retrieve721(address(nft), 1, 7);
    }

    function test_onlyTheOwnerSendsAnNft() public {
        uint256 id = _addPayee(payee);
        vm.warp(block.timestamp + MIN_RISK_TIMELOCK);
        vm.prank(thief);
        vm.expectRevert();
        vault.retrieve721(address(nft), 1, id);
    }

    /**
     * A lock keeps the owner's way out for an NFT, as it does for every other asset.
     */
    function test_aForeverLockedVaultStillSendsAnNftToItsRecipient() public {
        uint256 id = _addPayee(payee);
        vm.warp(block.timestamp + MIN_RISK_TIMELOCK);
        vm.prank(owner);
        vault.foreverLock(id);
        vm.prank(owner);
        vault.retrieve721(address(nft), 1, id);
        assertEq(nft.ownerOf(1), payee);
    }

    function test_aRecipientALockVoidedCannotTakeAnNft() public {
        uint256 id = _addPayee(thief);
        vm.prank(owner);
        vault.emergencyLock();
        vm.warp(block.timestamp + MIN_RISK_TIMELOCK);
        vm.prank(owner);
        vm.expectRevert(VaultLocked.selector);
        vault.retrieve721(address(nft), 1, id);
    }
}
