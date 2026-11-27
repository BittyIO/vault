// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;
import "./AcrossBridgeProtocol.t.sol";

contract PocAcross is AcrossBridgeProtocolTest {
    uint256 constant SOLANA = 34268394551451;
    address usdcOnSolana = address(0x1234); // whatever the route's output token is

    /// A Solana route (needed for bridgeTo to Solana) also lets bridge() "to self" go to Solana,
    /// paying the vault's 20 bytes as a Solana pubkey: an address no one holds.
    function test_poc_bridgeToSelfOnSolana() public {
        _route(address(usdc), SOLANA, usdcOnSolana, 6, 100);
        _bridge(adapter, address(usdc), 500_000e6, 0, 0, _quote(SOLANA, usdcOnSolana, 499_000e6));
        assertEq(spoke.recipient(), _b32(address(vault)));
        assertEq(spoke.destinationChainId(), SOLANA);
    }
}
