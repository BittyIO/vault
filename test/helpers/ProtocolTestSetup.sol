// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {GUARD_DEPLOYER} from "./GuardDeployer.sol";
import {AaveV3Protocol} from "protocol-contracts/src/protocols/AaveV3Protocol.sol";
import {LidoV2Protocol} from "protocol-contracts/src/protocols/LidoV2Protocol.sol";
import {UniswapV3Protocol} from "protocol-contracts/src/protocols/UniswapV3Protocol.sol";
import {mainnet} from "protocol-contracts/script/addresses.sol";
import {Path} from "protocol-contracts/src/libs/uniswap/v3/Uniswap.sol";
import {BittyV1Guard} from "guard-contracts/src/BittyV1Guard.sol";

/**
 *  @dev Mainnet fork setup with real Aave, Lido, and Uniswap V3 provider templates.
 */
abstract contract ProtocolTestSetup is Test {
    using Path for bytes;

    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    AaveV3Protocol internal aaveProtocol;
    LidoV2Protocol internal lidoProtocol;
    UniswapV3Protocol internal uniswapV3Protocol;

    /**
     * @dev `guard` is etched, with its roles and registry already configured, BEFORE any fork exists.
     *      Creating a fork replaces state wholesale, so without making it persistent the freshly built
     *      guard is discarded and every later call silently lands on the guard actually DEPLOYED on
     *      mainnet — an older build, whose interface predates whatever is being tested here.
     *
     *      Re-etching after the fork instead is not an option: the deployed guard already has a
     *      default admin in storage, and AccessControlDefaultAdminRules refuses to install a second.
     */
    function setupMainnetForkProtocols(BittyV1Guard guard) internal {
        vm.makePersistent(address(guard));
        // Pinned. Unpinned, this follows mainnet HEAD — and since the guard was deployed to
        // BITTY_GUARD at block 25830629 the fork now carries the real one, pre-populated with
        // assets, so setUp could not install its own and the fixtures no longer matched.
        // A pin below that block also makes these tests deterministic, which they were not.
        vm.createSelectFork("mainnet", 25829629);

        vm.startPrank(tx.origin);
        aaveProtocol = new AaveV3Protocol(mainnet.AAVE_V3, mainnet.POOL_DATA_PROVIDER);
        aaveProtocol.initialize(address(this));

        lidoProtocol = new LidoV2Protocol(mainnet.STETH, mainnet.UNSTETH, mainnet.WETH);
        lidoProtocol.initialize(address(this));

        uniswapV3Protocol = new UniswapV3Protocol(mainnet.UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER);
        uniswapV3Protocol.initialize(address(this));

        vm.stopPrank();

        // Registering a protocol is a guard-admin write, and the guard's admin is its hardcoded
        // deployer — not tx.origin, which only holds the manager roles that admin granted onward.
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guard.addProtocols(_single(address(aaveProtocol)));
        guard.addProtocols(_single(address(lidoProtocol)));
        guard.addProtocols(_single(address(uniswapV3Protocol)));
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

    function encodeUsdtToWethSwap(uint256 sellAmount, uint256 buyAmountMin) internal pure returns (bytes memory) {
        address[] memory path = new address[](2);
        path[0] = mainnet.USDT;
        path[1] = mainnet.WETH;
        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000;
        bytes memory encodedPath = Path.encodePath(path, fees);
        return abi.encode(mainnet.USDT, sellAmount, mainnet.WETH, buyAmountMin, encodedPath);
    }

    function _single(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }
}
