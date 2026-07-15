// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AmountIsZero} from "../../src/interfaces/IBittyV1Vault.sol";
import {InvalidIntentProtocol, InvalidValidTo} from "../../src/interfaces/IBittyV1AssetManager.sol";
import {Deprecated, NotRegistered} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {OrderNotExpired} from "protocol-contracts/src/interfaces/IBittyV1IntentProtocol.sol";
import {mainnet} from "protocol-contracts/script/addresses.sol";
import {BittyV1Guard} from "guard-contracts/src/BittyV1Guard.sol";
import {BittyV1VaultHarness} from "../helpers/BittyV1VaultHarness.sol";
import {ProtocolTestSetup} from "../helpers/ProtocolTestSetup.sol";
import {MockIntentProtocol, MockIntentRegistry} from "../helpers/MockIntentProtocol.sol";

/// @dev Exercises the vault intent subsystem (limit orders, TWAP, cancellation, EIP-1271)
///      using MockIntentProtocol as the instruction builder so no real CoW/UniswapX is needed.
contract TestIntent is ProtocolTestSetup, BittyV1VaultHarness {
    BittyV1Guard internal guardContract;
    MockIntentRegistry internal registry;
    MockIntentProtocol internal mock; // register + approve targets set
    MockIntentProtocol internal mockSkip; // register + approve skipped

    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant STRANGER = address(0xBEEF);
    address internal constant NOT_AN_ASSET = address(0x1234);

    uint32 internal validTo;

    function setUp() public {
        guardContract = new BittyV1Guard();

        vm.startPrank(tx.origin);
        guardContract.addAssets(_pair(WETH, WBTC));
        guardContract.addStableCoins(_pair(mainnet.USDT, USDC));
        vm.stopPrank();

        setupMainnetForkProtocols(guardContract);

        registry = new MockIntentRegistry();
        mock = new MockIntentProtocol(address(registry), false, false);
        mockSkip = new MockIntentProtocol(address(registry), true, true);

        // register both intent protocols in the guard (tx.origin holds INTENT_MANAGER_ROLE)
        vm.prank(tx.origin);
        guardContract.addIntentProtocols(_pair(address(mock), address(mockSkip)));

        address[] memory vaultAssets = new address[](4);
        vaultAssets[0] = WETH;
        vaultAssets[1] = WBTC;
        vaultAssets[2] = mainnet.USDT;
        vaultAssets[3] = USDC;

        address[] memory empty = new address[](0);
        address[] memory intents = new address[](1);
        intents[0] = address(mock);

        this.initialize(
            tx.origin, // owner
            "intent-test",
            _single(address(this)), // asset manager = this
            address(guardContract),
            WETH,
            vaultAssets,
            empty, // lending
            empty, // staking
            empty, // amm
            intents,
            address(0)
        );

        // add the second (skip) protocol to the vault set (owner-only)
        vm.prank(tx.origin);
        this.addIntentProtocols(_single(address(mockSkip)));

        // fund the vault so forceApprove targets a live token
        deal(WETH, address(this), 100 ether);
        deal(WBTC, address(this), 10e8);

        validTo = uint32(block.timestamp + 1 days);
    }

    // ---------- helpers ----------

    function _pair(address a, address b) private pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
    }

    // ---------- limit orders ----------

    function testLimitSellHappyPathAndReApproveSkip() public {
        // first order: sets max allowance via the approve branch
        bytes32 id1 = this.limitSell(address(mock), WETH, USDC, 1 ether, 1000e6, validTo);
        assertEq(registry.registerCount(), 1);
        assertEq(registry.lastRegistered(), id1);
        assertEq(IERC20(WETH).allowance(address(this), address(registry)), type(uint256).max);

        // second order same sell token: allowance already sufficient -> forceApprove skipped
        bytes32 id2 = this.limitSell(address(mock), WETH, USDC, 2 ether, 2000e6, validTo);
        assertEq(registry.registerCount(), 2);
        assertTrue(id1 != id2);
    }

    function testLimitSellSkipRegisterAndApprove() public {
        uint256 before = registry.registerCount();
        this.limitSell(address(mockSkip), WETH, USDC, 1 ether, 1000e6, validTo);
        // skipRegister protocol never calls the registry
        assertEq(registry.registerCount(), before);
        assertEq(IERC20(WETH).allowance(address(this), address(registry)), 0);
    }

    function testLimitBuyHappyPath() public {
        bytes32 id = this.limitBuy(address(mock), WETH, USDC, 1000e6, 1 ether, validTo);
        assertTrue(id != bytes32(0));
        assertEq(registry.registerCount(), 1);
    }

    function testLimitSellAmountIsZero() public {
        vm.expectRevert(AmountIsZero.selector);
        this.limitSell(address(mock), WETH, USDC, 0, 1000e6, validTo);

        vm.expectRevert(AmountIsZero.selector);
        this.limitSell(address(mock), WETH, USDC, 1 ether, 0, validTo);
    }

    function testLimitSellInvalidValidTo() public {
        vm.expectRevert(InvalidValidTo.selector);
        this.limitSell(address(mock), WETH, USDC, 1 ether, 1000e6, uint32(block.timestamp));
    }

    function testLimitSellInvalidIntentProtocol() public {
        vm.expectRevert(InvalidIntentProtocol.selector);
        this.limitSell(address(0xDEAD), WETH, USDC, 1 ether, 1000e6, validTo);
    }

    function testLimitSellDeprecatedProtocol() public {
        vm.prank(tx.origin);
        guardContract.deprecateIntentProtocols(_single(address(mock)));

        vm.expectRevert(Deprecated.selector);
        this.limitSell(address(mock), WETH, USDC, 1 ether, 1000e6, validTo);
    }

    function testLimitSellChecksAsset() public {
        vm.expectRevert(NotRegistered.selector);
        this.limitSell(address(mock), NOT_AN_ASSET, USDC, 1 ether, 1000e6, validTo);
    }

    function testLimitOrderOnlyAssetManager() public {
        vm.prank(STRANGER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, STRANGER, ASSET_MANAGER_ROLE
            )
        );
        this.limitSell(address(mock), WETH, USDC, 1 ether, 1000e6, validTo);
    }

    // ---------- cancel limit orders ----------

    function testCancelLimitOrder() public {
        bytes32 id = this.limitSell(address(mock), WETH, USDC, 1 ether, 1000e6, validTo);

        this.cancelLimitOrder(address(mock), abi.encode(id));
        assertEq(registry.cancelCount(), 1);
        assertEq(registry.lastCancelled(), id);

        // record gone -> second cancel reverts
        vm.expectRevert(InvalidIntentProtocol.selector);
        this.cancelLimitOrder(address(mock), abi.encode(id));
    }

    function testCancelLimitOrderNoClone() public {
        // mockSkip has never been cloned (no order placed on it yet)
        vm.expectRevert(InvalidIntentProtocol.selector);
        this.cancelLimitOrder(address(mockSkip), abi.encode(bytes32(uint256(1))));
    }

    // ---------- cleanExpiredLimitOrders (permissionless) ----------

    function testCleanExpiredLimitOrders() public {
        bytes32 id = this.limitSell(address(mock), WETH, USDC, 1 ether, 1000e6, validTo);

        // still live -> reverts
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        vm.expectRevert(OrderNotExpired.selector);
        this.cleanExpiredLimitOrders(address(mock), ids);

        // warp past validTo -> anyone can clean
        vm.warp(uint256(validTo) + 1);
        vm.prank(STRANGER);
        this.cleanExpiredLimitOrders(address(mock), ids);
        assertEq(registry.cancelCount(), 1);
    }

    function testCleanExpiredLimitOrdersNoClone() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        vm.expectRevert(InvalidIntentProtocol.selector);
        this.cleanExpiredLimitOrders(address(mockSkip), ids);
    }

    function testCleanExpiredUnknownOrder() public {
        // create a clone first so the no-clone guard passes
        this.limitSell(address(mock), WETH, USDC, 1 ether, 1000e6, validTo);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(0xABCDEF)); // never recorded -> expiresAt == 0
        vm.expectRevert(OrderNotExpired.selector);
        this.cleanExpiredLimitOrders(address(mock), ids);
    }

    // ---------- TWAP ----------

    function testTwapSellHappyPath() public {
        bytes32 twapId = this.twapSell(address(mock), WETH, USDC, 4 ether, 1000e6, 4, 300, 0);
        assertTrue(twapId != bytes32(0));
        assertEq(registry.registerCount(), 1);

        this.cancelTwapOrder(address(mock), twapId);
        assertEq(registry.cancelCount(), 1);
    }

    /**
     * @dev The whole point of the change: two TWAPs on the SAME sell token now coexist — the old
     *      one-per-token guard is gone. (The real CoWSwapV1Protocol also derives a per-block-timestamp
     *      appData salt so their CoW part orders never collide; that's covered in the fork suite. The
     *      mock builder has no salt, so here we vary the size to get distinct twapIds.)
     */
    function testTwapSellSameTokenCoexist() public {
        bytes32 id1 = this.twapSell(address(mock), WETH, USDC, 4 ether, 1000e6, 4, 300, 0);
        bytes32 id2 = this.twapSell(address(mock), WETH, USDC, 2 ether, 500e6, 4, 300, 0);
        assertTrue(id1 != id2);
        assertEq(registry.registerCount(), 2);
    }

    function testTwapSellAmountIsZero() public {
        vm.expectRevert(AmountIsZero.selector);
        this.twapSell(address(mock), WETH, USDC, 0, 1000e6, 4, 300, 0);

        vm.expectRevert(AmountIsZero.selector);
        this.twapSell(address(mock), WETH, USDC, 4 ether, 1000e6, 0, 300, 0);
    }

    function testTwapSellSkipTargets() public {
        this.twapSell(address(mockSkip), WETH, USDC, 4 ether, 1000e6, 4, 300, 0);
        assertEq(registry.registerCount(), 0);
        assertEq(IERC20(WETH).allowance(address(this), address(registry)), 0);
    }

    function testTwapBuyHappyPath() public {
        bytes32 twapId = this.twapBuy(address(mock), WETH, USDC, 4000e6, 1 ether, 4, 300, 0);
        assertTrue(twapId != bytes32(0));
        assertEq(registry.registerCount(), 1);

        // second TWAP on the same sell token coexists (per-token guard removed)
        bytes32 twapId2 = this.twapBuy(address(mock), WETH, USDC, 2000e6, 1 ether, 4, 300, 0);
        assertTrue(twapId2 != twapId);
        assertEq(registry.registerCount(), 2);
    }

    function testTwapBuyAmountIsZero() public {
        vm.expectRevert(AmountIsZero.selector);
        this.twapBuy(address(mock), WETH, USDC, 0, 1 ether, 4, 300, 0);

        // totalBuyAmount < n -> minPartLimit == 0
        vm.expectRevert(AmountIsZero.selector);
        this.twapBuy(address(mock), WETH, USDC, 3, 1 ether, 4, 300, 0);
    }

    function testCancelTwapUnknownId() public {
        vm.expectRevert(InvalidIntentProtocol.selector);
        this.cancelTwapOrder(address(mock), bytes32(uint256(0xDEAD)));
    }

    function testTwapOnlyAssetManager() public {
        vm.prank(STRANGER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, STRANGER, ASSET_MANAGER_ROLE
            )
        );
        this.twapSell(address(mock), WETH, USDC, 4 ether, 1000e6, 4, 300, 0);
    }

    // ---------- protocol set management ----------

    function testGetAndRemoveIntentProtocols() public {
        address[] memory active = this.getIntentProtocols();
        assertEq(active.length, 2);

        vm.prank(tx.origin);
        this.removeIntentProtocols(_single(address(mockSkip)));

        assertEq(this.getIntentProtocols().length, 1);

        // removed from the vault set -> reverts even though guard still knows it
        vm.expectRevert(InvalidIntentProtocol.selector);
        this.limitSell(address(mockSkip), WETH, USDC, 1 ether, 1000e6, validTo);
    }

    function testAddIntentProtocolsOnlyOwner() public {
        vm.prank(STRANGER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, STRANGER, DEFAULT_ADMIN_ROLE
            )
        );
        this.addIntentProtocols(_single(address(mock)));
    }

    function testGetClone() public {
        assertEq(this.getClone(address(mock)), address(0));
        this.limitSell(address(mock), WETH, USDC, 1 ether, 1000e6, validTo);
        assertTrue(this.getClone(address(mock)) != address(0));
    }

    // ---------- EIP-1271 ----------

    function testIsValidSignature() public {
        // create a clone so isValidSignature has something to delegate to
        this.limitSell(address(mock), WETH, USDC, 1 ether, 1000e6, validTo);
        address clone = this.getClone(address(mock));

        bytes32 goodHash = keccak256("good");
        bytes32 badHash = keccak256("bad");
        MockIntentProtocol(clone).setValid(goodHash, true);

        // matching clone returns the magic value
        assertEq(this.isValidSignature(goodHash, ""), bytes4(0x1626ba7e));
        // unknown hash: clone reverts, caught, no match -> failure value
        assertEq(this.isValidSignature(badHash, ""), bytes4(0xffffffff));
    }

    function testIsValidSignatureNoClones() public view {
        // nothing cloned yet -> loop skips everything -> failure value
        assertEq(this.isValidSignature(keccak256("x"), ""), bytes4(0xffffffff));
    }
}
