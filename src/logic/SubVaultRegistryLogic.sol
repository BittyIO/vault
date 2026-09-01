// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {AddressZero, ArrayLengthMismatch} from "../interfaces/IBittyV1Vault.sol";
import {IBittyV1SubVault, SubVaultNotFound, SubVaultClosedError} from "../interfaces/IBittyV1SubVault.sol";
import {BittyStorage, VaultStorage, SubVaultEntry} from "./BittyStorage.sol";

/**
 * @title SubVaultRegistryLogic
 * @notice The main vault's registry of sub vaults: create, fund, recall, close, assign the sub owner
 *         and their grant expiry, and flip each sub's gasless switch. Operates on the ERC-7201 {VaultStorage}. A sub is a
 *         CREATE2 UUPS proxy of a guard-approved implementation; funding/recall only ever move assets
 *         between the main vault and the sub, never to an outside address.
 */
library SubVaultRegistryLogic {
    using SafeERC20 for IERC20;

    event SubVaultCreated(uint256 indexed subId, address indexed account, address indexed subOwner);
    event SubVaultFunded(uint256 indexed subId, address asset, uint256 amount);
    event SubVaultRecalled(uint256 indexed subId, address asset, uint256 amount);
    event SubOwnerAssigned(uint256 indexed subId, address indexed subOwner, uint64 expiresAt);
    event SubOwnerExpirySet(uint256 indexed subId, uint64 expiresAt);
    event SubVaultGaslessSet(uint256 indexed subId, bool enabled);
    event SubVaultClosed(uint256 indexed subId);

    function _entry(VaultStorage storage $, uint256 subId) private view returns (SubVaultEntry storage e) {
        e = $.subs[subId];
        if (e.account == address(0)) revert SubVaultNotFound();
    }

    function createSubVault(address impl, address subOwner, bool allowlistEnabled, uint64 expiresAt)
        external
        returns (uint256 subId, address account)
    {
        if (subOwner == address(0)) revert AddressZero();
        VaultStorage storage $ = BittyStorage.vault();
        subId = ++$.nextSubId;
        bytes memory initData =
            abi.encodeCall(IBittyV1SubVault.initialize, (address(this), subOwner, allowlistEnabled, expiresAt));
        bytes32 salt = keccak256(abi.encodePacked(address(this), subId));
        account = address(new ERC1967Proxy{salt: salt}(impl, initData));
        $.subs[subId] = SubVaultEntry({
            account: account, owner: subOwner, closed: false, expiresAt: expiresAt, gaslessEnabled: false
        });
        ++$.openSubCount;
        emit SubVaultCreated(subId, account, subOwner);
    }

    function fundSubVault(uint256 subId, address[] calldata assets, uint256[] calldata amounts) external {
        if (assets.length != amounts.length) revert ArrayLengthMismatch();
        SubVaultEntry storage e = _entry(BittyStorage.vault(), subId);
        if (e.closed) revert SubVaultClosedError();
        for (uint256 i; i < assets.length; ++i) {
            if (amounts[i] == 0) continue;
            IERC20(assets[i]).safeTransfer(e.account, amounts[i]);
            emit SubVaultFunded(subId, assets[i], amounts[i]);
        }
    }

    function recallFromSubVault(uint256 subId, address[] calldata assets, uint256[] calldata amounts) external {
        if (assets.length != amounts.length) revert ArrayLengthMismatch();
        SubVaultEntry storage e = _entry(BittyStorage.vault(), subId);
        IBittyV1SubVault(e.account).recall(assets, amounts);
        for (uint256 i; i < assets.length; ++i) {
            emit SubVaultRecalled(subId, assets[i], amounts[i]);
        }
    }

    function assignSubOwner(uint256 subId, address newOwner, uint64 expiresAt) external {
        if (newOwner == address(0)) revert AddressZero();
        VaultStorage storage $ = BittyStorage.vault();
        SubVaultEntry storage e = _entry($, subId);
        if (e.closed) revert SubVaultClosedError();
        e.owner = newOwner;
        e.expiresAt = expiresAt;
        IBittyV1SubVault(e.account).setSubOwner(newOwner, expiresAt);
        emit SubOwnerAssigned(subId, newOwner, expiresAt);
    }

    function setSubOwnerExpiry(uint256 subId, uint64 expiresAt) external {
        VaultStorage storage $ = BittyStorage.vault();
        SubVaultEntry storage e = _entry($, subId);
        if (e.closed) revert SubVaultClosedError();
        e.expiresAt = expiresAt;
        IBittyV1SubVault(e.account).setSubOwnerExpiry(expiresAt);
        emit SubOwnerExpirySet(subId, expiresAt);
    }

    function setSubVaultGasless(uint256 subId, bool enabled) external {
        SubVaultEntry storage e = _entry(BittyStorage.vault(), subId);
        e.gaslessEnabled = enabled;
        IBittyV1SubVault(e.account).setGaslessEnabled(enabled);
        emit SubVaultGaslessSet(subId, enabled);
    }

    function closeSubVault(uint256 subId) external {
        VaultStorage storage $ = BittyStorage.vault();
        SubVaultEntry storage e = _entry($, subId);
        if (e.closed) revert SubVaultClosedError();
        e.closed = true;
        e.expiresAt = uint64(block.timestamp);
        --$.openSubCount;
        IBittyV1SubVault(e.account).expireSubOwnerNow();
        emit SubVaultClosed(subId);
    }

    function getSubVault(uint256[] calldata subIds)
        external
        view
        returns (
            address[] memory accounts,
            address[] memory owners,
            uint64[] memory expiresAts,
            bool[] memory gaslessEnabled,
            bool[] memory closed
        )
    {
        uint256 n = subIds.length;
        accounts = new address[](n);
        owners = new address[](n);
        expiresAts = new uint64[](n);
        gaslessEnabled = new bool[](n);
        closed = new bool[](n);
        mapping(uint256 => SubVaultEntry) storage subs = BittyStorage.vault().subs;
        for (uint256 i; i < n; ++i) {
            SubVaultEntry storage e = subs[subIds[i]];
            accounts[i] = e.account;
            owners[i] = e.owner;
            expiresAts[i] = e.expiresAt;
            gaslessEnabled[i] = e.gaslessEnabled;
            closed[i] = e.closed;
        }
    }

    function subVaultAccount(uint256 subId) external view returns (address) {
        return BittyStorage.vault().subs[subId].account;
    }

    function openSubCount() external view returns (uint256) {
        return BittyStorage.vault().openSubCount;
    }

    function nextSubId() external view returns (uint256) {
        return BittyStorage.vault().nextSubId;
    }
}
