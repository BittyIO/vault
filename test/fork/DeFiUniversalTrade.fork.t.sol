// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {MockGuard} from "../helpers/MockGuard.sol";
import {MARKET_TRADE_ID} from "../helpers/CategoryIds.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1SubVault} from "../../src/subvault/BittyV1SubVault.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";

import {UniswapUniversalTradeProtocol} from "protocol-contracts/src/protocols/UniswapUniversalTradeProtocol.sol";
import {sepolia} from "protocol-contracts/script/addresses.sol";

interface IVaultTrade {
    function marketSell(address amm, address sellToken, uint256 sellAmount, address buyToken, uint256 buyAmountMin, bytes calldata path)
        external;
    function addLiquidity(address amm, address token0, uint256 amount0, address token1, uint256 amount1, bytes calldata data)
        external;
    function getClone(address protocol) external view returns (address);
}

/**
 * Market swap through the VAULT and the REAL Universal Router + Permit2 — the integration a mock cannot
 * fake, and the net-new piece of the AMM split. Exercises the whole path: the vault approves the trade
 * clone, the clone pulls WETH, grants the router a Permit2 allowance, and the router routes a V3 swap on
 * the Sepolia WETH9/USDT pool, delivering USDT (net of the 0.2% output fee) back to the vault.
 *
 *   Run with:  FOUNDRY_PROFILE=fork ALCHEMY_KEY=<key> forge test --match-path test/fork/DeFiUniversalTrade.fork.t.sol
 */
contract DeFiUniversalTradeForkTest is Test {
    uint24 constant FEE = 500; // WETH/USDT 0.05% — the Sepolia pool that has liquidity
    uint8 constant ASSET_AMM_LIQUID = 4;

    BittyV1Vault vault;
    MockGuard guard;
    UniswapUniversalTradeProtocol tradeImpl;

    address owner = makeAddr("owner");
    address gasWrapped = makeAddr("gasWrapped");

    function setUp() public {
        vm.createSelectFork("sepolia");

        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);

        tradeImpl = new UniswapUniversalTradeProtocol(
            sepolia.UNISWAP_UNIVERSAL_ROUTER, sepolia.PERMIT2, sepolia.WETH9, sepolia.BITTY_GUARD
        );
        guard.setProtocol(address(tradeImpl), MARKET_TRADE_ID);
        // Both legs must be flagged AMM-liquid for a market swap; WETH9 crypto, USDT stable — both liquid.
        guard.setAsset(sepolia.WETH9, ASSET_AMM_LIQUID);
        guard.setAsset(sepolia.USDT, 1 | ASSET_AMM_LIQUID);

        BittyV1VaultDeFiFacet facet = new BittyV1VaultDeFiFacet();
        BittyV1SubVault subImpl = new BittyV1SubVault(address(facet));
        BittyV1Vault impl = new BittyV1Vault(address(facet), address(subImpl));
        bytes memory init =
            abi.encodeCall(BittyV1Vault.initialize, (owner, gasWrapped, false, address(0), 0, new bytes[](0)));
        vault = BittyV1Vault(payable(new ERC1967Proxy(address(impl), init)));
    }

    function test_vault_marketSell_throughUniversalRouter() public {
        uint256 sellAmount = 0.01 ether;
        deal(sepolia.WETH9, address(vault), sellAmount);

        uint256 usdtBefore = IERC20(sepolia.USDT).balanceOf(address(vault));
        bytes memory path = abi.encodePacked(sepolia.WETH9, FEE, sepolia.USDT);

        vm.prank(owner);
        IVaultTrade(address(vault)).marketSell(address(tradeImpl), sepolia.WETH9, sellAmount, sepolia.USDT, 0, path);

        assertEq(IERC20(sepolia.WETH9).balanceOf(address(vault)), 0, "the full sell amount left the vault");
        assertGt(
            IERC20(sepolia.USDT).balanceOf(address(vault)), usdtBefore, "USDT came back from the universal router"
        );
        // No dust stranded in the clone.
        address clone = IVaultTrade(address(vault)).getClone(address(tradeImpl));
        assertEq(IERC20(sepolia.WETH9).balanceOf(clone), 0, "no WETH left in the clone");
        assertEq(IERC20(sepolia.USDT).balanceOf(clone), 0, "no USDT left in the clone");
    }

    // Dispatch is by interface, not category: the trade adapter carries no market-maker methods, so
    // routing liquidity through it reverts at the interface call — no category gate needed to forbid it.
    function test_tradeAdapterCannotProvideLiquidity() public {
        deal(sepolia.WETH9, address(vault), 0.001 ether);
        bytes memory data = abi.encode(true, bytes("")); // shape is irrelevant; there is no addLiquidity to reach
        vm.prank(owner);
        vm.expectRevert();
        IVaultTrade(address(vault)).addLiquidity(address(tradeImpl), sepolia.WETH9, 0.001 ether, sepolia.USDT, 0, data);
    }
}
