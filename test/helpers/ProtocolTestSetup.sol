// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {AaveV3Protocol} from "protocol-contracts/src/protocols/AaveV3Protocol.sol";
import {LidoV2Protocol} from "protocol-contracts/src/protocols/LidoV2Protocol.sol";
import {UniswapV3Protocol} from "protocol-contracts/src/protocols/UniswapV3Protocol.sol";
import {mainnet} from "protocol-contracts/script/addresses.sol";
import {Path} from "protocol-contracts/src/libs/uniswap/v3/Uniswap.sol";
import {BittyGuard} from "guard-contracts/src/BittyGuard.sol";

/// @dev Mainnet fork setup with real Aave, Lido, and Uniswap V3 provider templates.
abstract contract ProtocolTestSetup is Test {
    using Path for bytes;

    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    AaveV3Protocol internal aaveProtocol;
    LidoV2Protocol internal lidoProtocol;
    UniswapV3Protocol internal uniswapV3Protocol;

    function setupMainnetForkProtocols(BittyGuard guard) internal {
        vm.createSelectFork("mainnet");

        vm.startPrank(tx.origin);
        aaveProtocol = new AaveV3Protocol(mainnet.AAVE_V3, mainnet.POOL_DATA_PROVIDER);
        aaveProtocol.initialize(address(this));

        lidoProtocol = new LidoV2Protocol(mainnet.STETH, mainnet.UNSTETH, mainnet.WETH);
        lidoProtocol.initialize(address(this));

        uniswapV3Protocol = new UniswapV3Protocol(
            mainnet.UNISWAP_V3_ROUTER, mainnet.UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER, address(guard)
        );
        uniswapV3Protocol.initialize(address(this));

        guard.addLendingProtocols(_single(address(aaveProtocol)));
        guard.addStakingProtocols(_single(address(lidoProtocol)));
        guard.addAMMProtocols(_single(address(uniswapV3Protocol)));
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
