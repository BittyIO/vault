// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {AaveV3Provider} from "provider-contracts/src/providers/AaveV3Provider.sol";
import {LidoV2Provider} from "provider-contracts/src/providers/LidoV2Provider.sol";
import {UniswapV3Provider} from "provider-contracts/src/providers/UniswapV3Provider.sol";
import {mainnet} from "provider-contracts/script/addresses.sol";
import {Path} from "provider-contracts/src/libs/uniswap/v3/Uniswap.sol";
import {WhiteList} from "whitelist-contracts/src/WhiteList.sol";

/// @dev Mainnet fork setup with real Aave, Lido, and Uniswap V3 provider templates.
abstract contract ProviderTestSetup is Test {
    using Path for bytes;

    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    AaveV3Provider internal aaveProvider;
    LidoV2Provider internal lidoProvider;
    UniswapV3Provider internal uniswapV3Provider;

    function setupMainnetForkProviders(WhiteList whiteList) internal {
        vm.createSelectFork("mainnet");

        vm.startPrank(tx.origin);
        aaveProvider = new AaveV3Provider(mainnet.AAVE_V3, mainnet.POOL_DATA_PROVIDER);
        aaveProvider.initialize(address(this));

        lidoProvider = new LidoV2Provider(mainnet.STETH, mainnet.UNSTETH, mainnet.WETH);
        lidoProvider.initialize(address(this));

        uniswapV3Provider =
            new UniswapV3Provider(mainnet.UNISWAP_V3_ROUTER, mainnet.UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER);
        uniswapV3Provider.initialize(address(this));

        whiteList.addLendingProviders(_single(address(aaveProvider)));
        whiteList.addStakingProviders(_single(address(lidoProvider)));
        whiteList.addAMMProviders(_single(address(uniswapV3Provider)));
        vm.stopPrank();
    }

    function encodeWethToUsdtSwap(uint256 sellAmount, uint256 buyAmountMin) internal pure returns (bytes memory) {
        address[] memory path = new address[](2);
        path[0] = mainnet.WETH;
        path[1] = mainnet.USDT;
        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000;
        bytes memory encodedPath = Path.encodePath(path, fees);
        return abi.encode(mainnet.WETH, sellAmount, mainnet.USDT, buyAmountMin, encodedPath);
    }

    function _single(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }
}
