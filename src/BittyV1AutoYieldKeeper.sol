// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {SignatureChecker} from "openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";

/**
 * @title BittyV1AutoYieldKeeper
 * @notice The address every vault names as its auto-yield trigger. Vaults see one address forever; the
 *         hot keys that actually sign rotate in here.
 *
 * @dev A vault's trigger is baked into its implementation and cannot be changed per vault, so the
 *      trigger has to be a stable address in front of moving parts rather than an EOA whose key can
 *      never be retired. Rotating a key is one transaction here instead of one per vault.
 *
 *      This contract only ever ANSWERS; it never acts. It holds nothing, can move nothing, and has no
 *      upgrade path — so a full compromise buys an attacker the ability to sweep vaults into routes
 *      their owners already chose, at inconvenient times, and to spend each vault's daily gas budget.
 *      Griefing, bounded. That is only true because the contract is this small; resist growing it.
 *
 *      It deliberately does NOT inspect what is being signed. ERC-1271 receives only a hash, so it
 *      could not anyway — but it does not need to: with `request.from` set to this keeper, the vault
 *      sees a caller that is neither its owner nor a payout operator, and {IBittyV1Vault-autoYield}
 *      is the only function that check passes for. The vault does the authorisation; this
 *      contract only does authentication.
 */
contract BittyV1AutoYieldKeeper {
    bytes4 private constant MAGIC_VALUE = 0x1626ba7e;
    bytes4 private constant INVALID_VALUE = 0xffffffff;

    address public owner;

    /**
     * @dev Forwarders whose questions this keeper answers. A SET, not one address: a vault's
     *      trustedForwarder is frozen at activation, so shipping a new forwarder leaves two generations
     *      of vaults live at once and one keeper has to serve both. An immutable here would force a
     *      keeper redeploy per forwarder version, and a new keeper address means every owner has to
     *      re-point their trigger — the exact problem this contract exists to remove.
     */
    mapping(address forwarder => bool trusted) public trustedForwarders;

    /**
     * @dev Unix second the key stops signing. 0 = not a signer.
     *
     *      There is deliberately no "never expires" here. A signer is always a machine key living in a
     *      signing service, never a person, so a leak nobody notices should stop mattering on its own.
     */
    mapping(address signer => uint64 expiresAt) public signerExpiresAt;

    error NotOwner();
    error AddressZero();
    error ExpiryInPast();

    event OwnerSet(address indexed owner);
    event ForwarderSet(address indexed forwarder, bool trusted);
    event SignerSet(address indexed signer, uint64 expiresAt);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /**
     * @dev Takes only the owner, deliberately. Forwarders are added afterwards with {setForwarder}, so
     *      this contract's init code — and therefore its CREATE2 address — does not move when a new
     *      forwarder generation ships. Vaults freeze their trigger, so a keeper that moved would strand
     *      every vault already activated.
     */
    constructor(address owner_) {
        if (owner_ == address(0)) revert AddressZero();
        owner = owner_;
        emit OwnerSet(owner_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert AddressZero();
        owner = newOwner;
        emit OwnerSet(newOwner);
    }

    function setForwarder(address forwarder, bool trusted) external onlyOwner {
        trustedForwarders[forwarder] = trusted;
        emit ForwarderSet(forwarder, trusted);
    }

    /**
     * @notice Authorise `signer` to sign sweeps until `expiresAt`, or revoke it with 0.
     */
    function setSigner(address signer, uint64 expiresAt) external onlyOwner {
        if (expiresAt != 0 && expiresAt <= block.timestamp) revert ExpiryInPast();
        signerExpiresAt[signer] = expiresAt;
        emit SignerSet(signer, expiresAt);
    }

    /**
     * @notice Whether `signer` may sign right now.
     */
    function isActiveSigner(address signer) public view returns (bool) {
        uint64 expiresAt = signerExpiresAt[signer];
        return expiresAt != 0 && expiresAt >= block.timestamp;
    }

    /**
     * @notice The signature format this keeper accepts: `abi.encode(signer, innerSignature)`.
     * @dev The signer is NAMED rather than recovered. Recovery can only ever produce the address of an
     *      EOA, so it made a contract signer structurally impossible — not merely unsupported — and a
     *      key set that can never include a multisig is a key set that can never stop depending on one
     *      secp256k1 secret.
     *
     *      Naming it costs nothing in authority: the address is attacker-chosen input, but it only
     *      passes if the owner already registered it AND a signature valid for it is supplied.
     *      {SignatureChecker} then tries ECDSA first and falls back to ERC-1271, so an EOA signer
     *      behaves exactly as before and a contract signer — a multisig today, an account that does not
     *      verify with ECDSA later — works with no further change here. That matters because this
     *      contract is immutable: the format is fixed for the life of a deployed keeper. Rotating to a
     *      new one is possible — a vault names its trigger in storage — but it is a per-vault migration,
     *      so the format wants to outlast the signing scheme rather than assume one.
     */
    function decodeSignature(bytes calldata signature) public pure returns (address signer, bytes calldata inner) {
        // abi.encode(address,bytes) lays out: [signer][offset to inner][inner length][inner data].
        // Every read is bounds-checked before it happens so a malformed payload returns "no signer"
        // instead of reverting, and each check short-circuits before any arithmetic can overflow.
        if (signature.length < 96) return (address(0), signature[0:0]);

        signer = address(uint160(uint256(bytes32(signature[0:32]))));

        uint256 innerOffset = uint256(bytes32(signature[32:64]));
        if (innerOffset > signature.length - 32) return (address(0), signature[0:0]);

        uint256 innerLength = uint256(bytes32(signature[innerOffset:innerOffset + 32]));
        uint256 start = innerOffset + 32;
        if (innerLength > signature.length - start) return (address(0), signature[0:0]);

        inner = signature[start:start + innerLength];
    }

    /**
     * @dev Only a trusted forwarder may ask. Without that check this keeper is a general-purpose
     *      ERC-1271 identity that anything accepting contract signatures would honour, which is far
     *      more authority than sweeping vaults needs.
     *
     *      Malformed input returns INVALID_VALUE rather than reverting. A revert would be caught by the
     *      caller's staticcall and read the same way, but only by accident; answering explicitly keeps
     *      that from being load-bearing.
     */
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        if (!trustedForwarders[msg.sender]) return INVALID_VALUE;

        (address signer, bytes calldata inner) = decodeSignature(signature);
        if (signer == address(0)) return INVALID_VALUE;
        if (!isActiveSigner(signer)) return INVALID_VALUE;

        return SignatureChecker.isValidSignatureNow(signer, hash, inner) ? MAGIC_VALUE : INVALID_VALUE;
    }
}
