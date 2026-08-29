// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {MockLendingProtocol} from "../helpers/MockLendingProtocol.sol";
import {LENDING_ID} from "../helpers/CategoryIds.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BittyV1SubVault} from "../../src/subvault/BittyV1SubVault.sol";
import {
    AddressZero,
    AmountIsZero,
    InsufficientBalance,
    ArrayLengthMismatch
} from "../../src/interfaces/IBittyV1Vault.sol";
import {
    InvalidDepositableProtocol,
    InvalidWithdrawableProtocol,
    ProtocolNFT
} from "../../src/interfaces/IBittyV1DeFi.sol";
import {BITTY_GUARD, STABLE_COIN_CATEGORY} from "../../src/logic/Constants.sol";

interface IFacet {
    function deposit(address protocol, address asset, uint256 amount) external;
    function withdraw(address protocol, address asset, uint256 amount) external;
    function claimWithdrawals(address protocol, uint256[] memory ids) external;
    function claimWithdrawal(address protocol, uint256 id) external;
    function getBalances(address[] calldata protocols, address[] calldata assets)
        external
        view
        returns (uint256[] memory);
    function getPendingWithdrawalIds(address protocol) external view returns (uint256[] memory);
    function getClone(address protocol) external view returns (address);
}

/// A lending mock that issues a receipt token, so the withdraw path has something to approve back.
/// Immutable, not storage: the vault reads this through an EIP-1167 clone, whose storage starts empty.
contract ReceiptLendingProtocol is MockLendingProtocol {
    address public immutable receipt;

    constructor(address token) {
        receipt = token;
    }

    function receiptTokenOf(address) external view override returns (address) {
        return receipt;
    }
}

/// A lending mock whose exits queue instead of settling, so pending-withdrawal ids are non-empty.
contract PendingLendingProtocol is MockLendingProtocol {
    uint256[] internal _pending;
    uint256[] public claimed;

    function getPendingWithdrawalIds() external view override returns (uint256[] memory) {
        return _pending;
    }

    function queue(uint256 id) external {
        _pending.push(id);
    }

    function claimWithdrawals(uint256[] memory ids) external override onlyOwner {
        claimed = ids;
    }
}

/**
 * A protocol that reports a position NFT, and only once initialized. The master copy answers zero and
 * the clone answers the NFT, which is exactly the asymmetry the rescue path has to handle: the NFT that
 * represents a live position is held under the CLONE, not the address the guard lists.
 */
contract NFTPositionProtocol is Ownable, Initializable {
    address public positionAssetManager;
    address internal immutable _nft;

    constructor(address nft) Ownable(msg.sender) {
        _nft = nft;
    }

    function claimPositionOnTheMaster() external {
        positionAssetManager = _nft;
    }

    function initialize(address newOwner) external initializer {
        _transferOwnership(newOwner);
        positionAssetManager = _nft;
    }

    function deposit(address asset, uint256 amount) external onlyOwner {
        SafeERC20.safeTransferFrom(IERC20(asset), msg.sender, address(this), amount);
    }

    function getBalance(address asset) external view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function receiptTokenOf(address) external pure returns (address) {
        return address(0);
    }
}

/// A withdrawable protocol that does not implement receiptTokenOf at all, so the probe staticcall
/// fails outright rather than returning a zero address.
contract NoReceiptProtocol is Ownable, Initializable {
    constructor() Ownable(msg.sender) {}

    function initialize(address newOwner) external initializer {
        _transferOwnership(newOwner);
    }

    function deposit(address asset, uint256 amount) external onlyOwner {
        SafeERC20.safeTransferFrom(IERC20(asset), msg.sender, address(this), amount);
    }

    function getBalance(address asset) external view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function withdraw(address asset, uint256 amount, address recipient) external onlyOwner returns (uint256) {
        if (amount == type(uint256).max) amount = IERC20(asset).balanceOf(address(this));
        SafeERC20.safeTransfer(IERC20(asset), recipient, amount);
        return amount;
    }
}

contract StrayNFT is ERC721("Stray", "STRAY") {
    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function tokenURI(uint256) public pure override returns (string memory) {
        return "";
    }
}

/**
 * The yield path's argument handling and its two escape hatches.
 *
 * Everything here is about what happens when the happy path does NOT hold: a protocol the vault never
 * cloned, an amount larger than the position, a rescue aimed at a live position NFT. The deposit and
 * withdraw success cases are covered in DeFiAllowlist; what is load-bearing here is that each refusal
 * is a distinct revert rather than a silent zero.
 */
contract DeFiYieldTest is Test {
    BittyV1Vault vault;
    MockGuard guard;
    MockERC20 usdc;
    MockLendingProtocol proto;

    address owner = makeAddr("owner");
    address weth = makeAddr("weth");
    address stranger = makeAddr("stranger");

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        guard = MockGuard(BITTY_GUARD);

        BittyV1VaultDeFiFacet facet = new BittyV1VaultDeFiFacet();
        BittyV1SubVault subImpl = new BittyV1SubVault(address(facet));
        BittyV1Vault impl = new BittyV1Vault(address(facet), address(subImpl));
        bytes memory init = abi.encodeCall(BittyV1Vault.initialize, (owner, weth, false, address(0), 0));
        vault = BittyV1Vault(payable(new ERC1967Proxy(address(impl), init)));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        proto = new MockLendingProtocol();
        guard.setAsset(address(usdc), STABLE_COIN_CATEGORY);
        guard.setProtocol(address(proto), LENDING_ID);
        usdc.mint(address(vault), 1_000e6);
    }

    function _f() internal view returns (IFacet) {
        return IFacet(address(vault));
    }

    function _one(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = a;
    }

    // ── deposit argument handling ─────────────────────────────────────────────

    function test_depositRejectsTheZeroAsset() public {
        vm.prank(owner);
        vm.expectRevert(AddressZero.selector);
        _f().deposit(address(proto), address(0), 1e6);
    }

    function test_depositRejectsZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(AmountIsZero.selector);
        _f().deposit(address(proto), address(usdc), 0);
    }

    function test_depositRejectsAProtocolTheGuardDoesNotKnow() public {
        vm.prank(owner);
        vm.expectRevert(InvalidDepositableProtocol.selector);
        _f().deposit(makeAddr("nowhere"), address(usdc), 1e6);
    }

    function test_theCloneIsMadeOnceAndReused() public {
        vm.startPrank(owner);
        _f().deposit(address(proto), address(usdc), 10e6);
        address first = _f().getClone(address(proto));
        _f().deposit(address(proto), address(usdc), 10e6);
        vm.stopPrank();
        assertEq(_f().getClone(address(proto)), first, "the second deposit reuses the vault's clone");
        assertEq(usdc.balanceOf(first), 20e6, "both deposits landed in the same clone");
    }

    // ── withdraw argument handling ────────────────────────────────────────────

    function test_withdrawRejectsTheZeroAsset() public {
        vm.prank(owner);
        vm.expectRevert(AddressZero.selector);
        _f().withdraw(address(proto), address(0), 1e6);
    }

    function test_withdrawRejectsZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(AmountIsZero.selector);
        _f().withdraw(address(proto), address(usdc), 0);
    }

    function test_withdrawFromANeverDepositedProtocolIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(InvalidWithdrawableProtocol.selector);
        _f().withdraw(address(proto), address(usdc), 1e6);
    }

    function test_withdrawMoreThanThePositionIsRefused() public {
        vm.startPrank(owner);
        _f().deposit(address(proto), address(usdc), 10e6);
        vm.expectRevert(InsufficientBalance.selector);
        _f().withdraw(address(proto), address(usdc), 11e6);
        vm.stopPrank();
    }

    function test_maxUintSweepsWithoutABalanceCheck() public {
        vm.startPrank(owner);
        _f().deposit(address(proto), address(usdc), 10e6);
        _f().withdraw(address(proto), address(usdc), type(uint256).max);
        vm.stopPrank();
        assertEq(usdc.balanceOf(_f().getClone(address(proto))), 0, "the whole position came back");
        assertEq(usdc.balanceOf(address(vault)), 1_000e6, "and landed in the vault");
    }

    function test_aReceiptTokenIsApprovedBackToTheCloneOnExit() public {
        MockERC20 receipt = new MockERC20("Receipt", "rUSDC", 6);
        ReceiptLendingProtocol rp = new ReceiptLendingProtocol(address(receipt));
        guard.setProtocol(address(rp), LENDING_ID);

        vm.startPrank(owner);
        _f().deposit(address(rp), address(usdc), 10e6);
        address clone = _f().getClone(address(rp));
        receipt.mint(address(vault), 10e6);
        _f().withdraw(address(rp), address(usdc), 10e6);
        vm.stopPrank();

        assertEq(receipt.allowance(address(vault), clone), type(uint256).max, "the clone can pull the receipt back");
    }

    // ── balance reads ─────────────────────────────────────────────────────────

    function test_balanceOfANeverDepositedProtocolIsZeroNotARevert() public view {
        uint256[] memory got = _f().getBalances(_one(address(proto)), _one(address(usdc)));
        assertEq(got[0], 0, "no clone means no position, not a failure");
    }

    function test_balanceReadRejectsTheZeroAsset() public {
        vm.expectRevert(AddressZero.selector);
        _f().getBalances(_one(address(proto)), _one(address(0)));
    }

    function test_balanceReadRejectsMismatchedArrays() public {
        address[] memory protocols = new address[](2);
        protocols[0] = address(proto);
        protocols[1] = address(proto);
        vm.expectRevert(ArrayLengthMismatch.selector);
        _f().getBalances(protocols, _one(address(usdc)));
    }

    // ── pending withdrawals ───────────────────────────────────────────────────

    function test_pendingIdsOfANeverDepositedProtocolAreEmpty() public view {
        assertEq(_f().getPendingWithdrawalIds(address(proto)).length, 0, "no clone, nothing pending");
    }

    function test_pendingIdsAreReadThroughTheClone() public {
        PendingLendingProtocol pp = new PendingLendingProtocol();
        guard.setProtocol(address(pp), LENDING_ID);
        vm.prank(owner);
        _f().deposit(address(pp), address(usdc), 10e6);
        PendingLendingProtocol(_f().getClone(address(pp))).queue(7);
        assertEq(_f().getPendingWithdrawalIds(address(pp))[0], 7, "the id came from the clone, not the master");
    }

    function test_claimingNothingIsANoOpEvenWithNoClone() public {
        vm.prank(owner);
        _f().claimWithdrawals(address(proto), new uint256[](0));
    }

    function test_claimingFromANeverDepositedProtocolIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(InvalidWithdrawableProtocol.selector);
        _f().claimWithdrawals(address(proto), _ids(1));
    }

    function test_claimingOneFromANeverDepositedProtocolIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(InvalidWithdrawableProtocol.selector);
        _f().claimWithdrawal(address(proto), 1);
    }

    function test_claimOneReachesTheCloneAsASingletonBatch() public {
        PendingLendingProtocol pp = new PendingLendingProtocol();
        guard.setProtocol(address(pp), LENDING_ID);
        vm.startPrank(owner);
        _f().deposit(address(pp), address(usdc), 10e6);
        _f().claimWithdrawal(address(pp), 42);
        vm.stopPrank();
        assertEq(PendingLendingProtocol(_f().getClone(address(pp))).claimed(0), 42, "the single id was forwarded");
    }

    // ── NFT rescue ────────────────────────────────────────────────────────────

    function test_ownerRescuesAStrayNFT() public {
        StrayNFT nft = new StrayNFT();
        nft.mint(address(vault), 1);
        vm.prank(owner);
        vault.retrieve721(address(nft), 1, owner);
        assertEq(nft.ownerOf(1), owner, "a token nobody's position depends on comes out");
    }

    function test_rescueRefusesTheZeroRecipient() public {
        StrayNFT nft = new StrayNFT();
        nft.mint(address(vault), 1);
        vm.prank(owner);
        vm.expectRevert(AddressZero.selector);
        vault.retrieve721(address(nft), 1, address(0));
    }

    function test_rescueCannotDrainAProtocolsPositionNFT() public {
        StrayNFT nft = new StrayNFT();
        NFTPositionProtocol np = new NFTPositionProtocol(address(nft));
        np.claimPositionOnTheMaster();
        guard.setProtocol(address(np), LENDING_ID);

        nft.mint(address(vault), 1);
        vm.prank(owner);
        vm.expectRevert(ProtocolNFT.selector);
        vault.retrieve721(address(nft), 1, owner);
    }

    function test_rescueCannotDrainAPositionNFTHeldUnderTheClone() public {
        StrayNFT nft = new StrayNFT();
        NFTPositionProtocol np = new NFTPositionProtocol(address(nft));
        guard.setProtocol(address(np), LENDING_ID);
        assertEq(np.positionAssetManager(), address(0), "the master copy claims no position");

        vm.startPrank(owner);
        _f().deposit(address(np), address(usdc), 10e6);
        address clone = _f().getClone(address(np));
        assertEq(NFTPositionProtocol(clone).positionAssetManager(), address(nft), "the clone does");

        nft.mint(address(vault), 1);
        vm.expectRevert(ProtocolNFT.selector);
        vault.retrieve721(address(nft), 1, owner);
        vm.stopPrank();
    }

    function test_onlyTheOwnerRescues() public {
        StrayNFT nft = new StrayNFT();
        nft.mint(address(vault), 1);
        vm.prank(stranger);
        vm.expectRevert();
        vault.retrieve721(address(nft), 1, stranger);
    }

    function test_aProtocolWithNoReceiptTokenAtAllStillExits() public {
        NoReceiptProtocol np = new NoReceiptProtocol();
        guard.setProtocol(address(np), LENDING_ID);

        vm.startPrank(owner);
        _f().deposit(address(np), address(usdc), 10e6);
        _f().withdraw(address(np), address(usdc), 10e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(vault)), 1_000e6, "the probe failed harmlessly and the exit worked");
    }

    function test_severalPendingWithdrawalsAreClaimedInOneCall() public {
        PendingLendingProtocol pp = new PendingLendingProtocol();
        guard.setProtocol(address(pp), LENDING_ID);

        vm.startPrank(owner);
        _f().deposit(address(pp), address(usdc), 10e6);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 7;
        ids[1] = 9;
        _f().claimWithdrawals(address(pp), ids);
        vm.stopPrank();

        PendingLendingProtocol clone = PendingLendingProtocol(_f().getClone(address(pp)));
        assertEq(clone.claimed(0), 7, "both ids were forwarded");
        assertEq(clone.claimed(1), 9);
    }
}
