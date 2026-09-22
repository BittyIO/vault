// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {IBittyV1Guard, ASSET_STABLE_COIN, IMPLEMENTATION_VAULT} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {IBittyV1Protocol} from "protocol-contracts/src/interfaces/IBittyV1Protocol.sol";
import {IBittyV1Yield} from "protocol-contracts/src/interfaces/IBittyV1Yield.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {MockLendingProtocol} from "../helpers/MockLendingProtocol.sol";
import {LENDING_ID} from "../helpers/CategoryIds.sol";
import {BittyV1VaultFactory} from "../../src/BittyV1VaultFactory.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1SubVault} from "../../src/subvault/BittyV1SubVault.sol";
import {InvalidActivationSignature} from "../../src/interfaces/IBittyV1VaultFactory.sol";
import {BITTY_GUARD, BITTY_VAULT_BOOTSTRAP, BITTY_FEE_COLLECTOR, CFG_GAS_WRAPPED} from "../../src/logic/Constants.sol";

interface IFacet {
    function deposit(address protocol, address asset, uint256 amount) external;
    function updateAssets(address[] calldata add, address[] calldata remove) external;
    function updateProtocols(address[] calldata add, address[] calldata remove) external;
    function getClone(address protocol) external view returns (address);
    function allowlistEnabled() external view returns (bool);
    function isProtocolAllowed(address protocol) external view returns (bool);
    function isAssetAllowed(address asset) external view returns (bool);
}

/**
 * A depositable that calls BACK into the vault during the deposit. It runs inside the activation
 * window, so it is the one caller that could conceivably borrow the owner's authority - which is
 * exactly what must not happen. It records whether the callback got through.
 */
contract ReenteringProtocol is IBittyV1Protocol, IBittyV1Yield, Ownable, Initializable {
    using SafeERC20 for IERC20;

    bool public calledBack;
    bool public callbackSucceeded;

    constructor() Ownable(msg.sender) {}

    function initialize(address newOwner) external override initializer {
        _transferOwnership(newOwner);
    }

    function protocolLineage() external pure returns (bytes32) {
        return keccak256("bitty.mock.reentering");
    }

    function protocolVersion() external pure returns (uint256) {
        return 1_000_000;
    }

    function versionName() external pure returns (string memory) {
        return "1.0.0";
    }

    function deposit(address asset, uint256 amount) external override onlyOwner {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        calledBack = true;
        try BittyV1Vault(payable(msg.sender)).enableAllowlist() {
            callbackSucceeded = true;
        } catch {}
    }

    function getBalance(address asset) external view override returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function withdraw(address asset, uint256 amount, address recipient) external override onlyOwner returns (uint256) {
        IERC20(asset).safeTransfer(recipient, amount);
        return amount;
    }

    function getPendingWithdrawalIds() external pure override returns (uint256[] memory) {
        return new uint256[](0);
    }

    function claimWithdrawals(uint256[] memory) external override onlyOwner {}
}

/**
 * Activate-and-call: the owner's first operations ride on the activation transaction, run AS THE
 * OWNER through a trusted-forwarder window that exists only for the length of `initialize`.
 *
 * What these pin: the calls carry the owner's authority and nothing more; the window is shut the
 * moment activation returns; nothing that re-enters during the window inherits it; a relayed
 * activation cannot have calls added by the relayer; and a failing entry leaves no vault behind.
 */
contract ActivateAndCallTest is Test {
    BittyV1VaultFactory factory;
    BittyV1Vault impl;
    MockGuard guard;
    MockERC20 usdc;
    WETH weth;
    MockLendingProtocol proto;

    uint256 ownerPk = 0xA11CE;
    address owner;
    address relayer = makeAddr("relayer");
    address stranger = makeAddr("stranger");

    function setUp() public {
        owner = vm.addr(ownerPk);
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);

        BittyV1VaultDeFiFacet facet = new BittyV1VaultDeFiFacet();
        BittyV1SubVault subImpl = new BittyV1SubVault(address(facet));
        impl = new BittyV1Vault(address(facet), address(subImpl));

        factory = new BittyV1VaultFactory();
        deployCodeTo("BittyV1VaultBootstrap.sol:BittyV1VaultBootstrap", BITTY_VAULT_BOOTSTRAP);
        guard.setLatestImpl(IMPLEMENTATION_VAULT, address(impl));

        weth = new WETH();
        guard.setConfigAddress(CFG_GAS_WRAPPED, address(weth));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        guard.setAsset(address(usdc), ASSET_STABLE_COIN);
        proto = new MockLendingProtocol();
        guard.setProtocol(address(proto), LENDING_ID);
    }

    function _predicted() internal view returns (address) {
        return factory.vaultAddress(owner);
    }

    function _one(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _none() internal pure returns (address[] memory) {
        return new address[](0);
    }

    function _onboarding(uint256 depositAmount) internal view returns (bytes[] memory calls) {
        calls = new bytes[](3);
        calls[0] = abi.encodeCall(IFacet.updateAssets, (_one(address(usdc)), _none()));
        calls[1] = abi.encodeCall(IFacet.updateProtocols, (_one(address(proto)), _none()));
        calls[2] = abi.encodeCall(IFacet.deposit, (address(proto), address(usdc), depositAmount));
    }

    function _sign(address o, address asset, uint256 amount, bool allowlistEnabled, bytes[] memory calls, uint256 pk)
        internal
        view
        returns (bytes memory)
    {
        bytes32[] memory hashes = new bytes32[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            hashes[i] = keccak256(calls[i]);
        }
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Activation(address owner,address stableCoinAddress,uint256 feeAmount,bool allowlistEnabled,bytes[] calls)"
                ),
                o,
                asset,
                amount,
                allowlistEnabled,
                keccak256(abi.encodePacked(hashes))
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("BittyV1VaultFactory"),
                keccak256("1"),
                block.chainid,
                address(factory)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }

    // ── the calls run as the owner ────────────────────────────────────────────

    function test_theWholeOnboardingRidesOnActivation() public {
        usdc.mint(_predicted(), 1_000e6);

        vm.prank(owner);
        address vault = factory.activateVault(true, _onboarding(600e6));

        assertEq(vault, _predicted(), "the address did not move");
        assertEq(BittyV1Vault(payable(vault)).owner(), owner, "owned by the caller");
        assertTrue(IFacet(vault).allowlistEnabled(), "activated with the allowlist on");
        assertTrue(IFacet(vault).isAssetAllowed(address(usdc)), "the batch listed the asset");
        assertTrue(IFacet(vault).isProtocolAllowed(address(proto)), "the batch enabled the protocol");
        address clone = IFacet(vault).getClone(address(proto));
        assertEq(MockLendingProtocol(clone).getBalance(address(usdc)), 600e6, "and the deposit landed");
        assertEq(usdc.balanceOf(vault), 400e6, "the rest stayed in the vault");
    }

    function test_anEmptyBatchIsPlainActivation() public {
        vm.prank(owner);
        address vault = factory.activateVault(true, new bytes[](0));
        assertEq(BittyV1Vault(payable(vault)).owner(), owner);
        assertEq(IFacet(vault).getClone(address(proto)), address(0), "nothing was touched");
    }

    function test_ethFundedBeforeActivationIsWethByTheTimeTheCallsRun() public {
        vm.deal(_predicted(), 1 ether);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IFacet.updateProtocols, (_one(address(proto)), _none()));
        calls[1] = abi.encodeCall(IFacet.deposit, (address(proto), address(weth), 1 ether));

        vm.prank(owner);
        address vault = factory.activateVault(false, calls);

        address clone = IFacet(vault).getClone(address(proto));
        assertEq(MockLendingProtocol(clone).getBalance(address(weth)), 1 ether, "the wrapped ETH was deposited");
        assertEq(vault.balance, 0, "no raw ETH left behind");
    }

    // ── the calls carry the owner's authority and nothing more ────────────────

    function test_theSameBatchIsRefusedToAStrangerOnceTheVaultExists() public {
        usdc.mint(_predicted(), 1_000e6);
        vm.prank(owner);
        address vault = factory.activateVault(true, new bytes[](0));

        vm.prank(stranger);
        vm.expectRevert();
        BittyV1Vault(payable(vault)).multicall(_onboarding(1e6));
    }

    /**
     * The factory was a trusted forwarder for the length of `initialize`. Afterwards a call from the
     * factory address carrying a forged owner suffix must be attributed to the factory, not the owner.
     */
    function test_theWindowIsShutOnceActivationReturns() public {
        vm.prank(owner);
        address vault = factory.activateVault(false, new bytes[](0));
        assertFalse(BittyV1Vault(payable(vault)).isTrustedForwarder(address(factory)), "not trusted at rest");

        bytes memory forged = abi.encodePacked(abi.encodeCall(BittyV1Vault.enableAllowlist, ()), owner);
        vm.prank(address(factory));
        (bool ok,) = vault.call(forged);
        assertFalse(ok, "the suffix is ignored, so the factory is not the owner");
        assertFalse(IFacet(vault).allowlistEnabled(), "and nothing changed");
    }

    /**
     * A protocol that re-enters the vault mid-activation is not the activator, so it gets no suffix
     * and is attributed to itself. Its owner-gated callback fails while the deposit around it lands.
     */
    function test_aReentrantCallerDuringTheWindowIsNotTheOwner() public {
        ReenteringProtocol trap = new ReenteringProtocol();
        guard.setProtocol(address(trap), LENDING_ID);
        usdc.mint(_predicted(), 100e6);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IFacet.updateProtocols, (_one(address(trap)), _none()));
        calls[1] = abi.encodeCall(IFacet.deposit, (address(trap), address(usdc), 100e6));

        vm.prank(owner);
        address vault = factory.activateVault(false, calls);

        ReenteringProtocol clone = ReenteringProtocol(IFacet(vault).getClone(address(trap)));
        assertTrue(clone.calledBack(), "the callback was attempted");
        assertFalse(clone.callbackSucceeded(), "and refused");
        assertFalse(IFacet(vault).allowlistEnabled(), "the owner-only switch stayed off");
        assertEq(clone.getBalance(address(usdc)), 100e6, "the deposit itself went through");
    }

    // ── atomic ────────────────────────────────────────────────────────────────

    function test_aFailingEntryLeavesNoVaultBehind() public {
        usdc.mint(_predicted(), 100e6);
        bytes[] memory calls = new bytes[](1);
        // Never registered on the guard, so the deposit is refused.
        calls[0] = abi.encodeCall(IFacet.deposit, (makeAddr("unknown"), address(usdc), 1e6));

        vm.prank(owner);
        vm.expectRevert();
        factory.activateVault(false, calls);

        assertEq(_predicted().code.length, 0, "no proxy was left on the address");
        assertEq(usdc.balanceOf(_predicted()), 100e6, "the funds are untouched");
    }

    // ── relayed: the calls are part of what the owner signed ──────────────────

    function test_aRelayedActivationRunsTheSignedCalls() public {
        usdc.mint(_predicted(), 1_000e6);
        bytes[] memory calls = _onboarding(500e6);
        bytes memory sig = _sign(owner, address(usdc), 2e6, true, calls, ownerPk);

        vm.prank(relayer);
        address vault = factory.activateVaultByAsset(owner, address(usdc), 2e6, true, calls, sig);

        assertEq(usdc.balanceOf(BITTY_FEE_COLLECTOR), 2e6, "the relayer's fee was collected");
        address clone = IFacet(vault).getClone(address(proto));
        assertEq(MockLendingProtocol(clone).getBalance(address(usdc)), 500e6, "and the signed deposit landed");
        assertEq(usdc.balanceOf(vault), 498e6, "fee out first, then the deposit");
    }

    function test_theRelayerCannotSwapTheCalls() public {
        usdc.mint(_predicted(), 1_000e6);
        bytes memory sig = _sign(owner, address(usdc), 2e6, true, _onboarding(1e6), ownerPk);

        vm.prank(relayer);
        vm.expectRevert(InvalidActivationSignature.selector);
        factory.activateVaultByAsset(owner, address(usdc), 2e6, true, _onboarding(999e6), sig);
    }

    function test_theRelayerCannotAppendACall() public {
        usdc.mint(_predicted(), 1_000e6);
        bytes memory sig = _sign(owner, address(usdc), 2e6, true, new bytes[](0), ownerPk);

        bytes[] memory extra = new bytes[](1);
        extra[0] = abi.encodeCall(IFacet.updateProtocols, (_one(address(proto)), _none()));
        vm.prank(relayer);
        vm.expectRevert(InvalidActivationSignature.selector);
        factory.activateVaultByAsset(owner, address(usdc), 2e6, true, extra, sig);
    }

    function test_aSignatureOverAnEmptyBatchStillOnlyActivates() public {
        usdc.mint(_predicted(), 100e6);
        bytes memory sig = _sign(owner, address(usdc), 2e6, true, new bytes[](0), ownerPk);
        vm.prank(relayer);
        address vault = factory.activateVaultByAsset(owner, address(usdc), 2e6, true, new bytes[](0), sig);
        assertEq(BittyV1Vault(payable(vault)).owner(), owner);
        assertEq(usdc.balanceOf(vault), 98e6);
    }
}
