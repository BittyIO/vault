// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {BittyV1VaultBootstrap} from "../../src/BittyV1VaultBootstrap.sol";
import {ASSET_STABLE_COIN} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC2771Forwarder} from "openzeppelin-contracts/contracts/metatx/ERC2771Forwarder.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {Safe} from "safe-contracts/Safe.sol";
import {SafeProxyFactory} from "safe-contracts/proxies/SafeProxyFactory.sol";
import {CompatibilityFallbackHandler} from "safe-contracts/handler/CompatibilityFallbackHandler.sol";
import {Enum} from "safe-contracts/common/Enum.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1SubVault} from "../../src/subvault/BittyV1SubVault.sol";
import {BittyV1VaultFactory} from "../../src/BittyV1VaultFactory.sol";
import {BittyV1VaultForwarder} from "../../src/BittyV1VaultForwarder.sol";
import {InvalidActivationSignature} from "../../src/interfaces/IBittyV1VaultFactory.sol";
import {BITTY_GUARD, BITTY_FORWARDER} from "../../src/logic/Constants.sol";

/**
 * A Gnosis Safe as the vault owner.
 *
 * This is the real Safe (v1.4.1), not a stand-in, because the thing worth testing is exactly what a
 * stand-in would get wrong. Safe's ERC-1271 does NOT check the signature against the hash it is given:
 * {CompatibilityFallbackHandler} re-enters the Safe with `abi.encode(dataHash)`, wraps that in a
 * Safe-domain EIP-712 envelope, and runs `checkSignatures` against the wrapped hash — with owners
 * sorted ascending and a threshold to meet. A mock that verified the raw hash would pass every test
 * here and tell us nothing.
 *
 * What the vault needs from a Safe owner falls into two halves. Direct calls, where the Safe is just
 * `msg.sender` and nothing must assume an EOA; and signed authority — activation and ERC-2771 relaying
 * — which both run through {SignatureChecker} and so must fall back to ERC-1271 correctly.
 */
contract SafeOwnerTest is Test {
    Safe safe;
    BittyV1Vault vault;
    BittyV1VaultFactory factory;
    BittyV1VaultForwarder fwd;
    BittyV1VaultDeFiFacet facet;
    MockGuard guard;
    MockERC20 usdc;

    // Three owners, a threshold of two. Kept sorted ascending, which is what checkSignatures demands.
    uint256[3] pks;
    address[3] owners;

    address weth = makeAddr("weth");
    address relayer = makeAddr("relayer");
    address fwdOwner = makeAddr("fwdOwner");
    address constant DEPLOYER = 0x12EE2de7BF086388B1D560eb95e7191Edfab9823;

    function setUp() public {
        vm.warp(1_000_000);
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);

        _makeSortedOwners();
        safe = _deploySafe();

        facet = new BittyV1VaultDeFiFacet();
        BittyV1SubVault subImpl = new BittyV1SubVault(address(facet));
        BittyV1Vault impl = new BittyV1Vault(address(facet), address(subImpl));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        guard.setAsset(address(usdc), ASSET_STABLE_COIN);

        vault = BittyV1Vault(
            payable(new ERC1967Proxy(
                    address(impl), abi.encodeCall(BittyV1Vault.initialize, (address(safe), weth, false, address(0), 0))
                ))
        );
        usdc.mint(address(vault), 1_000e6);

        BittyV1VaultFactory factoryImpl = new BittyV1VaultFactory();
        factory = BittyV1VaultFactory(address(new ERC1967Proxy(address(factoryImpl), "")));
        address boot = address(new BittyV1VaultBootstrap());
        vm.prank(DEPLOYER, DEPLOYER);
        factory.initialize(address(impl), weth, boot);

        BittyV1VaultForwarder fwdImpl = new BittyV1VaultForwarder();
        vm.etch(BITTY_FORWARDER, address(fwdImpl).code);
        fwd = BittyV1VaultForwarder(payable(BITTY_FORWARDER));
        vm.prank(DEPLOYER, DEPLOYER);
        fwd.initialize(fwdOwner);
        vm.prank(fwdOwner);
        fwd.setRelayerApproval(relayer, true);
    }

    // ── Safe plumbing ─────────────────────────────────────────────────────────

    function _makeSortedOwners() private {
        uint256[3] memory k = [uint256(0xA11CE), uint256(0xB0B), uint256(0xC0FFEE)];
        for (uint256 i; i < 3; i++) {
            for (uint256 j = i + 1; j < 3; j++) {
                if (vm.addr(k[j]) < vm.addr(k[i])) (k[i], k[j]) = (k[j], k[i]);
            }
        }
        for (uint256 i; i < 3; i++) {
            pks[i] = k[i];
            owners[i] = vm.addr(k[i]);
        }
    }

    function _deploySafe() private returns (Safe s) {
        Safe singleton = new Safe();
        SafeProxyFactory f = new SafeProxyFactory();
        CompatibilityFallbackHandler handler = new CompatibilityFallbackHandler();
        address[] memory o = new address[](3);
        for (uint256 i; i < 3; i++) {
            o[i] = owners[i];
        }
        bytes memory init =
            abi.encodeCall(Safe.setup, (o, 2, address(0), "", address(handler), address(0), 0, payable(address(0))));
        s = Safe(payable(address(f.createProxyWithNonce(address(singleton), init, 0))));
    }

    /// `count` owner signatures over `h`, concatenated in ascending owner order.
    function _sign(bytes32 h, uint256 count) private view returns (bytes memory sigs) {
        for (uint256 i; i < count; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(pks[i], h);
            sigs = abi.encodePacked(sigs, r, s, v);
        }
    }

    /// The Safe executing a call, the way a multisig actually does it.
    function _exec(address to, bytes memory data) private {
        bytes32 txHash = safe.getTransactionHash(
            to, 0, data, Enum.Operation.Call, 0, 0, 0, address(0), payable(address(0)), safe.nonce()
        );
        safe.execTransaction(
            to, 0, data, Enum.Operation.Call, 0, 0, 0, address(0), payable(address(0)), _sign(txHash, 2)
        );
    }

    /**
     * An ERC-1271 signature the Safe will accept for `dataHash`.
     * @dev The wrapped hash is asked of the Safe rather than recomputed here. Reimplementing the
     *      envelope would make this test agree with my reading of Safe instead of with Safe.
     */
    function _sign1271(bytes32 dataHash, uint256 count) private view returns (bytes memory) {
        bytes32 wrapped = CompatibilityFallbackHandler(payable(address(safe))).getMessageHash(abi.encode(dataHash));
        return _sign(wrapped, count);
    }

    // ── the Safe as a plain caller ────────────────────────────────────────────

    function test_aSafeOperatesTheVaultItOwns() public {
        assertEq(vault.owner(), address(safe), "the Safe owns it");

        _exec(
            address(vault),
            abi.encodeCall(
                BittyV1Vault.createSubVault, (makeAddr("subOwner"), false, uint64(block.timestamp + 365 days))
            )
        );
        assertEq(vault.subVaultOpenCount(), 1, "a 2-of-3 vote created a sub account");

        _exec(address(vault), abi.encodeCall(BittyV1VaultDeFiFacet.setAssetManager, (makeAddr("manager"), 0)));
        (address manager,,,) = BittyV1VaultDeFiFacet(payable(address(vault))).getAssetManagerSettings();
        assertEq(manager, makeAddr("manager"), "and appointed an asset manager");
    }

    /// Nothing in the ownership path assumes an EOA — the nominee only has to be able to call.
    function test_ownershipCanBeHandedToASafe() public {
        address eoa = makeAddr("eoa");
        BittyV1Vault v = BittyV1Vault(
            payable(new ERC1967Proxy(
                    address(new BittyV1Vault(address(facet), address(new BittyV1SubVault(address(facet))))),
                    abi.encodeCall(BittyV1Vault.initialize, (eoa, weth, false, address(0), 0))
                ))
        );

        vm.prank(eoa);
        v.transferOwnership(address(safe));
        assertEq(v.owner(), eoa, "not yet - the nominee must accept");

        _exec(address(v), abi.encodeCall(BittyV1Vault.acceptOwnership, ()));
        assertEq(v.owner(), address(safe), "the Safe proved it can call, and took it");
    }

    // ── signed authority: ERC-1271 through SignatureChecker ───────────────────

    function test_aSafeCanActivateAVaultGaslessly() public {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Activation(address owner,address stableCoinAddress,uint256 feeAmount,bool allowlistEnabled)"
                ),
                address(safe),
                address(0),
                uint256(0),
                true
            )
        );
        bytes32 digest = _domain712("BittyV1VaultFactory", address(factory), structHash);

        vm.prank(relayer);
        address created = factory.activateVaultByAsset(address(safe), address(0), 0, true, _sign1271(digest, 2));
        assertEq(BittyV1Vault(payable(created)).owner(), address(safe), "born under a multisig");
    }

    function test_aSafeSignedRelayIsExecuted() public {
        ERC2771Forwarder.ForwardRequestData memory r =
            _relay(address(safe), address(vault), abi.encodeCall(BittyV1Vault.enableAllowlist, ()), 2);
        vm.prank(relayer);
        fwd.executeWithFee(r, address(usdc), 0);
        assertTrue(BittyV1VaultDeFiFacet(payable(address(vault))).allowlistEnabled(), "relayed as the Safe");
    }

    /// The threshold is the whole point of a multisig, so it has to survive the relay path intact.
    function test_oneSignatureIsNotEnoughForATwoOfThree() public {
        ERC2771Forwarder.ForwardRequestData memory r =
            _relay(address(safe), address(vault), abi.encodeCall(BittyV1Vault.enableAllowlist, ()), 1);
        vm.prank(relayer);
        vm.expectRevert();
        fwd.executeWithFee(r, address(usdc), 0);
        assertFalse(BittyV1VaultDeFiFacet(payable(address(vault))).allowlistEnabled(), "nothing happened");
    }

    function test_anotherSafeSignatureDoesNotPassForThisOne() public {
        Safe other = _deploySafe();
        ERC2771Forwarder.ForwardRequestData memory r =
            _relay(address(other), address(vault), abi.encodeCall(BittyV1Vault.enableAllowlist, ()), 2);
        r.from = address(safe); // same signature, claimed for the wrong Safe

        vm.prank(relayer);
        vm.expectRevert();
        fwd.executeWithFee(r, address(usdc), 0);
    }

    /**
     * The test that keeps the rest of this file honest.
     *
     * Two valid owner signatures over the RAW digest — the bytes any EOA would sign, and exactly what
     * a hand-written ERC-1271 mock would accept — are refused. Safe checks against its own wrapped
     * message hash, so a signature has to be made for the Safe, not merely by its owners. If this ever
     * starts passing, every positive test here has stopped proving anything.
     */
    function test_rawDigestSignaturesAreRefusedBySafe() public {
        ERC2771Forwarder.ForwardRequestData memory r = ERC2771Forwarder.ForwardRequestData({
            from: address(safe),
            to: address(vault),
            value: 0,
            gas: 1_000_000,
            deadline: uint48(block.timestamp + 600),
            data: abi.encodeCall(BittyV1Vault.enableAllowlist, ()),
            signature: ""
        });
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint48 deadline,bytes data)"
                ),
                r.from,
                r.to,
                r.value,
                r.gas,
                fwd.nonceFor(r.from, r.to),
                r.deadline,
                keccak256(r.data)
            )
        );
        bytes32 digest = _domain712("BittyV1VaultForwarder", address(fwd), structHash);

        r.signature = _sign(digest, 2); // signed directly, WITHOUT Safe's envelope
        vm.prank(relayer);
        vm.expectRevert();
        fwd.executeWithFee(r, address(usdc), 0);

        r.signature = _sign1271(digest, 2); // the same two owners, wrapped properly
        vm.prank(relayer);
        fwd.executeWithFee(r, address(usdc), 0);
        assertTrue(
            BittyV1VaultDeFiFacet(payable(address(vault))).allowlistEnabled(),
            "same signers, same digest - only the envelope differed"
        );
    }

    // ── the intent path ───────────────────────────────────────────────────────

    /// CoW orders are signed off chain and checked through this predicate, so a Safe-owned vault would
    /// be unable to trade at all if it compared against anything EOA-shaped.
    function test_aSafeOwnerMaySignIntentOrders() public view {
        assertTrue(
            BittyV1VaultDeFiFacet(payable(address(vault)))
                .isOffchainOrderAuthorized(address(safe), address(usdc), address(usdc), 100e6),
            "the Safe is an authorised order signer"
        );
        assertTrue(
            BittyV1VaultDeFiFacet(payable(address(vault))).isOffchainCancellationAuthorized(address(safe)),
            "and may cancel"
        );
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    function _domain712(string memory name, address verifying, bytes32 structHash) private view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256("1"),
                block.chainid,
                verifying
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _relay(address from, address to, bytes memory data, uint256 count)
        private
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
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint48 deadline,bytes data)"
                ),
                r.from,
                r.to,
                r.value,
                r.gas,
                fwd.nonceFor(r.from, r.to),
                r.deadline,
                keccak256(r.data)
            )
        );
        r.signature = _sign1271(_domain712("BittyV1VaultForwarder", address(fwd), structHash), count);
    }
}
