// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;
import "./Bridge.t.sol";

contract PocBridge is BridgeTest {
    function test_poc_unmeteredCostDrainUnderLock() public {
        MockBridge costly = new MockBridge(0, 9_999); // reports 0.01% arriving
        guard.setProtocol(address(costly), PROTOCOL_BRIDGE);
        _enable();
        uint256 id = _addOn(TRON, TRON_PAYEE);
        vm.prank(owner);
        vault.updateRisk(IBittyV1Owner.RiskSettings(type(uint256).max, 0, 0));
        vm.prank(owner);
        vm.expectRevert(DailyLossAllowanceExceeded.selector);
        _b().bridge(address(costly), address(usdc), 10e6, 0, DATA);
        vm.prank(owner);
        vault.emergencyLock();
        uint256 before = usdc.balanceOf(address(vault));
        for (uint256 i; i < 200; i++) {
            vm.prank(owner);
            _b().bridgeToWhitelistedRecipient(address(costly), id, address(usdc), 10e6, 0, TRON, DATA);
        }
        assertEq(before - usdc.balanceOf(address(vault)), 2_000e6);
    }
}

contract PocClone is BridgeTest {
    /// A vault whose clone runs a deprecated implementation keeps running it when called with the
    /// fixed, registered implementation of the same lineage.
    function test_poc_deprecatedImplKeepsRunning() public {
        MockBridge buggy = new MockBridge(0, 5_000); // "buggy": half the money lost
        guard.setProtocol(address(buggy), PROTOCOL_BRIDGE);
        _enable();
        _bridge(address(buggy), address(usdc), 1_000e6, 0); // clone created from buggy
        guard.setDeprecated(address(buggy), true);
        MockBridge fixedImpl = new MockBridge(0, 0); // same lineage, honest
        guard.setProtocol(address(fixedImpl), PROTOCOL_BRIDGE);
        vm.expectEmit(address(vault));
        emit IBittyV1DeFi.Bridged(address(fixedImpl), address(usdc), 1_000e6, 0, 500e6, DATA);
        _bridge(address(fixedImpl), address(usdc), 1_000e6, 0); // still the buggy code: received 500
    }
}
