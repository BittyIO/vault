// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ASSET_STABLE_COIN} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {MockMarketProtocol} from "../helpers/MockMarketProtocol.sol";
import {MockIntentProtocol} from "../helpers/MockIntentProtocol.sol";
import {MockSettlement} from "../helpers/MockSettlement.sol";
import {MARKET_TRADE_ID, MARKET_MAKER_ID, INTENT_ID, LENDING_ID} from "../helpers/CategoryIds.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";

interface IFacet {
    function addLiquidity(address marketMaker, address t0, uint256 a0, address t1, uint256 a1, bytes memory data)
        external;
    function removeLiquidity(address marketMaker, bytes memory data) external;
    function claimMarketMakerFees(address marketMaker, bytes memory data) external;
    function getLiquidities(address[] calldata marketMakers, bytes[] calldata data)
        external
        view
        returns (uint256[] memory);
    function approveIntentRelayer(address intent, address token) external;
    function cancelIntentOrder(address intent, bytes calldata uid) external;
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4);
    function isOffchainOrderAuthorized(address signer, address sellToken, address buyToken, uint256 sellAmount)
        external
        view
        returns (bool);
    function isOffchainCancellationAuthorized(address signer) external view returns (bool);
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
    MockMarketProtocol marketMaker;
    MockIntentProtocol intent;
    MockSettlement settlement;

    address owner = makeAddr("owner");
    address gasWrapped = makeAddr("gasWrapped");
    bytes4 constant MAGIC = 0x1626ba7e;
    bytes4 constant INVALID = 0xffffffff;

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);

        BittyV1VaultDeFiFacet facet = new BittyV1VaultDeFiFacet();
        BittyV1Vault impl = new BittyV1Vault(address(facet));
        bytes memory init =
            abi.encodeCall(BittyV1Vault.initialize, (owner, gasWrapped, false, address(0), 0, new bytes[](0)));
        vault = BittyV1Vault(payable(new ERC1967Proxy(address(impl), init)));

        t0 = new MockERC20("Token0", "T0", 18);
        t1 = new MockERC20("Token1", "T1", 18);
        marketMaker = new MockMarketProtocol();
        settlement = new MockSettlement();
        intent = new MockIntentProtocol();
        intent.setEndpoints(address(settlement), address(settlement));

        guard.setAsset(address(t0), ASSET_STABLE_COIN);
        guard.setAsset(address(t1), 2);
        guard.setProtocol(address(marketMaker), MARKET_MAKER_ID);
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

    // ── market making ───────────────────────────────────────────────────────────────────

    function test_ownerAddsAndRemovesLiquidity() public {
        vm.startPrank(owner);
        _f().addLiquidity(address(marketMaker), address(t0), 10e18, address(t1), 10e18, "");
        address clone = _f().getClone(address(marketMaker));
        assertTrue(clone != address(0), "the market maker was cloned for this vault");

        _f().removeLiquidity(address(marketMaker), "");
        _f().claimMarketMakerFees(address(marketMaker), "");
        vm.stopPrank();
    }

    function test_liquidityIsReadable() public {
        vm.prank(owner);
        _f().addLiquidity(address(marketMaker), address(t0), 1e18, address(t1), 1e18, "");
        bytes[] memory data = new bytes[](1);
        data[0] = "";
        assertEq(_f().getLiquidities(_one(address(marketMaker)), data).length, 1);
    }

    /// The protocol must be guard-curated: one the guard never registered is refused up front,
    /// before any clone or interface call.
    function test_anUnregisteredProtocolCannotProvideLiquidity() public {
        MockMarketProtocol stranger = new MockMarketProtocol(); // never registered with the guard
        vm.prank(owner);
        vm.expectRevert();
        _f().addLiquidity(address(stranger), address(t0), 1e18, address(t1), 1e18, "");
    }

    /// Market makers carry their own guard category, so being registered is not enough - a protocol
    /// filed under any other category is refused even when it implements the market-maker interface.
    /// Without the category check, `addLiquidity` would approve the vault's tokens to the clone of a
    /// protocol the guard never blessed for market making.
    function test_aProtocolFiledUnderAnotherCategoryCannotProvideLiquidity() public {
        MockMarketProtocol miscategorised = new MockMarketProtocol();
        MockGuard(BITTY_GUARD).setProtocol(address(miscategorised), MARKET_TRADE_ID);
        vm.prank(owner);
        vm.expectRevert();
        _f().addLiquidity(address(miscategorised), address(t0), 1e18, address(t1), 1e18, "");

        MockGuard(BITTY_GUARD).setProtocol(address(miscategorised), LENDING_ID);
        vm.prank(owner);
        vm.expectRevert();
        _f().addLiquidity(address(miscategorised), address(t0), 1e18, address(t1), 1e18, "");
    }

    function test_onlyOwnerMayProvideLiquidity() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        _f().addLiquidity(address(marketMaker), address(t0), 1e18, address(t1), 1e18, "");
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
        _f().approveIntentRelayer(address(marketMaker), address(t0));
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
        guard.setProtocol(address(intent), MARKET_TRADE_ID); // recategorised
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
}
