// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {BittyVault} from "../src/BittyVault.sol";
import {ITrust} from "../src/interfaces/ITrust.sol";
import {ITrustee} from "../src/interfaces/ITrustee.sol";
import {IAssetManager} from "../src/interfaces/IAssetManager.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface IWETH {
    function deposit() external payable;
    function balanceOf(address account) external view returns (uint256);
}

contract MockWETH {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        return true;
    }
}

contract MockWBTC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        return true;
    }
}

contract MockUSDT {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract MockUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

interface IUniswapV4Router04 {
    function swap(bytes calldata data, uint256 deadline) external payable returns (int256);
}

contract MockUniswapV4Router is IUniswapV4Router04 {
    struct SwapParams {
        address sellAsset;
        address buyAsset;
        uint256 sellAmount;
        uint256 buyAmount;
        bool isSet;
    }

    SwapParams public nextSwap;

    function setNextSwap(address sellAsset, address buyAsset, uint256 sellAmount, uint256 buyAmount) external {
        nextSwap = SwapParams({
            sellAsset: sellAsset, buyAsset: buyAsset, sellAmount: sellAmount, buyAmount: buyAmount, isSet: true
        });
    }

    function swap(
        bytes calldata,
        /* data */
        uint256 /* deadline */
    )
        external
        payable
        returns (int256)
    {
        require(nextSwap.isSet, "Swap params not set");
        require(msg.sender != address(0), "Invalid caller");

        IERC20(nextSwap.sellAsset).transferFrom(msg.sender, address(this), nextSwap.sellAmount);
        IERC20(nextSwap.buyAsset).transfer(msg.sender, nextSwap.buyAmount);
        nextSwap.isSet = false;
        return int256(nextSwap.buyAmount);
    }
}

contract BittyVaultTrusteeTest is Test {
    BittyVault public bittyVault;
    MockWETH public mockWETH;
    MockWBTC public mockWBTC;
    MockUSDT public mockUSDT;
    MockUSDC public mockUSDC;
    MockUniswapV4Router public mockUniswap;
    address public trustee;
    IAssetManager.RebalanceLimit public rebalanceLimits;
    ITrustee.TrusteeFee public trusteeFee;

    function setUp() public {
        mockWETH = new MockWETH();
        mockWBTC = new MockWBTC();
        mockUSDT = new MockUSDT();
        mockUSDC = new MockUSDC();
        mockUniswap = new MockUniswapV4Router();
        bittyVault = new BittyVault();
        trustee = makeAddr("alice");
        bittyVault.setAsset(IAssetManager.AssetType.WETH, address(mockWETH));
        bittyVault.setAsset(IAssetManager.AssetType.WBTC, address(mockWBTC));
        bittyVault.setAsset(IAssetManager.AssetType.USDT, address(mockUSDT));
        bittyVault.setAsset(IAssetManager.AssetType.USDC, address(mockUSDC));
        bittyVault.initialize(address(this));
        bittyVault.setTrustee(trustee);
        vm.prank(trustee);
        bittyVault.setUniswapV4Router(address(mockUniswap));
        rebalanceLimits = IAssetManager.RebalanceLimit({
            minimalWBTCBalance: 1 * 1e8,
            minimalWETHBalance: 100 * 1e18,
            minimalStableCoinBalance: 100 * 1e6,
            minimalTimestampBetweenRebalances: 30,
            maxRebalancePercentage: 10
        });
        bittyVault.setRebalanceRules(rebalanceLimits);
        trusteeFee =
            ITrustee.TrusteeFee({baseFeeAmount: 100 * 1e6, baseFeeDuration: 30 days, isBaseFeePercentage: false});
    }

    function test_TrusteeGetBaseFeeFailedBeforeDuration() public {
        bittyVault.setTrusteeFee(trusteeFee);
        vm.expectRevert(ITrustee.BaseFeeDurationNotMet.selector);
        vm.prank(trustee);
        bittyVault.getTrusteeBaseFee();
    }

    function test_TrusteeGetBaseFeeShouldBeFine() public {
        bittyVault.setTrusteeFee(trusteeFee);
        mockUSDT.mint(address(bittyVault), trusteeFee.baseFeeAmount);
        vm.warp(block.timestamp + 30 days + 1);
        vm.prank(trustee);
        bittyVault.getTrusteeBaseFee();
        assertEq(mockUSDT.balanceOf(trustee), trusteeFee.baseFeeAmount);
        assertEq(mockUSDT.balanceOf(address(bittyVault)), 0);
    }

    function test_TrusteeGetBaseFeeShouldBeFineByPercentage() public {
        trusteeFee.isBaseFeePercentage = true;
        trusteeFee.baseFeeAmount = 1000;
        bittyVault.setTrusteeFee(trusteeFee);
        mockUSDT.mint(address(bittyVault), 100 * 1e6);
        vm.warp(block.timestamp + 30 days + 1);
        vm.prank(trustee);
        bittyVault.getTrusteeBaseFee();
        assertEq(mockUSDT.balanceOf(trustee), 10 * 1e6);
        assertEq(mockUSDT.balanceOf(address(bittyVault)), 90 * 1e6);
    }

    function test_RebalanceFailedIfRebalanceIsZero() public {
        mockWETH.mint(address(bittyVault), rebalanceLimits.minimalWETHBalance);
        vm.expectRevert(ITrust.AmountIsZero.selector);
        vm.prank(trustee);
        bittyVault.rebalance(IAssetManager.AssetType.WETH, IAssetManager.AssetType.USDT, 0, 100 * 1e6, "");
    }

    function test_RebalanceFailedIfRebalanceInMinimalTime() public {
        uint256 sellAmount = 1 * 1e6;
        mockUSDT.mint(address(bittyVault), rebalanceLimits.minimalStableCoinBalance);
        mockWETH.mint(address(bittyVault), rebalanceLimits.minimalWETHBalance + 2 * sellAmount);
        uint256 buyAmount = 10 * 1e6;
        mockUniswap.setNextSwap(address(mockWETH), address(mockUSDT), sellAmount, buyAmount);
        mockUSDT.mint(address(mockUniswap), buyAmount);

        vm.prank(address(bittyVault));
        mockWETH.approve(address(mockUniswap), sellAmount);

        vm.warp(block.timestamp + 30 + 1);
        vm.prank(trustee);
        bittyVault.rebalance(IAssetManager.AssetType.WETH, IAssetManager.AssetType.USDT, sellAmount, buyAmount, "");

        mockUniswap.setNextSwap(address(mockWETH), address(mockUSDT), sellAmount, buyAmount);
        mockUSDT.mint(address(mockUniswap), buyAmount);

        vm.expectRevert(IAssetManager.RebalanceInMinimalTime.selector);
        vm.warp(block.timestamp + rebalanceLimits.minimalTimestampBetweenRebalances - 1);
        vm.prank(trustee);
        bittyVault.rebalance(IAssetManager.AssetType.WETH, IAssetManager.AssetType.USDT, sellAmount, buyAmount, "");
    }

    function test_RebalanceFailedIfMinimalWBTCBalanceIsNotMet() public {
        uint256 sellAmount = rebalanceLimits.minimalWBTCBalance;
        mockWBTC.mint(address(bittyVault), rebalanceLimits.minimalWBTCBalance);

        mockUniswap.setNextSwap(address(mockWBTC), address(mockUSDT), sellAmount, 10 * 1e6);
        mockUSDT.mint(address(mockUniswap), 10 * 1e6);

        vm.prank(address(bittyVault));
        mockWBTC.approve(address(mockUniswap), sellAmount);

        vm.expectRevert(IAssetManager.MinimalWBTCBalanceLimit.selector);
        vm.prank(trustee);
        bittyVault.rebalance(IAssetManager.AssetType.WBTC, IAssetManager.AssetType.USDT, sellAmount, 10 * 1e6, "");
    }

    function test_RebalanceFailedIfMinimalWETHBalanceIsNotMet() public {
        uint256 sellAmount = 1;
        mockWETH.mint(address(bittyVault), rebalanceLimits.minimalWETHBalance);

        mockUniswap.setNextSwap(address(mockWETH), address(mockUSDT), sellAmount, 10 * 1e6);
        mockUSDT.mint(address(mockUniswap), 10 * 1e6);

        vm.prank(address(bittyVault));
        mockWETH.approve(address(mockUniswap), sellAmount);

        vm.expectRevert(IAssetManager.MinimalWETHBalanceLimit.selector);
        vm.prank(trustee);
        bittyVault.rebalance(IAssetManager.AssetType.WETH, IAssetManager.AssetType.USDT, sellAmount, 10 * 1e6, "");
    }

    function test_RebalanceFailedIfMinimalStableCoinBalanceIsNotMet() public {
        uint256 sellAmount = 1;
        mockUSDT.mint(address(bittyVault), rebalanceLimits.minimalStableCoinBalance);

        mockUniswap.setNextSwap(address(mockUSDT), address(mockWETH), sellAmount, 1);
        mockWETH.mint(address(mockUniswap), 1);

        vm.prank(address(bittyVault));
        mockUSDT.approve(address(mockUniswap), sellAmount);

        vm.expectRevert(IAssetManager.MinimalStableCoinBalanceLimit.selector);
        vm.prank(trustee);
        bittyVault.rebalance(IAssetManager.AssetType.USDT, IAssetManager.AssetType.WETH, sellAmount, 1, "");
    }

    function test_RebalanceBetweenStableCoinsShouldBeFine() public {
        uint256 sellAmount = 1;
        mockUSDT.mint(address(bittyVault), rebalanceLimits.minimalStableCoinBalance);

        mockUniswap.setNextSwap(address(mockUSDT), address(mockUSDC), sellAmount, 1);
        mockUSDC.mint(address(mockUniswap), 1);

        vm.prank(address(bittyVault));
        mockUSDT.approve(address(mockUniswap), sellAmount);

        vm.prank(trustee);
        bittyVault.rebalance(IAssetManager.AssetType.USDT, IAssetManager.AssetType.USDC, sellAmount, 1, "");
        assertEq(mockUSDT.balanceOf(address(bittyVault)), rebalanceLimits.minimalStableCoinBalance - sellAmount);
        assertEq(mockUSDC.balanceOf(address(bittyVault)), sellAmount);
    }
}
