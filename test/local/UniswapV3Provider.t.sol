// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {UniswapV3Provider} from "provider-contracts/src/providers/UniswapV3Provider.sol";
import {INonfungiblePositionManager} from "provider-contracts/src/libs/uniswap/v3/Uniswap.sol";

/// @notice Minimal NPM stub: records the recipient passed into `collect`.
contract MockNonfungiblePositionManagerCollect {
    address public lastCollectRecipient;

    function collect(INonfungiblePositionManager.CollectParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1)
    {
        lastCollectRecipient = params.recipient;
        return (0, 0);
    }
}

contract UniswapV3ProviderTest is Test {
    function test_ClaimFees_AlwaysPassesOwnerAsCollectRecipient() public {
        MockNonfungiblePositionManagerCollect npm = new MockNonfungiblePositionManagerCollect();
        UniswapV3Provider provider = new UniswapV3Provider(address(0x1234), address(npm));
        provider.initialize(address(this));

        address decoy = makeAddr("decoy");
        INonfungiblePositionManager.CollectParams memory params = INonfungiblePositionManager.CollectParams({
            tokenId: 7, recipient: decoy, amount0Max: type(uint128).max, amount1Max: type(uint128).max
        });

        provider.claimAMMFees(abi.encode(params));

        assertEq(npm.lastCollectRecipient(), address(this), "collect recipient must be owner, not calldata");
    }

    function test_ClaimFees_RecipientZeroStillCollectsToOwner() public {
        MockNonfungiblePositionManagerCollect npm = new MockNonfungiblePositionManagerCollect();
        UniswapV3Provider provider = new UniswapV3Provider(address(0x1234), address(npm));
        provider.initialize(address(this));

        INonfungiblePositionManager.CollectParams memory params = INonfungiblePositionManager.CollectParams({
            tokenId: 1, recipient: address(0), amount0Max: 100, amount1Max: 100
        });

        provider.claimAMMFees(abi.encode(params));

        assertEq(npm.lastCollectRecipient(), address(this));
    }
}
