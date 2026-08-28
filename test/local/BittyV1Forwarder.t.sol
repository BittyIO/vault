// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {guardAddAssets, guardAddStableCoins, guardAddProtocols} from "../helpers/GuardRegister.sol";
import {GUARD_DEPLOYER} from "../helpers/GuardDeployer.sol";
import {console2} from "forge-std/console2.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {VaultLogic} from "../../src/logic/VaultLogic.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1VaultForwarder} from "../../src/BittyV1VaultForwarder.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {AutoYield} from "../../src/interfaces/IBittyV1Vault.sol";
import {BittyV1Guard} from "guard-contracts/src/BittyV1Guard.sol";
import {BITTY_GUARD, BITTY_FORWARDER, BITTY_FEE_COLLECTOR} from "../../src/logic/Constants.sol";
import {ERC2771Forwarder} from "openzeppelin-contracts/contracts/metatx/ERC2771Forwarder.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {effectiveAssetManager} from "../helpers/AssetManagerView.sol";

contract BittyV1ForwarderTest is Test {
    BittyV1Vault internal vault;
    BittyV1VaultForwarder internal fwd;
    BittyV1Guard internal guard;
    WETH internal weth;
    MockERC20 internal usdc;

    address internal collector = BITTY_FEE_COLLECTOR;
    address internal relayer = makeAddr("relayer");
    address internal deployer = makeAddr("deployer");
    address internal alice;
    uint256 internal pk;
    address internal keeper;
    uint256 internal keeperPk;

    bytes32 constant TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint48 deadline,bytes data)"
    );

    function setUp() public {
        (alice, pk) = makeAddrAndKey("alice");
        weth = new WETH();
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        deployCodeTo("BittyV1Guard.sol:BittyV1Guard", BITTY_GUARD);
        vm.stopPrank();
        guard = BittyV1Guard(BITTY_GUARD);
        deployCodeTo("BittyV1VaultForwarder.sol:BittyV1VaultForwarder", BITTY_FORWARDER);
        fwd = BittyV1VaultForwarder(BITTY_FORWARDER);
        vm.prank(fwd.DEPLOYER(), fwd.DEPLOYER());
        fwd.initialize(deployer);
        vm.prank(deployer);
        fwd.setRelayerApproval(relayer, true);

        (keeper, keeperPk) = makeAddrAndKey("autoYieldKeeper");
        vault = new BittyV1Vault(address(new BittyV1VaultDeFiFacet()), keeper);
        vault.initialize(alice, address(weth), address(0), 0);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        address[] memory add = new address[](1);
        add[0] = address(usdc);
        vm.prank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddStableCoins(address(guard), add);
        usdc.mint(address(vault), 10_000_000000);

        // Relaying is off until the owner turns it on and names what may pay for it.
        address[] memory coins = new address[](1);
        coins[0] = address(usdc);
        vm.prank(alice);
        // Budget at the per-op cap so a single charge can exhaust it; derived from the contract's
        // ceilings so tightening them does not invalidate the amounts below.
        vault.setGasless(coins, VaultLogic.MAX_FEE_PER_OP, 0);
    }

    function _req(bytes memory data) internal view returns (ERC2771Forwarder.ForwardRequestData memory r) {
        r = ERC2771Forwarder.ForwardRequestData({
            from: alice,
            to: address(vault),
            value: 0,
            gas: 1_000_000,
            deadline: uint48(block.timestamp + 1 days),
            data: data,
            signature: ""
        });
        bytes32 structHash = keccak256(
            abi.encode(
                TYPEHASH,
                alice,
                address(vault),
                uint256(0),
                uint256(1_000_000),
                fwd.nonceFor(alice, address(vault)),
                r.deadline,
                keccak256(data)
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("BittyV1VaultForwarder")),
                keccak256(bytes("1")),
                block.chainid,
                address(fwd)
            )
        );
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        r.signature = abi.encodePacked(rr, ss, v);
    }

    function _reqWithNonce(bytes memory data, uint256 nonceOffset)
        internal
        view
        returns (ERC2771Forwarder.ForwardRequestData memory r)
    {
        r = ERC2771Forwarder.ForwardRequestData({
            from: alice,
            to: address(vault),
            value: 0,
            gas: 1_000_000,
            deadline: uint48(block.timestamp + 1 days),
            data: data,
            signature: ""
        });
        bytes32 structHash = keccak256(
            abi.encode(
                TYPEHASH,
                alice,
                address(vault),
                uint256(0),
                uint256(1_000_000),
                fwd.nonceFor(alice, address(vault)) + nonceOffset,
                r.deadline,
                keccak256(data)
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("BittyV1VaultForwarder")),
                keccak256(bytes("1")),
                block.chainid,
                address(fwd)
            )
        );
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        r.signature = abi.encodePacked(rr, ss, v);
    }

    function _setManagerCall(address mgr) internal pure returns (bytes memory) {
        return abi.encodeCall(IBittyV1Owner.setAssetManager, (mgr, 0));
    }

    // ============ End-to-end ============

    function test_RelayAndCharge() public {
        address mgr = makeAddr("mgr");
        ERC2771Forwarder.ForwardRequestData memory r = _req(_setManagerCall(mgr));
        vm.prank(relayer);
        fwd.executeWithFee(r, address(usdc), 3_000000);

        assertEq(effectiveAssetManager(address(vault)), mgr, "the owner's intent executed without them holding ETH");
        assertEq(usdc.balanceOf(collector), 3_000000);
        assertEq(vault.gasBudgetRemaining(), (uint256(VaultLogic.MAX_FEE_PER_OP) - 3) * 1e18);
    }

    function test_RelayWithoutCharging() public {
        address mgr = makeAddr("mgr");
        ERC2771Forwarder.ForwardRequestData memory r = _req(_setManagerCall(mgr));
        vm.prank(relayer);
        fwd.executeWithFee(r, address(usdc), 0);

        assertEq(effectiveAssetManager(address(vault)), mgr);
        assertEq(usdc.balanceOf(collector), 0, "fee 0 relays without charging");
    }

    /// Plain execute stays permissionless, as ERC-2771 intends — it just cannot charge.
    function test_PlainExecuteIsPermissionlessAndFree() public {
        address mgr = makeAddr("mgr");
        address bystander = makeAddr("bystander");
        ERC2771Forwarder.ForwardRequestData memory r = _req(_setManagerCall(mgr));
        vm.prank(bystander);
        fwd.execute(r);

        assertEq(effectiveAssetManager(address(vault)), mgr);
        assertEq(usdc.balanceOf(collector), 0);
    }

    // ============ Initialization ============

    /**
     * The whole reason the owner is not a constructor argument: constructor arguments are appended to
     * the init code, and init code is what CREATE2 hashes. With none, the same salt lands on the same
     * address on every chain even when each chain gives the forwarder a different owner.
     */
    function test_InitCodeIsIndependentOfOwner() public {
        bytes32 codeHash = keccak256(type(BittyV1VaultForwarder).creationCode);

        BittyV1VaultForwarder a = new BittyV1VaultForwarder();
        BittyV1VaultForwarder b = new BittyV1VaultForwarder();
        vm.prank(a.DEPLOYER(), a.DEPLOYER());
        a.initialize(makeAddr("ownerOnChainA"));
        vm.prank(b.DEPLOYER(), b.DEPLOYER());
        b.initialize(makeAddr("ownerOnChainB"));

        assertTrue(a.owner() != b.owner(), "different owners");
        assertEq(keccak256(type(BittyV1VaultForwarder).creationCode), codeHash, "same init code regardless");
    }

    function test_OnlyDeployerCanInitialize() public {
        BittyV1VaultForwarder fresh = new BittyV1VaultForwarder();
        vm.prank(makeAddr("squatter"), makeAddr("squatter"));
        vm.expectRevert(BittyV1VaultForwarder.NotDeployer.selector);
        fresh.initialize(makeAddr("squatter"));
    }

    function test_CannotInitializeTwice() public {
        vm.prank(fwd.DEPLOYER(), fwd.DEPLOYER());
        vm.expectRevert();
        fwd.initialize(makeAddr("other"));
    }

    function test_OwnerCannotBeZero() public {
        BittyV1VaultForwarder fresh = new BittyV1VaultForwarder();
        vm.prank(fresh.DEPLOYER(), fresh.DEPLOYER());
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableInvalidOwner.selector, address(0)));
        fresh.initialize(address(0));
    }

    // ============ Ownership transfer ============

    function test_OwnershipTransferIsTwoStep() public {
        address next = makeAddr("nextOwner");

        vm.prank(deployer);
        fwd.transferOwnership(next);
        assertEq(fwd.owner(), deployer, "nomination alone does not move authority");
        assertEq(fwd.pendingOwner(), next);

        vm.prank(next);
        fwd.acceptOwnership();
        assertEq(fwd.owner(), next, "authority moves only once the nominee accepts");
        assertEq(fwd.pendingOwner(), address(0), "and the nomination is consumed");
    }

    function test_OnlyOwnerCanNominate() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        fwd.transferOwnership(makeAddr("nextOwner"));
    }

    function test_OnlyNomineeCanAccept() public {
        vm.prank(deployer);
        fwd.transferOwnership(makeAddr("nextOwner"));

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        fwd.acceptOwnership();
        assertEq(fwd.owner(), deployer, "a rejected accept leaves the owner untouched");
    }

    function test_NominationCanBeCancelled() public {
        vm.startPrank(deployer);
        fwd.transferOwnership(makeAddr("nextOwner"));
        fwd.transferOwnership(address(0));
        vm.stopPrank();
        assertEq(fwd.pendingOwner(), address(0), "the nomination is withdrawn");
    }

    /// @dev Renouncing would strand the relayer allowlist on a forwarder no vault can be pointed away
    ///      from, so the inherited entry point is closed off.
    function test_OwnershipCannotBeRenounced() public {
        vm.prank(deployer);
        vm.expectRevert(BittyV1VaultForwarder.OwnershipNotRenounceable.selector);
        fwd.renounceOwnership();
        assertEq(fwd.owner(), deployer, "the allowlist keeps an owner");
    }

    function test_NewOwnerControlsTheRelayerAllowlist() public {
        address next = makeAddr("nextOwner");
        address newRelayer = makeAddr("newRelayer");

        vm.prank(deployer);
        fwd.transferOwnership(next);
        vm.prank(next);
        fwd.acceptOwnership();

        vm.prank(next);
        fwd.setRelayerApproval(newRelayer, true);
        assertTrue(fwd.approvedRelayers(newRelayer), "the new owner can approve");

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, deployer));
        fwd.setRelayerApproval(newRelayer, false);
    }

    /// @dev The reason this exists: a contract nominee proves it can call, which is what lets the
    ///      allowlist move to a multisig now and to a non-ECDSA account later.
    function test_OwnershipCanMoveToAContract() public {
        BittyV1VaultForwarder nominee = new BittyV1VaultForwarder();

        vm.prank(deployer);
        fwd.transferOwnership(address(nominee));
        vm.prank(address(nominee));
        fwd.acceptOwnership();

        assertEq(fwd.owner(), address(nominee), "a contract holds the allowlist");
        assertGt(address(nominee).code.length, 0, "and it is genuinely a contract");
    }

    // ============ Batched relay, one fee ============

    function test_BatchRelaysAllAndChargesOnce() public {
        address mgr = makeAddr("mgr");
        ERC2771Forwarder.ForwardRequestData[] memory batch = new ERC2771Forwarder.ForwardRequestData[](2);
        batch[0] = _req(abi.encodeCall(IBittyV1Owner.setAssetManager, (mgr, 0)));
        // Nonces increment per request, so the second must be signed against the next one.
        batch[1] = _reqWithNonce(abi.encodeCall(IBittyV1Owner.disableAddingAssets, ()), 1);

        vm.prank(relayer);
        fwd.executeBatchWithFee(batch, address(vault), address(usdc), 4_000000);

        assertEq(effectiveAssetManager(address(vault)), mgr, "first request ran");
        assertTrue(vault.isAddingAssetsDisabled(), "second request ran");
        assertEq(usdc.balanceOf(collector), 4_000000, "charged once for the pair");
        assertEq(vault.gasBudgetRemaining(), (uint256(VaultLogic.MAX_FEE_PER_OP) - 4) * 1e18);
    }

    /**
     * Without this check a relayer could put another vault's request in the batch and have THIS
     * vault's budget pay for it.
     */
    function test_BatchRejectsForeignTarget() public {
        ERC2771Forwarder.ForwardRequestData[] memory batch = new ERC2771Forwarder.ForwardRequestData[](1);
        batch[0] = _req(abi.encodeCall(IBittyV1Owner.setAssetManager, (makeAddr("mgr"), 0)));

        vm.prank(relayer);
        vm.expectRevert(BittyV1VaultForwarder.BatchTargetMismatch.selector);
        fwd.executeBatchWithFee(batch, makeAddr("someOtherVault"), address(usdc), 1_000000);
    }

    function test_BatchIsAtomic() public {
        ERC2771Forwarder.ForwardRequestData[] memory batch = new ERC2771Forwarder.ForwardRequestData[](2);
        batch[0] = _req(abi.encodeCall(IBittyV1Owner.setAssetManager, (makeAddr("mgr"), 0)));
        batch[1] = _reqWithNonce(abi.encodeCall(IBittyV1Owner.setAssetManager, (makeAddr("mgr2"), 0)), 99); // bad nonce

        vm.prank(relayer);
        vm.expectRevert();
        fwd.executeBatchWithFee(batch, address(vault), address(usdc), 1_000000);

        assertEq(effectiveAssetManager(address(vault)), alice, "nothing applied, and nothing charged");
        assertEq(usdc.balanceOf(collector), 0);
    }

    function test_BatchRequiresApprovedRelayer() public {
        ERC2771Forwarder.ForwardRequestData[] memory batch = new ERC2771Forwarder.ForwardRequestData[](1);
        batch[0] = _req(abi.encodeCall(IBittyV1Owner.setAssetManager, (makeAddr("mgr"), 0)));

        vm.prank(makeAddr("bystander"));
        vm.expectRevert(BittyV1VaultForwarder.NotApprovedRelayer.selector);
        fwd.executeBatchWithFee(batch, address(vault), address(usdc), 1_000000);
    }

    // ============ Relayer approval ============

    /**
     * Without this restriction a bystander could lift a signed request out of the mempool, submit it
     * with the maximum allowed fee, and burn the owner's daily budget for no benefit to anyone.
     */
    function test_UnapprovedRelayerCannotCharge() public {
        ERC2771Forwarder.ForwardRequestData memory r = _req(_setManagerCall(makeAddr("mgr")));
        vm.prank(makeAddr("bystander"));
        vm.expectRevert(BittyV1VaultForwarder.NotApprovedRelayer.selector);
        fwd.executeWithFee(r, address(usdc), 3_000000);
    }

    function test_RelayerApprovalIsOwnerOnly() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        fwd.setRelayerApproval(stranger, true);
    }

    function test_ApprovalCanBeRevoked() public {
        ERC2771Forwarder.ForwardRequestData memory r = _req(_setManagerCall(makeAddr("mgr")));
        vm.prank(deployer);
        fwd.setRelayerApproval(relayer, false);

        vm.prank(relayer);
        vm.expectRevert(BittyV1VaultForwarder.NotApprovedRelayer.selector);
        fwd.executeWithFee(r, address(usdc), 1e6);
    }

    // ============ Budget bounds ============

    /// The pre-check exists so a relay that could never be paid for fails before the work is done.
    function test_FeeOverRemainingBudgetIsRejectedBeforeExecuting() public {
        address mgr = makeAddr("mgr");
        ERC2771Forwarder.ForwardRequestData memory r = _req(_setManagerCall(mgr));
        vm.prank(relayer);
        vm.expectRevert(BittyV1VaultForwarder.FeeExceedsVaultBudget.selector);
        fwd.executeWithFee(r, address(usdc), (uint256(VaultLogic.MAX_FEE_PER_OP) + 1) * 1e6);

        // initialize() makes the owner the asset manager, so "unchanged" is alice, not address(0).
        assertEq(effectiveAssetManager(address(vault)), alice, "the request must not have executed");
        assertEq(fwd.nonceFor(alice, address(vault)), 0, "and its nonce must not have been consumed");
    }

    function test_BudgetDrainsAcrossCalls() public {
        uint256 quarter = (uint256(VaultLogic.MAX_FEE_PER_OP) * 1e6) / 4;
        for (uint256 i; i < 4; i++) {
            ERC2771Forwarder.ForwardRequestData memory each = _req(_setManagerCall(makeAddr("mgr")));
            vm.prank(relayer);
            fwd.executeWithFee(each, address(usdc), quarter);
        }
        assertEq(vault.gasBudgetRemaining(), 0);

        ERC2771Forwarder.ForwardRequestData memory r = _req(_setManagerCall(makeAddr("mgr")));
        vm.prank(relayer);
        vm.expectRevert(BittyV1VaultForwarder.FeeExceedsVaultBudget.selector);
        fwd.executeWithFee(r, address(usdc), 1_000000);
    }

    /// A vault with gasless switched off cannot be relayed-and-charged at all.
    /// @dev Off is {disableGasless}. setGasless with an empty list would ENABLE on guard defaults.
    function test_GaslessOffVaultRejectsCharging() public {
        ERC2771Forwarder.ForwardRequestData memory r = _req(_setManagerCall(makeAddr("mgr")));
        vm.prank(alice);
        vault.disableGasless();

        vm.prank(relayer);
        vm.expectRevert(BittyV1VaultForwarder.FeeExceedsVaultBudget.selector);
        fwd.executeWithFee(r, address(usdc), 1_000000);
    }

    // ============ Signature handling (OZ's, spot-checked through our entry point) ============

    function test_ForgedSignatureIsRejected() public {
        (, uint256 wrongPk) = makeAddrAndKey("mallory");
        ERC2771Forwarder.ForwardRequestData memory r = _req(_setManagerCall(makeAddr("mgr")));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", bytes32(0), bytes32(0)));
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(wrongPk, digest);
        r.signature = abi.encodePacked(rr, ss, v);

        vm.prank(relayer);
        vm.expectRevert();
        fwd.executeWithFee(r, address(usdc), 1_000000);
    }

    function test_ReplayIsRejected() public {
        ERC2771Forwarder.ForwardRequestData memory r = _req(_setManagerCall(makeAddr("mgr")));
        vm.prank(relayer);
        fwd.executeWithFee(r, address(usdc), 1_000000);

        // Same request again: the nonce has moved on.
        vm.prank(relayer);
        vm.expectRevert();
        fwd.executeWithFee(r, address(usdc), 1_000000);
    }

    function test_ExpiredRequestIsRejected() public {
        ERC2771Forwarder.ForwardRequestData memory r = _req(_setManagerCall(makeAddr("mgr")));
        vm.warp(block.timestamp + 2 days);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ERC2771Forwarder.ERC2771ForwarderExpiredRequest.selector, r.deadline));
        fwd.executeWithFee(r, address(usdc), 1_000000);
    }

    /// A relayed call still has to satisfy the vault's own roles — relaying is not authorisation.
    function test_RelayedCallStillSubjectToVaultRoles() public {
        (address mallory, uint256 mpk) = makeAddrAndKey("mallory");
        ERC2771Forwarder.ForwardRequestData memory r = ERC2771Forwarder.ForwardRequestData({
            from: mallory,
            to: address(vault),
            value: 0,
            gas: 1_000_000,
            deadline: uint48(block.timestamp + 1 days),
            data: _setManagerCall(mallory),
            signature: ""
        });
        bytes32 structHash = keccak256(
            abi.encode(
                TYPEHASH,
                mallory,
                address(vault),
                uint256(0),
                uint256(1_000_000),
                fwd.nonceFor(mallory, address(vault)),
                r.deadline,
                keccak256(r.data)
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("BittyV1VaultForwarder")),
                keccak256(bytes("1")),
                block.chainid,
                address(fwd)
            )
        );
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(mpk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        r.signature = abi.encodePacked(rr, ss, v);

        vm.prank(relayer);
        vm.expectRevert();
        fwd.executeWithFee(r, address(usdc), 1_000000);
    }

    // ============ Auto-yield relayed and charged to the vault ============

    /**
     * The keeper signs, an approved relayer submits, and the VAULT pays the fee in stable coin. This is
     * the property that decides who funds auto-yield: nothing here is paid by the keeper's own balance.
     */
    function test_AutoYield_RelayedAndPaidByTheVault() public {
        bytes memory data = abi.encodeCall(BittyV1Vault.autoYield, (address(weth)));
        ERC2771Forwarder.ForwardRequestData memory r = _reqSigned(keeper, keeperPk, address(vault), data);

        uint256 before = usdc.balanceOf(collector);
        vm.prank(relayer);
        fwd.executeWithFee(r, address(usdc), 2_000000);

        assertEq(usdc.balanceOf(collector) - before, 2_000000, "the vault, not the keeper, paid for the sweep");
        assertEq(vault.gasBudgetRemaining(), (uint256(VaultLogic.MAX_FEE_PER_OP) - 2) * 1e18);
    }

    /// Naming a keeper re-enables relaying, so even a vault whose owner switched it off can repay the

    /// Clearing the trigger must NOT switch relaying back off — the owner may want it for their own calls.
    function test_ClearingTheTriggerLeavesGaslessOn() public {
        vm.prank(alice);
        vault.setAutoYieldings(new AutoYield[](0));
        vm.prank(alice);
        vault.setAutoYieldings(new AutoYield[](0));

        (, uint256 dailyLimit,) = vault.gaslessConfig();
        assertGt(dailyLimit, 0, "relaying stayed on after the keeper was removed");
    }

    /// Relaying is on from birth, so the property the trigger guard actually controls is the reverse:

    function _reqSigned(address from, uint256 key, address to, bytes memory data)
        internal
        view
        returns (ERC2771Forwarder.ForwardRequestData memory r)
    {
        r = ERC2771Forwarder.ForwardRequestData({
            from: from,
            to: to,
            value: 0,
            gas: 1_000_000,
            deadline: uint48(block.timestamp + 1 days),
            data: data,
            signature: ""
        });
        r.signature = _sign(key, _digest(from, to, data, r.deadline));
    }

    /**
     * The auto-yield trigger can be a CONTRACT rather than an EOA, because the forwarder validates
     * request.from through ERC-1271. The vault sees one stable trigger address forever, while the hot
     * keys behind it rotate inside that contract — so rotating a keeper key stops being a transaction
     * per vault, which matters because setAutoYieldings is owner-only.
     */
    function test_AutoYield_ContractTriggerSignsWithRotatableKeys() public {
        (address k0, uint256 key0) = makeAddrAndKey("keeperKeyA");
        (address k1, uint256 key1) = makeAddrAndKey("keeperKeyB");
        MockMultisigWallet contractKeeper = new MockMultisigWallet(k0, k1);
        BittyV1Vault v = _vaultWithKeeper(address(contractKeeper));

        bytes memory data = abi.encodeCall(BittyV1Vault.autoYield, (address(weth)));
        ERC2771Forwarder.ForwardRequestData memory r = ERC2771Forwarder.ForwardRequestData({
            from: address(contractKeeper),
            to: address(v),
            value: 0,
            gas: 1_000_000,
            deadline: uint48(block.timestamp + 1 days),
            data: data,
            signature: ""
        });
        bytes32 digest = _digest(address(contractKeeper), address(v), data, r.deadline);
        r.signature = abi.encodePacked(_sign(key0, digest), _sign(key1, digest));

        uint256 before = usdc.balanceOf(collector);
        vm.prank(relayer);
        fwd.executeWithFee(r, address(usdc), 2_000000);

        assertEq(usdc.balanceOf(collector) - before, 2_000000, "contract trigger swept, vault paid");
    }

    // ============ Per-vault nonce lanes ============

    function _vaultWithKeeper(address keeper_) internal returns (BittyV1Vault v) {
        v = new BittyV1Vault(address(new BittyV1VaultDeFiFacet()), keeper_);
        v.initialize(alice, address(weth), address(0), 0);
        usdc.mint(address(v), 10_000_000000);
        address[] memory coins = new address[](1);
        coins[0] = address(usdc);
        vm.prank(alice);
        v.setGasless(coins, VaultLogic.MAX_FEE_PER_OP, 0);
    }

    function _secondVault() internal returns (BittyV1Vault v) {
        v = new BittyV1Vault(address(new BittyV1VaultDeFiFacet()), address(0xA07E1D));
        v.initialize(alice, address(weth), address(0), 0);
        usdc.mint(address(v), 10_000_000000);
        address[] memory coins = new address[](1);
        coins[0] = address(usdc);
        vm.prank(alice);
        v.setGasless(coins, VaultLogic.MAX_FEE_PER_OP, 0);
    }

    /**
     * The case a single flat nonce cannot serve: one signer relaying to two vaults. Both requests are
     * signed at nonce 0 of their own lane, and neither has to wait for the other.
     */
    function test_lanes_oneSignerTwoVaultsBothAtNonceZero() public {
        BittyV1Vault v2 = _secondVault();
        assertEq(fwd.nonceFor(alice, address(vault)), 0);
        assertEq(fwd.nonceFor(alice, address(v2)), 0);

        bytes memory data = _setManagerCall(makeAddr("mgrA"));
        ERC2771Forwarder.ForwardRequestData memory rA = _reqSigned(alice, pk, address(vault), data);
        ERC2771Forwarder.ForwardRequestData memory rB = _reqSigned(alice, pk, address(v2), data);

        vm.prank(relayer);
        fwd.executeWithFee(rB, address(usdc), 0);
        vm.prank(relayer);
        fwd.executeWithFee(rA, address(usdc), 0);

        assertEq(fwd.nonceFor(alice, address(vault)), 1, "vault A lane advanced");
        assertEq(fwd.nonceFor(alice, address(v2)), 1, "vault B lane advanced independently");
    }

    /// A lane that cannot progress must not hold up any other lane.
    function test_lanes_aStalledLaneDoesNotBlockAnother() public {
        BittyV1Vault v2 = _secondVault();

        // Signed at nonce 1 for vault A, so it can never execute until nonce 0 does.
        ERC2771Forwarder.ForwardRequestData memory stuck =
            _reqSignedNonce(alice, pk, address(vault), _setManagerCall(makeAddr("x")), 1);
        vm.prank(relayer);
        vm.expectRevert();
        fwd.executeWithFee(stuck, address(usdc), 0);

        // Vault B's lane is untouched by that.
        ERC2771Forwarder.ForwardRequestData memory ok =
            _reqSigned(alice, pk, address(v2), _setManagerCall(makeAddr("y")));
        vm.prank(relayer);
        fwd.executeWithFee(ok, address(usdc), 0);
        assertEq(effectiveAssetManager(address(v2)), makeAddr("y"), "other lane progressed regardless");
    }

    /// Within one lane the sequence still binds — replay is still impossible.
    function test_lanes_replayWithinALaneStillRejected() public {
        ERC2771Forwarder.ForwardRequestData memory r =
            _reqSigned(alice, pk, address(vault), _setManagerCall(makeAddr("mgr")));
        vm.prank(relayer);
        fwd.executeWithFee(r, address(usdc), 0);
        vm.prank(relayer);
        vm.expectRevert();
        fwd.executeWithFee(r, address(usdc), 0);
    }

    /// OpenZeppelin's non-atomic batch is disabled; executeBatchWithFee is the supported batch.
    function test_lanes_openZeppelinBatchIsDisabled() public {
        ERC2771Forwarder.ForwardRequestData[] memory one = new ERC2771Forwarder.ForwardRequestData[](1);
        one[0] = _reqSigned(alice, pk, address(vault), _setManagerCall(makeAddr("mgr")));
        vm.expectRevert(BittyV1VaultForwarder.BatchNotSupported.selector);
        fwd.executeBatch(one, payable(address(0)));
    }

    function _reqSignedNonce(address from, uint256 key, address to, bytes memory data, uint64 nonce)
        internal
        view
        returns (ERC2771Forwarder.ForwardRequestData memory r)
    {
        r = ERC2771Forwarder.ForwardRequestData({
            from: from,
            to: to,
            value: 0,
            gas: 1_000_000,
            deadline: uint48(block.timestamp + 1 days),
            data: data,
            signature: ""
        });
        bytes32 structHash = keccak256(
            abi.encode(TYPEHASH, from, to, uint256(0), uint256(1_000_000), nonce, r.deadline, keccak256(data))
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("BittyV1VaultForwarder")),
                keccak256(bytes("1")),
                block.chainid,
                address(fwd)
            )
        );
        r.signature = _sign(key, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
    }

    // ============ ERC-1271 (contract-wallet owners) ============

    function _digest(address from, address to, bytes memory data, uint48 deadline) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                TYPEHASH, from, to, uint256(0), uint256(1_000_000), fwd.nonceFor(from, to), deadline, keccak256(data)
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("BittyV1VaultForwarder")),
                keccak256(bytes("1")),
                block.chainid,
                address(fwd)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /**
     * A vault owned by a 2-of-2 contract wallet, gasless on and funded. The wallet's signature is two
     * concatenated ECDSA signatures — 130 bytes, which is exactly what `ECDSA.tryRecover` cannot handle,
     * so this vault is only relayable through the ERC-1271 branch.
     */
    function _walletOwnedVault() internal returns (BittyV1Vault v, MockMultisigWallet wallet, uint256 k0, uint256 k1) {
        address o0;
        address o1;
        (o0, k0) = makeAddrAndKey("walletOwner0");
        (o1, k1) = makeAddrAndKey("walletOwner1");
        wallet = new MockMultisigWallet(o0, o1);

        v = new BittyV1Vault(address(new BittyV1VaultDeFiFacet()), address(0xA07E1D));
        v.initialize(address(wallet), address(weth), address(0), 0);
        usdc.mint(address(v), 10_000_000000);

        address[] memory coins = new address[](1);
        coins[0] = address(usdc);
        vm.prank(address(wallet));
        v.setGasless(coins, VaultLogic.MAX_FEE_PER_OP, 0);
    }

    function _walletReq(BittyV1Vault v, MockMultisigWallet wallet, bytes memory data, uint256 k0, uint256 k1)
        internal
        view
        returns (ERC2771Forwarder.ForwardRequestData memory r)
    {
        r = ERC2771Forwarder.ForwardRequestData({
            from: address(wallet),
            to: address(v),
            value: 0,
            gas: 1_000_000,
            deadline: uint48(block.timestamp + 1 days),
            data: data,
            signature: ""
        });
        bytes32 digest = _digest(address(wallet), address(v), data, r.deadline);
        r.signature = abi.encodePacked(_sign(k0, digest), _sign(k1, digest));
    }

    /**
     * The gap this closes: {BittyV1VaultFactory} onboards contract-wallet owners through
     * SignatureChecker, so a Safe-owned vault could be activated gaslessly and then never relayed
     * again. Under OpenZeppelin's recover-and-compare this request fails as InvalidSigner.
     */
    function test_ERC1271OwnerCanRelayAndBeCharged() public {
        (BittyV1Vault v, MockMultisigWallet wallet, uint256 k0, uint256 k1) = _walletOwnedVault();
        address mgr = makeAddr("mgr");

        ERC2771Forwarder.ForwardRequestData memory r = _walletReq(v, wallet, _setManagerCall(mgr), k0, k1);
        vm.prank(relayer);
        fwd.executeWithFee(r, address(usdc), 3_000000);

        assertEq(effectiveAssetManager(address(v)), mgr, "the contract wallet's intent executed without it holding ETH");
        assertEq(usdc.balanceOf(collector), 3_000000);
        assertEq(v.gasBudgetRemaining(), (uint256(VaultLogic.MAX_FEE_PER_OP) - 3) * 1e18);
    }

    function test_ERC1271VerifyAcceptsTheSignature() public {
        (BittyV1Vault v, MockMultisigWallet wallet, uint256 k0, uint256 k1) = _walletOwnedVault();
        ERC2771Forwarder.ForwardRequestData memory r = _walletReq(v, wallet, _setManagerCall(makeAddr("mgr")), k0, k1);

        assertTrue(fwd.verify(r), "verify() must agree with what execute will accept");
    }

    /// One good signature and one stranger's: the wallet rejects it, so the forwarder must too.
    function test_ERC1271RejectsSignatureTheWalletDoesNotAccept() public {
        (BittyV1Vault v, MockMultisigWallet wallet, uint256 k0,) = _walletOwnedVault();
        (, uint256 strangerKey) = makeAddrAndKey("stranger");
        bytes memory data = _setManagerCall(makeAddr("mgr"));

        ERC2771Forwarder.ForwardRequestData memory r = ERC2771Forwarder.ForwardRequestData({
            from: address(wallet),
            to: address(v),
            value: 0,
            gas: 1_000_000,
            deadline: uint48(block.timestamp + 1 days),
            data: data,
            signature: ""
        });
        bytes32 digest = _digest(address(wallet), address(v), data, r.deadline);
        r.signature = abi.encodePacked(_sign(k0, digest), _sign(strangerKey, digest));

        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC2771Forwarder.ERC2771ForwarderInvalidSigner.selector, address(wallet), address(wallet)
            )
        );
        fwd.executeWithFee(r, address(usdc), 1_000000);
    }

    /**
     * `request.from` is now ASSERTED rather than recovered, so SignatureChecker is the only thing
     * binding it to the signature. Against an EOA the ERC-1271 fallback staticcalls an address with no
     * code, which returns empty data and fails the magic-value check — a bad signature must not become
     * a bypass just because the ECDSA branch declined it.
     */
    function test_ERC1271FallbackCannotSpoofACodelessSigner() public {
        bytes memory data = _setManagerCall(makeAddr("mgr"));
        ERC2771Forwarder.ForwardRequestData memory r = ERC2771Forwarder.ForwardRequestData({
            from: alice,
            to: address(vault),
            value: 0,
            gas: 1_000_000,
            deadline: uint48(block.timestamp + 1 days),
            data: data,
            // 130 bytes of nonsense: the wrong length for ECDSA, and alice has no isValidSignature.
            signature: abi.encodePacked(keccak256("a"), keccak256("b"), keccak256("c"), keccak256("d"), uint16(0))
        });

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ERC2771Forwarder.ERC2771ForwarderInvalidSigner.selector, alice, alice));
        fwd.executeWithFee(r, address(vault), 0);
        assertEq(effectiveAssetManager(address(vault)), alice, "asset manager untouched");
    }

    /// The nonce is burned against `request.from`, which is the wallet — so a replay cannot land.
    function test_ERC1271RequestCannotBeReplayed() public {
        (BittyV1Vault v, MockMultisigWallet wallet, uint256 k0, uint256 k1) = _walletOwnedVault();
        ERC2771Forwarder.ForwardRequestData memory r = _walletReq(v, wallet, _setManagerCall(makeAddr("mgr")), k0, k1);

        assertEq(fwd.nonceFor(address(wallet), address(v)), 0);
        vm.prank(relayer);
        fwd.executeWithFee(r, address(usdc), 0);
        assertEq(fwd.nonceFor(address(wallet), address(v)), 1, "nonce consumed against the wallet, not a recovered EOA");

        vm.prank(relayer);
        vm.expectRevert();
        fwd.executeWithFee(r, address(usdc), 0);
    }

    /// The ECDSA path is tried first and must be untouched by any of the above.
    function test_EOAOwnerStillRelaysAfterERC1271Support() public {
        address mgr = makeAddr("mgrEOA");
        ERC2771Forwarder.ForwardRequestData memory r = _req(_setManagerCall(mgr));
        vm.prank(relayer);
        fwd.executeWithFee(r, address(usdc), 1_000000);

        assertEq(effectiveAssetManager(address(vault)), mgr);
    }
}

/**
 * @dev A 2-of-2 contract wallet, standing in for a Safe: its "signature" is its owners' signatures
 *      concatenated, so there is no single address to recover from it.
 */
contract MockMultisigWallet {
    address private immutable _owner0;
    address private immutable _owner1;

    constructor(address owner0_, address owner1_) {
        _owner0 = owner0_;
        _owner1 = owner1_;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        if (signature.length != 130) return 0xffffffff;
        (address r0, ECDSA.RecoverError e0,) = ECDSA.tryRecover(hash, signature[0:65]);
        (address r1, ECDSA.RecoverError e1,) = ECDSA.tryRecover(hash, signature[65:130]);
        if (e0 != ECDSA.RecoverError.NoError || e1 != ECDSA.RecoverError.NoError) return 0xffffffff;
        if (r0 != _owner0 || r1 != _owner1) return 0xffffffff;
        return 0x1626ba7e;
    }
}
