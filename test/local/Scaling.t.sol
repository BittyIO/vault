// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {guardAddAssets, guardAddStableCoins, guardAddProtocols} from "../helpers/GuardRegister.sol";
import {GUARD_DEPLOYER} from "../helpers/GuardDeployer.sol";
import {console2} from "forge-std/console2.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1VaultFactory} from "../../src/BittyV1VaultFactory.sol";
import {BittyV1VaultForwarder} from "../../src/BittyV1VaultForwarder.sol";
import {BittyV1AutoYieldKeeper} from "../../src/BittyV1AutoYieldKeeper.sol";
import {BittyV1Guard} from "guard-contracts/src/BittyV1Guard.sol";
import {BITTY_GUARD, BITTY_FORWARDER, BITTY_FEE_COLLECTOR} from "../../src/logic/Constants.sol";
import {ERC2771Forwarder} from "openzeppelin-contracts/contracts/metatx/ERC2771Forwarder.sol";
import {AutoYield} from "../../src/interfaces/IBittyV1Vault.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockLendingProtocol} from "../helpers/MockLendingProtocol.sol";

/**
 * @notice Does the relaying architecture actually hold up with many vaults behind one keeper?
 *
 * @dev Everything here is a property that only shows up at N > 1. A single-vault test cannot tell a
 *      per-vault nonce lane from a flat one, cannot show that a stuck vault leaves the others alone,
 *      and cannot show that rotating one key reaches every vault at once.
 */
contract ScalingTest is Test {
    uint256 internal constant N = 2000;

    /// Stable coin each vault holds back so it can still pay for the relay that swept it.
    uint256 internal constant FEE_FUNDING = 50_000000;

    BittyV1Guard internal guard;
    WETH internal weth;
    MockERC20 internal usdc;
    MockERC20 internal usdt;
    MockLendingProtocol internal lending;
    BittyV1VaultForwarder internal fwd;
    BittyV1VaultFactory internal factory;
    BittyV1AutoYieldKeeper internal keeper;

    address internal relayer = makeAddr("relayer");
    address internal collector = BITTY_FEE_COLLECTOR;
    address internal keeperOwner = makeAddr("keeperOwner");

    address internal hotKey;
    uint256 internal hotKeyPk;

    address[] internal owners;
    BittyV1Vault[] internal vaults;
    mapping(address => bool) internal _seen;

    bytes32 constant TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint48 deadline,bytes data)"
    );

    function setUp() public {
        (hotKey, hotKeyPk) = makeAddrAndKey("keeperHotKey");
        weth = new WETH();
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        deployCodeTo("BittyV1Guard.sol:BittyV1Guard", BITTY_GUARD);
        vm.stopPrank();
        guard = BittyV1Guard(BITTY_GUARD);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        // A second stable coin with NO auto-yield route. Relayed sweeps are charged in this one,
        // because a sweep takes the WHOLE balance of the asset it routes — there is no per-asset
        // floor holding anything back — so charging in the swept coin would leave nothing to pay
        // with. See test_sweepingTheFeeCoinLeavesNothingToPayTheRelayer.
        usdt = new MockERC20("Tether USD", "USDT", 6);
        lending = new MockLendingProtocol();

        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guard.grantRole(guard.PROTOCOL_MANAGER_ROLE(), tx.origin);
        guardAddStableCoins(address(guard), _two(address(usdc), address(usdt)));
        guardAddProtocols(address(guard), _one(address(lending)));
        vm.stopPrank();

        deployCodeTo("BittyV1VaultForwarder.sol:BittyV1VaultForwarder", BITTY_FORWARDER);
        fwd = BittyV1VaultForwarder(BITTY_FORWARDER);
        vm.prank(fwd.DEPLOYER(), fwd.DEPLOYER());
        fwd.initialize(keeperOwner);
        vm.prank(keeperOwner);
        fwd.setRelayerApproval(relayer, true);

        keeper = new BittyV1AutoYieldKeeper(keeperOwner);
        vm.startPrank(keeperOwner);
        keeper.setForwarder(address(fwd), true);
        keeper.setSigner(hotKey, uint64(block.timestamp + 365 days));
        vm.stopPrank();

        address facet = address(new BittyV1VaultDeFiFacet());
        address impl = address(new BittyV1Vault(facet, address(keeper)));
        factory = new BittyV1VaultFactory();
        vm.prank(factory.DEPLOYER(), factory.DEPLOYER());
        factory.initialize(impl, address(weth));

        for (uint256 i; i < N; ++i) {
            address o = makeAddr(string.concat("owner", vm.toString(i)));
            owners.push(o);
            vm.prank(o);
            factory.activateVault();
            BittyV1Vault v = BittyV1Vault(payable(factory.vaultAddress(o)));
            vaults.push(v);

            usdc.mint(address(v), 1_000_000000);
            // Funds the relayer fee. USDT has no route, so the sweep leaves it alone.
            usdt.mint(address(v), FEE_FUNDING);
            vm.startPrank(o);
            v.setAutoYielding(AutoYield({asset: address(usdc), protocol: address(lending)}));
            vm.stopPrank();
        }
    }

    function _one(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function _two(address a, address b) internal pure returns (address[] memory r) {
        r = new address[](2);
        r[0] = a;
        r[1] = b;
    }

    function _sweepRequest(uint256 i) internal view returns (ERC2771Forwarder.ForwardRequestData memory r) {
        bytes memory data = abi.encodeCall(BittyV1Vault.autoYield, (address(usdc)));
        address to = address(vaults[i]);
        r = ERC2771Forwarder.ForwardRequestData({
            from: address(keeper),
            to: to,
            value: 0,
            gas: 2_000_000,
            deadline: uint48(block.timestamp + 1 days),
            data: data,
            signature: ""
        });
        bytes32 structHash = keccak256(
            abi.encode(
                TYPEHASH,
                address(keeper),
                to,
                uint256(0),
                uint256(2_000_000),
                fwd.nonceFor(address(keeper), to),
                r.deadline,
                keccak256(data)
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("BittyV1VaultForwarder")),
                keccak256(bytes("1")),
                block.chainid,
                address(fwd)
            )
        );
        (uint8 v, bytes32 rr, bytes32 ss) =
            vm.sign(hotKeyPk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        r.signature = abi.encodePacked(rr, ss, v);
    }

    /**
     * @dev Builds the request before pranking. vm.prank applies to the very next call, and
     *      _sweepRequest reads fwd.nonceFor — so passing it inline as an argument silently spends the
     *      prank on that read and the relay arrives from the test contract instead.
     */
    function _relay(uint256 i, uint256 fee) internal {
        ERC2771Forwarder.ForwardRequestData memory r = _sweepRequest(i);
        vm.prank(relayer);
        fwd.executeWithFee(r, address(usdt), fee);
    }

    /// Reads through the fallback into the DeFi facet, which is how the balance getter is reached.
    function _supplied(BittyV1Vault v) internal view returns (uint256) {
        address[] memory p = _one(address(lending));
        address[] memory a = _one(address(usdc));
        (bool ok, bytes memory ret) =
            address(v).staticcall(abi.encodeWithSignature("getBalances(address[],address[])", p, a));
        require(ok, "getBalances failed");
        uint256[] memory balances = abi.decode(ret, (uint256[]));
        return balances[0];
    }

    // ============ The properties that only exist at N > 1 ============

    /**
     * Every vault is a distinct clone at its own deterministic address, and one keeper signs for all of
     * them — every request at nonce 0 of its OWN lane. Under a flat per-signer nonce only the first
     * would be valid.
     */
    function test_oneKeeperSweepsEveryVault() public {
        for (uint256 i; i < N; ++i) {
            assertEq(fwd.nonceFor(address(keeper), address(vaults[i])), 0, "each lane starts at zero");
        }

        for (uint256 i; i < N; ++i) {
            _relay(i, 1_000000);
        }

        for (uint256 i; i < N; ++i) {
            assertGt(_supplied(vaults[i]), 0, "vault swept into its route");
            assertEq(fwd.nonceFor(address(keeper), address(vaults[i])), 1, "its own lane advanced by one");
        }
        assertEq(usdt.balanceOf(collector), N * 1_000000, "one fee collected per vault");
    }

    /**
     * Requests signed for every vault up front, then relayed BACKWARDS. Order across vaults must not
     * matter — this is the property a flat nonce cannot provide, since it forces a global ordering.
     */
    function test_sweepsRelayOutOfOrderAcrossVaults() public {
        ERC2771Forwarder.ForwardRequestData[] memory reqs = new ERC2771Forwarder.ForwardRequestData[](N);
        for (uint256 i; i < N; ++i) {
            reqs[i] = _sweepRequest(i);
        }

        for (uint256 i = N; i > 0; --i) {
            ERC2771Forwarder.ForwardRequestData memory r = reqs[i - 1];
            vm.prank(relayer);
            fwd.executeWithFee(r, address(usdt), 0);
        }

        for (uint256 i; i < N; ++i) {
            assertGt(_supplied(vaults[i]), 0, "swept regardless of relay order");
        }
    }

    /// One vault that cannot be swept must not hold up the other forty-nine.
    function test_oneBrokenVaultDoesNotStallTheFleet() public {
        uint256 broken = 7;
        vm.prank(owners[broken]);
        vaults[broken].disableGasless();

        ERC2771Forwarder.ForwardRequestData[] memory reqs = new ERC2771Forwarder.ForwardRequestData[](N);
        for (uint256 i; i < N; ++i) {
            reqs[i] = _sweepRequest(i);
        }

        uint256 swept;
        for (uint256 i; i < N; ++i) {
            vm.prank(relayer);
            if (i == broken) {
                vm.expectRevert(BittyV1VaultForwarder.FeeExceedsVaultBudget.selector);
                fwd.executeWithFee(reqs[i], address(usdt), 1_000000);
            } else {
                fwd.executeWithFee(reqs[i], address(usdt), 1_000000);
                ++swept;
            }
        }

        assertEq(swept, N - 1, "every other vault went through");
        assertEq(_supplied(vaults[broken]), 0, "the broken one did not");
        assertEq(fwd.nonceFor(address(keeper), address(vaults[broken])), 0, "and its lane never advanced");
    }

    /// Rotating the hot key is ONE transaction and reaches every vault, with no owner action anywhere.
    function test_keyRotationReachesEveryVaultAtOnce() public {
        _relay(0, 0);

        (address next, uint256 nextPk) = makeAddrAndKey("keeperHotKey2");
        vm.startPrank(keeperOwner);
        keeper.setSigner(next, uint64(block.timestamp + 365 days));
        keeper.setSigner(hotKey, 0);
        vm.stopPrank();

        // The old key is dead everywhere at once.
        ERC2771Forwarder.ForwardRequestData memory stale = _sweepRequest(1);
        vm.prank(relayer);
        vm.expectRevert();
        fwd.executeWithFee(stale, address(usdt), 0);

        // The new key works everywhere at once, and no vault was touched to make that true.
        hotKeyPk = nextPk;
        hotKey = next;
        for (uint256 i = 1; i < 5; ++i) {
            _relay(i, 0);
            assertGt(_supplied(vaults[i]), 0);
        }
    }

    /// Budgets are per vault: draining one must not reduce what any other can pay.
    function test_gasBudgetsAreIsolatedPerVault() public {
        uint256 before1 = vaults[1].gasBudgetRemaining();

        _relay(0, 10_000000);

        assertLt(vaults[0].gasBudgetRemaining(), before1, "vault 0 spent from its own budget");
        assertEq(vaults[1].gasBudgetRemaining(), before1, "vault 1 untouched");
    }

    /**
     * Cost per sweep must not grow with fleet size — nothing in the vault or forwarder may iterate over
     * anything global. Compares the first sweep against the last of fifty.
     */
    function test_perSweepCostIsFlatAcrossTheFleet() public {
        ERC2771Forwarder.ForwardRequestData memory first = _sweepRequest(0);
        uint256 g0 = gasleft();
        vm.prank(relayer);
        fwd.executeWithFee(first, address(usdt), 1_000000);
        uint256 firstCost = g0 - gasleft();

        for (uint256 i = 1; i < N - 1; ++i) {
            _relay(i, 1_000000);
        }

        ERC2771Forwarder.ForwardRequestData memory last = _sweepRequest(N - 1);
        uint256 g1 = gasleft();
        vm.prank(relayer);
        fwd.executeWithFee(last, address(usdt), 1_000000);
        uint256 lastCost = g1 - gasleft();

        console2.log("first sweep gas", firstCost);
        console2.log("last  sweep gas", lastCost);
        // Generous bound: the point is O(1), not a precise figure. Warm-slot effects make the last
        // sweep cheaper, never meaningfully dearer.
        assertLt(lastCost, firstCost + 5_000, "per-sweep cost must not grow with the number of vaults");
    }

    /**
     * The trap the removal of MIN_STABLE_COIN_RESERVE left behind: with no minimal balance, auto-yield
     * supplies the entire stable coin balance, and the fee — charged after the call — has nothing left
     * to draw on. The relay reverts and the sweep is lost.
     */
    /**
     * @notice Charging a relayed sweep in the coin it sweeps leaves nothing to pay with.
     * @dev The constraint that replaced the per-asset minimal balance. A sweep routes the WHOLE free
     *      balance of its asset, so if the fee is charged in that same asset the fee leg finds a zero
     *      balance and the transaction reverts — nothing is swept and the relayer eats the gas.
     *
     *      So a gasless auto-yield vault has to hold a stable coin that is NOT routed, which is what
     *      every other test here does by charging in USDT while routing USDC.
     */
    function test_sweepingTheFeeCoinLeavesNothingToPayTheRelayer() public {
        address o = makeAddr("feeCoinIsRoutedOwner");
        vm.prank(o);
        factory.activateVault();
        BittyV1Vault v = BittyV1Vault(payable(factory.vaultAddress(o)));
        usdc.mint(address(v), 1_000_000000);
        vm.prank(o);
        v.setAutoYielding(AutoYield({asset: address(usdc), protocol: address(lending)}));

        vaults.push(v);
        ERC2771Forwarder.ForwardRequestData memory r = _sweepRequest(vaults.length - 1);
        // Charged in USDC, the very coin being swept.
        vm.prank(relayer);
        vm.expectRevert();
        fwd.executeWithFee(r, address(usdc), 1_000000);
    }

    /// Owners, vaults — the factory's one-vault-per-owner rule holds at scale.
    function test_everyVaultIsADistinctAddress() public {
        for (uint256 i; i < N; ++i) {
            assertFalse(_seen[address(vaults[i])], "no address collision");
            _seen[address(vaults[i])] = true;
            assertEq(vaults[i].owner(), owners[i], "each vault belongs to its own owner");
        }
    }
}
