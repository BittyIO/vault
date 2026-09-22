// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Create2} from "openzeppelin-contracts/contracts/utils/Create2.sol";
import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SignatureChecker} from "openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";
import {VaultAlreadyActivated, InvalidActivationSignature} from "./interfaces/IBittyV1VaultFactory.sol";
import {BittyV1VaultBootstrap} from "./BittyV1VaultBootstrap.sol";
import {IBittyV1Guard, IMPLEMENTATION_VAULT} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {BITTY_GUARD, BITTY_VAULT_BOOTSTRAP, CFG_GAS_WRAPPED, CFG_OWNER} from "./logic/Constants.sol";

/**
 * @dev Only the vault's activation selector, declared here rather than imported from {BittyV1Vault}.
 *      Importing the concrete vault pulled its entire storage/logic closure into the factory's metadata,
 *      so an unrelated change to vault storage rebuilt the factory implementation and forced a needless
 *      proxy upgrade. The factory needs nothing but this one signature to initialise a fresh vault, so
 *      its build now stays put unless the factory's OWN logic changes.
 */
interface IBittyV1VaultActivation {
    function initialize(
        address owner,
        address gasWrapped,
        bool allowlistEnabled,
        address activationAsset,
        uint256 activationAmount,
        bytes[] calldata calls
    ) external;
}

/**
 * @title BittyV1VaultFactory
 * @notice Deploys main vaults as ERC-1967 proxies at a per-owner CREATE2 address. Each proxy is born on
 *         the constant {BITTY_VAULT_BOOTSTRAP} and upgraded to the current implementation in the same
 *         transaction, so the counterfactual address depends only on the owner — an owner can pre-fund
 *         the predicted address and anyone can then activate it.
 * @dev The implementation comes from the guard's {IBittyV1Guard-latestImplementation}, the wrapped-gas
 *      token from the guard config; there is no per-factory config to set. The factory itself is a UUPS
 *      proxy born on {BittyV1VaultFactoryBootstrap}, so its address is independent of its logic — a new
 *      factory build is an upgrade, not a redeploy, and vault addresses (which are CREATE2'd off this
 *      factory) never move. Its upgrade owner is the guard's configured owner. Allowlist defaults ON.
 */
contract BittyV1VaultFactory is EIP712, UUPSUpgradeable {
    bytes32 private constant _ACTIVATION_TYPEHASH = keccak256(
        "Activation(address owner,address stableCoinAddress,uint256 feeAmount,bool allowlistEnabled,bytes[] calls)"
    );

    error NotOwner();

    event VaultActivated(address indexed owner, address vault);

    constructor() EIP712("BittyV1VaultFactory", "1") {
        _disableInitializers();
    }

    function owner() public view returns (address) {
        return IBittyV1Guard(BITTY_GUARD).getAddress(CFG_OWNER);
    }

    modifier onlyOwner() {
        if (msg.sender != owner()) revert NotOwner();
        _;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function activateVault(bool allowlistEnabled, bytes[] calldata calls) external returns (address vault) {
        return _deploy(msg.sender, address(0), 0, allowlistEnabled, calls);
    }

    function activateVaultByAsset(
        address owner,
        address asset,
        uint256 amount,
        bool allowlistEnabled,
        bytes[] calldata calls,
        bytes calldata signature
    ) external returns (address vault) {
        _checkActivationSignature(owner, asset, amount, allowlistEnabled, calls, signature);
        return _deploy(owner, asset, amount, allowlistEnabled, calls);
    }

    function _deploy(address owner, address asset, uint256 amount, bool allowlistEnabled, bytes[] calldata calls)
        private
        returns (address vault)
    {
        bytes32 salt = keccak256(abi.encodePacked(owner));
        vault = _predict(salt);
        if (vault.code.length > 0) revert VaultAlreadyActivated();
        address deployed = address(new ERC1967Proxy{salt: salt}(BITTY_VAULT_BOOTSTRAP, ""));
        address vaultImpl = IBittyV1Guard(BITTY_GUARD).latestImplementation(IMPLEMENTATION_VAULT);
        address gasWrapped = IBittyV1Guard(BITTY_GUARD).getAddress(CFG_GAS_WRAPPED);
        BittyV1VaultBootstrap(payable(deployed))
            .upgradeToAndCall(
                vaultImpl,
                abi.encodeCall(
                    IBittyV1VaultActivation.initialize, (owner, gasWrapped, allowlistEnabled, asset, amount, calls)
                )
            );
        emit VaultActivated(owner, deployed);
        vault = deployed;
    }

    function _predict(bytes32 salt) private view returns (address) {
        bytes memory bytecode =
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(BITTY_VAULT_BOOTSTRAP, bytes("")));
        return Create2.computeAddress(salt, keccak256(bytecode));
    }

    function vaultAddress(address owner) external view returns (address) {
        return _predict(keccak256(abi.encodePacked(owner)));
    }

    /**
     * @dev `calls` are part of what the owner signs. A relayer that could add its own entries would be
     *      running owner-authorised operations on a vault it does not own.
     */
    function _checkActivationSignature(
        address owner,
        address stableCoinAddress,
        uint256 feeAmount,
        bool allowlistEnabled,
        bytes[] calldata calls,
        bytes calldata signature
    ) private view {
        bytes32 structHash = keccak256(
            abi.encode(_ACTIVATION_TYPEHASH, owner, stableCoinAddress, feeAmount, allowlistEnabled, _hashCalls(calls))
        );
        if (!SignatureChecker.isValidSignatureNow(owner, _hashTypedDataV4(structHash), signature)) {
            revert InvalidActivationSignature();
        }
    }

    /**
     * @dev EIP-712 encoding of a `bytes[]`: the hash of the concatenated hashes of its members, which
     *      is what a wallet produces for a `bytes[] calls` field without any custom handling.
     */
    function _hashCalls(bytes[] calldata calls) private pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            hashes[i] = keccak256(calls[i]);
        }
        return keccak256(abi.encodePacked(hashes));
    }
}
