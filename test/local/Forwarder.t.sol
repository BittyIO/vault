// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC2771Forwarder} from "openzeppelin-contracts/contracts/metatx/ERC2771Forwarder.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1SubVault} from "../../src/subvault/BittyV1SubVault.sol";
import {BittyV1VaultForwarder} from "../../src/BittyV1VaultForwarder.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {BITTY_GUARD, BITTY_FORWARDER, BITTY_FEE_COLLECTOR, STABLE_COIN_CATEGORY} from "../../src/logic/Constants.sol";

/// Answers ERC-1271 for one key, so a contract-owned vault can be relayed.
contract ContractWallet {
    address public signer;

    constructor(address signer_) {
        signer = signer_;
    }

    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        (address rec,,) = _recover(hash, sig);
        return rec == signer ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }

    function _recover(bytes32 h, bytes calldata sig) private pure returns (address, bytes32, bytes32) {
        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        uint8 v = uint8(sig[64]);
        return (ecrecover(h, v, r, s), r, s);
    }
}

/**
 * The relay path: who may charge, what bounds the charge, and the nonce lanes.
 *
 * The lanes are the part worth pinning. OpenZeppelin gives a signer ONE counter, so a request stuck
 * against one vault blocks that signer against every other. This forwarder keys the nonce on
 * (signer, target) instead — which is what lets a single keeper sweep a whole fleet.
 */
contract ForwarderTest is Test {
    BittyV1VaultForwarder fwd;
    BittyV1Vault vaultA;
    BittyV1Vault vaultB;
    BittyV1Vault impl;
    MockGuard guard;
    MockERC20 usdc;

    uint256 ownerPk = 0xA11CE;
    address owner;
    address relayer = makeAddr("relayer");
    address fwdOwner = makeAddr("fwdOwner");
    address weth = makeAddr("weth");
    address constant DEPLOYER = 0x12EE2de7BF086388B1D560eb95e7191Edfab9823;

    function setUp() public {
        owner = vm.addr(ownerPk);
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);

        // The vault trusts BITTY_FORWARDER by constant, so the forwarder has to live there.
        vm.etch(BITTY_FORWARDER, address(new BittyV1VaultForwarder()).code);
        fwd = BittyV1VaultForwarder(payable(BITTY_FORWARDER));
        vm.prank(DEPLOYER, DEPLOYER);
        fwd.initialize(fwdOwner);
        vm.prank(fwdOwner);
        fwd.setRelayerApproval(relayer, true);

        BittyV1VaultDeFiFacet facet = new BittyV1VaultDeFiFacet();
        BittyV1SubVault subImpl = new BittyV1SubVault(address(facet));
        impl = new BittyV1Vault(address(facet), address(subImpl));
        vaultA = _newVault(owner);
        vaultB = _newVault(owner);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        guard.setAsset(address(usdc), STABLE_COIN_CATEGORY);
        usdc.mint(address(vaultA), 1_000e6);
        usdc.mint(address(vaultB), 1_000e6);
    }

    function _newVault(address o) internal returns (BittyV1Vault) {
        bytes memory init = abi.encodeCall(BittyV1Vault.initialize, (o, weth, false, address(0), 0));
        return BittyV1Vault(payable(new ERC1967Proxy(address(impl), init)));
    }

    /// An owner-only call, harmless and observable.
    function _enableAllowlistCall() internal pure returns (bytes memory) {
        return abi.encodeWithSignature("enableAllowlist()");
    }

    function _req(address from, address to, bytes memory data)
        internal
        view
        returns (ERC2771Forwarder.ForwardRequestData memory r)
    {
        r = ERC2771Forwarder.ForwardRequestData({
            from: from,
            to: to,
            value: 0,
            gas: 1_000_000,
            deadline: uint48(block.timestamp + 600),
            data: data,
            signature: ""
        });
    }

    function _sign(ERC2771Forwarder.ForwardRequestData memory r, uint256 pk)
        internal
        view
        returns (ERC2771Forwarder.ForwardRequestData memory)
    {
        return _signNonce(r, pk, fwd.nonceFor(r.from, r.to));
    }

    /// Requests batched together consume consecutive lane nonces, so each has to be signed for its own.
    function _signNonce(ERC2771Forwarder.ForwardRequestData memory r, uint256 pk, uint256 nonce)
        internal
        view
        returns (ERC2771Forwarder.ForwardRequestData memory)
    {
        bytes32 typeHash = keccak256(
            "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint48 deadline,bytes data)"
        );
        bytes32 structHash =
            keccak256(abi.encode(typeHash, r.from, r.to, r.value, r.gas, nonce, r.deadline, keccak256(r.data)));
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("BittyV1VaultForwarder"),
                keccak256("1"),
                block.chainid,
                address(fwd)
            )
        );
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        r.signature = abi.encodePacked(rr, ss, v);
        return r;
    }

    function _allowlistOn(BittyV1Vault v) internal view returns (bool) {
        (, bytes memory out) = address(v).staticcall(abi.encodeWithSignature("allowlistEnabled()"));
        return abi.decode(out, (bool));
    }

    // ── relaying ──────────────────────────────────────────────────────────────

    function test_relayExecutesAsTheSigner() public {
        ERC2771Forwarder.ForwardRequestData memory r =
            _sign(_req(owner, address(vaultA), _enableAllowlistCall()), ownerPk);
        vm.prank(relayer);
        fwd.executeWithFee(r, address(usdc), 2e6);

        assertTrue(_allowlistOn(vaultA), "the owner's intent ran without the owner holding ETH");
        assertEq(usdc.balanceOf(BITTY_FEE_COLLECTOR), 2e6, "and the vault paid for it");
    }

    function test_onlyApprovedRelayersMayCharge() public {
        ERC2771Forwarder.ForwardRequestData memory r =
            _sign(_req(owner, address(vaultA), _enableAllowlistCall()), ownerPk);
        vm.prank(makeAddr("randomRelayer"));
        vm.expectRevert(BittyV1VaultForwarder.NotApprovedRelayer.selector);
        fwd.executeWithFee(r, address(usdc), 1e6);
    }

    /// Permissionless relaying at the relayer's own expense is still ERC-2771's default.
    function test_anyoneMayRelayAtTheirOwnExpense() public {
        ERC2771Forwarder.ForwardRequestData memory r =
            _sign(_req(owner, address(vaultA), _enableAllowlistCall()), ownerPk);
        vm.prank(makeAddr("goodSamaritan"));
        fwd.execute(r);
        assertTrue(_allowlistOn(vaultA));
        assertEq(usdc.balanceOf(BITTY_FEE_COLLECTOR), 0, "no fee taken");
    }

    function test_forgedSignatureRejected() public {
        (, uint256 wrongPk) = makeAddrAndKey("mallory");
        ERC2771Forwarder.ForwardRequestData memory r =
            _sign(_req(owner, address(vaultA), _enableAllowlistCall()), wrongPk);
        vm.prank(relayer);
        vm.expectRevert();
        fwd.executeWithFee(r, address(usdc), 1e6);
    }

    function test_expiredRequestRejected() public {
        ERC2771Forwarder.ForwardRequestData memory r =
            _sign(_req(owner, address(vaultA), _enableAllowlistCall()), ownerPk);
        vm.warp(block.timestamp + 601);
        vm.prank(relayer);
        vm.expectRevert();
        fwd.executeWithFee(r, address(usdc), 1e6);
    }

    // ── nonce lanes ───────────────────────────────────────────────────────────

    /// Replaying a spent request fails: its lane has moved on.
    function test_replayIsRefused() public {
        ERC2771Forwarder.ForwardRequestData memory r =
            _sign(_req(owner, address(vaultA), _enableAllowlistCall()), ownerPk);
        vm.prank(relayer);
        fwd.executeWithFee(r, address(usdc), 1e6);
        assertEq(fwd.nonceFor(owner, address(vaultA)), 1, "lane advanced");

        vm.prank(relayer);
        vm.expectRevert();
        fwd.executeWithFee(r, address(usdc), 1e6);
    }

    /**
     * The reason lanes exist. Spending the lane against vault A must not invalidate a signature
     * already produced for vault B — with one flat counter per signer it would, and a fleet-wide
     * keeper would serialise behind whichever vault it touched last.
     */
    function test_lanesAreIndependentPerTarget() public {
        ERC2771Forwarder.ForwardRequestData memory forB =
            _sign(_req(owner, address(vaultB), _enableAllowlistCall()), ownerPk);

        // Advance the owner's lane against A twice.
        for (uint256 i; i < 2; i++) {
            ERC2771Forwarder.ForwardRequestData memory rA =
                _sign(_req(owner, address(vaultA), _enableAllowlistCall()), ownerPk);
            vm.prank(relayer);
            fwd.executeWithFee(rA, address(usdc), 1e6);
        }
        assertEq(fwd.nonceFor(owner, address(vaultA)), 2);
        assertEq(fwd.nonceFor(owner, address(vaultB)), 0, "B's lane untouched");

        // The B signature, made before any of that, still verifies.
        vm.prank(relayer);
        fwd.executeWithFee(forB, address(usdc), 1e6);
        assertTrue(_allowlistOn(vaultB), "B ran on a signature made two A-relays ago");
    }

    // ── ERC-1271 ──────────────────────────────────────────────────────────────

    /**
     * A vault owned by a contract wallet must be relayable. OpenZeppelin's forwarder RECOVERS an
     * address and compares, which can only work for an EOA — a Safe's signature has no single address
     * to recover. This forwarder asks the contract instead.
     */
    function test_contractWalletOwnerCanBeRelayedFor() public {
        (address walletSigner, uint256 walletPk) = makeAddrAndKey("walletKey");
        ContractWallet wallet = new ContractWallet(walletSigner);
        BittyV1Vault v = _newVault(address(wallet));
        usdc.mint(address(v), 100e6);

        ERC2771Forwarder.ForwardRequestData memory r =
            _sign(_req(address(wallet), address(v), _enableAllowlistCall()), walletPk);
        vm.prank(relayer);
        fwd.executeWithFee(r, address(usdc), 1e6);
        assertTrue(_allowlistOn(v), "a contract-owned vault relayed");
    }

    // ── fee ceilings ──────────────────────────────────────────────────────────

    /// Checked before the call runs, so an unaffordable fee costs the relayer nothing.
    function test_feeOverTheVaultBudgetIsRefusedUpFront() public {
        address[] memory none = new address[](0);
        vm.prank(owner);
        vaultA.setGasless(none, 5, 5); // 5 whole tokens a day

        ERC2771Forwarder.ForwardRequestData memory r =
            _sign(_req(owner, address(vaultA), _enableAllowlistCall()), ownerPk);
        vm.prank(relayer);
        vm.expectRevert(BittyV1VaultForwarder.FeeExceedsVaultBudget.selector);
        fwd.executeWithFee(r, address(usdc), 6e6);

        assertFalse(_allowlistOn(vaultA), "the inner call never ran");
        assertEq(fwd.nonceFor(owner, address(vaultA)), 0, "and the lane did not move");
    }

    /// Fee 0 relays without charging at all.
    function test_zeroFeeRelaysWithoutCharging() public {
        ERC2771Forwarder.ForwardRequestData memory r =
            _sign(_req(owner, address(vaultA), _enableAllowlistCall()), ownerPk);
        vm.prank(relayer);
        fwd.executeWithFee(r, address(usdc), 0);
        assertTrue(_allowlistOn(vaultA));
        assertEq(usdc.balanceOf(BITTY_FEE_COLLECTOR), 0);
    }

    // ── batch ─────────────────────────────────────────────────────────────────

    /// One vault, one fee, several requests — the reason the batch entry point exists.
    function test_batchChargesOnceForTheWholeLot() public {
        ERC2771Forwarder.ForwardRequestData[] memory rs = new ERC2771Forwarder.ForwardRequestData[](1);
        rs[0] = _sign(_req(owner, address(vaultA), _enableAllowlistCall()), ownerPk);

        vm.prank(relayer);
        fwd.executeBatchWithFee(rs, address(vaultA), address(usdc), 2e6);
        assertTrue(_allowlistOn(vaultA));
        assertEq(usdc.balanceOf(BITTY_FEE_COLLECTOR), 2e6, "charged once");
    }

    /// Every request must target the named vault, or one vault would pay for another's calls.
    function test_batchRefusesAMixedTarget() public {
        ERC2771Forwarder.ForwardRequestData[] memory rs = new ERC2771Forwarder.ForwardRequestData[](1);
        rs[0] = _sign(_req(owner, address(vaultB), _enableAllowlistCall()), ownerPk);

        vm.prank(relayer);
        vm.expectRevert(BittyV1VaultForwarder.BatchTargetMismatch.selector);
        fwd.executeBatchWithFee(rs, address(vaultA), address(usdc), 1e6);
    }

    function test_emptyBatchRefused() public {
        ERC2771Forwarder.ForwardRequestData[] memory rs = new ERC2771Forwarder.ForwardRequestData[](0);
        vm.prank(relayer);
        vm.expectRevert(BittyV1VaultForwarder.EmptyBatch.selector);
        fwd.executeBatchWithFee(rs, address(vaultA), address(usdc), 0);
    }

    /// OpenZeppelin's own batch is disabled: it cannot say which vault pays, and the lane needs a target.
    function test_openZeppelinBatchIsDisabled() public {
        ERC2771Forwarder.ForwardRequestData[] memory rs = new ERC2771Forwarder.ForwardRequestData[](1);
        rs[0] = _sign(_req(owner, address(vaultA), _enableAllowlistCall()), ownerPk);
        vm.prank(relayer);
        vm.expectRevert(BittyV1VaultForwarder.BatchNotSupported.selector);
        fwd.executeBatch(rs, payable(relayer));
    }

    // ── admin ─────────────────────────────────────────────────────────────────

    function test_onlyDeployerMayInitialize() public {
        vm.etch(address(0xF00D), address(new BittyV1VaultForwarder()).code);
        BittyV1VaultForwarder fresh = BittyV1VaultForwarder(payable(address(0xF00D)));
        address squatter = makeAddr("squatter");
        vm.prank(squatter, squatter);
        vm.expectRevert(BittyV1VaultForwarder.NotDeployer.selector);
        fresh.initialize(squatter);
    }

    function test_ownershipIsNotRenounceable() public {
        vm.prank(fwdOwner);
        vm.expectRevert(BittyV1VaultForwarder.OwnershipNotRenounceable.selector);
        fwd.renounceOwnership();
    }

    function test_onlyOwnerMayApproveRelayers() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        fwd.setRelayerApproval(makeAddr("x"), true);
    }

    // ── value handling and inner failure ──────────────────────────────────────

    /// The request declares the ETH it carries; the relayer must send exactly that or the call is a lie.
    function test_aRelayerCannotUnderfundTheDeclaredValue() public {
        ERC2771Forwarder.ForwardRequestData memory r = _req(owner, address(vaultA), _enableAllowlistCall());
        r.value = 1 ether;
        r = _sign(r, ownerPk);

        vm.deal(relayer, 1 ether);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ERC2771Forwarder.ERC2771ForwarderMismatchedValue.selector, 1 ether, 0));
        fwd.executeWithFee(r, address(usdc), 1e6);
    }

    /// Charging happens after the call, so a request the vault rejects must take the whole relay down
    /// rather than leaving the owner billed for work that did not happen.
    function test_aRequestTheVaultRejectsRevertsTheWholeRelay() public {
        uint256 strangerPk = 0xBEEF;
        ERC2771Forwarder.ForwardRequestData memory r =
            _sign(_req(vm.addr(strangerPk), address(vaultA), _enableAllowlistCall()), strangerPk);

        uint256 before = usdc.balanceOf(BITTY_FEE_COLLECTOR);
        vm.prank(relayer);
        vm.expectRevert();
        fwd.executeWithFee(r, address(usdc), 2e6);
        assertEq(usdc.balanceOf(BITTY_FEE_COLLECTOR), before, "nothing was charged");
    }

    function test_aFailingRequestInABatchTakesTheBatchDown() public {
        uint256 strangerPk = 0xBEEF;
        ERC2771Forwarder.ForwardRequestData[] memory rs = new ERC2771Forwarder.ForwardRequestData[](2);
        rs[0] = _sign(_req(owner, address(vaultA), _enableAllowlistCall()), ownerPk);
        rs[1] = _sign(_req(vm.addr(strangerPk), address(vaultA), _enableAllowlistCall()), strangerPk);

        vm.prank(relayer);
        vm.expectRevert();
        fwd.executeBatchWithFee(rs, address(vaultA), address(usdc), 2e6);
        assertFalse(_allowlistOn(vaultA), "the successful leg was rolled back too");
    }

    /// The batch carries no ETH — the fee is the only value that moves — so a request declaring some
    /// is refused outright rather than silently relayed with zero.
    function test_aBatchRequestCarryingValueIsRefused() public {
        ERC2771Forwarder.ForwardRequestData[] memory rs = new ERC2771Forwarder.ForwardRequestData[](1);
        ERC2771Forwarder.ForwardRequestData memory r = _req(owner, address(vaultA), _enableAllowlistCall());
        r.value = 1;
        rs[0] = _sign(r, ownerPk);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ERC2771Forwarder.ERC2771ForwarderMismatchedValue.selector, 1, 0));
        fwd.executeBatchWithFee(rs, address(vaultA), address(usdc), 1e6);
    }

    function test_onlyApprovedRelayersMayRunABatch() public {
        ERC2771Forwarder.ForwardRequestData[] memory rs = new ERC2771Forwarder.ForwardRequestData[](1);
        rs[0] = _sign(_req(owner, address(vaultA), _enableAllowlistCall()), ownerPk);

        vm.prank(makeAddr("randomRelayer"));
        vm.expectRevert(BittyV1VaultForwarder.NotApprovedRelayer.selector);
        fwd.executeBatchWithFee(rs, address(vaultA), address(usdc), 1e6);
    }

    function test_aRevokedRelayerCannotCharge() public {
        vm.prank(fwdOwner);
        fwd.setRelayerApproval(relayer, false);

        ERC2771Forwarder.ForwardRequestData memory r =
            _sign(_req(owner, address(vaultA), _enableAllowlistCall()), ownerPk);
        vm.prank(relayer);
        vm.expectRevert(BittyV1VaultForwarder.NotApprovedRelayer.selector);
        fwd.executeWithFee(r, address(usdc), 1e6);
    }

    function test_aZeroFeeBatchRelaysWithoutCharging() public {
        ERC2771Forwarder.ForwardRequestData[] memory rs = new ERC2771Forwarder.ForwardRequestData[](1);
        rs[0] = _sign(_req(owner, address(vaultA), _enableAllowlistCall()), ownerPk);

        vm.prank(relayer);
        fwd.executeBatchWithFee(rs, address(vaultA), address(usdc), 0);
        assertTrue(_allowlistOn(vaultA), "relayed");
        assertEq(usdc.balanceOf(BITTY_FEE_COLLECTOR), 0, "and free");
    }

    // ── relayed money movement ────────────────────────────────────────────────
    //
    // Everything above relays an owner-only config change. These relay a SEND, which is the path that
    // actually matters: the vault must read the signer out of the ERC-2771 suffix rather than trusting
    // msg.sender, or a relayer would be able to move funds on its own authority.

    function _sendCall(address to, address asset, uint256 amount) internal pure returns (bytes memory) {
        return abi.encodeWithSignature(
            "send(address,address,uint256,address[],uint256[])", to, asset, amount, new address[](0), new uint256[](0)
        );
    }

    function _relay(ERC2771Forwarder.ForwardRequestData memory r, uint256 fee) internal {
        vm.prank(relayer);
        fwd.executeWithFee(r, address(usdc), fee);
    }

    function test_theOwnerCanSendWithoutHoldingAnyEth() public {
        address payee = makeAddr("payee");
        _relay(_sign(_req(owner, address(vaultA), _sendCall(payee, address(usdc), 100e6)), ownerPk), 2e6);

        assertEq(usdc.balanceOf(payee), 100e6, "the relayed send paid the payee");
        assertEq(usdc.balanceOf(BITTY_FEE_COLLECTOR), 2e6, "and the vault covered the gas");
        assertEq(owner.balance, 0, "the owner never touched ETH");
    }

    /// The vault reads the signer from the request, so a relayed operator send is still only a
    /// PROPOSAL — the relayer's own address is never mistaken for authority.
    function test_aRelayedOperatorSendIsStillOnlyAProposal() public {
        uint256 operatorPk = 0x0FF1CE;
        address operator = vm.addr(operatorPk);
        address payee = makeAddr("payee");

        vm.prank(owner);
        vaultA.updatePayoutOperator(operator, true);

        _relay(_sign(_req(operator, address(vaultA), _sendCall(payee, address(usdc), 100e6)), operatorPk), 1e6);
        assertEq(usdc.balanceOf(payee), 0, "queued, not paid");

        vm.prank(owner);
        vaultA.approveSend(0);
        assertEq(usdc.balanceOf(payee), 100e6, "paid only once the owner approved");
    }

    function test_aRelayerCannotSpendAVaultItMerelyRelaysFor() public {
        address payee = makeAddr("payee");
        ERC2771Forwarder.ForwardRequestData memory r =
            _sign(_req(relayer, address(vaultA), _sendCall(payee, address(usdc), 100e6)), ownerPk);

        vm.prank(relayer);
        vm.expectRevert();
        fwd.executeWithFee(r, address(usdc), 1e6);
        assertEq(usdc.balanceOf(payee), 0, "nothing moved");
    }

    function test_aRelayedBatchSendPaysEveryLeg() public {
        address one = makeAddr("one");
        address two = makeAddr("two");
        address[] memory rs = new address[](2);
        address[] memory as_ = new address[](2);
        uint256[] memory ms = new uint256[](2);
        rs[0] = one;
        rs[1] = two;
        as_[0] = address(usdc);
        as_[1] = address(usdc);
        ms[0] = 10e6;
        ms[1] = 20e6;

        bytes memory data = abi.encodeWithSignature(
            "batchSend(address[],address[],uint256[],address[][],uint256[][])",
            rs,
            as_,
            ms,
            new address[](0),
            new uint256[](0)
        );
        _relay(_sign(_req(owner, address(vaultA), data), ownerPk), 1e6);

        assertEq(usdc.balanceOf(one), 10e6);
        assertEq(usdc.balanceOf(two), 20e6);
    }

    /// Two relayed calls in one batch, charged once — the reason executeBatchWithFee exists.
    function test_aBatchOfRelayedSendsIsChargedOnce() public {
        address one = makeAddr("one");
        address two = makeAddr("two");
        ERC2771Forwarder.ForwardRequestData[] memory rs = new ERC2771Forwarder.ForwardRequestData[](2);
        uint256 n = fwd.nonceFor(owner, address(vaultA));
        rs[0] = _signNonce(_req(owner, address(vaultA), _sendCall(one, address(usdc), 10e6)), ownerPk, n);
        rs[1] = _signNonce(_req(owner, address(vaultA), _sendCall(two, address(usdc), 20e6)), ownerPk, n + 1);

        vm.prank(relayer);
        fwd.executeBatchWithFee(rs, address(vaultA), address(usdc), 3e6);

        assertEq(usdc.balanceOf(one), 10e6);
        assertEq(usdc.balanceOf(two), 20e6);
        assertEq(usdc.balanceOf(BITTY_FEE_COLLECTOR), 3e6, "one charge for both");
    }
}
