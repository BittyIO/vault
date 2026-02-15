// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {Test} from "lib/forge-std/src/Test.sol";
import {Vault} from "../src/Vault.sol";
import {AddressZero, AlreadyInitialized} from "../src/interfaces/IVault.sol";
import {WETH} from "lib/solmate/src/tokens/WETH.sol";
import {WhiteList} from "../src/WhiteList.sol";
import {MockERC20} from "lib/solmate/src/test/utils/mocks/MockERC20.sol";
import {Factory} from "../src/Factory.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract PersonalVaultTest is Test {
    Vault public vault;
    WETH public weth;
    address public whiteListAddress;
    address public ownerAddress;
    address[] public assets;
    address[] public stableCoins;
    address[] public lendingProviders;
    address[] public stakingProviders;
    address[] public swapProviders;
    address public mockWETH;
    address public mockWBTC;
    address public mockUSDT;
    address public mockUSDC;
    Factory public factory;

    function setUp() public {
        weth = new WETH();
        mockWETH = address(new WETH());
        mockWBTC = address(new MockERC20("WBTC", "WBTC", 18));
        mockUSDT = address(new MockERC20("USDT", "USDT", 18));
        mockUSDC = address(new MockERC20("USDC", "USDC", 18));
        vault = new Vault();
        whiteListAddress = address(new WhiteList());
        ownerAddress = makeAddr("ownerAddress");
        assets = new address[](2);
        assets[0] = mockWBTC;
        assets[1] = mockWETH;
        stableCoins = new address[](2);
        stableCoins[0] = mockUSDT;
        stableCoins[1] = mockUSDC;
        lendingProviders = new address[](0);
        stakingProviders = new address[](0);
        swapProviders = new address[](0);
        vm.startPrank(tx.origin);
        WhiteList(whiteListAddress).addAssets(assets);
        WhiteList(whiteListAddress).addStableCoins(stableCoins);
        WhiteList(whiteListAddress).addLendingProviders(lendingProviders);
        WhiteList(whiteListAddress).addStakingProviders(stakingProviders);
        WhiteList(whiteListAddress).addSwapProviders(swapProviders);
        vm.stopPrank();
        factory = new Factory();
        factory.initialize(address(vault), address(whiteListAddress), address(mockWETH));
        address vaultAddress =
            factory.deployVault(assets, stableCoins, lendingProviders, stakingProviders, swapProviders);
        vault = Vault(payable(vaultAddress));
    }

    function test_DepositWETHToVault() public {
        deal(address(mockWETH), address(this), 1 ether);
        vm.prank(address(this));
        IERC20(address(mockWETH)).transfer(address(vault), 1 ether);
        assertEq(IERC20(address(mockWETH)).balanceOf(address(vault)), 1 ether);
    }
}
