// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ASSET_STABLE_COIN} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockGuard} from "../helpers/MockGuard.sol";
import {LENDING_ID} from "../helpers/CategoryIds.sol";
import {UpgradeableLendingV1} from "./ProtocolUpgrade.t.sol";
import {BittyV1VaultDeFiFacet} from "../../src/BittyV1VaultDeFiFacet.sol";
import {BittyV1Vault} from "../../src/BittyV1Vault.sol";
import {BITTY_GUARD} from "../../src/logic/Constants.sol";

/**
 * A lending adapter shaped like Aave's: the deposit hands the vault a receipt token, and the
 * withdrawal pulls it back with a transferFrom — so the vault must have approved the clone for it.
 */
contract ReceiptLendingV1 is UpgradeableLendingV1 {
    using SafeERC20 for IERC20;

    function _receipt() internal view virtual returns (MockERC20) {
        return MockERC20(address(uint160(uint256(keccak256("receipt.v1")))));
    }

    function receiptTokenOf(address) external view returns (address) {
        return address(_receipt());
    }

    function deposit(address asset, uint256 amount) external override onlyOwner {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        _receipt().mint(msg.sender, amount);
    }

    function withdraw(address asset, uint256 amount, address recipient) external override onlyOwner returns (uint256) {
        IERC20(address(_receipt())).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(asset).safeTransfer(recipient, amount);
        return amount;
    }
}

/**
 * The next version names a different receipt token, which the vault has never approved.
 */
contract ReceiptLendingV2 is ReceiptLendingV1 {
    function _receipt() internal view override returns (MockERC20) {
        return MockERC20(address(uint160(uint256(keccak256("receipt.v2")))));
    }

    function protocolVersion() external pure override returns (uint256) {
        return 2_000_000;
    }
}

interface IFacet {
    function deposit(address protocol, address asset, uint256 amount) external;
    function withdraw(address protocol, address asset, uint256 amount) external;
    function upgradeProtocol(address protocol, address newImplementation) external;
    function getClone(address protocol) external view returns (address);
}

/**
 * The receipt-token approval is made once per clone version and asset, then remembered: asking the
 * clone for its receipt token and the token for an allowance on every withdrawal cost three calls.
 */
contract ReceiptApprovalTest is Test {
    BittyV1Vault vault;
    MockERC20 usdc;
    ReceiptLendingV1 v1;
    ReceiptLendingV2 v2;
    address owner = makeAddr("owner");

    function setUp() public {
        vm.etch(BITTY_GUARD, address(new MockGuard()).code);
        MockGuard guard = MockGuard(BITTY_GUARD);
        BittyV1Vault impl = new BittyV1Vault(address(new BittyV1VaultDeFiFacet()));
        vault = BittyV1Vault(
            payable(new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(
                        BittyV1Vault.initialize, (owner, makeAddr("gasWrapped"), false, address(0), 0, new bytes[](0))
                    )
                ))
        );
        usdc = new MockERC20("USD Coin", "USDC", 6);
        v1 = new ReceiptLendingV1();
        v2 = new ReceiptLendingV2();
        deployCodeTo(
            "MockERC20.sol:MockERC20", abi.encode("R1", "R1", uint8(6)), address(v1.receiptTokenOf(address(0)))
        );
        deployCodeTo(
            "MockERC20.sol:MockERC20", abi.encode("R2", "R2", uint8(6)), address(v2.receiptTokenOf(address(0)))
        );
        guard.setAsset(address(usdc), ASSET_STABLE_COIN);
        guard.setProtocol(address(v1), LENDING_ID);
        guard.setProtocol(address(v2), LENDING_ID);
        usdc.mint(address(vault), 1_000e6);
    }

    function _f() internal view returns (IFacet) {
        return IFacet(address(vault));
    }

    function test_theApprovalIsMadeOnceThenRemembered() public {
        vm.startPrank(owner);
        _f().deposit(address(v1), address(usdc), 100e6);
        _f().withdraw(address(v1), address(usdc), 10e6);

        address clone = _f().getClone(address(v1));
        vm.expectCall(clone, abi.encodeWithSignature("receiptTokenOf(address)", address(usdc)), 0);
        _f().withdraw(address(v1), address(usdc), 10e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(vault)), 920e6);
    }

    function test_anUpgradeThatNamesANewReceiptTokenIsApprovedAgain() public {
        vm.startPrank(owner);
        _f().deposit(address(v1), address(usdc), 100e6);
        _f().withdraw(address(v1), address(usdc), 10e6);
        _f().upgradeProtocol(address(v1), address(v2));
        _f().deposit(address(v1), address(usdc), 50e6);
        _f().withdraw(address(v1), address(usdc), 50e6);
        vm.stopPrank();

        address clone = _f().getClone(address(v1));
        assertEq(
            IERC20(v2.receiptTokenOf(address(0))).allowance(address(vault), clone),
            type(uint256).max,
            "the new token was approved"
        );
        assertEq(usdc.balanceOf(address(vault)), 910e6);
    }
}
