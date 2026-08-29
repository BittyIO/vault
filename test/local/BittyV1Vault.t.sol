// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import "forge-std/console.sol";
import {vaultProtocols} from "../helpers/VaultSets.sol";
import {guardAddAssets, guardAddStableCoins, guardAddProtocols} from "../helpers/GuardRegister.sol";
import {GUARD_DEPLOYER} from "../helpers/GuardDeployer.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {IVaultFull} from "../helpers/IVaultFull.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {IBittyV1PayoutOperator} from "../../src/interfaces/IBittyV1PayoutOperator.sol";
import {
    IBittyV1Vault,
    AddressZero,
    AmountIsZero,
    ArrayLengthMismatch,
    EmptyArray,
    ScheduledPaymentNotFound,
    ScheduledPaymentImmutable,
    ScheduledPaymentPaymentCountZero,
    AssetAddressNotContract,
    ProtectionPeriodNotEnded,
    PaymentProtectionTooLong,
    ScheduledPaymentNotStartYet,
    ScheduledPaymentStartTimestampInPast,
    PayMoreThanScheduledPaymentAmount,
    PayScheduledPaymentAmountTriggerEmpty,
    ScheduledPaymentTriggerError,
    ScheduledPaymentInInterval,
    InsufficientBalance,
    NotInitialized,
    WhitelistedRecipientNotFound,
    WhitelistedRecipientAssetNotAllowed,
    PaymentNotApproved,
    NotPendingApproval,
    NotProposalOwner,
    ScheduledPaymentContentMismatch,
    WhitelistedRecipientContentMismatch,
    PendingSendNotFound,
    NotPayoutOperator,
    OwnerAndPayoutOperatorMustDiffer,
    PaymentExceedsPeriodLimit,
    TransferFailed,
    PaymentExceedsRiskCap,
    PaymentNotStableCoin,
    InvalidAsset,
    PayoutOperatorAlreadyRegistered,
    PayoutOperatorNotFound,
    OwnershipNotRenounceable,
    PendingOwnerIsPayoutOperator,
    ImmutableScheduledPaymentLocked,
    NoRescueTarget,
    OnlyImmutablePayableAfterRenounce,
    RiskSettings,
    AutoYield
} from "../../src/interfaces/IBittyV1Vault.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockERC721} from "solmate/test/utils/mocks/MockERC721.sol";
import {InvalidDepositableProtocol, NotAssetManager, ProtocolNFT} from "../../src/interfaces/IBittyV1AssetManager.sol";
import {IBittyV1AMMProtocol} from "protocol-contracts/src/interfaces/IBittyV1AMMProtocol.sol";
import {MockStakingProtocol} from "../helpers/MockStakingProtocol.sol";
import {MockLendingProtocol} from "../helpers/MockLendingProtocol.sol";
import {MockAMMProtocol} from "../helpers/MockAMMProtocol.sol";
import {BittyV1Guard} from "guard-contracts/src/BittyV1Guard.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";
import {NotRegistered} from "../../src/interfaces/IBittyV1Vault.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {Initializable} from "openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {effectiveAssetManager} from "../helpers/AssetManagerView.sol";

/**
 * @dev On receiving native ETH, tries to reenter payScheduled once (swallowing any revert), to prove
 * a reentering recipient cannot double-pay.
 */
contract ReentrantEthReceiver {
    BittyV1Vault public vault;
    uint256 public scheduledPaymentId;
    bool private armed;

    function arm(BittyV1Vault v, uint256 id) external {
        vault = v;
        scheduledPaymentId = id;
        armed = true;
    }

    receive() external payable {
        if (armed) {
            armed = false;
            try vault.payScheduled(scheduledPaymentId, new address[](0)) {} catch {}
        }
    }
}

/**
 *  @dev Has code but no payable receive/fallback, so a native-ETH transfer to it returns false.
 */
contract RejectEthReceiver {
    function ping() external pure returns (bool) {
        return true;
    }
}

/**
 * @dev AMM protocol reporting a position NFT (like Uniswap V3), for proving retrieve721 refuses
 *      protocol position NFTs. `nft` is immutable so clones report it too.
 */
contract MockAMMWithPositionNFT is MockAMMProtocol {
    address public immutable nft;

    constructor(address nft_) {
        nft = nft_;
    }

    function positionAssetManager() external view returns (address) {
        return nft;
    }
}

/**
 * @dev AMM protocol whose position NFT lives in CLONE storage (set by initialize), while the
 *      template reports address(0) — exercises checkNotProtocolNFT's clone-probe branch, which
 *      only matters when the template's probe and the clone's disagree.
 */
contract MockAMMWithCloneNFT is IBittyV1AMMProtocol {
    // Template storage stays zero; each clone's initialize fills its own copy.
    address public positionAssetManager;
    address public immutable cloneNft;

    constructor(address cloneNft_) {
        cloneNft = cloneNft_;
    }

    function initialize(address) external override {
        positionAssetManager = cloneNft;
    }

    function name() external pure override returns (string memory) {
        return "MockAMMCloneNFT";
    }

    function version() external pure override returns (string memory) {
        return "1.0.0";
    }

    function addLiquidity(bytes memory) external override {}
    function removeLiquidity(bytes memory) external override {}
    function decreaseLiquidity(bytes memory) external override {}
    function claimAMMFees(bytes memory) external override {}

    function getLiquidity(bytes memory) external pure override returns (uint256) {
        return 0;
    }

    /**
     * @dev Declares its category so the guard will register it as an AMM protocol.
     */
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IBittyV1AMMProtocol).interfaceId || interfaceId == 0x01ffc9a7;
    }
}

contract BittyV1VaultTest is Test {
    BittyV1Vault public vault;
    address public defiFacet;
    WETH public weth;
    address public guardAddress;
    address public ownerAddress;
    address public assetManagerAddress;

    function setUp() public {
        weth = new WETH();
        defiFacet = address(new BittyV1VaultDeFiFacet());
        vault = new BittyV1Vault(defiFacet, address(0xA07E1D));
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        deployCodeTo("BittyV1Guard.sol:BittyV1Guard", BITTY_GUARD);
        vm.stopPrank();
        guardAddress = BITTY_GUARD;
        ownerAddress = tx.origin;
        assetManagerAddress = makeAddr("assetManager");
    }

    function _grantAssetManager(address assetManager) internal {
        vm.prank(ownerAddress);
        vault.setAssetManager(assetManager, 0);
    }

    /**
     * @dev The vault expresses ownership through Ownable now, so `role` is vestigial — kept so the
     * call sites still read as "this caller lacks that authority".
     */
    function _roleError(address account, bytes32) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, account);
    }

    function _makeScheduledPayment(
        address scheduledPaymentAddress_,
        address trigger_,
        address assetAddress_,
        uint256 amount_,
        uint256 remainingPaymentCount_,
        uint256 startTimestamp_,
        uint256 paymentInterval_,
        bool isImmutable_
    ) internal pure returns (IBittyV1Vault.ScheduledPayment memory) {
        return IBittyV1Vault.ScheduledPayment({
            recipient: scheduledPaymentAddress_,
            trigger: trigger_,
            assetAddress: assetAddress_,
            amount: amount_,
            remainingPaymentCount: remainingPaymentCount_,
            startTimestamp: startTimestamp_,
            paymentInterval: paymentInterval_,
            isImmutable: isImmutable_,
            payWithInsufficientBalance: false
        });
    }

    function test_Receive_acceptsPlainEthTransfer() public {
        _initializeVault();
        address depositor = makeAddr("ethDepositor");
        uint256 amount = 0.1 ether;

        vm.deal(depositor, amount);
        vm.prank(depositor);
        (bool success, bytes memory returnData) = address(vault).call{value: amount}("");

        assertTrue(success, string(returnData));
        // Held as WETH, not raw ETH — receive() wraps on the way in.
        assertEq(address(vault).balance, 0);
        assertEq(weth.balanceOf(address(vault)), amount);
    }

    /**
     * @dev An UNINITIALIZED vault refuses ETH, and that is fine: only the implementation contract is
     *      ever in that state, since the factory clones and initializes in one transaction. The path
     *      that matters — funding a vault address before it is activated — never reaches this code,
     *      because there is no code there yet.
     */
    function test_Receive_refusedBeforeInitialize() public {
        BittyV1Vault bare = new BittyV1Vault(defiFacet, address(0xA07E1D));
        vm.deal(address(this), 1 ether);
        (bool success,) = address(bare).call{value: 1 ether}("");

        assertFalse(success, "no WETH configured, nothing to wrap into");
        assertEq(address(bare).balance, 0);
    }

    function test_Receive_acceptsEthAfterInitialize() public {
        vault.initialize(ownerAddress, address(weth), address(0), 0);
        _grantAssetManager(assetManagerAddress);

        address depositor = makeAddr("ethDepositor");
        uint256 amount = 0.05 ether;

        vm.deal(depositor, amount);
        vm.prank(depositor);
        (bool success,) = address(vault).call{value: amount}("");

        // Once WETH is configured, receive() auto-wraps: the vault holds WETH, not native ETH.
        assertTrue(success);
        assertEq(address(vault).balance, 0);
        assertEq(weth.balanceOf(address(vault)), amount);
    }

    function test_ETHToWETH_wrapsStrandedNativeEth() public {
        vault.initialize(ownerAddress, address(weth), address(0), 0);

        // Native ETH that landed on the vault before it existed (a pre-deployment
        // deposit to the counterfactual address) — receive() never wrapped it.
        uint256 amount = 0.03 ether;
        vm.deal(address(vault), amount);
        assertEq(weth.balanceOf(address(vault)), 0);

        // Permissionless: anyone can convert the vault's native ETH to WETH.
        vm.prank(makeAddr("keeper"));
        vault.ETHToWETH();

        assertEq(address(vault).balance, 0);
        assertEq(weth.balanceOf(address(vault)), amount);
    }

    function test_ETHToWETH_noopWhenNoNativeEth() public {
        vault.initialize(ownerAddress, address(weth), address(0), 0);

        // Nothing to wrap — must not revert.
        vault.ETHToWETH();
        assertEq(address(vault).balance, 0);
        assertEq(weth.balanceOf(address(vault)), 0);
    }

    function test_InitSucceedsWithDifferentAssetManager() public {
        vault.initialize(ownerAddress, address(weth), address(0), 0);
        _grantAssetManager(assetManagerAddress);
        assertEq(effectiveAssetManager(address(vault)), assetManagerAddress);
    }

    function test_Init_defaultsAssetManagerToOwner() public {
        // Every level defaults the asset manager to the owner (Zero = full access, Standard/High =
        // bounded with the level's trade throttle + invest cap).
        assertEq(effectiveAssetManager(address(_initAtZero())), ownerAddress);
        assertEq(effectiveAssetManager(address(_initAtStandard())), ownerAddress);
        assertEq(effectiveAssetManager(address(_initAtHigh())), ownerAddress);
    }

    function test_OwnerMayBeAddedAsAssetManager() public {
        _initializeVault();
        vm.prank(ownerAddress);
        vault.setAssetManager(ownerAddress, 0);
        assertEq(effectiveAssetManager(address(vault)), ownerAddress);
        assertTrue(vault.owner() == ownerAddress);
    }

    function test_SetPayoutOperatorRevertsWhenOwner() public {
        _initializeVault();
        vm.prank(ownerAddress);
        vm.expectRevert(OwnerAndPayoutOperatorMustDiffer.selector);
        vault.updatePayoutOperator(ownerAddress, true);
    }

    function test_AssetManagerMayAlsoBePayoutOperator() public {
        _initializeVault();
        address mgr = makeAddr("mgr");
        vm.startPrank(ownerAddress);
        vault.setAssetManager(mgr, 0);
        vault.updatePayoutOperator(mgr, true);
        vm.stopPrank();
        assertEq(effectiveAssetManager(address(vault)), mgr);
        assertTrue(vault.isPayoutOperator(mgr));
    }

    // One call reads several whitelisted recipients; one call pays several scheduled payments.
    function test_arrayGetters_getWhitelistedRecipients_and_payScheduled_batch() public {
        _initializeVault();
        MockERC20 usdc = _addStableCoin(6);
        usdc.mint(address(vault), 1_000e6);
        address a = makeAddr("wlA");
        address b = makeAddr("wlB");

        vm.startPrank(ownerAddress);
        uint256 idA = _addWhitelistedRecipient(a, address(weth));
        uint256 idB = _addWhitelistedRecipient(b, address(usdc));
        vm.stopPrank();

        // Batched read returns entries in order.
        uint256[] memory wlIds = new uint256[](2);
        wlIds[0] = idA;
        wlIds[1] = idB;
        (address[] memory recips, address[] memory assetsOut) = vault.getWhitelistedRecipients(wlIds);
        assertEq(recips[0], a);
        assertEq(recips[1], b);
        assertEq(assetsOut[0], address(weth));
        assertEq(assetsOut[1], address(usdc));

        // Two owner-created (auto-approved) scheduled payments paid in one payScheduled call.
        address p1 = makeAddr("p1");
        address p2 = makeAddr("p2");
        vm.startPrank(ownerAddress);
        uint256 s1 = _addScheduledPayment(
            _makeScheduledPayment(p1, address(0), address(usdc), 100e6, 1, block.timestamp, 0, false)
        );
        uint256 s2 = _addScheduledPayment(
            _makeScheduledPayment(p2, address(0), address(usdc), 250e6, 1, block.timestamp, 0, false)
        );
        vm.stopPrank();
        vm.warp(block.timestamp + 3 days + 1);

        uint256[] memory payIds = new uint256[](2);
        payIds[0] = s1;
        payIds[1] = s2;
        _payScheduled(payIds);
        assertEq(usdc.balanceOf(p1), 100e6);
        assertEq(usdc.balanceOf(p2), 250e6);
    }

    // One owner call approves one operator-proposed scheduled payment and rejects (removes) another.
    function test_reviewScheduledPayments_approvesAndCancelsInOneCall() public {
        _initializeVault();
        address op = makeAddr("op");
        _addPayoutOperator(op);
        address keep = makeAddr("keep");
        address reject = makeAddr("reject");

        vm.prank(op);
        uint256 keepId = _addScheduledPayment(_spTo(keep)); // pending proposal
        vm.prank(op);
        uint256 rejectId = _addScheduledPayment(_spTo(reject)); // pending proposal

        // Approve keepId (bound to reviewed content), reject rejectId, in one call.
        vm.prank(ownerAddress);
        vault.reviewScheduledPayments(_oneU(keepId), _oneB(_spHash(_spTo(keep))), _oneU(rejectId));

        // keepId is now approved (no pending proposer) and payable; rejectId is gone.
        deal(address(weth), address(vault), 1 ether);
        vm.warp(block.timestamp + 3 days + 1);
        _payScheduled(_oneU(keepId));
        assertEq(weth.balanceOf(keep), 1 ether);

        vm.expectRevert(ScheduledPaymentNotFound.selector);
        _payScheduled(_oneU(rejectId));
    }

    // Same merged approve+reject for whitelisted recipient proposals.
    function test_reviewWhitelistedRecipients_approvesAndCancelsInOneCall() public {
        _initializeVault();
        address op = makeAddr("op");
        _addPayoutOperator(op);
        address keep = makeAddr("keep");
        address reject = makeAddr("reject");

        vm.prank(op);
        uint256 keepId = _addWhitelistedRecipient(keep, address(weth));
        vm.prank(op);
        uint256 rejectId = _addWhitelistedRecipient(reject, address(weth));

        vm.prank(ownerAddress);
        vault.reviewWhitelistedRecipients(_oneU(keepId), _oneB(_wrHash(keep, address(weth))), _oneU(rejectId));

        // keepId approved; rejectId removed.
        deal(address(weth), address(vault), 1 ether);
        vm.warp(block.timestamp + 3 days + 1);
        vm.prank(ownerAddress);
        _sendWl(keepId, address(weth), 1 ether);
        assertEq(weth.balanceOf(keep), 1 ether);

        (address r,) = _getWlOne(rejectId);
        assertEq(r, address(0));
    }

    function test_reviewSends_batchApprovesMultipleInOneCall() public {
        _initializeVault();
        MockERC20 usdc = _addStableCoin(6);
        usdc.mint(address(vault), 2_000e6);
        address op = makeAddr("op");
        _addPayoutOperator(op);
        address payee = makeAddr("payee");

        vm.prank(op);
        _send(payee, address(usdc), 400e6);
        vm.prank(op);
        _send(payee, address(usdc), 200e6);

        // One call approves both proposals.
        uint256[] memory ids = new uint256[](2);
        ids[0] = 0;
        ids[1] = 1;
        vm.prank(ownerAddress);
        vault.reviewSends(ids, new uint256[](0));

        assertEq(usdc.balanceOf(payee), 600e6);
    }

    function test_reviewSends_approvesAndCancelsInOneCall() public {
        _initializeVault();
        MockERC20 usdc = _addStableCoin(6);
        usdc.mint(address(vault), 2_000e6);
        address op = makeAddr("op");
        _addPayoutOperator(op);
        address payee = makeAddr("payee");

        vm.prank(op);
        _send(payee, address(usdc), 400e6); // id 0 -> approve
        vm.prank(op);
        _send(payee, address(usdc), 200e6); // id 1 -> cancel

        vm.prank(ownerAddress);
        vault.reviewSends(_oneU(0), _oneU(1));

        // Only the approved proposal paid out; the cancelled one is gone.
        assertEq(usdc.balanceOf(payee), 400e6);
        vm.expectRevert();
        vm.prank(ownerAddress);
        vault.reviewSends(_oneU(1), new uint256[](0));
    }

    function test_cancelSends_operatorCancelsOwnBatch() public {
        _initializeVault();
        MockERC20 usdc = _addStableCoin(6);
        usdc.mint(address(vault), 2_000e6);
        address op = makeAddr("op");
        _addPayoutOperator(op);
        address payee = makeAddr("payee");

        vm.prank(op);
        _send(payee, address(usdc), 400e6);
        vm.prank(op);
        _send(payee, address(usdc), 200e6);

        uint256[] memory ids = new uint256[](2);
        ids[0] = 0;
        ids[1] = 1;
        vm.prank(op);
        vault.cancelSends(ids);

        // Both proposals cancelled: nothing left for the owner to approve.
        vm.expectRevert();
        vm.prank(ownerAddress);
        vault.reviewSends(_oneU(0), new uint256[](0));
    }

    function test_MultiplePayoutOperators_bothCanProposeSends() public {
        _initializeVault();
        MockERC20 usdc = _addStableCoin(6);
        usdc.mint(address(vault), 2_000e6);
        address op1 = makeAddr("op1");
        address op2 = makeAddr("op2");
        _addPayoutOperator(op1);
        _addPayoutOperator(op2);

        address payee = makeAddr("payee");
        vm.prank(op1);
        _send(payee, address(usdc), 400e6);
        vm.prank(ownerAddress);
        _approveSend(0);

        vm.prank(op2);
        _send(payee, address(usdc), 200e6);
        vm.prank(ownerAddress);
        _approveSend(1);

        assertEq(usdc.balanceOf(payee), 600e6);
    }

    function test_addPayoutOperator_revertsWhenAlreadyRegistered() public {
        _initializeVault();
        address op = makeAddr("op");
        _addPayoutOperator(op);
        vm.prank(ownerAddress);
        vm.expectRevert(PayoutOperatorAlreadyRegistered.selector);
        vault.updatePayoutOperator(op, true);
    }

    function test_removePayoutOperator() public {
        _initializeVault();
        address op = makeAddr("op");
        _addPayoutOperator(op);
        assertTrue(vault.isPayoutOperator(op));

        vm.prank(ownerAddress);
        vault.updatePayoutOperator(op, false);
        assertFalse(vault.isPayoutOperator(op));

        vm.prank(ownerAddress);
        vm.expectRevert(PayoutOperatorNotFound.selector);
        vault.updatePayoutOperator(op, false);
    }

    function test_updatePayoutOperator_addAndRemoveAcrossCalls() public {
        _initializeVault();
        address op1 = makeAddr("op1");
        address op2 = makeAddr("op2");
        address op3 = makeAddr("op3");

        vm.startPrank(ownerAddress);
        vault.updatePayoutOperator(op1, true);
        vault.updatePayoutOperator(op2, true);
        assertTrue(vault.isPayoutOperator(op1) && vault.isPayoutOperator(op2), "both registered");

        vault.updatePayoutOperator(op3, true);
        vault.updatePayoutOperator(op1, false);
        vm.stopPrank();

        assertFalse(vault.isPayoutOperator(op1));
        assertTrue(vault.isPayoutOperator(op2));
        assertTrue(vault.isPayoutOperator(op3));
    }

    /**
     * @dev The list getter is gone - PayoutOperatorUpdated carries changes - so this asserts the
     * thing the list was standing in for: each operator is registered, and a stranger is not.
     */
    function test_payoutOperatorMembership() public {
        _initializeVault();
        address op1 = makeAddr("op1");
        address op2 = makeAddr("op2");
        _addPayoutOperator(op1);
        _addPayoutOperator(op2);
        assertTrue(vault.isPayoutOperator(op1));
        assertTrue(vault.isPayoutOperator(op2));
        assertFalse(vault.isPayoutOperator(makeAddr("stranger")));
    }

    function test_InitErrorWithAlreadyInitialized() public {
        vault.initialize(ownerAddress, address(weth), address(0), 0);
        _grantAssetManager(assetManagerAddress);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(ownerAddress, address(weth), address(0), 0);
    }

    function test_AddScheduledPaymentSuccess() public {
        vault.initialize(ownerAddress, address(weth), address(0), 0);
        _grantAssetManager(assetManagerAddress);
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            scheduledPaymentAddr, address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, false
        );
        vm.prank(ownerAddress);
        uint256 aliceId = _addScheduledPayment(r);
    }

    function test_AddScheduledPaymentSuccessSameNameAfterRemoveScheduledPayment() public {
        vault.initialize(ownerAddress, address(weth), address(0), 0);
        _grantAssetManager(assetManagerAddress);
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            makeAddr("scheduledPayment"), address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, false
        );
        vm.startPrank(ownerAddress);
        uint256 aliceId = _addScheduledPayment(r);
        _removeScheduledPayment(aliceId);
        aliceId = _addScheduledPayment(r);
        vm.stopPrank();
    }

    function test_AddScheduledPaymentRevertUnauthorized() public {
        vault.initialize(ownerAddress, address(weth), address(0), 0);
        _grantAssetManager(assetManagerAddress);
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            makeAddr("scheduledPayment"), address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, false
        );
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(NotPayoutOperator.selector);
        _addScheduledPayment(r);
    }

    function test_AddScheduledPaymentRevertAssetAddressNotContract() public {
        vault.initialize(ownerAddress, address(weth), address(0), 0);
        _grantAssetManager(assetManagerAddress);
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            makeAddr("scheduledPayment"), address(0), makeAddr("eoaAsset"), 1 ether, 1, block.timestamp, 0, false
        );
        vm.prank(ownerAddress);
        vm.expectRevert(AssetAddressNotContract.selector);
        uint256 aliceId = _addScheduledPayment(r);
    }

    function test_AddScheduledPaymentRevertAmountZero() public {
        vault.initialize(ownerAddress, address(weth), address(0), 0);
        _grantAssetManager(assetManagerAddress);
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            makeAddr("scheduledPayment"), address(0), address(weth), 0, 1, block.timestamp, 0, false
        );
        vm.prank(ownerAddress);
        vm.expectRevert(AmountIsZero.selector);
        uint256 aliceId = _addScheduledPayment(r);
    }

    function test_AddScheduledPaymentRevertZeroPayee() public {
        vault.initialize(ownerAddress, address(weth), address(0), 0);
        _grantAssetManager(assetManagerAddress);
        IBittyV1Vault.ScheduledPayment memory r =
            _makeScheduledPayment(address(0), address(0), address(weth), 1 ether, 1, block.timestamp, 0, false);
        vm.prank(ownerAddress);
        vm.expectRevert(AddressZero.selector);
        _addScheduledPayment(r);
    }

    function test_AddScheduledPaymentRevertPaymentCountZero() public {
        vault.initialize(ownerAddress, address(weth), address(0), 0);
        _grantAssetManager(assetManagerAddress);
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            makeAddr("scheduledPayment"), address(0), address(weth), 1 ether, 0, block.timestamp, 0, false
        );
        vm.prank(ownerAddress);
        vm.expectRevert(ScheduledPaymentPaymentCountZero.selector);
        uint256 aliceId = _addScheduledPayment(r);
    }

    function test_AddScheduledPaymentRevertStartTimestampInPast() public {
        _initializeVault();
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            makeAddr("scheduledPayment"), address(0), address(weth), 1 ether, 1, block.timestamp - 1, 1 days, false
        );
        vm.prank(ownerAddress);
        vm.expectRevert(ScheduledPaymentStartTimestampInPast.selector);
        uint256 aliceId = _addScheduledPayment(r);
    }

    function test_UpdateScheduledPaymentRevertStartTimestampInPast() public {
        _initializeVault();
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            makeAddr("scheduledPayment"), address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, false
        );
        vm.prank(ownerAddress);
        uint256 aliceId = _addScheduledPayment(r);

        r.startTimestamp = block.timestamp - 1;
        vm.prank(ownerAddress);
        vm.expectRevert(ScheduledPaymentStartTimestampInPast.selector);
        _updateScheduledPayment(aliceId, r);
    }

    function test_AddScheduledPaymentSuccessWithShortIntervalWhenPaymentCountIsOne() public {
        vault.initialize(ownerAddress, address(weth), address(0), 0);
        _grantAssetManager(assetManagerAddress);
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            makeAddr("scheduledPayment"), address(0), address(weth), 1 ether, 1, block.timestamp, 0, false
        );
        vm.prank(ownerAddress);
        uint256 aliceId = _addScheduledPayment(r);
    }

    function test_UpdateScheduledPaymentSuccessWithShortIntervalWhenPaymentCountIsOne() public {
        vault.initialize(ownerAddress, address(weth), address(0), 0);
        _grantAssetManager(assetManagerAddress);
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            makeAddr("scheduledPayment"), address(0), address(weth), 1 ether, 2, block.timestamp, 7 days, false
        );
        vm.prank(ownerAddress);
        uint256 aliceId = _addScheduledPayment(r);

        r.remainingPaymentCount = 1;
        r.paymentInterval = 0;
        vm.prank(ownerAddress);
        _updateScheduledPayment(aliceId, r);
    }

    function test_UpdateScheduledPaymentSuccess() public {
        vault.initialize(ownerAddress, address(weth), address(0), 0);
        _grantAssetManager(assetManagerAddress);
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            scheduledPaymentAddr, address(0), address(weth), 1 ether, 2, block.timestamp, 7 days, false
        );
        vm.startPrank(ownerAddress);
        uint256 aliceId = _addScheduledPayment(r);
        r.amount = 2 ether;
        _updateScheduledPayment(aliceId, r);
        vm.stopPrank();
    }

    function test_UpdateScheduledPaymentRevertNotFound() public {
        vault.initialize(ownerAddress, address(weth), address(0), 0);
        _grantAssetManager(assetManagerAddress);
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            makeAddr("scheduledPayment"), address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, false
        );
        vm.prank(ownerAddress);
        vm.expectRevert(ScheduledPaymentNotFound.selector);
        _updateScheduledPayment(99999, r);
    }

    function test_UpdateScheduledPaymentRevertImmutable() public {
        vault.initialize(ownerAddress, address(weth), address(0), 0);
        _grantAssetManager(assetManagerAddress);
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            makeAddr("scheduledPayment"), address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, true
        );
        vm.startPrank(ownerAddress);
        uint256 aliceId = _addScheduledPayment(r);
        r.amount = 2 ether;
        vm.expectRevert(ScheduledPaymentImmutable.selector);
        _updateScheduledPayment(aliceId, r);
        vm.stopPrank();
    }

    function test_UpdateScheduledPaymentRevertOnlyOwner() public {
        vault.initialize(ownerAddress, address(weth), address(0), 0);
        _grantAssetManager(assetManagerAddress);
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            makeAddr("scheduledPayment"), address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, false
        );
        vm.prank(ownerAddress);
        uint256 aliceId = _addScheduledPayment(r);
        r.amount = 2 ether;
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(NotPayoutOperator.selector);
        _updateScheduledPayment(aliceId, r);
    }

    function test_RemoveScheduledPaymentSuccess() public {
        vault.initialize(ownerAddress, address(weth), address(0), 0);
        _grantAssetManager(assetManagerAddress);
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            makeAddr("scheduledPayment"), address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, false
        );
        vm.startPrank(ownerAddress);
        uint256 aliceId = _addScheduledPayment(r);
        _removeScheduledPayment(aliceId);
        vm.stopPrank();
        vm.expectRevert(ScheduledPaymentNotFound.selector);
        _payScheduled(_oneU(aliceId));
    }

    function test_RemoveScheduledPaymentRevertOnlyOwner() public {
        vault.initialize(ownerAddress, address(weth), address(0), 0);
        _grantAssetManager(assetManagerAddress);
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            makeAddr("scheduledPayment"), address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, false
        );
        vm.prank(ownerAddress);
        uint256 aliceId = _addScheduledPayment(r);
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(NotPayoutOperator.selector);
        _removeScheduledPayment(aliceId);
    }

    function test_PayScheduledPayment_revertScheduledPaymentNotStartYet() public {
        vault.initialize(ownerAddress, address(weth), address(0), 0);
        _grantAssetManager(assetManagerAddress);
        uint256 futureStartTimestamp = block.timestamp + 100;
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            makeAddr("scheduledPayment"), address(0), address(weth), 1 ether, 1, futureStartTimestamp, 1 days, false
        );
        vm.prank(ownerAddress);
        uint256 aliceId = _addScheduledPayment(r);

        vm.expectRevert(ScheduledPaymentNotStartYet.selector);
        _payScheduled(_oneU(aliceId));
    }

    function test_PayScheduledPayment_singlePaymentWithZeroInterval() public {
        vault.initialize(ownerAddress, address(weth), address(0), 0);
        _grantAssetManager(assetManagerAddress);
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            scheduledPaymentAddr, address(0), address(weth), 1 ether, 1, block.timestamp, 0, false
        );
        vm.prank(ownerAddress);
        uint256 aliceId = _addScheduledPayment(r);

        deal(address(weth), address(vault), 1 ether);

        _payScheduled(_oneU(aliceId));
        assertEq(weth.balanceOf(scheduledPaymentAddr), 1 ether);

        vm.expectRevert(ScheduledPaymentPaymentCountZero.selector);
        _payScheduled(_oneU(aliceId));
    }

    function test_PayScheduledPayment_scheduledPaymentStorageUpdatedSoPaymentCountEnforced() public {
        vault.initialize(ownerAddress, address(weth), address(0), 0);
        _grantAssetManager(assetManagerAddress);
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        vm.warp(1000);
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            scheduledPaymentAddr, address(0), address(weth), 1 ether, 2, block.timestamp, 7 days, false
        );
        vm.prank(ownerAddress);
        uint256 aliceId = _addScheduledPayment(r);

        deal(address(weth), address(vault), 2 ether);

        _payScheduled(_oneU(aliceId));
        vm.warp(block.timestamp + 7 days);
        _payScheduled(_oneU(aliceId));

        assertEq(weth.balanceOf(scheduledPaymentAddr), 2 ether, "scheduledPayment should have received 2 payments");

        vm.expectRevert(ScheduledPaymentPaymentCountZero.selector);
        _payScheduled(_oneU(aliceId));
    }

    function test_PayScheduled_revertWhenPaidWithinInterval() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        vm.warp(1000);
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            scheduledPaymentAddr, address(0), address(weth), 1 ether, 2, block.timestamp, 7 days, false
        );
        vm.prank(ownerAddress);
        uint256 aliceId = _addScheduledPayment(r);
        deal(address(weth), address(vault), 2 ether);

        _payScheduled(_oneU(aliceId));
        // Second payout before the interval elapses is rejected.
        vm.expectRevert(ScheduledPaymentInInterval.selector);
        _payScheduled(_oneU(aliceId));
    }

    function test_UpdateScheduledPayment_ownerMakesImmutable() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            scheduledPaymentAddr, address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, false
        );
        vm.prank(ownerAddress);
        uint256 aliceId = _addScheduledPayment(r);

        IBittyV1Vault.ScheduledPayment memory immutableR = _makeScheduledPayment(
            scheduledPaymentAddr, address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, true
        );
        vm.prank(ownerAddress);
        _updateScheduledPayment(aliceId, immutableR);
    }

    function test_SetScheduledPaymentProtectionRevertUnauthorizedWhenNotInitialized() public {
        vm.expectRevert(); // no roles granted before initialize, AccessControl fires first
        _setNewPaymentProtection(1 days);
    }

    function test_SetScheduledPaymentProtectionRevertUnauthorized() public {
        _initializeVault();
        bytes32 _adminRole = bytes32(0);
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(_roleError(stranger, _adminRole));
        _setNewPaymentProtection(1 days);
    }

    function test_SetScheduledPaymentProtection_RaisingIsImmediate() public {
        _initializeVault();
        vm.startPrank(ownerAddress);
        _setNewPaymentProtection(2 days);
        _setNewPaymentProtection(5 days); // raising (tightening) applies immediately
        vm.stopPrank();
        (uint64 nap,,,) = vault.getRiskConfig();
        assertEq(nap, 5 days);
    }

    function test_SetScheduledPaymentProtection_capsAtTenYears() public {
        _initializeVault();
        vm.startPrank(ownerAddress);
        _setNewPaymentProtection(3650 days); // at the cap is allowed
        (uint64 sched,,,) = vault.getRiskConfig();
        assertEq(sched, 3650 days);
        // Above the cap reverts, so the recurring-payment path can never be permanently locked out.
        vm.expectRevert(PaymentProtectionTooLong.selector);
        _setNewPaymentProtection(3650 days + 1);
        vm.stopPrank();
    }

    function test_Risk_LoweringScheduledPaymentProtection_DelayedByTimelock() public {
        BittyV1Vault v = _initAtStandard();
        (uint64 nap0,, uint64 tl,) = v.getRiskConfig();
        vm.prank(ownerAddress);
        _setNewPaymentProtectionOn(v, 1 hours); // loosening
        (uint64 napNow,,,) = v.getRiskConfig();
        assertEq(napNow, nap0); // unchanged until the timelock elapses
        vm.warp(block.timestamp + tl);
        (uint64 napAfter,,,) = v.getRiskConfig();
        assertEq(napAfter, 1 hours);
    }

    function test_Risk_Cap_TighteningImmediate_LooseningDelayed() public {
        BittyV1Vault v = _initAtStandard();
        (, uint64 send0, uint64 tl,) = v.getRiskConfig();
        vm.prank(ownerAddress);
        _setMaxSendValueOn(v, send0 - 1); // tighten (lower cap) -> immediate
        (, uint64 sendTight,,) = v.getRiskConfig();
        assertEq(sendTight, send0 - 1);

        vm.prank(ownerAddress);
        _setMaxSendValueOn(v, send0 + 1_000); // loosen (raise cap) -> delayed
        (, uint64 sendNow,,) = v.getRiskConfig();
        assertEq(sendNow, send0 - 1);
        vm.warp(block.timestamp + tl);
        (, uint64 sendAfter,,) = v.getRiskConfig();
        assertEq(sendAfter, send0 + 1_000);
    }

    function test_Risk_Cap_ClearingToZeroIsLooseningDelayed() public {
        BittyV1Vault v = _initAtStandard();
        (, uint64 send0, uint64 tl,) = v.getRiskConfig();
        vm.prank(ownerAddress);
        _setMaxSendValueOn(v, 0); // removing the restriction = loosening
        (, uint64 sendNow,,) = v.getRiskConfig();
        assertEq(sendNow, send0); // still restricted until the timelock elapses
        vm.warp(block.timestamp + tl);
        (, uint64 sendAfter,,) = v.getRiskConfig();
        assertEq(sendAfter, 0);
    }

    function test_Risk_ChangeTimelock_LoweringDelayedByItself_RaisingImmediate() public {
        BittyV1Vault v = _initAtHigh();
        (,, uint64 tl0,) = v.getRiskConfig();

        vm.prank(ownerAddress);
        _setChangeTimelockOn(v, tl0 + 10 days); // raising is immediate
        (,, uint64 tlRaised,) = v.getRiskConfig();
        assertEq(tlRaised, tl0 + 10 days);

        vm.prank(ownerAddress);
        _setChangeTimelockOn(v, 1 hours); // lowering waits the CURRENT (raised) timelock
        (,, uint64 tlNow,) = v.getRiskConfig();
        assertEq(tlNow, tl0 + 10 days);
        vm.warp(block.timestamp + tl0 + 10 days);
        (,, uint64 tlAfter,) = v.getRiskConfig();
        assertEq(tlAfter, 1 hours);
    }

    function test_PayScheduledPayment_revertProtectionPeriodNotEnded() public {
        _initializeVault();
        uint256 protection = 3 days;
        vm.prank(ownerAddress);
        _setNewPaymentProtection(protection);

        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            scheduledPaymentAddr, address(0), address(weth), 1 ether, 1, block.timestamp, 0, false
        );
        vm.prank(ownerAddress);
        uint256 aliceId = _addScheduledPayment(r);

        deal(address(weth), address(vault), 1 ether);

        vm.expectRevert(ProtectionPeriodNotEnded.selector);
        _payScheduled(_oneU(aliceId));
    }

    function test_PayScheduledPayment_successAfterScheduledPaymentProtectionEnds() public {
        _initializeVault();
        uint256 protection = 3 days;
        vm.prank(ownerAddress);
        _setNewPaymentProtection(protection);

        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        uint256 addedAt = block.timestamp;
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            scheduledPaymentAddr, address(0), address(weth), 1 ether, 1, block.timestamp, 0, false
        );
        vm.prank(ownerAddress);
        uint256 aliceId = _addScheduledPayment(r);

        deal(address(weth), address(vault), 1 ether);

        vm.warp(addedAt + protection);
        _payScheduled(_oneU(aliceId));
        assertEq(weth.balanceOf(scheduledPaymentAddr), 1 ether);
    }

    function test_PayScheduledPayment_noProtectionWhenProtectionIsZero() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            scheduledPaymentAddr, address(0), address(weth), 1 ether, 1, block.timestamp, 0, false
        );
        vm.prank(ownerAddress);
        uint256 aliceId = _addScheduledPayment(r);

        deal(address(weth), address(vault), 1 ether);

        _payScheduled(_oneU(aliceId));
        assertEq(weth.balanceOf(scheduledPaymentAddr), 1 ether);
    }

    function test_PayScheduledPayment_protectionOnlyAppliesToScheduledPaymentsAddedWhileEnabled() public {
        _initializeVault();
        address aliceScheduledPayment = makeAddr("aliceScheduledPayment");
        address bobScheduledPayment = makeAddr("bobScheduledPayment");

        // bob is added before protection is ever enabled (default-0, opt-in), so it is unprotected.
        IBittyV1Vault.ScheduledPayment memory bob = _makeScheduledPayment(
            bobScheduledPayment, address(0), address(weth), 1 ether, 1, block.timestamp, 0, false
        );
        vm.prank(ownerAddress);
        uint256 bobId = _addScheduledPayment(bob);

        // Enabling protection only time-locks addresses introduced from now on.
        vm.prank(ownerAddress);
        _setNewPaymentProtection(2 days);

        IBittyV1Vault.ScheduledPayment memory alice = _makeScheduledPayment(
            aliceScheduledPayment, address(0), address(weth), 1 ether, 1, block.timestamp, 0, false
        );
        vm.prank(ownerAddress);
        uint256 aliceId = _addScheduledPayment(alice);

        deal(address(weth), address(vault), 2 ether);

        vm.expectRevert(ProtectionPeriodNotEnded.selector);
        _payScheduled(_oneU(aliceId));

        _payScheduled(_oneU(bobId));
        assertEq(weth.balanceOf(bobScheduledPayment), 1 ether);
    }

    function test_RemoveScheduledPayment_clearsProtectionSoReAddCanPayAfterProtection() public {
        _initializeVault();
        uint256 protection = 1 days;
        address scheduledPaymentAddr = makeAddr("scheduledPayment");

        vm.prank(ownerAddress);
        _setNewPaymentProtection(protection);

        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            scheduledPaymentAddr, address(0), address(weth), 1 ether, 1, block.timestamp, 0, false
        );
        vm.startPrank(ownerAddress);
        uint256 aliceId = _addScheduledPayment(r);
        _removeScheduledPayment(aliceId);
        aliceId = _addScheduledPayment(r);
        vm.stopPrank();

        deal(address(weth), address(vault), 1 ether);

        vm.expectRevert(ProtectionPeriodNotEnded.selector);
        _payScheduled(_oneU(aliceId));

        vm.warp(block.timestamp + protection);
        _payScheduled(_oneU(aliceId));
        assertEq(weth.balanceOf(scheduledPaymentAddr), 1 ether);
    }

    function test_RemoveScheduledPayment_clearsLastReceiveTimestampSoReAddCanPayImmediately() public {
        _initializeVault();
        vm.warp(1_000_000);
        address scheduledPaymentAddr = makeAddr("scheduledPayment");

        uint256 aliceId = _addScheduledPayment(scheduledPaymentAddr, 1 ether, 2, 7 days);
        deal(address(weth), address(vault), 3 ether);
        _payScheduled(_oneU(aliceId));
        assertEq(weth.balanceOf(scheduledPaymentAddr), 1 ether);

        vm.prank(ownerAddress);
        _removeScheduledPayment(aliceId);
        aliceId = _addScheduledPayment(scheduledPaymentAddr, 1 ether, 1, 7 days);

        _payScheduled(_oneU(aliceId));
        assertEq(weth.balanceOf(scheduledPaymentAddr), 2 ether, "re-added scheduledPayment must be payable immediately");
    }

    function test_PayScheduledPayment_revertNotInitialized() public {
        vm.expectRevert(NotInitialized.selector);
        _payScheduled(_oneU(1));
    }

    function test_PayScheduledPaymentAmount_revertNotInitialized() public {
        vm.expectRevert(NotInitialized.selector);
        vault.payScheduledAmount(1, 1);
    }

    function test_PayScheduledPaymentAmount_revertTriggerEmpty() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        uint256 aliceId = _addScheduledPayment(scheduledPaymentAddr, 1 ether, 1, 0);

        deal(address(weth), address(vault), 1 ether);

        vm.expectRevert(PayScheduledPaymentAmountTriggerEmpty.selector);
        vault.payScheduledAmount(aliceId, 1 ether);
    }

    function test_PayScheduledPaymentAmount_revertWhenCallerIsNotTrigger() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        address trigger = makeAddr("trigger");
        address attacker = makeAddr("attacker");
        uint256 aliceId = _addScheduledPaymentWithTrigger(scheduledPaymentAddr, trigger, 1 ether, 1, 0);

        deal(address(weth), address(vault), 1 ether);

        vm.prank(attacker);
        vm.expectRevert(ScheduledPaymentTriggerError.selector);
        vault.payScheduledAmount(aliceId, 1 ether);

        assertEq(weth.balanceOf(scheduledPaymentAddr), 0);

        vm.prank(trigger);
        vault.payScheduledAmount(aliceId, 1 ether);
        assertEq(weth.balanceOf(scheduledPaymentAddr), 1 ether);
    }

    function test_PayScheduled_revertWhenCallerIsNotTrigger() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        address trigger = makeAddr("trigger");
        address attacker = makeAddr("attacker");
        uint256 aliceId = _addScheduledPaymentWithTrigger(scheduledPaymentAddr, trigger, 1 ether, 1, 0);

        deal(address(weth), address(vault), 1 ether);

        vm.prank(attacker);
        vm.expectRevert(ScheduledPaymentTriggerError.selector);
        _payScheduled(_oneU(aliceId));

        vm.prank(trigger);
        _payScheduled(_oneU(aliceId));
        assertEq(weth.balanceOf(scheduledPaymentAddr), 1 ether);
    }

    function test_PayScheduledPaymentAmount_successWhenAmountEqualsScheduledPaymentAmount() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        address trigger = makeAddr("trigger");
        uint256 aliceId = _addScheduledPaymentWithTrigger(scheduledPaymentAddr, trigger, 1 ether, 1, 0);

        deal(address(weth), address(vault), 1 ether);

        vm.prank(trigger);
        vault.payScheduledAmount(aliceId, 1 ether);
        assertEq(weth.balanceOf(scheduledPaymentAddr), 1 ether);

        vm.prank(trigger);
        vm.expectRevert(ScheduledPaymentPaymentCountZero.selector);
        vault.payScheduledAmount(aliceId, 1 ether);
    }

    function test_PayScheduledPaymentAmount_successWhenAmountLessThanScheduledPaymentAmount() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        address trigger = makeAddr("trigger");
        uint256 aliceId = _addScheduledPaymentWithTrigger(scheduledPaymentAddr, trigger, 1 ether, 1, 0);

        deal(address(weth), address(vault), 1 ether);

        vm.prank(trigger);
        vault.payScheduledAmount(aliceId, 0.5 ether);

        assertEq(weth.balanceOf(scheduledPaymentAddr), 0.5 ether, "transfers requested partial amount");
        assertEq(weth.balanceOf(address(vault)), 0.5 ether, "vault retains the remainder");
    }

    function test_PayScheduledPaymentAmount_partialAmountEmitsPaidAmount() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        address trigger = makeAddr("trigger");
        uint256 aliceId = _addScheduledPaymentWithTrigger(scheduledPaymentAddr, trigger, 1 ether, 1, 0);

        deal(address(weth), address(vault), 1 ether);

        vm.prank(trigger);
        vm.expectEmit(true, false, false, true, address(vault));
        emit IBittyV1Vault.ScheduledPaymentPaid(aliceId, scheduledPaymentAddr, address(weth), 0.25 ether, 0);
        vault.payScheduledAmount(aliceId, 0.25 ether);

        assertEq(weth.balanceOf(scheduledPaymentAddr), 0.25 ether);
    }

    function test_PayScheduledPaymentAmount_revertPayMoreThanScheduledPaymentAmount() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        address trigger = makeAddr("trigger");
        uint256 aliceId = _addScheduledPaymentWithTrigger(scheduledPaymentAddr, trigger, 1 ether, 1, 0);

        deal(address(weth), address(vault), 1 ether);

        vm.prank(trigger);
        vm.expectRevert(PayMoreThanScheduledPaymentAmount.selector);
        vault.payScheduledAmount(aliceId, 1 ether + 1);
    }

    function test_PayScheduledPaymentAmount_revertScheduledPaymentNotStartYet() public {
        _initializeVault();
        uint256 futureStart = block.timestamp + 100;
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        address trigger = makeAddr("trigger");
        IBittyV1Vault.ScheduledPayment memory r =
            _makeScheduledPayment(scheduledPaymentAddr, trigger, address(weth), 1 ether, 1, futureStart, 0, false);
        vm.prank(ownerAddress);
        uint256 aliceId = _addScheduledPayment(r);

        deal(address(weth), address(vault), 1 ether);

        vm.prank(trigger);
        vm.expectRevert(ScheduledPaymentNotStartYet.selector);
        vault.payScheduledAmount(aliceId, 1 ether);
    }

    function test_PayScheduledPaymentAmount_revertProtectionPeriodNotEnded() public {
        _initializeVault();
        vm.prank(ownerAddress);
        _setNewPaymentProtection(2 days);

        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        address trigger = makeAddr("trigger");
        uint256 aliceId = _addScheduledPaymentWithTrigger(scheduledPaymentAddr, trigger, 1 ether, 1, 0);

        deal(address(weth), address(vault), 1 ether);

        vm.prank(trigger);
        vm.expectRevert(ProtectionPeriodNotEnded.selector);
        vault.payScheduledAmount(aliceId, 1 ether);
    }

    function test_PayScheduledPaymentAmount_revertInsufficientBalance() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        address trigger = makeAddr("trigger");
        uint256 aliceId = _addScheduledPaymentWithTrigger(scheduledPaymentAddr, trigger, 1 ether, 1, 0);

        deal(address(weth), address(vault), 0.5 ether);

        vm.prank(trigger);
        vm.expectRevert(InsufficientBalance.selector);
        vault.payScheduledAmount(aliceId, 1 ether);
    }

    function test_PayScheduledPayment_revertInsufficientBalance_whenPayWithInsufficientBalanceFalse() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            scheduledPaymentAddr, address(0), address(weth), 1 ether, 1, block.timestamp, 0, false
        );
        vm.prank(ownerAddress);
        uint256 aliceId = _addScheduledPayment(r);

        deal(address(weth), address(vault), 0.5 ether);

        vm.expectRevert(InsufficientBalance.selector);
        _payScheduled(_oneU(aliceId));
        assertEq(weth.balanceOf(scheduledPaymentAddr), 0, "no partial transfer on revert");
    }

    function test_PayScheduledPayment_paysAvailableBalance_whenPayWithInsufficientBalanceTrue() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        uint256 vaultBalance = 0.5 ether;
        IBittyV1Vault.ScheduledPayment memory r = IBittyV1Vault.ScheduledPayment({
            recipient: scheduledPaymentAddr,
            trigger: address(0),
            assetAddress: address(weth),
            amount: 1 ether,
            remainingPaymentCount: 1,
            startTimestamp: block.timestamp,
            paymentInterval: 0,
            isImmutable: false,
            payWithInsufficientBalance: true
        });
        vm.prank(ownerAddress);
        uint256 aliceId = _addScheduledPayment(r);

        deal(address(weth), address(vault), vaultBalance);

        _payScheduled(_oneU(aliceId));

        assertEq(weth.balanceOf(scheduledPaymentAddr), vaultBalance, "transfers entire vault balance");
        assertEq(weth.balanceOf(address(vault)), 0);
        vm.expectRevert(ScheduledPaymentPaymentCountZero.selector);
        _payScheduled(_oneU(aliceId));
    }

    function test_PayScheduledPayment_paysFullAmount_whenPayWithInsufficientBalanceTrueAndBalanceSufficient() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        IBittyV1Vault.ScheduledPayment memory r = IBittyV1Vault.ScheduledPayment({
            recipient: scheduledPaymentAddr,
            trigger: address(0),
            assetAddress: address(weth),
            amount: 1 ether,
            remainingPaymentCount: 1,
            startTimestamp: block.timestamp,
            paymentInterval: 0,
            isImmutable: false,
            payWithInsufficientBalance: true
        });
        vm.prank(ownerAddress);
        uint256 aliceId = _addScheduledPayment(r);

        deal(address(weth), address(vault), 1 ether);

        _payScheduled(_oneU(aliceId));

        assertEq(weth.balanceOf(scheduledPaymentAddr), 1 ether);
        assertEq(weth.balanceOf(address(vault)), 0);
    }

    function test_PayScheduledPayment_partialPaymentsAcrossMultiplePayouts_whenPayWithInsufficientBalanceTrue() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        uint256 start = block.timestamp;
        IBittyV1Vault.ScheduledPayment memory r = IBittyV1Vault.ScheduledPayment({
            recipient: scheduledPaymentAddr,
            trigger: address(0),
            assetAddress: address(weth),
            amount: 1 ether,
            remainingPaymentCount: 3,
            startTimestamp: start,
            paymentInterval: 7 days,
            isImmutable: false,
            payWithInsufficientBalance: true
        });
        vm.prank(ownerAddress);
        uint256 aliceId = _addScheduledPayment(r);

        deal(address(weth), address(vault), 1.5 ether);

        _payScheduled(_oneU(aliceId));
        assertEq(weth.balanceOf(scheduledPaymentAddr), 1 ether);

        vm.warp(start + 7 days + 1);
        _payScheduled(_oneU(aliceId));
        assertEq(weth.balanceOf(scheduledPaymentAddr), 1.5 ether, "second payout sends remaining 0.5 ether");

        // Third attempt with a zero balance: rather than burn the last slot for a zero delivery, it is
        // skipped — the count and interval clock are NOT consumed, so the payment stays due.
        vm.warp(start + 2 * (7 days + 1));
        _payScheduled(_oneU(aliceId));
        assertEq(weth.balanceOf(scheduledPaymentAddr), 1.5 ether, "zero-balance payout delivers nothing");

        // Once funded, the still-due third payment goes through and only then reaches zero remaining.
        deal(address(weth), address(vault), 1 ether);
        _payScheduled(_oneU(aliceId));
        assertEq(weth.balanceOf(scheduledPaymentAddr), 2.5 ether, "third payment made once the vault is funded");

        vm.expectRevert(ScheduledPaymentPaymentCountZero.selector);
        _payScheduled(_oneU(aliceId));
    }

    // ─── ScheduledPayment Events ──────────────────────────────────────────────────────

    // Three adds are now three calls, so three singular events — one per payment.
    function test_addScheduledPayment_emitsOneEventPerAdd() public {
        _initializeVault();
        vm.recordLogs();
        vm.startPrank(ownerAddress);
        vault.addScheduledPayment(_spTo(makeAddr("a")));
        vault.addScheduledPayment(_spTo(makeAddr("b")));
        vault.addScheduledPayment(_spTo(makeAddr("c")));
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 vaultEvents;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(vault)) ++vaultEvents;
        }
        assertEq(vaultEvents, 3, "one singular event per add");
    }

    function test_AddScheduledPayment_emitsScheduledPaymentAddedEvent() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            scheduledPaymentAddr, address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, false
        );

        vm.expectEmit(true, false, false, true, address(vault));
        emit IBittyV1PayoutOperator.ScheduledPaymentAdded(1, r);

        vm.prank(ownerAddress);
        uint256 aliceId = _addScheduledPayment(r);
    }

    function test_UpdateScheduledPayment_emitsScheduledPaymentUpdatedEvent() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            scheduledPaymentAddr, address(0), address(weth), 1 ether, 1, block.timestamp, 1 days, false
        );
        vm.prank(ownerAddress);
        uint256 aliceId = _addScheduledPayment(r);

        IBittyV1Vault.ScheduledPayment memory updated = _makeScheduledPayment(
            scheduledPaymentAddr, address(0), address(weth), 2 ether, 2, block.timestamp, 7 days, false
        );

        vm.expectEmit(false, false, false, true, address(vault));
        emit IBittyV1PayoutOperator.ScheduledPaymentsUpdated(_oneU(aliceId), _oneSP(updated));

        vm.prank(ownerAddress);
        _updateScheduledPayment(aliceId, updated);
    }

    function test_RemoveScheduledPayment_emitsScheduledPaymentRemovedEvent() public {
        _initializeVault();
        uint256 aliceId = _addScheduledPayment(makeAddr("scheduledPayment"), 1 ether, 1, 0);

        vm.expectEmit(false, false, false, true, address(vault));
        emit IBittyV1PayoutOperator.ScheduledPaymentsRemoved(_oneU(aliceId));

        vm.prank(ownerAddress);
        _removeScheduledPayment(aliceId);
    }

    function test_updatePaymentRisk_emitsPaymentRiskUpdatedEvent() public {
        _initializeVault();
        uint256 protection = 1 days;

        IBittyV1Owner.PaymentRisk memory expected = _noRiskChange();
        expected.newPaymentProtection = protection;

        vm.expectEmit(false, false, false, true, address(vault));
        emit IBittyV1Owner.PaymentRiskUpdated(expected);

        vm.prank(ownerAddress);
        _setNewPaymentProtection(protection);
    }

    function test_PayScheduledPayment_emitsScheduledPaymentPaidEvent() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        uint256 aliceId = _addScheduledPayment(scheduledPaymentAddr, 1 ether, 2, 7 days);
        deal(address(weth), address(vault), 1 ether);

        vm.expectEmit(true, false, false, true, address(vault));
        emit IBittyV1Vault.ScheduledPaymentPaid(aliceId, scheduledPaymentAddr, address(weth), 1 ether, 1);

        _payScheduled(_oneU(aliceId));
    }

    function test_PayScheduledPaymentAmount_emitsScheduledPaymentPaidEvent() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        address trigger = makeAddr("trigger");
        uint256 aliceId = _addScheduledPaymentWithTrigger(scheduledPaymentAddr, trigger, 1 ether, 1, 0);
        deal(address(weth), address(vault), 1 ether);

        vm.prank(trigger);
        vm.expectEmit(true, false, false, true, address(vault));
        emit IBittyV1Vault.ScheduledPaymentPaid(aliceId, scheduledPaymentAddr, address(weth), 1 ether, 0);
        vault.payScheduledAmount(aliceId, 1 ether);
    }

    function test_PayScheduledPayment_emitsScheduledPaymentPaidEvent_withPartialBalance() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("scheduledPayment");
        uint256 vaultBalance = 0.5 ether;
        IBittyV1Vault.ScheduledPayment memory r = IBittyV1Vault.ScheduledPayment({
            recipient: scheduledPaymentAddr,
            trigger: address(0),
            assetAddress: address(weth),
            amount: 1 ether,
            remainingPaymentCount: 1,
            startTimestamp: block.timestamp,
            paymentInterval: 0,
            isImmutable: false,
            payWithInsufficientBalance: true
        });
        vm.prank(ownerAddress);
        uint256 aliceId = _addScheduledPayment(r);
        deal(address(weth), address(vault), vaultBalance);

        vm.expectEmit(true, false, false, true, address(vault));
        emit IBittyV1Vault.ScheduledPaymentPaid(aliceId, scheduledPaymentAddr, address(weth), vaultBalance, 0);

        _payScheduled(_oneU(aliceId));
    }

    // ─── Fuzz Tests ───────────────────────────────────────────────────────────

    function testFuzz_AddScheduledPayment_validAmountAndCount(uint256 amount, uint8 remainingPaymentCount) public {
        vm.assume(amount > 0 && remainingPaymentCount > 0);
        _initializeVault();
        uint256 interval = remainingPaymentCount > 1 ? 7 days : 0;
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            makeAddr("r"), address(0), address(weth), amount, remainingPaymentCount, block.timestamp, interval, false
        );
        vm.prank(ownerAddress);
        uint256 rId = _addScheduledPayment(r);
    }

    function testFuzz_SetScheduledPaymentProtection_anyValueRaisesImmediately(uint256 protection) public {
        protection = bound(protection, 1, 3650 days);
        _initializeVault(); // Zero level: raising from 0 is a tightening -> immediate
        vm.prank(ownerAddress);
        _setNewPaymentProtection(protection);
        (uint64 nap,,,) = vault.getRiskConfig();
        assertEq(nap, uint64(protection));
    }

    function testFuzz_ScheduledPaymentProtection_blocksDuringWindow(uint256 protection, uint256 elapsed) public {
        protection = bound(protection, 1 hours, 3650 days);
        elapsed = bound(elapsed, 0, protection - 1);
        _initializeVault();
        vm.prank(ownerAddress);
        _setNewPaymentProtection(protection);
        address scheduledPaymentAddr = makeAddr("r");
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            scheduledPaymentAddr, address(0), address(weth), 1 ether, 1, block.timestamp, 0, false
        );
        vm.prank(ownerAddress);
        uint256 rId = _addScheduledPayment(r);
        deal(address(weth), address(vault), 1 ether);
        vm.warp(block.timestamp + elapsed);
        vm.expectRevert(ProtectionPeriodNotEnded.selector);
        _payScheduled(_oneU(rId));
    }

    function testFuzz_ScheduledPaymentProtection_allowsAfterWindow(uint256 protection, uint256 extra) public {
        protection = bound(protection, 1 hours, 3650 days);
        extra = bound(extra, 0, 365 days);
        _initializeVault();
        vm.prank(ownerAddress);
        _setNewPaymentProtection(protection);
        address scheduledPaymentAddr = makeAddr("r");
        uint256 addedAt = block.timestamp;
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            scheduledPaymentAddr, address(0), address(weth), 1 ether, 1, block.timestamp, 0, false
        );
        vm.prank(ownerAddress);
        uint256 rId = _addScheduledPayment(r);
        deal(address(weth), address(vault), 1 ether);
        vm.warp(addedAt + protection + extra);
        _payScheduled(_oneU(rId));
        assertEq(weth.balanceOf(scheduledPaymentAddr), 1 ether);
    }

    function testFuzz_PayScheduledPayment_allPaymentsComplete(uint8 remainingPaymentCount) public {
        remainingPaymentCount = uint8(bound(uint256(remainingPaymentCount), 1, 10));
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("r");
        uint256 amount = 0.1 ether;
        uint256 start = block.timestamp;
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            scheduledPaymentAddr,
            address(0),
            address(weth),
            amount,
            remainingPaymentCount,
            start,
            remainingPaymentCount > 1 ? 7 days : 0,
            false
        );
        vm.prank(ownerAddress);
        uint256 rId = _addScheduledPayment(r);
        deal(address(weth), address(vault), uint256(remainingPaymentCount) * amount);
        _payScheduled(_oneU(rId));
        for (uint8 i = 1; i < remainingPaymentCount; i++) {
            vm.warp(start + uint256(i) * 7 days);
            _payScheduled(_oneU(rId));
        }
        assertEq(weth.balanceOf(scheduledPaymentAddr), uint256(remainingPaymentCount) * amount);
        vm.expectRevert(ScheduledPaymentPaymentCountZero.selector);
        _payScheduled(_oneU(rId));
    }

    // ─── Stress Tests ─────────────────────────────────────────────────────────

    function test_stress_fiftyScheduledPayments_addAndPayAll() public {
        _initializeVault();
        uint256 n = 50;
        uint256 amount = 0.01 ether;
        deal(address(weth), address(vault), n * amount);
        address[] memory scheduledPayments = new address[](n);
        uint256[] memory spIds = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            scheduledPayments[i] = makeAddr(string.concat("r", Strings.toString(i)));
            IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
                scheduledPayments[i], address(0), address(weth), amount, 1, block.timestamp, 0, false
            );
            vm.prank(ownerAddress);
            spIds[i] = _addScheduledPayment(r);
        }
        for (uint256 i = 0; i < n; i++) {
            _payScheduled(_oneU(spIds[i]));
            assertEq(weth.balanceOf(scheduledPayments[i]), amount);
        }
    }

    function test_stress_twentySequentialPayments() public {
        _initializeVault();
        address scheduledPaymentAddr = makeAddr("r");
        uint8 remainingPaymentCount = 20;
        uint256 amount = 0.05 ether;
        uint256 start = block.timestamp;
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            scheduledPaymentAddr, address(0), address(weth), amount, remainingPaymentCount, start, 7 days, false
        );
        vm.prank(ownerAddress);
        uint256 rId = _addScheduledPayment(r);
        deal(address(weth), address(vault), uint256(remainingPaymentCount) * amount);
        _payScheduled(_oneU(rId));
        for (uint8 i = 1; i < remainingPaymentCount; i++) {
            vm.warp(start + uint256(i) * 7 days);
            _payScheduled(_oneU(rId));
        }
        assertEq(weth.balanceOf(scheduledPaymentAddr), uint256(remainingPaymentCount) * amount);
        vm.expectRevert(ScheduledPaymentPaymentCountZero.selector);
        _payScheduled(_oneU(rId));
    }

    function _addScheduledPayment(
        address scheduledPaymentAddr,
        uint256 amount,
        uint8 remainingPaymentCount,
        uint256 paymentInterval
    ) internal returns (uint256 id) {
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            scheduledPaymentAddr,
            address(0),
            address(weth),
            amount,
            remainingPaymentCount,
            block.timestamp,
            paymentInterval,
            false
        );
        vm.prank(ownerAddress);
        id = _addScheduledPayment(r);
    }

    function _addScheduledPaymentWithTrigger(
        address scheduledPaymentAddr,
        address trigger,
        uint256 amount,
        uint8 remainingPaymentCount,
        uint256 paymentInterval
    ) internal returns (uint256 id) {
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            scheduledPaymentAddr,
            trigger,
            address(weth),
            amount,
            remainingPaymentCount,
            block.timestamp,
            paymentInterval,
            false
        );
        vm.prank(ownerAddress);
        id = _addScheduledPayment(r);
    }

    function _addWlByOwner(address recipient, address allowedAsset) internal returns (uint256 id) {
        vm.prank(ownerAddress);
        id = _addWhitelistedRecipient(recipient, allowedAsset);
    }

    // ============ Scalar (single-item) twins ============

    function test_scalar_send_paysOnePayee() public {
        _initializeVault();
        address payee = makeAddr("payee");
        deal(address(weth), address(vault), 5 ether);
        vm.prank(ownerAddress);
        vault.send(payee, address(weth), 2 ether, new address[](0), new uint256[](0));
        assertEq(weth.balanceOf(payee), 2 ether);
    }

    function test_scalar_send_sourcesFromLending() public {
        _initializeVault();
        MockERC20 usdc = _addStableCoin(6);
        MockLendingProtocol impl = new MockLendingProtocol();
        address payee = makeAddr("payee");
        _setupSuppliedReserve(usdc, impl, 1_000e6);
        vm.prank(ownerAddress);
        vault.send(payee, address(usdc), 400e6, _oneAddr(address(impl)), _oneU(400e6));
        assertEq(usdc.balanceOf(payee), 400e6);
    }

    function test_scalar_send_revertsOnMismatchedWithdrawSources() public {
        _initializeVault();
        MockERC20 usdc = _addStableCoin(6);
        MockLendingProtocol impl = new MockLendingProtocol();
        address payee = makeAddr("payee");
        _setupSuppliedReserve(usdc, impl, 1_000e6);

        vm.prank(ownerAddress);
        vm.expectRevert(ArrayLengthMismatch.selector);
        vault.send(payee, address(usdc), 400e6, _oneAddr(address(impl)), new uint256[](0));

        vm.prank(ownerAddress);
        vm.expectRevert(ArrayLengthMismatch.selector);
        vault.send(payee, address(usdc), 400e6, new address[](0), _oneU(400e6));
    }

    function test_scalar_scheduledPayment_addPayRemove() public {
        _initializeVault();
        address payee = makeAddr("payee");
        deal(address(weth), address(vault), 5 ether);
        vm.prank(ownerAddress);
        uint256 id = vault.addScheduledPayment(
            _makeScheduledPayment(payee, address(0), address(weth), 1 ether, 2, block.timestamp, 0, false)
        );
        vault.payScheduled(id, new address[](0));
        assertEq(weth.balanceOf(payee), 1 ether, "scalar payScheduled paid");

        vm.prank(ownerAddress);
        vault.removeScheduledPayments(_oneU(id));
        vm.expectRevert();
        vault.payScheduled(id, new address[](0));
    }

    function test_scalar_whitelistedRecipient_addPaySendRemove() public {
        _initializeVault();
        address payee = makeAddr("payee");
        deal(address(weth), address(vault), 5 ether);
        vm.prank(ownerAddress);
        uint256 id = vault.addWhitelistedRecipient(payee, address(weth));
        vm.prank(ownerAddress);
        vault.sendToWhitelistedRecipient(id, address(weth), 1 ether, new address[](0), new uint256[](0));
        assertEq(weth.balanceOf(payee), 1 ether);

        vm.prank(ownerAddress);
        vault.removeWhitelistedRecipients(_oneU(id));
        vm.prank(ownerAddress);
        vm.expectRevert();
        vault.sendToWhitelistedRecipient(id, address(weth), 1 ether, new address[](0), new uint256[](0));
    }

    function test_scalar_approveSend_executesOperatorProposal() public {
        _initializeVault();
        address op = makeAddr("op");
        _addPayoutOperator(op);
        address payee = makeAddr("payee");
        deal(address(weth), address(vault), 5 ether);
        vm.prank(op);
        vault.send(payee, address(weth), 1 ether, new address[](0), new uint256[](0));
        assertEq(weth.balanceOf(payee), 0, "operator proposal does not pay yet");
        vm.prank(ownerAddress);
        vault.approveSend(0);
        assertEq(weth.balanceOf(payee), 1 ether, "owner approval paid it");
    }

    function test_scalar_cancelSend_dropsOperatorProposal() public {
        _initializeVault();
        address op = makeAddr("op");
        _addPayoutOperator(op);
        deal(address(weth), address(vault), 5 ether);
        vm.prank(op);
        vault.send(makeAddr("payee"), address(weth), 1 ether, new address[](0), new uint256[](0));
        vm.prank(ownerAddress);
        vault.cancelSend(0);
        vm.prank(ownerAddress);
        vm.expectRevert();
        vault.approveSend(0);
    }

    function _initializeVault() internal {
        vault.initialize(ownerAddress, address(weth), address(0), 0);
        _grantAssetManager(assetManagerAddress);
    }

    // ============ Risk framework ============

    function _addStableCoin(uint8 decimals) internal returns (MockERC20 usdc) {
        usdc = new MockERC20("USD Coin", "USDC", decimals);
        address[] memory toAdd = new address[](1);
        toAdd[0] = address(usdc);
        vm.prank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddStableCoins(address(BittyV1Guard(guardAddress)), toAdd);
        vm.prank(ownerAddress);
        vault.updateAssets(toAdd, new address[](0));
    }

    function _initAtSettings(RiskSettings memory settings) internal returns (BittyV1Vault v) {
        v = new BittyV1Vault(defiFacet, address(0xA07E1D));
        v.initialize(ownerAddress, address(weth), address(0), 0);
        // Risk controls are configured after activation now. From all-zero every field is a
        // tightening, so this applies immediately and lands on the same state initialize used to seed.
        vm.prank(ownerAddress);
        v.updatePaymentRisk(
            IBittyV1Owner.PaymentRisk({
                newPaymentProtection: settings.newPaymentProtection,
                maxSendValue: settings.maxSendValue,
                maxSendInterval: settings.maxSendInterval,
                changeTimelock: settings.changeTimelock
            })
        );
    }

    // Named convenience wrappers mapping the former RiskControlLevels to their RiskSettings.
    // Order: newPaymentProtection, maxSendValue, maxSendInterval, changeTimelock.
    function _initAtZero() internal returns (BittyV1Vault v) {
        v = _initAtSettings(RiskSettings(0, 0, 0, 0));
    }

    function _initAtStandard() internal returns (BittyV1Vault v) {
        v = _initAtSettings(RiskSettings(3 days, 10000, 3 days, 3 days));
    }

    function _initAtHigh() internal returns (BittyV1Vault v) {
        v = _initAtSettings(RiskSettings(7 days, 1000, 7 days, 7 days));
    }

    function test_Risk_LevelDefaults_NoneIsAllZero() public {
        (uint64 nap, uint64 sVal, uint64 tl,) = _initAtZero().getRiskConfig();
        assertEq(nap, 0);
        assertEq(sVal, 0);
        assertEq(tl, 0); // Zero level: no loosening delay, changes are instant
    }

    function test_Risk_LevelDefaults_StandardAndHighAreConfigured() public {
        (uint64 stdNap, uint64 stdSend, uint64 stdTl,) = _initAtStandard().getRiskConfig();
        assertGt(stdNap, 0);
        assertGt(stdSend, 0);
        assertGt(stdTl, 0);

        (uint64 hiNap, uint64 hiSend, uint64 hiTl,) = _initAtHigh().getRiskConfig();
        assertGt(hiNap, 0);
        assertGt(hiSend, 0);
        assertGt(hiTl, 0);
        // High keeps at least as long a reaction window as Standard (new-address protection + change
        // timelock). The send cap is the owner's dollar policy, so no cross-level ordering is assumed.
        assertGe(hiNap, stdNap);
        assertGe(hiTl, stdTl);
    }

    function test_Risk_Send_RevertsForNonStableCoin() public {
        _initializeVault();
        vm.prank(ownerAddress);
        _setMaxSendValue(1_000);
        vm.prank(ownerAddress);
        vm.expectRevert(PaymentNotStableCoin.selector);
        _send(makeAddr("payee"), address(weth), 1);
    }

    function test_Risk_Send_RevertsOverCap() public {
        _initializeVault();
        MockERC20 usdc = _addStableCoin(6);
        vm.prank(ownerAddress);
        _setMaxSendValue(1_000);
        vm.prank(ownerAddress);
        vm.expectRevert(PaymentExceedsRiskCap.selector);
        _send(makeAddr("payee"), address(usdc), 1_001 * 1e6);
    }

    // The tests above go through batchSend. The scalar send validates separately, so the same policy
    // has to be proven on that path too — a cap that only binds the array form is not a cap.
    function test_Risk_scalarSend_RevertsForNonStableCoin() public {
        _initializeVault();
        vm.prank(ownerAddress);
        _setMaxSendValue(1_000);
        vm.prank(ownerAddress);
        vm.expectRevert(PaymentNotStableCoin.selector);
        vault.send(makeAddr("payee"), address(weth), 1, new address[](0), new uint256[](0));
    }

    function test_Risk_scalarSend_RevertsOverCap() public {
        _initializeVault();
        MockERC20 usdc = _addStableCoin(6);
        vm.prank(ownerAddress);
        _setMaxSendValue(1_000);
        vm.prank(ownerAddress);
        vm.expectRevert(PaymentExceedsRiskCap.selector);
        vault.send(makeAddr("payee"), address(usdc), 1_001 * 1e6, new address[](0), new uint256[](0));
    }

    function test_Risk_scalarSend_SucceedsWithinCap() public {
        _initializeVault();
        MockERC20 usdc = _addStableCoin(6);
        address payee = makeAddr("payee");
        deal(address(usdc), address(vault), 2_000e6);
        vm.prank(ownerAddress);
        _setMaxSendValue(1_000);
        vm.prank(ownerAddress);
        vault.send(payee, address(usdc), 900e6, new address[](0), new uint256[](0));
        assertEq(usdc.balanceOf(payee), 900e6);
    }

    function test_Risk_Send_SucceedsWithinCap() public {
        _initializeVault();
        MockERC20 usdc = _addStableCoin(6);
        usdc.mint(address(vault), 1_000 * 1e6);
        address payee = makeAddr("payee");
        vm.prank(ownerAddress);
        _setMaxSendValue(1_000);
        vm.prank(ownerAddress);
        _send(payee, address(usdc), 1_000 * 1e6);
        assertEq(usdc.balanceOf(payee), 1_000 * 1e6);
    }

    function test_Risk_ApproveSend_RechecksCapAfterTightening() public {
        _initializeVault();
        MockERC20 usdc = _addStableCoin(6);
        usdc.mint(address(vault), 5_000 * 1e6);
        address pm = makeAddr("pmSend");
        _addPayoutOperator(pm);

        // Payout operator proposes a 5,000 USDC send while there is no cap (pending id 0).
        address payee = makeAddr("sendPayee");
        vm.prank(pm);
        _send(payee, address(usdc), 5_000 * 1e6);

        // Owner tightens the send cap to 1,000 (immediate at Zero level).
        vm.prank(ownerAddress);
        _setMaxSendValue(1_000);

        // Approving the already-queued over-cap send now re-checks and reverts.
        vm.prank(ownerAddress);
        vm.expectRevert(PaymentExceedsRiskCap.selector);
        _approveSend(0);
    }

    function test_MaxSendInterval_levelDefaults() public {
        (,,, uint64 zeroInterval) = _initAtZero().getRiskConfig();
        assertEq(zeroInterval, 0);
        (,,, uint64 stdInterval) = _initAtStandard().getRiskConfig();
        assertEq(stdInterval, 3 days);
        (,,, uint64 highInterval) = _initAtHigh().getRiskConfig();
        assertEq(highInterval, 7 days);
    }

    function test_MaxSendInterval_capsCumulativeOwnerSendsPerWindow() public {
        _initializeVault();
        MockERC20 usdc = _addStableCoin(6);
        usdc.mint(address(vault), 10_000e6);
        address payee = makeAddr("payee");

        vm.prank(ownerAddress);
        _setMaxSendValue(1_000);
        vm.prank(ownerAddress);
        _setMaxSendInterval(1 days);

        // First batch up to the cap: ok.
        vm.prank(ownerAddress);
        _send(payee, address(usdc), 1_000e6);
        assertEq(usdc.balanceOf(payee), 1_000e6);

        // Any more within the same window exceeds the cumulative cap: blocked. This is the drain a
        // leaked owner key would otherwise pull off cap-by-cap without pause.
        vm.prank(ownerAddress);
        vm.expectRevert(PaymentExceedsPeriodLimit.selector);
        _send(payee, address(usdc), 1e6);

        // Once the window elapses, the quota resets.
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(ownerAddress);
        _send(payee, address(usdc), 1_000e6);
        assertEq(usdc.balanceOf(payee), 2_000e6);
    }

    function test_MaxSendInterval_zeroKeepsPerBatchCap() public {
        _initializeVault();
        MockERC20 usdc = _addStableCoin(6);
        usdc.mint(address(vault), 10_000e6);
        address payee = makeAddr("payee");

        // A cap with no rolling window (interval 0) stays per-transaction, so repeated capped batches
        // are still allowed — the legacy behavior maxSendInterval is meant to close.
        vm.prank(ownerAddress);
        _setMaxSendValue(1_000);

        vm.prank(ownerAddress);
        _send(payee, address(usdc), 1_000e6);
        vm.prank(ownerAddress);
        _send(payee, address(usdc), 1_000e6);
        assertEq(usdc.balanceOf(payee), 2_000e6);
    }

    function test_Risk_ZeroLevel_AllChangesInstant() public {
        _initializeVault(); // Zero level -> changeTimelock 0, so even loosening is instant
        vm.startPrank(ownerAddress);
        _setMaxSendValue(1_000); // enable (tighten)
        _setMaxSendValue(500); // lower (tighten)
        _setMaxSendValue(5_000); // raise (loosen) -> instant
        _setMaxSendValue(0); // clear (loosen) -> instant
        vm.stopPrank();
        (, uint64 sVal,,) = vault.getRiskConfig();
        assertEq(sVal, 0);
    }

    function test_Risk_SetMaxSendValue_OnlyOwner() public {
        _initializeVault();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        _setMaxSendValue(1_000);
    }

    function test_ownerGetter_resolvesToTheOwner() public {
        _initializeVault();
        assertEq(vault.owner(), ownerAddress);
        assertTrue(vault.owner() == ownerAddress);
    }

    function test_owner_ownerCanActInstantly() public {
        _initializeVault();
        assertTrue(vault.owner() == ownerAddress);

        address newAssetManager = makeAddr("instantAssetManager");
        vm.prank(ownerAddress);
        vault.setAssetManager(newAssetManager, 0);
        assertEq(effectiveAssetManager(address(vault)), newAssetManager);
    }

    function test_setAssetManager_emitsAssetManagerSet() public {
        _initializeVault();
        address newAssetManager = makeAddr("newAssetManager");
        vm.prank(ownerAddress);
        vm.expectEmit(true, false, false, true);
        emit IBittyV1Owner.AssetManagerSet(newAssetManager, 0);
        vault.setAssetManager(newAssetManager, 0);
    }

    // ============ Ownership transfer ============

    function test_vaultOwnershipTransferIsTwoStep() public {
        _initializeVault();
        address next = makeAddr("nextOwner");

        vm.prank(ownerAddress);
        vault.transferOwnership(next);
        assertEq(vault.owner(), ownerAddress, "nomination alone moves nothing");
        assertEq(vault.pendingOwner(), next);
        assertTrue(vault.owner() == ownerAddress, "old owner still admin");

        vm.prank(next);
        vault.acceptOwnership();
        assertEq(vault.owner(), next, "authority moves on acceptance");
        assertEq(vault.pendingOwner(), address(0), "the nomination is consumed");
        assertTrue(vault.owner() == next, "and the role follows owner()");
        assertFalse(vault.owner() == ownerAddress, "the old owner loses it");
    }

    function test_vaultOwnershipOnlyOwnerCanNominate() public {
        _initializeVault();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        vault.transferOwnership(makeAddr("nextOwner"));
    }

    function test_vaultOwnershipOnlyNomineeCanAccept() public {
        _initializeVault();
        vm.prank(ownerAddress);
        vault.transferOwnership(makeAddr("nextOwner"));

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        vault.acceptOwnership();
        assertEq(vault.owner(), ownerAddress, "a rejected accept leaves the owner untouched");
    }

    function test_vaultOwnershipNominationCanBeWithdrawn() public {
        _initializeVault();
        address next = makeAddr("nextOwner");
        vm.startPrank(ownerAddress);
        vault.transferOwnership(next);
        vault.transferOwnership(address(0));
        vm.stopPrank();
        assertEq(vault.pendingOwner(), address(0));

        vm.prank(next);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, next));
        vault.acceptOwnership();
    }

    /**
     * @dev Dropping ownership must go through renounceVaultOwnership, which first proves a locked
     * escape route exists; the inherited entry point would skip that proof entirely.
     */
    function test_vaultOwnershipCannotBeRenouncedDirectly() public {
        _initializeVault();
        vm.prank(ownerAddress);
        vm.expectRevert(OwnershipNotRenounceable.selector);
        vault.renounceOwnership();
        assertEq(vault.owner(), ownerAddress);
    }

    /**
     * @dev Owner and payout operator are required to differ; accepting is the other direction from
     * which that invariant could be broken.
     */
    function test_vaultOwnershipNomineeCannotBeAPayoutOperator() public {
        _initializeVault();
        address op = makeAddr("payoutOperator");
        _addPayoutOperator(op);
        vm.prank(ownerAddress);
        vault.transferOwnership(op);

        vm.prank(op);
        vm.expectRevert(PendingOwnerIsPayoutOperator.selector);
        vault.acceptOwnership();
        assertEq(vault.owner(), ownerAddress);
    }

    function test_vaultOwnershipNewOwnerHoldsOwnerPowers() public {
        _initializeVault();
        address next = makeAddr("nextOwner");
        vm.prank(ownerAddress);
        vault.transferOwnership(next);
        vm.prank(next);
        vault.acceptOwnership();

        address mgr = makeAddr("mgr");
        vm.prank(next);
        vault.setAssetManager(mgr, 0);
        assertEq(effectiveAssetManager(address(vault)), mgr, "the new owner governs");

        vm.prank(ownerAddress);
        vm.expectRevert();
        vault.setAssetManager(makeAddr("other"), 0);
    }

    /**
     * @dev The reason this exists: the vault can move to an account that does not verify with ECDSA,
     * without a single asset moving.
     */
    function test_vaultOwnershipCanMoveToAContract() public {
        _initializeVault();
        address nominee = address(new MockLendingProtocol());

        vm.prank(ownerAddress);
        vault.transferOwnership(nominee);
        vm.prank(nominee);
        vault.acceptOwnership();

        assertEq(vault.owner(), nominee);
        assertGt(nominee.code.length, 0, "the owner is genuinely a contract");
    }

    // ─── Immutable scheduled payment lock ─────────────────────────────────────

    function _addPayment(address recipient, uint256 count, bool isImmutable_) internal returns (uint256 id) {
        IBittyV1Vault.ScheduledPayment memory r = _makeScheduledPayment(
            recipient, address(0), address(weth), 1 ether, count, block.timestamp, 30 days, isImmutable_
        );
        vm.prank(ownerAddress);
        id = _addScheduledPayment(r);
    }

    function test_removeImmutableScheduledPayment_allowedDuringLockWindow() public {
        _initializeVault();
        // The immutable lock window is exactly newPaymentProtection: set a 3-day protection so the
        // entry has a removable window before it locks.
        vm.prank(ownerAddress);
        _setNewPaymentProtection(3 days);
        uint256 id = _addPayment(makeAddr("payee"), 1, true);

        vm.warp(block.timestamp + 3 days - 2);
        vm.prank(ownerAddress);
        _removeScheduledPayment(id);
    }

    function test_removeImmutableScheduledPayment_revertsAfterLockWindow() public {
        _initializeVault();
        // Lock deadline = added-at + newPaymentProtection; past it the immutable entry is permanently locked.
        vm.prank(ownerAddress);
        _setNewPaymentProtection(3 days);
        uint256 id = _addPayment(makeAddr("payee"), 1, true);

        vm.warp(block.timestamp + 3 days + 1);
        vm.prank(ownerAddress);
        vm.expectRevert(ImmutableScheduledPaymentLocked.selector);
        _removeScheduledPayment(id);
    }

    function test_removeImmutableScheduledPayment_lockWindowFollowsProtection() public {
        _initializeVault();
        vm.prank(ownerAddress);
        _setNewPaymentProtection(4 days);
        uint256 id = _addPayment(makeAddr("payee"), 1, true);

        vm.warp(block.timestamp + 4 days - 2);
        vm.prank(ownerAddress);
        _removeScheduledPayment(id);
    }

    function test_removeImmutableScheduledPayment_exhaustedEntryCleanup() public {
        _initializeVault();
        uint256 id = _addPayment(makeAddr("payee"), 1, true);
        weth.deposit{value: 1 ether}();
        weth.transfer(address(vault), 1 ether);

        vm.warp(block.timestamp + 3 days + 1);
        _payScheduled(_oneU(id));

        // The locked entry has no payments left, so removing the dead entry is allowed.
        vm.prank(ownerAddress);
        _removeScheduledPayment(id);
    }

    function test_mutableScheduledPayment_alwaysRemovable() public {
        _initializeVault();
        uint256 id = _addPayment(makeAddr("payee"), 1, false);
        vm.warp(block.timestamp + 365 days);
        vm.prank(ownerAddress);
        _removeScheduledPayment(id);
    }

    /**
     * @dev The exposed-owner-key playbook end to end: the owner pre-configures an immutable escape
     * payment to a cold address and lets it lock. When the key leaks, the hacker (who holds the same
     * key) can neither redirect nor remove it; the real owner deletes everything else, renounces to
     * address(0), and the escape payments keep flowing while the leaked key has become worthless.
     */
    function test_exposedOwnerKey_immutableEscapePaymentSurvivesAndPaysOut() public {
        _initializeVault();
        address coldWallet = makeAddr("coldWallet");
        address hackerWallet = makeAddr("hackerWallet");
        // Absolute checkpoints: under via-ir the optimizer may cache block.timestamp across vm.warp,
        // so warp targets must not be re-derived from block.timestamp mid-test.
        uint256 start = block.timestamp;

        // Day 0: owner sets up the unlimited immutable escape payment and funds the vault.
        uint256 escapeId = _addPayment(coldWallet, type(uint256).max, true);
        weth.deposit{value: 3 ether}();
        weth.transfer(address(vault), 3 ether);

        // The escape payment is now permanently locked (protection 0 -> lock deadline = added-at, so it
        // locks immediately).
        vm.warp(start + 3 days + 1);

        // The key leaks. The hacker cannot redirect, remove, or replace the escape payment.
        vm.startPrank(ownerAddress);
        vm.expectRevert(ScheduledPaymentImmutable.selector);
        _updateScheduledPayment(
            escapeId,
            _makeScheduledPayment(
                hackerWallet, address(0), address(weth), 1 ether, 255, start + 3 days + 2 days, 30 days, true
            )
        );
        vm.expectRevert(ImmutableScheduledPaymentLocked.selector);
        _removeScheduledPayment(escapeId);

        // The hacker plants their own payment instead.
        uint256 maliciousId = _addScheduledPayment(
            _makeScheduledPayment(
                hackerWallet, address(0), address(weth), 3 ether, 1, start + 3 days + 2 days, 30 days, false
            )
        );
        vm.stopPrank();

        // The real owner detects the compromise: one atomic renounceVaultOwnership()
        // naming the immutable rescue drops ownership instantly. The hacker's
        // mutable entry isn't cleared but becomes un-payable (ownerless vault
        // pays only locked immutable), so it can never drain.
        vm.prank(ownerAddress);
        vault.renounceVaultOwnership(escapeId);
        assertEq(vault.owner(), address(0));

        // The hacker's mutable payment is now inert.
        vm.warp(start + 3 days + 3 days);
        vm.expectRevert(OnlyImmutablePayableAfterRenounce.selector);
        _payScheduled(_oneU(maliciousId));

        // The leaked key is now worthless: no owner powers remain.
        vm.prank(ownerAddress);
        vm.expectRevert(NotPayoutOperator.selector);
        _addScheduledPayment(
            _makeScheduledPayment(hackerWallet, address(0), address(weth), 3 ether, 1, start + 30 days, 30 days, false)
        );

        // The escape payments keep flowing to the cold wallet forever (unlimited count).
        _payScheduled(_oneU(escapeId));
        assertEq(weth.balanceOf(coldWallet), 1 ether);
        vm.warp(start + 3 days + 32 days);
        _payScheduled(_oneU(escapeId));
        assertEq(weth.balanceOf(coldWallet), 2 ether);
        assertEq(weth.balanceOf(hackerWallet), 0);
    }

    // ─── renounceVaultOwnership ────────────────────────────────────────────────────

    function test_renounceVaultOwnership_neutralizesInjectedRenouncesInstantlyAndPaysOut() public {
        _initializeVault();
        address coldWallet = makeAddr("coldWallet");
        address hackerWallet = makeAddr("hackerWallet");
        bytes32 adminRole = bytes32(0);
        uint256 start = block.timestamp;

        // Day 0: the pre-compromise immutable rescue payment to the cold wallet.
        uint256 escapeId = _addPayment(coldWallet, type(uint256).max, true);
        weth.deposit{value: 3 ether}();
        weth.transfer(address(vault), 3 ether);
        // Its lock window passes — now permanent.
        vm.warp(start + 3 days + 1);

        // Key leaks: the hacker queues their own scheduled payment (pending).
        vm.prank(ownerAddress);
        uint256 maliciousId = _addScheduledPayment(
            _makeScheduledPayment(
                hackerWallet, address(0), address(weth), 3 ether, 1, start + 3 days + 2 days, 30 days, false
            )
        );

        // One atomic call naming the immutable rescue renounces instantly.
        vm.prank(ownerAddress);
        vm.expectEmit(true, false, false, false);
        emit IBittyV1Owner.OwnershipRenounced(ownerAddress);
        vault.renounceVaultOwnership(escapeId);

        // Instantly ownerless — no 1-day delay.
        assertEq(vault.owner(), address(0));
        // The hacker's mutable entry isn't deleted but is inert: un-payable.
        vm.warp(start + 3 days + 3 days);
        vm.expectRevert(OnlyImmutablePayableAfterRenounce.selector);
        _payScheduled(_oneU(maliciousId));
        // The leaked key is worthless.
        vm.prank(ownerAddress);
        vm.expectRevert(NotPayoutOperator.selector);
        _addScheduledPayment(
            _makeScheduledPayment(hackerWallet, address(0), address(weth), 3 ether, 1, start + 30 days, 30 days, false)
        );

        // The rescue payment still flows to the cold wallet.
        _payScheduled(_oneU(escapeId));
        assertEq(weth.balanceOf(coldWallet), 1 ether);
        assertEq(weth.balanceOf(hackerWallet), 0);
    }

    function _armRescue() internal returns (address coldWallet, uint256 escapeId) {
        coldWallet = makeAddr("coldWallet");
        uint256 start = block.timestamp;
        escapeId = _addPayment(coldWallet, type(uint256).max, true);
        weth.deposit{value: 3 ether}();
        weth.transfer(address(vault), 3 ether);
        vm.warp(start + 3 days + 1);
    }

    /**
     * @notice Renouncing strips a manager that IS the owner.
     * @dev That grant is the owner's own authority wearing another hat, so it goes with the rest of
     *      it — otherwise renouncing would leave the very key being disowned still able to trade.
     */
    /**
     * @dev Renouncing routes through _transferOwnership, which deletes any pending owner. Without
     * that, a nomination made before the owner walked away would still be claimable afterwards —
     * handing the vault to someone the escape route was never meant to involve.
     */
    function test_renounceVaultOwnership_voidsAnInFlightNomination() public {
        _initializeVault();
        (, uint256 escapeId) = _armRescue();
        address nominee = makeAddr("nominee");

        vm.startPrank(ownerAddress);
        vault.transferOwnership(nominee);
        assertEq(vault.pendingOwner(), nominee, "a transfer is in flight");
        vault.renounceVaultOwnership(escapeId);
        vm.stopPrank();

        assertEq(vault.owner(), address(0), "ownerless");
        assertEq(vault.pendingOwner(), address(0), "and the nomination went with it");

        vm.prank(nominee);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, nominee));
        vault.acceptOwnership();
        assertEq(vault.owner(), address(0), "the vault stays ownerless");
    }

    /**
     * @dev Nothing can re-own a renounced vault: transferOwnership is owner-gated and the owner is
     * now an address nobody can transact from.
     */
    function test_renounceVaultOwnership_cannotBeReversed() public {
        _initializeVault();
        (, uint256 escapeId) = _armRescue();
        vm.prank(ownerAddress);
        vault.renounceVaultOwnership(escapeId);

        vm.prank(ownerAddress);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, ownerAddress));
        vault.transferOwnership(ownerAddress);
        assertEq(vault.owner(), address(0));
    }

    function test_renounceVaultOwnership_stripsTheOwnerAsManager() public {
        _initializeVault();
        (address coldWallet, uint256 escapeId) = _armRescue();

        vm.startPrank(ownerAddress);
        vault.setAssetManager(ownerAddress, 0);
        assertEq(effectiveAssetManager(address(vault)), ownerAddress, "owner is its own manager");
        vault.renounceVaultOwnership(escapeId);
        vm.stopPrank();

        assertEq(vault.owner(), address(0), "ownerless");
        assertEq(effectiveAssetManager(address(vault)), address(0), "and no manager left to trade the rescue away");

        _payScheduled(_oneU(escapeId));
        assertEq(weth.balanceOf(coldWallet), 1 ether);
    }

    /**
     * @notice A separately appointed manager SURVIVES the renounce.
     * @dev It was delegated deliberately, and never held the owner key. An ownerless vault still
     *      wants its strategy run and its scheduled payments funded, so stripping it would strand the
     *      position and protect nobody.
     */
    function test_renounceVaultOwnership_keepsAManagerThatIsNotTheOwner() public {
        _initializeVault();
        (, uint256 escapeId) = _armRescue();
        address agent = makeAddr("delegatedAgent");

        vm.prank(ownerAddress);
        vault.setAssetManager(agent, 0);
        // The delay is what makes keeping the delegate safe — an attacker's install would still be
        // pending at this point. Without it the vault cannot tell the two apart and drops both.
        vm.prank(ownerAddress);
        _setChangeTimelock(3 days);

        vm.prank(ownerAddress);
        vault.renounceVaultOwnership(escapeId);

        assertEq(vault.owner(), address(0), "ownerless");
        assertEq(effectiveAssetManager(address(vault)), agent, "the delegate keeps managing");
    }

    /**
     * @notice A SCHEDULED manager is dropped by the renounce, even though a live one is kept.
     * @dev This is what the defence rests on. A stolen owner key installing a manager is a change
     *      that has to wait out changeTimelock, so at the moment of the renounce it is still pending
     *      — and pending is exactly what gets dropped. The delegate the owner appointed earlier, long
     *      since live, is untouched.
     */
    function test_renounceVaultOwnership_dropsAScheduledAssetManager() public {
        _initializeVault();
        (, uint256 escapeId) = _armRescue();
        address agent = makeAddr("delegatedAgent2");
        address hacker = makeAddr("hackerManager");

        vm.prank(ownerAddress);
        vault.setAssetManager(agent, 0);
        vm.prank(ownerAddress);
        _setChangeTimelock(3 days);

        // Key leaks: the attacker schedules their own manager, then renounces to lock it in.
        vm.startPrank(ownerAddress);
        vault.setAssetManager(hacker, 0);
        (,, address pending,) = vault.getAssetManagerSettings();
        assertEq(pending, hacker, "scheduled, not yet in force");
        vault.renounceVaultOwnership(escapeId);
        vm.stopPrank();

        vm.warp(block.timestamp + 30 days);
        (address manager,, address pendingAfter, uint64 pendingAt) = vault.getAssetManagerSettings();
        assertEq(pendingAfter, address(0), "the attacker's grant went with the renounce");
        assertEq(pendingAt, 0);
        assertEq(manager, agent, "and the real delegate is still there");
        assertEq(effectiveAssetManager(address(vault)), agent);
    }

    /**
     * @notice With no changeTimelock, the renounce drops the manager whoever it is.
     * @dev Keeping a delegate is only safe because installing one is normally delayed, which leaves
     *      a stolen key's manager pending at the renounce. A vault with no delay has no pending
     *      stage, so an attacker's manager is live and looks exactly like a deliberate delegate.
     *      Nothing distinguishes them, so neither is kept — the renounce falls back to stripping
     *      trading authority outright, which is what it is for.
     */
    function test_renounceVaultOwnership_withNoTimelockDropsTheManagerToo() public {
        _initializeVault();
        (address coldWallet, uint256 escapeId) = _armRescue();
        address hacker = makeAddr("hackerManagerNoDelay");

        vm.startPrank(ownerAddress);
        vault.setAssetManager(hacker, 0);
        assertEq(effectiveAssetManager(address(vault)), hacker, "no delay: live immediately");
        vault.renounceVaultOwnership(escapeId);
        vm.stopPrank();

        assertEq(effectiveAssetManager(address(vault)), address(0), "dropped: nothing tells it from an attacker");

        // And the rescue still pays, with no manager left to trade the asset away first.
        _payScheduled(_oneU(escapeId));
        assertEq(weth.balanceOf(coldWallet), 1 ether);
    }

    function test_renounceVaultOwnership_revertsWithoutRescueTarget() public {
        _initializeVault();
        // No locked immutable scheduled payment exists — any id fails the check.
        vm.prank(ownerAddress);
        vm.expectRevert(NoRescueTarget.selector);
        vault.renounceVaultOwnership(1);
        // Ownership is untouched.
        assertEq(vault.owner(), ownerAddress);
    }

    function test_renounceVaultOwnership_whitelistedRecipientAloneIsNotRescue() public {
        _initializeVault();
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        address[] memory toAdd = new address[](1);
        toAdd[0] = address(usdc);
        vm.prank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddStableCoins(address(BittyV1Guard(guardAddress)), toAdd);
        vm.prank(ownerAddress);
        vault.updateAssets(toAdd, new address[](0));

        // A whitelisted recipient can't pay out in an ownerless vault (no role to
        // trigger it), so it is NOT a valid rescue — emergency renounce reverts.
        _addWlByOwner(makeAddr("coldWallet"), address(usdc));
        vm.prank(ownerAddress);
        vm.expectRevert(NoRescueTarget.selector);
        vault.renounceVaultOwnership(1);
        assertEq(vault.owner(), ownerAddress);
    }

    function test_renounceVaultOwnership_leavesWhitelistedRecipientsIntact() public {
        _initializeVault();
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        address[] memory toAdd = new address[](1);
        toAdd[0] = address(usdc);
        vm.prank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddStableCoins(address(BittyV1Guard(guardAddress)), toAdd);
        vm.prank(ownerAddress);
        vault.updateAssets(toAdd, new address[](0));
        address wl = makeAddr("wl");
        uint256 wlId = _addWlByOwner(wl, address(usdc));

        // With a locked immutable payment as the rescue, renounce succeeds. The
        // whitelisted recipient is left as-is — it's inert in an ownerless vault
        // (sendToWhitelistedRecipient is owner-only), so clearing it is wasted gas.
        uint256 rescueId = _addPayment(makeAddr("cold"), type(uint256).max, true);
        vm.warp(block.timestamp + 3 days + 1);
        vm.prank(ownerAddress);
        vault.renounceVaultOwnership(rescueId);
        assertEq(vault.owner(), address(0));
        (address recip,) = _getWlOne(wlId);
        assertEq(recip, wl);
    }

    function test_renounceVaultOwnership_onlyOwner() public {
        _initializeVault();
        uint256 rescueId = _addPayment(makeAddr("cold"), type(uint256).max, true);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        vault.renounceVaultOwnership(rescueId);
    }

    function test_renounceVaultOwnership_notGriefableByManyPayments() public {
        _initializeVault();
        // The pre-committed immutable rescue.
        uint256 rescueId = _addPayment(makeAddr("cold"), type(uint256).max, true);
        vm.warp(block.timestamp + 3 days + 1);

        // Attacker (same key) inflates the scheduled-payment id space to try to
        // brick the renounce. Renounce is O(1) — names one id, loops over nothing
        // — so it still completes in a single call regardless of the count.
        vm.startPrank(ownerAddress);
        for (uint256 i = 0; i < 200; i++) {
            _addScheduledPayment(
                _makeScheduledPayment(
                    makeAddr("hacker"), address(0), address(weth), 1, 1, block.timestamp + 1 days, 30 days, false
                )
            );
        }
        vault.renounceVaultOwnership(rescueId);
        vm.stopPrank();
        assertEq(vault.owner(), address(0));
    }

    // ─── Unified updateAssets (add + remove) ───────────────────────────────────

    function test_AddAssets_addsRegisteredStableCoinToStableCoinsSet() public {
        _initializeVault();
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        address[] memory toAdd = new address[](1);
        toAdd[0] = address(usdc);

        vm.prank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddStableCoins(address(BittyV1Guard(guardAddress)), toAdd);

        vm.prank(ownerAddress);
        vault.updateAssets(toAdd, new address[](0));

        // Routing is exclusive, so landing in stable coins IS the assertion that it did not land in
        // assets - which is what the old before/after counts were standing in for.
        assertTrue(vault.isStableCoinAllowed(address(usdc)), "a stable coin lands in stable coins");
    }

    function test_AddAssets_addsRegisteredAssetToAssetsSet() public {
        _initializeVault();
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        address[] memory toAdd = new address[](1);
        toAdd[0] = address(dai);

        vm.prank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddAssets(address(BittyV1Guard(guardAddress)), toAdd);

        // Relative to what activation seeded (WETH plus the guard's stable coins), because the
        // list is no longer empty at birth — an empty list would now permit nothing at all.

        vm.prank(ownerAddress);
        vault.updateAssets(toAdd, new address[](0));

        assertTrue(vault.isAssetAllowed(address(dai)), "a plain asset is allowed");
        assertFalse(vault.isStableCoinAllowed(address(dai)), "a plain asset does not touch stable coins");
    }

    function test_RemoveAssets_removesStableCoinFromStableCoinsSet() public {
        _initializeVault();
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        address[] memory toAdd = new address[](1);
        toAdd[0] = address(usdc);

        vm.prank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddStableCoins(address(BittyV1Guard(guardAddress)), toAdd);
        vm.prank(ownerAddress);
        vault.updateAssets(toAdd, new address[](0));

        vm.prank(ownerAddress);
        vault.updateAssets(new address[](0), toAdd);

        assertFalse(vault.isStableCoinAllowed(address(usdc)), "nothing listed as a stable coin");
    }

    function test_RemoveAssets_removesAssetFromAssetsSet() public {
        _initializeVault();
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        address[] memory toAdd = new address[](1);
        toAdd[0] = address(dai);

        vm.prank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddAssets(address(BittyV1Guard(guardAddress)), toAdd);

        vm.prank(ownerAddress);
        vault.updateAssets(toAdd, new address[](0));

        vm.prank(ownerAddress);
        vault.updateAssets(new address[](0), toAdd);

        assertFalse(vault.isAssetAllowed(address(dai)), "back to what activation seeded");
    }

    function test_AddAssets_revertsWhenNotRegisteredOnGuard() public {
        _initializeVault();
        address unregistered = makeAddr("unregistered");
        address[] memory toAdd = new address[](1);
        toAdd[0] = unregistered;

        vm.prank(ownerAddress);
        vm.expectRevert(NotRegistered.selector);
        vault.updateAssets(toAdd, new address[](0));
    }

    function test_RemoveAssets_revertsWhenNotInVault() public {
        _initializeVault();
        address unregistered = makeAddr("unregistered");
        address[] memory toRemove = new address[](1);
        toRemove[0] = unregistered;

        vm.prank(ownerAddress);
        vm.expectRevert(NotRegistered.selector);
        vault.updateAssets(new address[](0), toRemove);
    }

    // ============ Pay scheduledPayment directly from yield (on-behalf) ============

    function _arr(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _amounts(uint256 amount) internal pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = amount;
    }

    function _send(address recipient, address asset, uint256 amount) internal {
        _send(_arr(recipient), _arr(asset), _amounts(amount));
    }

    // Whitelisted-recipient send from vault balance (no yield-position sourcing).
    function _sendWl(uint256 id, address asset, uint256 amount) internal {
        vault.sendToWhitelistedRecipient(id, asset, amount, new address[](0), new uint256[](0));
    }

    // Plain vault-balance send (empty position arrays) — most tests don't source from positions.
    function _send(address[] memory recipients, address[] memory assets, uint256[] memory amounts) internal {
        vault.batchSend(recipients, assets, amounts, new address[](0), new uint256[](0));
    }

    /**
     * @dev Registers a staking mock in the guard + vault, funds the vault, and stakes it.
     */
    function _setupStakedReserve(MockERC20 usdc, MockStakingProtocol impl, uint256 stakeAmount) internal {
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddProtocols(address(BittyV1Guard(guardAddress)), _arr(address(impl)));
        vm.stopPrank();
        vm.prank(ownerAddress);
        IVaultFull(payable(address(vault))).updateProtocols(_arr(address(impl)), new address[](0));

        usdc.mint(address(vault), stakeAmount);
        vm.prank(assetManagerAddress);
        IVaultFull(payable(address(vault))).deposit(address(impl), address(usdc), stakeAmount);
    }

    /**
     * @dev Registers a lending mock in the guard + vault, funds the vault, and supplies it.
     */
    function _setupSuppliedReserve(MockERC20 usdc, MockLendingProtocol impl, uint256 supplyAmount) internal {
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddProtocols(address(BittyV1Guard(guardAddress)), _arr(address(impl)));
        vm.stopPrank();
        vm.prank(ownerAddress);
        IVaultFull(payable(address(vault))).updateProtocols(_arr(address(impl)), new address[](0));

        usdc.mint(address(vault), supplyAmount);
        vm.prank(assetManagerAddress);
        IVaultFull(payable(address(vault))).deposit(address(impl), address(usdc), supplyAmount);
    }

    function test_payScheduledFromStaking_deliversToPayee() public {
        _initializeVault();
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockStakingProtocol impl = new MockStakingProtocol();
        address payee = makeAddr("rentScheduledPayment");
        _setupStakedReserve(usdc, impl, 1_000e6);

        uint256 payAmount = 250e6;
        vm.prank(ownerAddress);
        uint256 id = _addScheduledPayment(
            _makeScheduledPayment(payee, address(0), address(usdc), payAmount, 3, block.timestamp, 7 days, false)
        );

        // Triggerless → callable by anyone; the shortfall is unstaked from the staked reserve
        // straight to the payee in the same call.
        vm.prank(makeAddr("caller"));
        vault.payScheduled(id, _arr(address(impl)));

        assertEq(usdc.balanceOf(payee), payAmount, "payee received the scheduled amount");
        // The pulled funds transit the vault but are fully paid out, so its net balance ends at 0.
        assertEq(usdc.balanceOf(address(vault)), 0, "pulled funds were fully paid out");
    }

    function test_payScheduledFromLending_deliversToPayee() public {
        _initializeVault();
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockLendingProtocol impl = new MockLendingProtocol();
        address payee = makeAddr("payrollScheduledPayment");
        _setupSuppliedReserve(usdc, impl, 800e6);

        uint256 payAmount = 300e6;
        vm.prank(ownerAddress);
        uint256 id = _addScheduledPayment(
            _makeScheduledPayment(payee, address(0), address(usdc), payAmount, 2, block.timestamp, 7 days, false)
        );

        // The shortfall is withdrawn from the lending position straight to the payee in the same call.
        vm.prank(makeAddr("caller"));
        vault.payScheduled(id, _arr(address(impl)));

        assertEq(usdc.balanceOf(payee), payAmount, "payee received the scheduled amount");
        // The pulled funds transit the vault but are fully paid out, so its net balance ends at 0.
        assertEq(usdc.balanceOf(address(vault)), 0, "pulled funds were fully paid out");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Subscription model. Like a card subscription, the merchant is both the payee
    // and the trigger: the merchant initiates each charge and pays its own gas, so
    // the subscriber's vault can be fully invested (zero free balance) and never
    // needs to cover a relayer fee. These pin down that model and its guardrails.
    // ─────────────────────────────────────────────────────────────────────────

    function test_subscription_merchantTriggerChargesFullyInvestedVault() public {
        _initializeVault();
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockLendingProtocol impl = new MockLendingProtocol();
        address merchant = makeAddr("merchant");

        // Subscriber's vault is 100% invested — every USDC is supplied, none sits free.
        _setupSuppliedReserve(usdc, impl, 1_000e6);
        assertEq(usdc.balanceOf(address(vault)), 0, "vault holds no free balance");

        uint256 monthly = 30e6;
        vm.prank(ownerAddress);
        uint256 subId = _addScheduledPayment(
            _makeScheduledPayment(merchant, merchant, address(usdc), monthly, 12, block.timestamp, 30 days, false)
        );

        // The merchant submits the charge and is msg.sender, so the merchant pays the gas — no
        // relayer, no vault gas budget, no free stablecoin required. The cycle is sourced straight
        // from the position to the merchant.
        vm.prank(merchant);
        vault.payScheduled(subId, _arr(address(impl)));

        assertEq(usdc.balanceOf(merchant), monthly, "merchant charged exactly one cycle");
        assertEq(usdc.balanceOf(address(vault)), 0, "vault still holds no free balance");
    }

    function test_subscription_onlyMerchantTriggerCanCharge() public {
        _initializeVault();
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockLendingProtocol impl = new MockLendingProtocol();
        address merchant = makeAddr("merchant");
        _setupSuppliedReserve(usdc, impl, 1_000e6);

        vm.prank(ownerAddress);
        uint256 subId = _addScheduledPayment(
            _makeScheduledPayment(merchant, merchant, address(usdc), 30e6, 12, block.timestamp, 30 days, false)
        );

        // Only the named trigger may charge; a stranger cannot pull the subscription.
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(ScheduledPaymentTriggerError.selector);
        vault.payScheduled(subId, _arr(address(impl)));
    }

    function test_subscription_chargeCannotExceedScheduledAmount() public {
        _initializeVault();
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockLendingProtocol impl = new MockLendingProtocol();
        address merchant = makeAddr("merchant");
        _setupSuppliedReserve(usdc, impl, 1_000e6);

        uint256 monthly = 30e6;
        vm.prank(ownerAddress);
        uint256 subId = _addScheduledPayment(
            _makeScheduledPayment(merchant, merchant, address(usdc), monthly, 12, block.timestamp, 30 days, false)
        );

        // Even though the merchant lists the position, only the cycle's amount is withdrawn — the
        // caller can't force an oversized exit. The rest of the position stays invested.
        vm.prank(merchant);
        vault.payScheduled(subId, _arr(address(impl)));

        assertEq(usdc.balanceOf(merchant), monthly, "merchant received only the cycle amount");
        assertEq(
            IVaultFull(payable(address(vault))).getBalances(_arr(address(impl)), _arr(address(usdc)))[0],
            1_000e6 - monthly,
            "position drawn down by exactly one cycle, not drained"
        );
    }

    function test_subscription_triggerCannotRewriteRecipientOrAmount() public {
        _initializeVault();
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockLendingProtocol impl = new MockLendingProtocol();
        address merchant = makeAddr("merchant");
        _setupSuppliedReserve(usdc, impl, 1_000e6);

        vm.prank(ownerAddress);
        uint256 subId = _addScheduledPayment(
            _makeScheduledPayment(merchant, merchant, address(usdc), 30e6, 12, block.timestamp, 30 days, false)
        );

        // A trigger's only power is to execute the pre-authorised pull. Even a compromised merchant
        // cannot point the subscription at itself for a bigger amount or a new payee — rewriting a
        // payment is owner-only, so the merchant is rejected before it can touch the entry.
        address attacker = makeAddr("attacker");
        IBittyV1Vault.ScheduledPayment[] memory tampered = new IBittyV1Vault.ScheduledPayment[](1);
        tampered[0] =
            _makeScheduledPayment(attacker, merchant, address(usdc), 1_000e6, 12, block.timestamp, 30 days, false);
        vm.prank(merchant);
        vm.expectRevert(NotPayoutOperator.selector);
        vault.updateScheduledPayments(_oneU(subId), tampered);
    }

    function test_payScheduled_nativePaymentFundedFromPosition() public {
        _initializeVault();
        MockLendingProtocol impl = new MockLendingProtocol();
        address payee = makeAddr("nativePayee");

        // Supply WETH (backed by real ETH so it can be unwrapped) into the position, leaving the
        // vault with zero free WETH.
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddProtocols(address(BittyV1Guard(guardAddress)), _arr(address(impl)));
        vm.stopPrank();
        vm.prank(ownerAddress);
        IVaultFull(payable(address(vault))).updateProtocols(_arr(address(impl)), new address[](0));
        _fundVaultWeth(3 ether);
        vm.prank(assetManagerAddress);
        IVaultFull(payable(address(vault))).deposit(address(impl), address(weth), 3 ether);
        assertEq(weth.balanceOf(address(vault)), 0, "vault holds no free WETH");

        // A native (address(0)) payment: the shortfall is pulled from the WETH position into the
        // vault, unwrapped, and the recipient receives real ETH — not WETH.
        vm.prank(ownerAddress);
        uint256 id = _addScheduledPayment(
            _makeScheduledPayment(payee, address(0), address(0), 1 ether, 3, block.timestamp, 7 days, false)
        );

        uint256 payeeEthBefore = payee.balance;
        vault.payScheduled(id, _arr(address(impl)));

        assertEq(payee.balance - payeeEthBefore, 1 ether, "payee received real ETH");
        assertEq(address(vault).balance, 0, "no leftover ETH stuck in the vault");
        assertEq(weth.balanceOf(address(vault)), 0, "no leftover WETH stuck in the vault");
    }

    function test_payScheduled_skipsZeroAndEmptyProtocols() public {
        _initializeVault();
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockLendingProtocol impl = new MockLendingProtocol();
        address payee = makeAddr("payee");
        _setupSuppliedReserve(usdc, impl, 1_000e6);

        uint256 pay = 30e6;
        vm.prank(ownerAddress);
        uint256 id = _addScheduledPayment(
            _makeScheduledPayment(payee, payee, address(usdc), pay, 12, block.timestamp, 30 days, false)
        );

        // The list leads with a zero address and an unregistered protocol (no clone, zero balance);
        // both are skipped, and the real position covers the charge.
        address[] memory protocols = new address[](3);
        protocols[0] = address(0);
        protocols[1] = makeAddr("unregistered");
        protocols[2] = address(impl);
        vm.prank(payee);
        vault.payScheduled(id, protocols);

        assertEq(usdc.balanceOf(payee), pay, "charge covered from the real position after skipping the rest");
    }

    function test_payScheduled_skipsUnfundedPayWithInsufficientBalanceAndNoProtocols() public {
        _initializeVault();
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        address payee = makeAddr("payee");

        // payWithInsufficientBalance, zero on-hand balance, no protocols supplied → the call is a
        // silent no-op: nothing paid, no revert, and the payment count is left intact.
        IBittyV1Vault.ScheduledPayment memory sp = IBittyV1Vault.ScheduledPayment({
            recipient: payee,
            trigger: address(0),
            assetAddress: address(usdc),
            amount: 100e6,
            remainingPaymentCount: 2,
            startTimestamp: block.timestamp,
            paymentInterval: 0,
            isImmutable: false,
            payWithInsufficientBalance: true
        });
        vm.prank(ownerAddress);
        uint256 id = _addScheduledPayment(sp);

        vault.payScheduled(id, new address[](0));
        assertEq(usdc.balanceOf(payee), 0, "nothing was paid");

        // Count untouched: once funded, the payment still has both cycles available.
        usdc.mint(address(vault), 100e6);
        vault.payScheduled(id, new address[](0));
        assertEq(usdc.balanceOf(payee), 100e6, "first real cycle pays");
    }

    function test_send_sourcesFromLendingPosition() public {
        _initializeVault();
        MockERC20 usdc = _addStableCoin(6);
        MockLendingProtocol impl = new MockLendingProtocol();
        address payee = makeAddr("payee");
        _setupSuppliedReserve(usdc, impl, 1_000e6);
        assertEq(usdc.balanceOf(address(vault)), 0, "vault holds no free balance");

        uint256 amount = 400e6;
        vm.prank(ownerAddress);
        vault.batchSend(_arr(payee), _arr(address(usdc)), _amounts(amount), _arr(address(impl)), _amounts(amount));

        assertEq(usdc.balanceOf(payee), amount, "payee paid from the lending position");
        assertEq(usdc.balanceOf(address(vault)), 0, "no residual in the vault");
    }

    function test_send_sourcesFromStakingPosition() public {
        _initializeVault();
        MockERC20 usdc = _addStableCoin(6);
        MockStakingProtocol impl = new MockStakingProtocol();
        address payee = makeAddr("payee");
        _setupStakedReserve(usdc, impl, 1_000e6);
        assertEq(usdc.balanceOf(address(vault)), 0, "vault holds no free balance");

        uint256 amount = 250e6;
        vm.prank(ownerAddress);
        vault.batchSend(_arr(payee), _arr(address(usdc)), _amounts(amount), _arr(address(impl)), _amounts(amount));

        assertEq(usdc.balanceOf(payee), amount, "payee paid from the staked position");
        assertEq(usdc.balanceOf(address(vault)), 0, "no residual in the vault");
    }

    function test_payScheduled_revertsWhenBalanceAndPositionsCannotCover() public {
        _initializeVault();
        MockERC20 usdc = _addStableCoin(6);
        MockLendingProtocol impl = new MockLendingProtocol();
        address payee = makeAddr("payee");
        // Position holds 40, payment needs 100, vault holds nothing: 40 < 100 and the payment is
        // strict, so the shortfall can't be met and the whole call reverts.
        _setupSuppliedReserve(usdc, impl, 40e6);
        vm.prank(ownerAddress);
        uint256 id = _addScheduledPayment(
            _makeScheduledPayment(payee, address(0), address(usdc), 100e6, 1, block.timestamp, 0, false)
        );
        vm.expectRevert(InsufficientBalance.selector);
        vault.payScheduled(id, _arr(address(impl)));
    }

    function test_fallback_delegatesViewCallsToDeFiFacet() public {
        _initializeVault();
        MockERC20 usdc = _addStableCoin(6);
        MockLendingProtocol impl = new MockLendingProtocol();
        _setupSuppliedReserve(usdc, impl, 100e6);
        assertEq(IVaultFull(payable(address(vault))).getBalances(_arr(address(impl)), _arr(address(usdc)))[0], 100e6);
    }

    function test_fallback_bubblesRevertFromDeFiFacet() public {
        _initializeVault();
        vm.prank(assetManagerAddress);
        vm.expectRevert(InvalidDepositableProtocol.selector);
        IVaultFull(payable(address(vault))).deposit(makeAddr("unknownLending"), address(weth), 1);
    }

    // ─── Owner-as-manager one-tx yield (simple*) ───────────────────────────────

    function _grantOwnerAsAssetManager() internal {
        vm.prank(ownerAddress);
        vault.setAssetManager(ownerAddress, 0);
    }

    function _autoYieldRoute(address asset, address protocol) internal pure returns (AutoYield[] memory routes) {
        routes = new AutoYield[](1);
        routes[0] = AutoYield({asset: asset, protocol: protocol});
    }

    function test_supply_requiresTheProtocolToBeListed() public {
        _initializeVault();
        _grantOwnerAsAssetManager();
        MockERC20 usdc = _addStableCoin(6);
        MockLendingProtocol impl = new MockLendingProtocol();
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddProtocols(address(BittyV1Guard(guardAddress)), _arr(address(impl)));
        vm.stopPrank();

        uint256 amount = 500e6;
        usdc.mint(address(vault), amount);
        assertEq(vaultProtocols(guardAddress, address(vault)).length, 0);

        // Supplying into a protocol this vault has not listed is refused: an empty list permits
        // nothing, and `supply` is an ASSET MANAGER path, so it must not be able to widen the list.
        vm.prank(ownerAddress);
        vm.expectRevert(InvalidDepositableProtocol.selector);
        IVaultFull(payable(address(vault))).deposit(address(impl), address(usdc), amount);

        // The owner lists it, and only then does the supply go through.
        vm.prank(ownerAddress);
        IVaultFull(payable(address(vault))).updateProtocols(_arr(address(impl)), new address[](0));

        vm.prank(ownerAddress);
        IVaultFull(payable(address(vault))).deposit(address(impl), address(usdc), amount);

        assertEq(vaultProtocols(guardAddress, address(vault)).length, 1, "listed, and only that");
        assertEq(IVaultFull(payable(address(vault))).getBalances(_arr(address(impl)), _arr(address(usdc)))[0], amount);
    }

    function test_stake_requiresTheProtocolToBeListed() public {
        _initializeVault();
        _grantOwnerAsAssetManager();
        MockERC20 usdc = _addStableCoin(6);
        MockStakingProtocol impl = new MockStakingProtocol();
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddProtocols(address(BittyV1Guard(guardAddress)), _arr(address(impl)));
        vm.stopPrank();

        uint256 amount = 300e6;
        usdc.mint(address(vault), amount);
        assertEq(vaultProtocols(guardAddress, address(vault)).length, 0);

        vm.prank(ownerAddress);
        IVaultFull(payable(address(vault))).updateProtocols(_arr(address(impl)), new address[](0));

        vm.prank(ownerAddress);
        IVaultFull(payable(address(vault))).deposit(address(impl), address(usdc), amount);

        assertEq(vaultProtocols(guardAddress, address(vault)).length, 1, "listed, and only that");
        assertGt(IVaultFull(payable(address(vault))).getBalances(_arr(address(impl)), _arr(address(usdc)))[0], 0);
    }

    function test_clearRouteThenWithdraw() public {
        _initializeVault();
        _grantOwnerAsAssetManager();
        MockERC20 usdc = _addStableCoin(6);
        MockLendingProtocol impl = new MockLendingProtocol();
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddProtocols(address(BittyV1Guard(guardAddress)), _arr(address(impl)));
        vm.stopPrank();
        // The vault must LIST the protocol before it may be used — an empty list permits nothing.
        vm.prank(ownerAddress);
        IVaultFull(payable(address(vault))).updateProtocols(_arr(address(impl)), new address[](0));

        uint256 amount = 1_000e6;
        usdc.mint(address(vault), amount);
        vm.startPrank(ownerAddress);
        IVaultFull(payable(address(vault))).deposit(address(impl), address(usdc), amount);
        vault.setAutoYieldings(_autoYieldRoute(address(usdc), address(impl)));
        address[] memory routed = vault.getAutoYieldings(_arr(address(usdc)));
        assertEq(routed[0], address(impl));

        vault.setAutoYieldings(_autoYieldRoute(address(usdc), address(0)));
        IVaultFull(payable(address(vault))).withdraw(address(impl), address(usdc), 400e6);
        routed = vault.getAutoYieldings(_arr(address(usdc)));
        assertEq(routed[0], address(0));
        vm.stopPrank();

        assertGe(usdc.balanceOf(address(vault)), 400e6);
    }

    function test_clearRouteThenUnstake() public {
        _initializeVault();
        _grantOwnerAsAssetManager();
        MockERC20 usdc = _addStableCoin(6);
        MockStakingProtocol impl = new MockStakingProtocol();
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddProtocols(address(BittyV1Guard(guardAddress)), _arr(address(impl)));
        vm.stopPrank();
        // The vault must LIST the protocol before it may be used — an empty list permits nothing.
        vm.prank(ownerAddress);
        IVaultFull(payable(address(vault))).updateProtocols(_arr(address(impl)), new address[](0));

        uint256 amount = 800e6;
        usdc.mint(address(vault), amount);
        vm.startPrank(ownerAddress);
        IVaultFull(payable(address(vault))).deposit(address(impl), address(usdc), amount);
        vault.setAutoYieldings(_autoYieldRoute(address(usdc), address(impl)));
        address[] memory routed = vault.getAutoYieldings(_arr(address(usdc)));
        assertEq(routed[0], address(impl));

        vault.setAutoYieldings(_autoYieldRoute(address(usdc), address(0)));
        IVaultFull(payable(address(vault))).withdraw(address(impl), address(usdc), 250e6);
        routed = vault.getAutoYieldings(_arr(address(usdc)));
        assertEq(routed[0], address(0));
        vm.stopPrank();

        assertGe(usdc.balanceOf(address(vault)), 250e6);
    }

    function test_supply_revertsWhenCallerIsNotAssetManager() public {
        _initializeVault();
        MockERC20 usdc = _addStableCoin(6);
        MockLendingProtocol impl = new MockLendingProtocol();
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddProtocols(address(BittyV1Guard(guardAddress)), _arr(address(impl)));
        vm.stopPrank();
        usdc.mint(address(vault), 100e6);
        vm.prank(ownerAddress);
        vm.expectRevert(NotAssetManager.selector);
        IVaultFull(payable(address(vault))).deposit(address(impl), address(usdc), 100e6);
    }

    function test_supply_repeatsOnceListed() public {
        _initializeVault();
        _grantOwnerAsAssetManager();
        MockERC20 usdc = _addStableCoin(6);
        MockLendingProtocol impl = new MockLendingProtocol();
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddProtocols(address(BittyV1Guard(guardAddress)), _arr(address(impl)));
        vm.stopPrank();
        // The vault must LIST the protocol before it may be used — an empty list permits nothing.
        vm.prank(ownerAddress);
        IVaultFull(payable(address(vault))).updateProtocols(_arr(address(impl)), new address[](0));

        usdc.mint(address(vault), 700e6);
        vm.startPrank(ownerAddress);
        IVaultFull(payable(address(vault))).deposit(address(impl), address(usdc), 500e6);
        assertEq(vaultProtocols(guardAddress, address(vault)).length, 1, "listing once is enough for repeats");
        IVaultFull(payable(address(vault))).deposit(address(impl), address(usdc), 200e6);
        vm.stopPrank();

        assertEq(IVaultFull(payable(address(vault))).getBalances(_arr(address(impl)), _arr(address(usdc)))[0], 700e6);
    }

    function test_withdrawLeavesTheRouteAlone() public {
        _initializeVault();
        _grantOwnerAsAssetManager();
        MockERC20 usdc = _addStableCoin(6);
        MockLendingProtocol impl = new MockLendingProtocol();
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddProtocols(address(BittyV1Guard(guardAddress)), _arr(address(impl)));
        vm.stopPrank();
        // The vault must LIST the protocol before it may be used — an empty list permits nothing.
        vm.prank(ownerAddress);
        IVaultFull(payable(address(vault))).updateProtocols(_arr(address(impl)), new address[](0));

        usdc.mint(address(vault), 1_000e6);
        vm.startPrank(ownerAddress);
        IVaultFull(payable(address(vault))).deposit(address(impl), address(usdc), 1_000e6);
        vault.setAutoYieldings(_autoYieldRoute(address(usdc), address(impl)));
        IVaultFull(payable(address(vault))).withdraw(address(impl), address(usdc), 200e6);
        address[] memory routed = vault.getAutoYieldings(_arr(address(usdc)));
        assertEq(routed[0], address(impl));
        vm.stopPrank();
    }

    /**
     * The facet is published by the vault itself now that the factory no longer keeps a copy.
     */
    function test_vaultPublishesItsOwnFacet() public {
        _initializeVault();
        assertEq(vault.DEFI_FACET(), defiFacet, "readable from the vault, never stale");
    }

    /**
     * The trigger is baked into the implementation, so every vault of a generation reports the same one.
     */
    function test_getAutoYieldTrigger_returnsTheImplementationKeeper() public {
        _initializeVault();
        assertEq(vault.AUTO_YIELD_KEEPER(), address(0xA07E1D));
    }

    function test_fallback_delegatesMutatingCallToDeFiFacet() public {
        _initializeVault();
        MockERC20 usdc = _addStableCoin(6);
        MockLendingProtocol impl = new MockLendingProtocol();
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddProtocols(address(BittyV1Guard(guardAddress)), _arr(address(impl)));
        vm.stopPrank();
        vm.prank(ownerAddress);
        IVaultFull(payable(address(vault))).updateProtocols(_arr(address(impl)), new address[](0));

        usdc.mint(address(vault), 50e6);
        vm.prank(assetManagerAddress);
        IVaultFull(payable(address(vault))).deposit(address(impl), address(usdc), 50e6);
        assertEq(IVaultFull(payable(address(vault))).getBalances(_arr(address(impl)), _arr(address(usdc)))[0], 50e6);
    }

    // ─── Unlimited scheduled payment ───────────────────────────────────────────

    function test_ScheduledPayment_maxPaymentCountIsUnlimited() public {
        _initializeVault();
        address to = makeAddr("unlimited");
        uint256 amount = 0.01 ether;
        uint256 start = block.timestamp;
        IBittyV1Vault.ScheduledPayment memory r =
            _makeScheduledPayment(to, address(0), address(weth), amount, type(uint256).max, start, 7 days, false);
        vm.prank(ownerAddress);
        uint256 uId = _addScheduledPayment(r);

        // Pay 260 times to exercise the unlimited (type(uint256).max) sentinel: the count never
        // decrements and so never runs out.
        uint256 payments = 260;
        deal(address(weth), address(vault), payments * amount);
        _payScheduled(_oneU(uId));
        for (uint256 i = 1; i < payments; i++) {
            vm.warp(start + i * 7 days);
            _payScheduled(_oneU(uId));
        }
        assertEq(weth.balanceOf(to), payments * amount);
    }

    // ─── Whitelisted recipients ────────────────────────────────────────────────

    function test_WhitelistedRecipient_addAndGet() public {
        _initializeVault();
        address to = makeAddr("wlr");
        vm.prank(ownerAddress);
        uint256 bobIdWr = _addWhitelistedRecipient(to, address(weth));

        (address recipient, address allowedAsset) = _getWlOne(bobIdWr);
        assertEq(recipient, to);
        assertEq(allowedAsset, address(weth));
    }

    function test_WhitelistedRecipient_addRevertsOnZeroRecipient() public {
        _initializeVault();
        vm.prank(ownerAddress);
        vm.expectRevert(AddressZero.selector);
        uint256 bobIdWr = _addWhitelistedRecipient(address(0), address(0));
    }

    function test_WhitelistedRecipient_updateChangesEntry() public {
        _initializeVault();
        address to1 = makeAddr("to1");
        address to2 = makeAddr("to2");
        vm.startPrank(ownerAddress);
        uint256 bobIdWr = _addWhitelistedRecipient(to1, address(weth));
        _updateWhitelistedRecipient(bobIdWr, to2, address(0));
        vm.stopPrank();

        (address recipient, address allowedAsset) = _getWlOne(bobIdWr);
        assertEq(recipient, to2);
        assertEq(allowedAsset, address(0));
    }

    function test_WhitelistedRecipient_updateRevertsWhenNotFound() public {
        _initializeVault();
        vm.prank(ownerAddress);
        vm.expectRevert(WhitelistedRecipientNotFound.selector);
        _updateWhitelistedRecipient(99999, makeAddr("to"), address(0));
    }

    function test_WhitelistedRecipient_anyAssetWhenAllowedAssetZero() public {
        _initializeVault();
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        address to = makeAddr("wlr");
        vm.prank(ownerAddress);
        uint256 bobIdWr = _addWhitelistedRecipient(to, address(0));

        deal(address(weth), address(vault), 1 ether);
        usdc.mint(address(vault), 5_000e6);

        vm.startPrank(ownerAddress);
        _sendWl(bobIdWr, address(weth), 1 ether);
        _sendWl(bobIdWr, address(usdc), 5_000e6);
        vm.stopPrank();

        assertEq(weth.balanceOf(to), 1 ether);
        assertEq(usdc.balanceOf(to), 5_000e6);
    }

    // Two scalar calls pay two whitelisted recipients (plain vault-balance payout).
    function test_sendToWhitelistedRecipient_paysMultipleAcrossCalls() public {
        _initializeVault();
        MockERC20 usdc = _addStableCoin(6);
        address a = makeAddr("wlA");
        address b = makeAddr("wlB");
        deal(address(weth), address(vault), 1 ether);
        usdc.mint(address(vault), 5_000e6);

        vm.startPrank(ownerAddress);
        uint256 idA = _addWhitelistedRecipient(a, address(weth));
        uint256 idB = _addWhitelistedRecipient(b, address(usdc));

        uint256[] memory ids = new uint256[](2);
        ids[0] = idA;
        ids[1] = idB;
        address[] memory assets = new address[](2);
        assets[0] = address(weth);
        assets[1] = address(usdc);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1 ether;
        amounts[1] = 5_000e6;

        vault.sendToWhitelistedRecipient(ids[0], assets[0], amounts[0], new address[](0), new uint256[](0));
        vault.sendToWhitelistedRecipient(ids[1], assets[1], amounts[1], new address[](0), new uint256[](0));
        vm.stopPrank();

        assertEq(weth.balanceOf(a), 1 ether);
        assertEq(usdc.balanceOf(b), 5_000e6);
    }

    function test_WhitelistedRecipient_sourcesFromLendingPosition() public {
        _initializeVault();
        MockERC20 usdc = _addStableCoin(6);
        MockLendingProtocol impl = new MockLendingProtocol();
        address to = makeAddr("wlr");
        vm.prank(ownerAddress);
        uint256 wId = _addWhitelistedRecipient(to, address(usdc));
        _setupSuppliedReserve(usdc, impl, 1_000e6);
        assertEq(usdc.balanceOf(address(vault)), 0, "vault holds no free balance");

        uint256 amount = 400e6;
        vm.prank(ownerAddress);
        vault.sendToWhitelistedRecipient(wId, address(usdc), amount, _oneAddr(address(impl)), _oneU(amount));

        assertEq(usdc.balanceOf(to), amount, "recipient paid from the lending position");
        assertEq(usdc.balanceOf(address(vault)), 0, "no residual in the vault");
    }

    function test_WhitelistedRecipient_sourcesFromStakingPosition() public {
        _initializeVault();
        MockERC20 usdc = _addStableCoin(6);
        MockStakingProtocol impl = new MockStakingProtocol();
        address to = makeAddr("wlr");
        vm.prank(ownerAddress);
        uint256 wId = _addWhitelistedRecipient(to, address(usdc));
        _setupStakedReserve(usdc, impl, 1_000e6);
        assertEq(usdc.balanceOf(address(vault)), 0, "vault holds no free balance");

        uint256 amount = 250e6;
        vm.prank(ownerAddress);
        vault.sendToWhitelistedRecipient(wId, address(usdc), amount, _oneAddr(address(impl)), _oneU(amount));

        assertEq(usdc.balanceOf(to), amount, "recipient paid from the staked position");
        assertEq(usdc.balanceOf(address(vault)), 0, "no residual in the vault");
    }

    function test_WhitelistedRecipient_sendRevertsOnZeroAmount() public {
        _initializeVault();
        address to = makeAddr("wlr");
        vm.prank(ownerAddress);
        uint256 wId = _addWhitelistedRecipient(to, address(weth));
        deal(address(weth), address(vault), 1 ether);

        vm.prank(ownerAddress);
        vm.expectRevert(AmountIsZero.selector);
        _sendWl(wId, address(weth), 0);
    }

    function test_WhitelistedRecipient_restrictsToAllowedAsset() public {
        _initializeVault();
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        address to = makeAddr("wlr");
        vm.prank(ownerAddress);
        uint256 bobIdWr = _addWhitelistedRecipient(to, address(weth));

        deal(address(weth), address(vault), 1 ether);
        usdc.mint(address(vault), 5_000e6);

        vm.prank(ownerAddress);
        vm.expectRevert(WhitelistedRecipientAssetNotAllowed.selector);
        _sendWl(bobIdWr, address(usdc), 5_000e6);

        vm.prank(ownerAddress);
        _sendWl(bobIdWr, address(weth), 1 ether);
        assertEq(weth.balanceOf(to), 1 ether);
    }

    function test_WhitelistedRecipient_revertsWhenNotFound() public {
        _initializeVault();
        deal(address(weth), address(vault), 1 ether);
        vm.prank(ownerAddress);
        vm.expectRevert(WhitelistedRecipientNotFound.selector);
        _sendWl(99999, address(weth), 1 ether);
    }

    function test_WhitelistedRecipient_remove() public {
        _initializeVault();
        address to = makeAddr("wlr");
        vm.startPrank(ownerAddress);
        uint256 bobIdWr = _addWhitelistedRecipient(to, address(0));
        _removeWhitelistedRecipient(bobIdWr);
        vm.stopPrank();

        (address recipient,) = _getWlOne(bobIdWr);
        assertEq(recipient, address(0));

        deal(address(weth), address(vault), 1 ether);
        vm.prank(ownerAddress);
        vm.expectRevert(WhitelistedRecipientNotFound.selector);
        _sendWl(bobIdWr, address(weth), 1 ether);
    }

    function test_WhitelistedRecipient_removeRevertsWhenNotFound() public {
        _initializeVault();
        vm.prank(ownerAddress);
        vm.expectRevert(WhitelistedRecipientNotFound.selector);
        _removeWhitelistedRecipient(99999);
    }

    function test_WhitelistedRecipient_onlyOwnerOrPayoutOperator() public {
        _initializeVault();
        address stranger = makeAddr("stranger");
        bytes32 adminRole = bytes32(0);

        vm.startPrank(stranger);
        vm.expectRevert(NotPayoutOperator.selector);
        uint256 bobIdWr = _addWhitelistedRecipient(makeAddr("to"), address(0));
        vm.expectRevert(NotPayoutOperator.selector);
        _updateWhitelistedRecipient(bobIdWr, makeAddr("to"), address(0));
        vm.expectRevert(NotPayoutOperator.selector);
        _removeWhitelistedRecipient(bobIdWr);
        vm.expectRevert(_roleError(stranger, adminRole));
        _sendWl(bobIdWr, address(weth), 1);
        vm.stopPrank();
    }

    // ─── Per-entry, per-function protection (scheduled payments vs whitelisted recipients) ─────────

    function test_WhitelistedRecipient_protectionBlocksThenAllowsAfterWindow() public {
        _initializeVault();
        uint256 protection = 3 days;
        address to = makeAddr("wlr");

        vm.startPrank(ownerAddress);
        _setNewPaymentProtection(protection);
        uint256 bobIdWr = _addWhitelistedRecipient(to, address(weth));
        vm.stopPrank();

        deal(address(weth), address(vault), 1 ether);

        vm.prank(ownerAddress);
        vm.expectRevert(ProtectionPeriodNotEnded.selector);
        _sendWl(bobIdWr, address(weth), 1 ether);

        vm.warp(block.timestamp + protection);
        vm.prank(ownerAddress);
        _sendWl(bobIdWr, address(weth), 1 ether);
        assertEq(weth.balanceOf(to), 1 ether);
    }

    function test_WhitelistedRecipient_noProtectionWhenDisabled() public {
        _initializeVault();
        address to = makeAddr("wlr");
        vm.prank(ownerAddress);
        uint256 bobIdWr = _addWhitelistedRecipient(to, address(weth));

        deal(address(weth), address(vault), 1 ether);
        vm.prank(ownerAddress);
        _sendWl(bobIdWr, address(weth), 1 ether);
        assertEq(weth.balanceOf(to), 1 ether);
    }

    function test_WhitelistedRecipient_removeThenReAddArmsFreshWindow() public {
        _initializeVault();
        uint256 protection = 2 days;
        address to = makeAddr("wlr");

        vm.startPrank(ownerAddress);
        _setNewPaymentProtection(protection);
        uint256 bobIdWr = _addWhitelistedRecipient(to, address(weth));
        _removeWhitelistedRecipient(bobIdWr);
        bobIdWr = _addWhitelistedRecipient(to, address(weth));
        vm.stopPrank();

        deal(address(weth), address(vault), 1 ether);

        vm.prank(ownerAddress);
        vm.expectRevert(ProtectionPeriodNotEnded.selector);
        _sendWl(bobIdWr, address(weth), 1 ether);

        vm.warp(block.timestamp + protection);
        vm.prank(ownerAddress);
        _sendWl(bobIdWr, address(weth), 1 ether);
        assertEq(weth.balanceOf(to), 1 ether);
    }

    // Scheduled payments and whitelisted recipients both derive their per-entry protection window from
    // the single newPaymentProtection, but each entry's deadline is tracked independently per id: with
    // one protection set, both are blocked during the shared window and both become payable after it.
    function test_Protection_scheduledAndWhitelistedUseTheirOwnDuration() public {
        _initializeVault();
        address payee = makeAddr("payee");
        uint256 base = 1_000_000;
        vm.warp(base);

        vm.startPrank(ownerAddress);
        _setNewPaymentProtection(3 days);
        IBittyV1Vault.ScheduledPayment memory sp =
            _makeScheduledPayment(payee, address(0), address(weth), 1 ether, 1, block.timestamp, 0, false);
        uint256 spId = _addScheduledPayment(sp);
        uint256 wlId = _addWhitelistedRecipient(payee, address(weth));
        vm.stopPrank();

        deal(address(weth), address(vault), 2 ether);

        // Within the shared window both entries are blocked (each tracked by its own id).
        vm.expectRevert(ProtectionPeriodNotEnded.selector);
        _payScheduled(_oneU(spId));
        vm.prank(ownerAddress);
        vm.expectRevert(ProtectionPeriodNotEnded.selector);
        _sendWl(wlId, address(weth), 1 ether);

        // After the window both are payable.
        vm.warp(base + 3 days + 1);
        _payScheduled(_oneU(spId));
        assertEq(weth.balanceOf(payee), 1 ether);
        vm.prank(ownerAddress);
        _sendWl(wlId, address(weth), 1 ether);
        assertEq(weth.balanceOf(payee), 2 ether);
    }

    // Each entry has its own window: two whitelist entries for the same address are independent, so
    // removing one never affects the other's protection.
    function test_Protection_perEntryIndependent() public {
        _initializeVault();
        uint256 protection = 7 days;
        address payee = makeAddr("payee");
        deal(address(weth), address(vault), 1 ether);

        vm.startPrank(ownerAddress);
        _setNewPaymentProtection(protection);
        uint256 aId = _addWhitelistedRecipient(payee, address(0));
        uint256 bId = _addWhitelistedRecipient(payee, address(0));
        _removeWhitelistedRecipient(bId); // does not touch aId's window
        vm.expectRevert(ProtectionPeriodNotEnded.selector);
        _sendWl(aId, address(weth), 1 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + protection);
        vm.prank(ownerAddress);
        _sendWl(aId, address(weth), 1 ether);
        assertEq(weth.balanceOf(payee), 1 ether);
    }

    // The protection window is exactly the delete opportunity: a still-protected entry can be removed
    // mid-window, after which it no longer exists.
    function test_Protection_deleteDuringWindowRemovesEntry() public {
        _initializeVault();
        vm.startPrank(ownerAddress);
        _setNewPaymentProtection(3 days);
        IBittyV1Vault.ScheduledPayment memory sp =
            _makeScheduledPayment(makeAddr("payee"), address(0), address(weth), 1 ether, 1, block.timestamp, 0, false);
        uint256 spId = _addScheduledPayment(sp);
        _removeScheduledPayment(spId); // deleted while still in its protection window
        vm.stopPrank();

        deal(address(weth), address(vault), 1 ether);
        vm.expectRevert(ScheduledPaymentNotFound.selector);
        _payScheduled(_oneU(spId));
    }

    // ─── Payout operator: propose → owner approve ───────────────────────────────

    function _oneAddr(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _oneU(uint256 v) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = v;
    }

    // Plain vault-balance payScheduled (no yield-position sourcing).
    function _payScheduled(uint256[] memory ids) internal {
        for (uint256 i = 0; i < ids.length; i++) {
            vault.payScheduled(ids[i], new address[](0));
        }
    }

    function _oneB(bytes32 v) internal pure returns (bytes32[] memory arr) {
        arr = new bytes32[](1);
        arr[0] = v;
    }

    // A PaymentRisk with all fields UNCHANGED (type(uint256).max); callers set the one they want.
    function _noRiskChange() internal pure returns (IBittyV1Owner.PaymentRisk memory u) {
        u = IBittyV1Owner.PaymentRisk({
            newPaymentProtection: type(uint256).max,
            maxSendValue: type(uint256).max,
            maxSendInterval: type(uint256).max,
            changeTimelock: type(uint256).max
        });
    }

    // Single-field wrappers over updatePaymentRisk (keep vm.prank landing on the vault call).
    function _setNewPaymentProtection(uint256 v) internal {
        IBittyV1Owner.PaymentRisk memory u = _noRiskChange();
        u.newPaymentProtection = v;
        vault.updatePaymentRisk(u);
    }

    function _setMaxSendValue(uint256 v) internal {
        IBittyV1Owner.PaymentRisk memory u = _noRiskChange();
        u.maxSendValue = v;
        vault.updatePaymentRisk(u);
    }

    function _setMaxSendInterval(uint256 v) internal {
        IBittyV1Owner.PaymentRisk memory u = _noRiskChange();
        u.maxSendInterval = v;
        vault.updatePaymentRisk(u);
    }

    function _setChangeTimelock(uint256 v) internal {
        IBittyV1Owner.PaymentRisk memory u = _noRiskChange();
        u.changeTimelock = v;
        vault.updatePaymentRisk(u);
    }

    // Same, but on a specific vault instance (the risk-timelock tests spin up their own).
    function _setNewPaymentProtectionOn(BittyV1Vault vlt, uint256 v) internal {
        IBittyV1Owner.PaymentRisk memory u = _noRiskChange();
        u.newPaymentProtection = v;
        vlt.updatePaymentRisk(u);
    }

    function _setMaxSendValueOn(BittyV1Vault vlt, uint256 v) internal {
        IBittyV1Owner.PaymentRisk memory u = _noRiskChange();
        u.maxSendValue = v;
        vlt.updatePaymentRisk(u);
    }

    function _setChangeTimelockOn(BittyV1Vault vlt, uint256 v) internal {
        IBittyV1Owner.PaymentRisk memory u = _noRiskChange();
        u.changeTimelock = v;
        vlt.updatePaymentRisk(u);
    }

    // Single-item read over the batch getWhitelistedRecipients.
    function _getWlOne(uint256 id) internal view returns (address recipient, address allowedAsset) {
        (address[] memory recipients, address[] memory allowedAssets) = vault.getWhitelistedRecipients(_oneU(id));
        return (recipients[0], allowedAssets[0]);
    }

    // Single-item wrappers over the batch approve functions — internal, so a
    // vm.prank / vm.expectRevert set before the call still lands on the vault call.
    function _approveSend(uint256 id) internal {
        vault.reviewSends(_oneU(id), new uint256[](0));
    }

    function _cancelSend(uint256 id) internal {
        vault.cancelSends(_oneU(id));
    }

    function _approveScheduledPayment(uint256 id, bytes32 h) internal {
        vault.reviewScheduledPayments(_oneU(id), _oneB(h), new uint256[](0));
    }

    function _approveWhitelistedRecipient(uint256 id, bytes32 h) internal {
        vault.reviewWhitelistedRecipients(_oneU(id), _oneB(h), new uint256[](0));
    }

    // Single-item wrappers over the batch payout-operator functions.
    function _oneSP(IBittyV1Vault.ScheduledPayment memory sp)
        internal
        pure
        returns (IBittyV1Vault.ScheduledPayment[] memory arr)
    {
        arr = new IBittyV1Vault.ScheduledPayment[](1);
        arr[0] = sp;
    }

    function _addScheduledPayment(IBittyV1Vault.ScheduledPayment memory sp) internal returns (uint256) {
        // ids is empty when a vm.expectRevert swallows the call; guard so those sites don't OOB-panic.
        uint256[] memory ids = _oneU(vault.addScheduledPayment(sp));
        return ids.length == 0 ? 0 : ids[0];
    }

    function _updateScheduledPayment(uint256 id, IBittyV1Vault.ScheduledPayment memory sp) internal {
        vault.updateScheduledPayments(_oneU(id), _oneSP(sp));
    }

    function _removeScheduledPayment(uint256 id) internal {
        vault.removeScheduledPayments(_oneU(id));
    }

    function _addWhitelistedRecipient(address recipient, address allowedAsset) internal returns (uint256) {
        // ids is empty when a vm.expectRevert swallows the call; guard so those sites don't OOB-panic.
        uint256[] memory ids = _oneU(vault.addWhitelistedRecipient(recipient, allowedAsset));
        return ids.length == 0 ? 0 : ids[0];
    }

    function test_updateWhitelistedRecipients_revertsOnMismatchedArrays() public {
        _initializeVault();
        address payee = makeAddr("payee");
        vm.startPrank(ownerAddress);
        uint256 id = _addWhitelistedRecipient(payee, address(weth));

        vm.expectRevert(ArrayLengthMismatch.selector);
        vault.updateWhitelistedRecipients(_oneU(id), new address[](0), _oneAddr(address(weth)));

        vm.expectRevert(ArrayLengthMismatch.selector);
        vault.updateWhitelistedRecipients(_oneU(id), _oneAddr(payee), new address[](0));
        vm.stopPrank();
    }

    function _updateWhitelistedRecipient(uint256 id, address recipient, address allowedAsset) internal {
        vault.updateWhitelistedRecipients(_oneU(id), _oneAddr(recipient), _oneAddr(allowedAsset));
    }

    function _removeWhitelistedRecipient(uint256 id) internal {
        vault.removeWhitelistedRecipients(_oneU(id));
    }

    function _addPayoutOperator(address op) internal {
        vm.prank(ownerAddress);
        vault.updatePayoutOperator(op, true);
    }

    function _spTo(address to) internal view returns (IBittyV1Vault.ScheduledPayment memory) {
        return _makeScheduledPayment(to, address(0), address(weth), 1 ether, 1, block.timestamp, 0, false);
    }

    function _spHash(IBittyV1Vault.ScheduledPayment memory p) internal pure returns (bytes32) {
        return keccak256(abi.encode(p));
    }

    function _wrHash(address recipient, address allowedAsset) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(IBittyV1Vault.WhitelistedRecipient({recipient: recipient, allowedAsset: allowedAsset}))
            );
    }

    function test_PaymentAssetManager_scheduledPendingUntilApproved() public {
        _initializeVault();
        address pm = makeAddr("pm");
        _addPayoutOperator(pm);
        address to = makeAddr("payee");
        deal(address(weth), address(vault), 10 ether);

        vm.prank(pm);
        uint256 pId = _addScheduledPayment(_spTo(to));

        vm.expectRevert(PaymentNotApproved.selector);
        _payScheduled(_oneU(pId));

        vm.prank(ownerAddress);
        _approveScheduledPayment(pId, _spHash(_spTo(to)));
        _payScheduled(_oneU(pId));
        assertEq(weth.balanceOf(to), 1 ether);
    }

    function test_PaymentAssetManager_ownerCreatedIsAutoApproved() public {
        _initializeVault();
        address to = makeAddr("payee");
        deal(address(weth), address(vault), 10 ether);
        vm.prank(ownerAddress);
        uint256 pId = _addScheduledPayment(_spTo(to));
        _payScheduled(_oneU(pId));
        assertEq(weth.balanceOf(to), 1 ether);
    }

    function test_PaymentAssetManager_whitelistedPendingUntilApproved() public {
        _initializeVault();
        address pm = makeAddr("pm");
        _addPayoutOperator(pm);
        address to = makeAddr("payee");
        deal(address(weth), address(vault), 10 ether);

        vm.prank(pm);
        uint256 wIdWr = _addWhitelistedRecipient(to, address(0));

        vm.prank(ownerAddress);
        vm.expectRevert(PaymentNotApproved.selector);
        _sendWl(wIdWr, address(weth), 1 ether);

        vm.prank(ownerAddress);
        _approveWhitelistedRecipient(wIdWr, _wrHash(to, address(0)));
        vm.prank(ownerAddress);
        _sendWl(wIdWr, address(weth), 1 ether);
        assertEq(weth.balanceOf(to), 1 ether);
    }

    function test_PaymentAssetManager_sendProposalThenApprove() public {
        _initializeVault();
        address pm = makeAddr("pm");
        _addPayoutOperator(pm);
        MockERC20 usdc = _addStableCoin(6);
        address to = makeAddr("payee");
        usdc.mint(address(vault), 10e6);

        vm.prank(pm);
        _send(to, address(usdc), 1e6); // proposal id 0, no transfer
        assertEq(usdc.balanceOf(to), 0);

        vm.prank(ownerAddress);
        _approveSend(0);
        assertEq(usdc.balanceOf(to), 1e6);
    }

    function test_PaymentAssetManager_ownerSendIsImmediate() public {
        _initializeVault();
        address to = makeAddr("payee");
        deal(address(weth), address(vault), 10 ether);
        vm.prank(ownerAddress);
        _send(to, address(weth), 1 ether);
        assertEq(weth.balanceOf(to), 1 ether);
    }

    function test_SendBatch_ownerTransfersMultipleAssetsToMultipleRecipients() public {
        _initializeVault();
        MockERC20 usdc = _addStableCoin(6);
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        deal(address(weth), address(vault), 2 ether);
        usdc.mint(address(vault), 500e6);

        address[] memory recipients = new address[](2);
        recipients[0] = alice;
        recipients[1] = bob;
        address[] memory assets = new address[](2);
        assets[0] = address(weth);
        assets[1] = address(usdc);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 2 ether;
        amounts[1] = 500e6;

        vm.prank(ownerAddress);
        _send(recipients, assets, amounts);

        assertEq(weth.balanceOf(alice), 2 ether);
        assertEq(usdc.balanceOf(bob), 500e6);
    }

    function test_SendBatch_paymentAssetManagerProposalApprovesAtomically() public {
        _initializeVault();
        address pm = makeAddr("pm");
        _addPayoutOperator(pm);
        MockERC20 usdc = _addStableCoin(6);
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        usdc.mint(address(vault), 300e6);

        address[] memory recipients = new address[](2);
        recipients[0] = alice;
        recipients[1] = bob;
        address[] memory assets = new address[](2);
        assets[0] = address(usdc);
        assets[1] = address(usdc);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e6;
        amounts[1] = 200e6;

        vm.prank(pm);
        _send(recipients, assets, amounts);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(bob), 0);

        vm.prank(ownerAddress);
        _approveSend(0);
        assertEq(usdc.balanceOf(alice), 100e6);
        assertEq(usdc.balanceOf(bob), 200e6);
    }

    function test_SendBatch_riskCapAppliesToAggregateBatchValue() public {
        _initializeVault();
        MockERC20 usdc = _addStableCoin(6);
        usdc.mint(address(vault), 1_200e6);
        vm.prank(ownerAddress);
        _setMaxSendValue(1_000);

        address[] memory recipients = new address[](2);
        recipients[0] = makeAddr("alice");
        recipients[1] = makeAddr("bob");
        address[] memory assets = new address[](2);
        assets[0] = address(usdc);
        assets[1] = address(usdc);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 600e6;
        amounts[1] = 600e6;

        vm.prank(ownerAddress);
        vm.expectRevert(PaymentExceedsRiskCap.selector);
        _send(recipients, assets, amounts);
    }

    function test_SendBatch_revertsForEmptyOrMismatchedArrays() public {
        _initializeVault();
        address[] memory recipients = new address[](0);
        address[] memory assets = new address[](0);
        uint256[] memory amounts = new uint256[](0);

        vm.prank(ownerAddress);
        vm.expectRevert(EmptyArray.selector);
        _send(recipients, assets, amounts);

        recipients = _arr(makeAddr("payee"));
        vm.prank(ownerAddress);
        vm.expectRevert(ArrayLengthMismatch.selector);
        _send(recipients, assets, amounts);
    }

    function test_PaymentAssetManager_cancelOwnSendNotOthers() public {
        _initializeVault();
        address pm = makeAddr("pm");
        address pm2 = makeAddr("pm2");
        _addPayoutOperator(pm);
        _addPayoutOperator(pm2);
        MockERC20 usdc = _addStableCoin(6);
        usdc.mint(address(vault), 10e6);

        vm.prank(pm);
        _send(makeAddr("payee"), address(usdc), 1e6); // id 0

        vm.prank(pm2);
        vm.expectRevert(NotProposalOwner.selector);
        _cancelSend(0);

        vm.prank(pm);
        _cancelSend(0);

        vm.prank(ownerAddress);
        vm.expectRevert(PendingSendNotFound.selector);
        _approveSend(0);
    }

    function test_PaymentAssetManager_cannotEditOrRemoveApprovedEntry() public {
        _initializeVault();
        address pm = makeAddr("pm");
        _addPayoutOperator(pm);
        IBittyV1Vault.ScheduledPayment memory r = _spTo(makeAddr("payee"));
        vm.prank(ownerAddress);
        uint256 pId = _addScheduledPayment(r); // owner-created = approved

        r.amount = 2 ether;
        vm.prank(pm);
        vm.expectRevert(NotProposalOwner.selector);
        _updateScheduledPayment(pId, r);

        vm.prank(pm);
        vm.expectRevert(NotProposalOwner.selector);
        _removeScheduledPayment(pId);
    }

    function test_PaymentAssetManager_cancelOwnPendingScheduled() public {
        _initializeVault();
        address pm = makeAddr("pm");
        _addPayoutOperator(pm);
        vm.prank(pm);
        uint256 pId = _addScheduledPayment(_spTo(makeAddr("payee")));
        vm.prank(pm);
        _removeScheduledPayment(pId);

        vm.expectRevert(ScheduledPaymentNotFound.selector);
        _payScheduled(_oneU(pId));
    }

    function test_PaymentAssetManager_onlyOwnerApproves() public {
        _initializeVault();
        address pm = makeAddr("pm");
        _addPayoutOperator(pm);
        vm.prank(pm);
        uint256 pId = _addScheduledPayment(_spTo(makeAddr("payee")));

        bytes32 adminRole = bytes32(0);
        vm.prank(pm);
        vm.expectRevert(_roleError(pm, adminRole));
        _approveScheduledPayment(pId, bytes32(0));
    }

    function test_PaymentAssetManager_approveNonPendingReverts() public {
        _initializeVault();
        vm.prank(ownerAddress);
        uint256 pId = _addScheduledPayment(_spTo(makeAddr("payee"))); // auto-approved

        vm.prank(ownerAddress);
        vm.expectRevert(NotPendingApproval.selector);
        _approveScheduledPayment(pId, _spHash(_spTo(makeAddr("payee"))));
    }

    function test_PaymentAssetManager_ownerCancelsPendingSend() public {
        _initializeVault();
        address pm = makeAddr("pm");
        _addPayoutOperator(pm);
        MockERC20 usdc = _addStableCoin(6);
        usdc.mint(address(vault), 10e6);
        vm.prank(pm);
        _send(makeAddr("payee"), address(usdc), 1e6); // id 0
        vm.prank(ownerAddress);
        _cancelSend(0); // owner cancels a assetManager's proposal
        vm.prank(ownerAddress);
        vm.expectRevert(PendingSendNotFound.selector);
        _approveSend(0);
    }

    function test_PaymentAssetManager_managerEditsOwnPendingScheduled() public {
        _initializeVault();
        address pm = makeAddr("pm");
        _addPayoutOperator(pm);
        address to = makeAddr("payee");
        deal(address(weth), address(vault), 10 ether);
        vm.prank(pm);
        uint256 pId = _addScheduledPayment(_spTo(to));

        IBittyV1Vault.ScheduledPayment memory r2 = _spTo(to);
        r2.amount = 2 ether;
        vm.prank(pm);
        _updateScheduledPayment(pId, r2); // assetManager edits its own still-pending proposal

        vm.expectRevert(PaymentNotApproved.selector);
        _payScheduled(_oneU(pId));

        vm.prank(ownerAddress);
        _approveScheduledPayment(pId, _spHash(r2));
        _payScheduled(_oneU(pId));
        assertEq(weth.balanceOf(to), 2 ether);
    }

    function test_PaymentAssetManager_approveRevertsWhenContentSwappedAfterReview() public {
        _initializeVault();
        address pm = makeAddr("pm");
        _addPayoutOperator(pm);
        address payee = makeAddr("payee");
        deal(address(weth), address(vault), 10 ether);

        vm.prank(pm);
        uint256 pId = _addScheduledPayment(_spTo(payee));

        // owner reviews the benign proposal and captures its content hash
        bytes32 reviewedHash = _spHash(_spTo(payee));

        // proposer front-runs the approval, swapping the payee to itself
        IBittyV1Vault.ScheduledPayment memory swapped = _spTo(pm);
        vm.prank(pm);
        _updateScheduledPayment(pId, swapped);

        // owner's approval bound to the reviewed content now reverts
        vm.prank(ownerAddress);
        vm.expectRevert(ScheduledPaymentContentMismatch.selector);
        _approveScheduledPayment(pId, reviewedHash);

        // approval only succeeds against the current (swapped) content, which the owner would re-review
        vm.prank(ownerAddress);
        _approveScheduledPayment(pId, _spHash(swapped));
        _payScheduled(_oneU(pId));
        assertEq(weth.balanceOf(pm), 1 ether);
    }

    function test_PaymentAssetManager_managerEditsOwnPendingWhitelisted() public {
        _initializeVault();
        address pm = makeAddr("pm");
        _addPayoutOperator(pm);
        address to2 = makeAddr("payee2");
        deal(address(weth), address(vault), 10 ether);
        vm.prank(pm);
        uint256 wIdWr = _addWhitelistedRecipient(makeAddr("payee"), address(0));
        vm.prank(pm);
        _updateWhitelistedRecipient(wIdWr, to2, address(weth)); // edit own pending

        vm.prank(ownerAddress);
        _approveWhitelistedRecipient(wIdWr, _wrHash(to2, address(weth)));
        vm.prank(ownerAddress);
        _sendWl(wIdWr, address(weth), 1 ether);
        assertEq(weth.balanceOf(to2), 1 ether);
    }

    function test_PaymentAssetManager_approveWhitelistedRevertsWhenContentSwappedAfterReview() public {
        _initializeVault();
        address pm = makeAddr("pm");
        _addPayoutOperator(pm);
        address payee = makeAddr("payee");
        deal(address(weth), address(vault), 10 ether);

        vm.prank(pm);
        uint256 wId = _addWhitelistedRecipient(payee, address(0));

        // owner reviews the benign proposal and captures its content hash
        bytes32 reviewedHash = _wrHash(payee, address(0));

        // proposer front-runs the approval, swapping the recipient to itself
        vm.prank(pm);
        _updateWhitelistedRecipient(wId, pm, address(weth));

        // owner's approval bound to the reviewed content now reverts
        vm.prank(ownerAddress);
        vm.expectRevert(WhitelistedRecipientContentMismatch.selector);
        _approveWhitelistedRecipient(wId, reviewedHash);

        // approval only succeeds against the current (swapped) content, which the owner would re-review
        vm.prank(ownerAddress);
        _approveWhitelistedRecipient(wId, _wrHash(pm, address(weth)));
        vm.prank(ownerAddress);
        _sendWl(wId, address(weth), 1 ether);
        assertEq(weth.balanceOf(pm), 1 ether);
    }

    function test_PaymentAssetManager_managerCannotTouchApprovedWhitelisted() public {
        _initializeVault();
        address pm = makeAddr("pm");
        _addPayoutOperator(pm);
        address to = makeAddr("payee");
        vm.prank(ownerAddress);
        uint256 wIdWr = _addWhitelistedRecipient(to, address(0)); // approved

        vm.prank(pm);
        vm.expectRevert(NotProposalOwner.selector);
        _updateWhitelistedRecipient(wIdWr, to, address(weth));
        vm.prank(pm);
        vm.expectRevert(NotProposalOwner.selector);
        _removeWhitelistedRecipient(wIdWr);
    }

    function test_PaymentAssetManager_managerCancelsOwnPendingWhitelisted() public {
        _initializeVault();
        address pm = makeAddr("pm");
        _addPayoutOperator(pm);
        vm.prank(pm);
        uint256 wIdWr = _addWhitelistedRecipient(makeAddr("payee"), address(0));
        vm.prank(pm);
        _removeWhitelistedRecipient(wIdWr); // cancel own pending
        (address r,) = _getWlOne(wIdWr);
        assertEq(r, address(0));
    }

    function test_PaymentAssetManager_approveScheduledNotFound() public {
        _initializeVault();
        vm.prank(ownerAddress);
        vm.expectRevert(ScheduledPaymentNotFound.selector);
        _approveScheduledPayment(99999, bytes32(0));
    }

    function test_PaymentAssetManager_approveWhitelistedNotFoundAndNotPending() public {
        _initializeVault();
        vm.prank(ownerAddress);
        vm.expectRevert(WhitelistedRecipientNotFound.selector);
        _approveWhitelistedRecipient(99999, bytes32(0));

        vm.prank(ownerAddress);
        uint256 wIdWr = _addWhitelistedRecipient(makeAddr("to"), address(0)); // owner-created = approved
        vm.prank(ownerAddress);
        vm.expectRevert(NotPendingApproval.selector);
        _approveWhitelistedRecipient(wIdWr, bytes32(0));
    }

    function test_PaymentAssetManager_cancelSendNotFound() public {
        _initializeVault();
        vm.prank(ownerAddress);
        vm.expectRevert(PendingSendNotFound.selector);
        _cancelSend(42);
    }

    function test_WhitelistedRecipient_updateZeroRecipientReverts() public {
        _initializeVault();
        vm.prank(ownerAddress);
        vm.expectRevert(AddressZero.selector);
        _updateWhitelistedRecipient(99999, address(0), address(0));
    }

    // Fund the vault with real (ETH-backed) WETH so unwrap-to-ETH works, unlike a bare `deal`.
    function _fundVaultWeth(uint256 amount) internal {
        vm.deal(address(this), amount);
        weth.deposit{value: amount}();
        weth.transfer(address(vault), amount);
    }

    // ─── ETH payouts (asset address(0) = pay native ETH) ────────────────────────

    function test_ETH_ownerSendUnwrapsWethToNativeEth() public {
        _initializeVault();
        _fundVaultWeth(5 ether);
        address to = makeAddr("payee");
        assertEq(to.balance, 0);

        vm.prank(ownerAddress);
        _send(to, address(0), 2 ether);

        assertEq(to.balance, 2 ether);
        assertEq(weth.balanceOf(address(vault)), 3 ether);
    }

    function test_ETH_scheduledPaysNativeEth() public {
        _initializeVault();
        _fundVaultWeth(5 ether);
        address to = makeAddr("payee");
        vm.prank(ownerAddress);
        uint256 pId = _addScheduledPayment(
            _makeScheduledPayment(to, address(0), address(0), 1 ether, 1, block.timestamp, 0, false)
        );

        _payScheduled(_oneU(pId));
        assertEq(to.balance, 1 ether);
        assertEq(weth.balanceOf(address(vault)), 4 ether);
    }

    function test_ETH_scheduledPartialPayWithInsufficientBalance() public {
        _initializeVault();
        _fundVaultWeth(0.4 ether); // less than the 1 ETH scheduled
        address to = makeAddr("payee");
        IBittyV1Vault.ScheduledPayment memory r =
            _makeScheduledPayment(to, address(0), address(0), 1 ether, 1, block.timestamp, 0, false);
        r.payWithInsufficientBalance = true;
        vm.prank(ownerAddress);
        uint256 pId = _addScheduledPayment(r);

        _payScheduled(_oneU(pId));
        assertEq(to.balance, 0.4 ether); // paid what the vault had
        assertEq(weth.balanceOf(address(vault)), 0);
    }

    function test_ETH_whitelistedPaysNativeEth() public {
        _initializeVault();
        _fundVaultWeth(5 ether);
        address to = makeAddr("payee");
        vm.prank(ownerAddress);
        uint256 wIdWr = _addWhitelistedRecipient(to, address(0)); // allowedAsset = any

        vm.prank(ownerAddress);
        _sendWl(wIdWr, address(0), 2 ether);
        assertEq(to.balance, 2 ether);
    }

    function test_PayoutOperator_ethSendProposalThenApprove() public {
        _initializeVault();
        address pm = makeAddr("pm");
        _addPayoutOperator(pm);
        _fundVaultWeth(5 ether);
        address to = makeAddr("payee");

        vm.prank(pm);
        _send(to, address(0), 2 ether);
        assertEq(to.balance, 0);

        vm.prank(ownerAddress);
        _approveSend(0);
        assertEq(to.balance, 2 ether);
    }

    function test_ETH_reentrantRecipientCannotDoublePay() public {
        _initializeVault();
        _fundVaultWeth(5 ether);
        ReentrantEthReceiver attacker = new ReentrantEthReceiver();

        vm.startPrank(ownerAddress);
        uint256 pId = _addScheduledPayment(
            _makeScheduledPayment(address(attacker), address(0), address(0), 1 ether, 1, block.timestamp, 0, false)
        );
        uint256 qId = _addScheduledPayment(
            _makeScheduledPayment(address(attacker), address(0), address(0), 1 ether, 1, block.timestamp, 0, false)
        );
        vm.stopPrank();
        // Reentering a *different*, independently-due ETH payment reaches _payOut while the transient
        // lock is still held, so the reentry hits the ReentrantCall guard instead of double-paying.
        attacker.arm(vault, qId);

        _payScheduled(_oneU(pId));
        // "p" paid once; the reentrant "q" payout reverted and was swallowed, so it never sent.
        assertEq(address(attacker).balance, 1 ether);
        assertEq(weth.balanceOf(address(vault)), 4 ether);
    }

    function test_ETH_paymentToRejectingRecipientReverts() public {
        _initializeVault();
        _fundVaultWeth(5 ether);
        RejectEthReceiver rejecter = new RejectEthReceiver();

        vm.prank(ownerAddress);
        uint256 pId = _addScheduledPayment(
            _makeScheduledPayment(address(rejecter), address(0), address(0), 1 ether, 1, block.timestamp, 0, false)
        );

        vm.expectRevert(TransferFailed.selector);
        _payScheduled(_oneU(pId));
    }

    function test_Retrieve721_ownerRescuesStrayNFT() public {
        _initializeVault();
        MockERC721 nft = new MockERC721("Stray", "STRAY");
        nft.mint(address(vault), 7);

        address rescueTo = makeAddr("rescueTo");
        vm.expectEmit(true, true, true, true, address(vault));
        emit IBittyV1Owner.Retrieved721(address(nft), 7, rescueTo);
        vm.prank(ownerAddress);
        vault.retrieve721(address(nft), 7, rescueTo);

        assertEq(nft.ownerOf(7), rescueTo);
    }

    function test_Retrieve721_revertsForNonOwner() public {
        _initializeVault();
        MockERC721 nft = new MockERC721("Stray", "STRAY");
        nft.mint(address(vault), 1);

        bytes32 adminRole = bytes32(0);
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(_roleError(stranger, adminRole));
        vault.retrieve721(address(nft), 1, stranger);
    }

    function test_Retrieve721_revertsForZeroRecipient() public {
        _initializeVault();
        MockERC721 nft = new MockERC721("Stray", "STRAY");
        nft.mint(address(vault), 1);

        vm.prank(ownerAddress);
        vm.expectRevert(AddressZero.selector);
        vault.retrieve721(address(nft), 1, address(0));
    }

    /**
     * Removing a protocol does not remove the position it holds, so its NFT must stay unretrievable
     * afterwards — otherwise the owner could unregister a protocol and walk the LP position out.
     *
     * Recognised from the guard's protocol list, so registration there is enough and the vault keeps
     * no list of its own — the check is rare and a per-vault set would cost more in aggregate than
     * one list in the guard.
     */
    function test_Retrieve721_blocksProtocolPositionNFT_evenAfterProtocolRemoval() public {
        MockERC721 positionNft = new MockERC721("UniV3 Positions", "UNI-V3-POS");
        MockAMMWithPositionNFT amm = new MockAMMWithPositionNFT(address(positionNft));
        address[] memory amms = new address[](1);
        amms[0] = address(amm);
        MockERC20 t0 = new MockERC20("Token0", "T0", 18);
        MockERC20 t1 = new MockERC20("Token1", "T1", 18);
        address[] memory assets = new address[](2);
        assets[0] = address(t0);
        assets[1] = address(t1);

        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddProtocols(address(BittyV1Guard(guardAddress)), amms);
        guardAddAssets(address(BittyV1Guard(guardAddress)), assets);
        vm.stopPrank();

        vault.initialize(ownerAddress, address(weth), address(0), 0);
        vm.startPrank(ownerAddress);
        vault.updateAssets(assets, new address[](0));
        vault.updateProtocols(amms, new address[](0));
        vm.stopPrank();
        _grantAssetManager(assetManagerAddress);

        // Opening the position is what clones the protocol, and the clone is what outlives removal.
        vm.prank(assetManagerAddress);
        IVaultFull(payable(address(vault))).addLiquidity(address(amm), address(t0), 0, address(t1), 0, "");

        positionNft.mint(address(vault), 42);
        vm.prank(ownerAddress);
        vm.expectRevert(ProtocolNFT.selector);
        vault.retrieve721(address(positionNft), 42, ownerAddress);

        vm.prank(ownerAddress);
        vault.updateProtocols(new address[](0), amms);
        vm.prank(ownerAddress);
        vm.expectRevert(ProtocolNFT.selector);
        vault.retrieve721(address(positionNft), 42, ownerAddress);

        assertEq(positionNft.ownerOf(42), address(vault));
    }

    function test_Retrieve721_blocksCloneReportedPositionNFT() public {
        MockERC721 positionNft = new MockERC721("UniV3 Positions", "UNI-V3-POS");
        MockAMMWithCloneNFT amm = new MockAMMWithCloneNFT(address(positionNft));
        address[] memory amms = new address[](1);
        amms[0] = address(amm);
        MockERC20 t0 = new MockERC20("Token0", "T0", 18);
        MockERC20 t1 = new MockERC20("Token1", "T1", 18);
        address[] memory assets = new address[](2);
        assets[0] = address(t0);
        assets[1] = address(t1);
        vm.startPrank(GUARD_DEPLOYER, GUARD_DEPLOYER);
        guardAddProtocols(address(BittyV1Guard(guardAddress)), amms);
        guardAddAssets(address(BittyV1Guard(guardAddress)), assets);
        vm.stopPrank();

        vault.initialize(ownerAddress, address(weth), address(0), 0);
        vm.startPrank(ownerAddress);
        vault.updateAssets(assets, new address[](0));
        vault.updateProtocols(amms, new address[](0));
        vm.stopPrank();
        _grantAssetManager(assetManagerAddress);

        vm.prank(assetManagerAddress);
        IVaultFull(payable(address(vault))).addLiquidity(address(amm), address(t0), 0, address(t1), 0, "");
        assertEq(amm.positionAssetManager(), address(0));

        positionNft.mint(address(vault), 1);
        vm.prank(ownerAddress);
        vm.expectRevert(ProtocolNFT.selector);
        vault.retrieve721(address(positionNft), 1, ownerAddress);

        MockERC721 stray = new MockERC721("Stray", "STRAY");
        stray.mint(address(vault), 2);
        address rescueTo = makeAddr("rescueTo");
        vm.prank(ownerAddress);
        vault.retrieve721(address(stray), 2, rescueTo);
        assertEq(stray.ownerOf(2), rescueTo);
    }

    function test_Retrieve721_cannotMoveERC20() public {
        _initializeVault();
        MockERC20 token = new MockERC20("Token", "TKN", 18);
        token.mint(address(vault), 1_000e18);
        vm.prank(ownerAddress);
        vm.expectRevert();
        vault.retrieve721(address(token), 1_000e18, makeAddr("attackerExit"));

        assertEq(token.balanceOf(address(vault)), 1_000e18);
    }

    function _contains(address[] memory list, address a) internal pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == a) return true;
        }
        return false;
    }
}
