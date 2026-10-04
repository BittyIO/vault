// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";

import {MockGuard} from "../helpers/MockGuard.sol";
import {MARKET_MAKER_ID} from "../helpers/CategoryIds.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1SubVault} from "../../src/subvault/BittyV1SubVault.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";

import {UniswapV3MarketMakerProtocol} from "protocol-contracts/src/protocols/UniswapV3MarketMakerProtocol.sol";
import {sepolia} from "protocol-contracts/script/addresses.sol";
import {
    IUniswapV3Factory,
    IUniswapV3Pool,
    IUniswapV3Router,
    INonfungiblePositionManager
} from "protocol-contracts/src/libs/uniswap/v3/Uniswap.sol";

interface IVaultLP {
    function addLiquidity(address amm, address token0, uint256 amount0, address token1, uint256 amount1, bytes calldata data)
        external;
    function removeLiquidity(address amm, bytes calldata data) external;
    function claimAMMFees(address amm, bytes calldata data) external;
}

/**
 * Uniswap V3 LP through the VAULT and the REAL on-chain adapter — the integration a mock cannot fake.
 *
 * This is the test that catches interface drift like the `positionAssetManager()` vs `positionManager()`
 * getter mismatch: the local mocks (NFTPositionProtocol / DeFiGuardrails mocks) were written to match the
 * vault's expected name, so `_approveNFTIfNeeded` "worked" against them and remove/claim passed — while
 * the DEPLOYED UniswapV3Protocol exposes a different name, so the NFT approval never landed and every
 * unwind reverted with "ERC721: transfer caller is not owner nor approved". Here the vault clones the
 * real adapter and hits the real NonfungiblePositionManager, so the whole approve → transfer → decrease →
 * collect → return path is exercised end to end.
 *
 *   Run with:  FOUNDRY_PROFILE=fork ALCHEMY_KEY=<key> forge test --match-path test/fork/DeFiUniswapLP.fork.t.sol
 */
contract DeFiUniswapLPForkTest is Test {
    bytes32 constant ERC721_TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    uint24 constant FEE = 500; // WETH/USDT 0.05% — the sepolia pool that has liquidity
    int24 constant SPACING = 10;

    BittyV1Vault vault;
    MockGuard guard;
    UniswapV3MarketMakerProtocol uniImpl; // the real adapter implementation the vault clones

    address npm; // NonfungiblePositionManager
    address token0;
    address token1;

    address owner = makeAddr("owner");
    address gasWrapped = makeAddr("gasWrapped");

    function setUp() public {
        vm.createSelectFork("sepolia");

        // Guard the vault reads from — register the real adapter as AMM and both tokens as assets.
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);

        uniImpl = new UniswapV3MarketMakerProtocol(sepolia.UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER);
        npm = sepolia.UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER;
        guard.setProtocol(address(uniImpl), MARKET_MAKER_ID);
        guard.setAsset(sepolia.WETH9, 1);
        guard.setAsset(sepolia.USDT, 1);

        // The vault (facet behind an ERC1967 proxy), allowlist off.
        BittyV1VaultDeFiFacet facet = new BittyV1VaultDeFiFacet();
        BittyV1SubVault subImpl = new BittyV1SubVault(address(facet));
        BittyV1Vault impl = new BittyV1Vault(address(facet), address(subImpl));
        bytes memory init =
            abi.encodeCall(BittyV1Vault.initialize, (owner, gasWrapped, false, address(0), 0, new bytes[](0)));
        vault = BittyV1Vault(payable(new ERC1967Proxy(address(impl), init)));

        (token0, token1) =
            sepolia.USDT < sepolia.WETH9 ? (sepolia.USDT, sepolia.WETH9) : (sepolia.WETH9, sepolia.USDT);
    }

    // Provide full-ish liquidity from the vault through the real adapter; returns the minted tokenId.
    function _addLiquidity() internal returns (uint256 tokenId) {
        address pool =
            IUniswapV3Factory(IUniswapV3Router(sepolia.UNISWAP_V3_ROUTER).factory()).getPool(token0, token1, FEE);
        require(pool != address(0), "no WETH/USDT pool on this fork");
        (, int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();
        int24 lower = (tick / SPACING) * SPACING - SPACING * 10;
        int24 upper = (tick / SPACING) * SPACING + SPACING * 10;

        uint256 amount0 = token0 == sepolia.WETH9 ? 0.01 ether : 20e6;
        uint256 amount1 = token1 == sepolia.WETH9 ? 0.01 ether : 20e6;
        deal(token0, address(vault), amount0);
        deal(token1, address(vault), amount1);

        INonfungiblePositionManager.MintParams memory mp = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: FEE,
            tickLower: lower,
            tickUpper: upper,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(0), // the adapter mints to itself then hands the NFT to the vault
            deadline: block.timestamp
        });
        bytes memory data = abi.encode(true, abi.encode(mp)); // (isMint, params) — the wrapper the adapter requires

        vm.recordLogs();
        vm.prank(owner);
        IVaultLP(address(vault)).addLiquidity(address(uniImpl), token0, amount0, token1, amount1, data);

        // The NFT's final Transfer lands on the vault.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 toVault = bytes32(uint256(uint160(address(vault))));
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == npm && logs[i].topics.length == 4 && logs[i].topics[0] == ERC721_TRANSFER_TOPIC
                    && logs[i].topics[2] == toVault
            ) {
                tokenId = uint256(logs[i].topics[3]);
                break;
            }
        }
        require(tokenId != 0, "no LP NFT minted to the vault");
    }

    function _liquidity(uint256 tokenId) internal view returns (uint128 liq) {
        (,,,,,,, liq,,,,) = INonfungiblePositionManager(npm).positions(tokenId);
    }

    function test_vault_addLiquidity_mintsNftToVault() public {
        uint256 tokenId = _addLiquidity();
        assertEq(IERC721(npm).ownerOf(tokenId), address(vault), "vault should hold the LP NFT");
        assertGt(_liquidity(tokenId), 0, "position should have liquidity");
    }

    function test_vault_addLiquidity_dataCannotOutspendValidatedAmount() public {
        address pool =
            IUniswapV3Factory(IUniswapV3Router(sepolia.UNISWAP_V3_ROUTER).factory()).getPool(token0, token1, FEE);
        (, int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();
        int24 lower = (tick / SPACING) * SPACING - SPACING * 10;
        int24 upper = (tick / SPACING) * SPACING + SPACING * 10;

        // Caller validates a tiny amount but tells the adapter (via data) to pull far more; the vault holds it.
        uint256 validated0 = token0 == sepolia.WETH9 ? 0.001 ether : 1e6;
        uint256 validated1 = token1 == sepolia.WETH9 ? 0.001 ether : 1e6;
        uint256 dataAmount0 = token0 == sepolia.WETH9 ? 0.05 ether : 500e6;
        uint256 dataAmount1 = token1 == sepolia.WETH9 ? 0.05 ether : 500e6;
        deal(token0, address(vault), dataAmount0);
        deal(token1, address(vault), dataAmount1);

        INonfungiblePositionManager.MintParams memory mp = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: FEE,
            tickLower: lower,
            tickUpper: upper,
            amount0Desired: dataAmount0,
            amount1Desired: dataAmount1,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(0),
            deadline: block.timestamp
        });
        bytes memory data = abi.encode(true, abi.encode(mp));

        vm.prank(owner);
        vm.expectRevert(); // the adapter's transferFrom exceeds the scoped allowance
        IVaultLP(address(vault)).addLiquidity(address(uniImpl), token0, validated0, token1, validated1, data);
    }

    // Would REVERT ("ERC721: transfer caller is not owner nor approved") when _positionNFT can't resolve
    // the adapter's NFT-manager getter, so the vault never approved the clone to pull the position NFT.
    function test_vault_claimAMMFees_worksThroughRealAdapter() public {
        uint256 tokenId = _addLiquidity();
        bytes memory data = abi.encode(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(0),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        vm.prank(owner);
        IVaultLP(address(vault)).claimAMMFees(address(uniImpl), data);
        // The position (and its NFT) survives a fee claim.
        assertEq(IERC721(npm).ownerOf(tokenId), address(vault), "vault keeps the NFT after claim");
    }

    // Same NFT-approval path as claim — a full exit must return both tokens to the vault.
    function test_vault_removeLiquidity_returnsTokens() public {
        uint256 tokenId = _addLiquidity();
        assertGt(_liquidity(tokenId), 0, "liquidity before remove");

        uint256 bal0Before = IERC20(token0).balanceOf(address(vault));
        uint256 bal1Before = IERC20(token1).balanceOf(address(vault));

        bytes memory data = abi.encode(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: _liquidity(tokenId),
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
        vm.prank(owner);
        IVaultLP(address(vault)).removeLiquidity(address(uniImpl), data);

        assertEq(_liquidity(tokenId), 0, "liquidity must be zero after full remove");
        assertGt(
            IERC20(token0).balanceOf(address(vault)) + IERC20(token1).balanceOf(address(vault)),
            bal0Before + bal1Before,
            "principal should return to the vault"
        );
        assertEq(IERC721(npm).ownerOf(tokenId), address(vault), "vault keeps the (now-empty) NFT");
    }
}
