// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {MockAMMProtocol} from "../helpers/MockAMMProtocol.sol";
import {MockIntentProtocol} from "../helpers/MockIntentProtocol.sol";
import {MockSettlement} from "../helpers/MockSettlement.sol";
import {AMM_ID, INTENT_ID, LENDING_ID} from "../helpers/CategoryIds.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1SubVault} from "../../src/subvault/BittyV1SubVault.sol";
import {BITTY_GUARD, STABLE_COIN_CATEGORY} from "../../src/logic/Constants.sol";

interface IFacet {
    function addLiquidity(address amm, address t0, uint256 a0, address t1, uint256 a1, bytes memory data) external;
    function removeLiquidity(address amm, bytes memory data) external;
    function claimAMMFees(address amm, bytes memory data) external;
    function getLiquidities(address[] calldata amms, bytes[] calldata data) external view returns (uint256[] memory);
    function approveIntentRelayer(address intent, address token) external;
    function cancelIntentOrder(address intent, bytes calldata uid) external;
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4);
    function isOffchainOrderAuthorized(address signer, address sellToken, address buyToken, uint256 sellAmount)
        external
        view
        returns (bool);
    function isOffchainCancellationAuthorized(address signer) external view returns (bool);
    function disableTradeUntilTimestamp(uint256 ts) external;
    function updateAssets(address[] calldata add, address[] calldata remove) external;
    function updateProtocols(address[] calldata add, address[] calldata remove) external;
    function getClone(address protocol) external view returns (address);
}

/**
 * Market making and intent trading: the two paths where a protocol is handed real authority.
 *
 * An intent protocol is the sharper one — the vault vouches for an ORDER SIGNATURE, so the
 * category check is what stops an arbitrary registered contract being asked to sign for the vault.
 */
contract DeFiTradingTest is Test {
    BittyV1Vault vault;
    MockGuard guard;
    MockERC20 t0;
    MockERC20 t1;
    MockAMMProtocol amm;
    MockIntentProtocol intent;
    MockSettlement settlement;

    address owner = makeAddr("owner");
    address weth = makeAddr("weth");
    bytes4 constant MAGIC = 0x1626ba7e;
    bytes4 constant INVALID = 0xffffffff;

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);

        BittyV1VaultDeFiFacet facet = new BittyV1VaultDeFiFacet();
        BittyV1SubVault subImpl = new BittyV1SubVault(address(facet));
        BittyV1Vault impl = new BittyV1Vault(address(facet), address(subImpl));
        bytes memory init = abi.encodeCall(BittyV1Vault.initialize, (owner, weth, false, address(0), 0));
        vault = BittyV1Vault(payable(new ERC1967Proxy(address(impl), init)));

        t0 = new MockERC20("Token0", "T0", 18);
        t1 = new MockERC20("Token1", "T1", 18);
        amm = new MockAMMProtocol();
        settlement = new MockSettlement();
        intent = new MockIntentProtocol();
        intent.setEndpoints(address(settlement), address(settlement));

        guard.setAsset(address(t0), STABLE_COIN_CATEGORY);
        guard.setAsset(address(t1), 2);
        guard.setProtocol(address(amm), AMM_ID);
        guard.setProtocol(address(intent), INTENT_ID);

        t0.mint(address(vault), 1_000e18);
        t1.mint(address(vault), 1_000e18);
    }

    function _f() internal view returns (IFacet) {
        return IFacet(address(vault));
    }

    function _one(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    // ── AMM ───────────────────────────────────────────────────────────────────

    function test_ownerAddsAndRemovesLiquidity() public {
        vm.startPrank(owner);
        _f().addLiquidity(address(amm), address(t0), 10e18, address(t1), 10e18, "");
        address clone = _f().getClone(address(amm));
        assertTrue(clone != address(0), "the AMM was cloned for this vault");

        _f().removeLiquidity(address(amm), "");
        _f().claimAMMFees(address(amm), "");
        vm.stopPrank();
    }

    function test_liquidityIsReadable() public {
        vm.prank(owner);
        _f().addLiquidity(address(amm), address(t0), 1e18, address(t1), 1e18, "");
        bytes[] memory data = new bytes[](1);
        data[0] = "";
        assertEq(_f().getLiquidities(_one(address(amm)), data).length, 1);
    }

    /// A protocol registered under the WRONG category cannot be used as an AMM.
    function test_aNonAMMCannotProvideLiquidity() public {
        guard.setProtocol(address(amm), LENDING_ID);
        vm.prank(owner);
        vm.expectRevert();
        _f().addLiquidity(address(amm), address(t0), 1e18, address(t1), 1e18, "");
    }

    function test_onlyOwnerMayProvideLiquidity() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        _f().addLiquidity(address(amm), address(t0), 1e18, address(t1), 1e18, "");
    }

    // ── intent ────────────────────────────────────────────────────────────────

    function test_ownerApprovesTheIntentRelayer() public {
        vm.prank(owner);
        _f().approveIntentRelayer(address(intent), address(t0));
        assertGt(t0.allowance(address(vault), address(settlement)), 0, "the relayer may pull the sell leg");
    }

    /**
     * The category check is the whole protection here. Approving a relayer hands out an ERC-20
     * allowance on the vault's balance, so a non-intent protocol must not be able to ask for one.
     */
    function test_aNonIntentProtocolCannotBeApproved() public {
        vm.prank(owner);
        vm.expectRevert();
        _f().approveIntentRelayer(address(amm), address(t0));
    }

    function test_ownerCancelsAnIntentOrder() public {
        vm.startPrank(owner);
        _f().approveIntentRelayer(address(intent), address(t0));
        _f().cancelIntentOrder(address(intent), hex"1234");
        vm.stopPrank();
    }

    // ── order signatures ──────────────────────────────────────────────────────

    /**
     * The vault vouches for an order only through a CLONED intent protocol.
     *
     * Adding the protocol LOCALLY is what clones it — and it is the only thing that does, which makes
     * updateProtocols a required setup step for off-chain trading even on a vault whose allowlist is
     * off. Registering it in the guard alone is not enough, and the failure is silent: orders simply
     * never validate.
     */
    function test_signatureValidatesOnlyThroughALocallyAddedIntentProtocol() public {
        assertEq(_f().isValidSignature(keccak256("order"), hex"00"), INVALID, "guard-registered is not enough");

        vm.prank(owner);
        _f().updateProtocols(_one(address(intent)), new address[](0)); // clones it
        assertEq(_f().isValidSignature(keccak256("order"), hex"00"), MAGIC, "now it can vouch");
    }

    /// A cloned protocol in the wrong category is skipped, so it can never sign for the vault.
    function test_aNonIntentCloneIsNeverAskedToSign() public {
        vm.prank(owner);
        _f().updateProtocols(_one(address(intent)), new address[](0));
        guard.setProtocol(address(intent), AMM_ID); // recategorised
        assertEq(_f().isValidSignature(keccak256("order"), hex"00"), INVALID, "skipped on category");
    }

    // ── off-chain authorisation ───────────────────────────────────────────────

    function test_orderAuthorisedForTheOwnerOnly() public {
        address stranger = makeAddr("stranger");
        assertTrue(_f().isOffchainOrderAuthorized(owner, address(t0), address(t1), 1e18));
        assertFalse(_f().isOffchainOrderAuthorized(stranger, address(t0), address(t1), 1e18));
    }

    /// The buy leg must be something the vault may hold, or a trade could deliver an unheld asset.
    function test_orderRefusedWhenTheBuyLegIsNotAllowed() public {
        MockERC20 rogue = new MockERC20("Rogue", "RGE", 18);
        assertFalse(_f().isOffchainOrderAuthorized(owner, address(t0), address(rogue), 1e18));
    }

    /// And it must be backed: an over-signed order simply stops authorising once its backing is gone.
    function test_orderRefusedWhenUnbacked() public {
        assertFalse(_f().isOffchainOrderAuthorized(owner, address(t0), address(t1), 10_000e18));
    }

    /**
     * Pausing trading stops new orders but NOT cancellation — otherwise pausing would be the one
     * action guaranteeing the orders already signed keep filling.
     */
    function test_pausingStopsOrdersButNotCancellation() public {
        vm.prank(owner);
        _f().disableTradeUntilTimestamp(block.timestamp + 7 days);
        assertFalse(_f().isOffchainOrderAuthorized(owner, address(t0), address(t1), 1e18), "no new orders");
        assertTrue(_f().isOffchainCancellationAuthorized(owner), "but cancelling still works");
    }
}
