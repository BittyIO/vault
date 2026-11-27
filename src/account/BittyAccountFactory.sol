// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {BittyAccount} from "./BittyAccount.sol";

/**
 * @title BittyAccountFactory
 * @notice Makes {BittyAccount}s. An owner's account has a fixed address before it exists
 *         ({predictAccount}), so it can receive USDT first and be created only when it
 *         first spends. Anyone may create it (a relayer, typically), and it always belongs to the
 *         owner its address was derived from.
 *
 * @dev CREATE2 hashes a one-byte prefix with the deployer, salt and init code: 0xff on the EVM, 0x41
 *      on TRON. The constructor finds out which by deploying the implementation with CREATE2 and
 *      checking which prediction it landed on, so {predictAccount} is right on both.
 *
 *      The one thing that can change is the RELAYER: the address relayed batches pay their USDT fee to
 *      (outside the accounts' payee, lock and daily-limit rules, up to a cap per account per day) and
 *      that receives the swap fee. The owner (the deployer, then whoever it hands over to) sets it,
 *      at once. It cannot move anyone's money: a fee is only ever paid by a batch the account's owner
 *      signed, to the address that batch names. What it can do, with the owner key and an account's
 *      key both stolen, is let that account pay the cap per day to an address the thief chose despite
 *      a lock. No upgrade: account code and every other setting are fixed.
 */
contract BittyAccountFactory {
    address public immutable implementation;
    /// This chain's CREATE2 prefix, found at deploy: 0xff (EVM) or 0x41 (TRON).
    bytes1 public immutable create2Prefix;
    bytes32 private immutable _cloneCodeHash;

    address public owner;
    address public pendingOwner;
    address public relayer;

    event AccountCreated(address indexed account, address indexed owner, uint256 index);
    event RelayerChanged(address indexed previous, address indexed current);
    event OwnershipProposed(address indexed current, address indexed proposed);
    event OwnershipTransferred(address indexed previous, address indexed current);

    error NotOwner();
    error NotPendingOwner();
    error InvalidAddress();

    error UnknownCreate2();
    error WrongAddress(address predicted, address deployed);

    /// @param config What every account of this factory is built against: USDT, TRON's stake ops,
    ///        SunSwap's router and Permit2, and the TRX/USD feed.
    /// @param relayer_ The first relayer; the deployer becomes the owner who can change it.
    constructor(BittyAccount.Config memory config, address relayer_) {
        if (relayer_ == address(0)) revert InvalidAddress();
        owner = msg.sender;
        relayer = relayer_;
        emit OwnershipTransferred(address(0), msg.sender);
        emit RelayerChanged(address(0), relayer_);
        address impl = address(new BittyAccount{salt: bytes32(0)}(config));
        bytes32 implCode = keccak256(abi.encodePacked(type(BittyAccount).creationCode, abi.encode(config)));
        bytes1 prefix;
        if (impl == _create2(0xff, bytes32(0), implCode)) prefix = 0xff;
        else if (impl == _create2(0x41, bytes32(0), implCode)) prefix = 0x41;
        else revert UnknownCreate2();
        implementation = impl;
        create2Prefix = prefix;
        _cloneCodeHash = keccak256(
            abi.encodePacked(hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", impl, hex"5af43d82803e903d91602b57fd5bf3")
        );
    }

    /**
     * @notice Create `owner_`'s account number `index` (0 for a user's first). Returns it if it exists.
     */
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// Change the relayer, at once, for every account of this factory.
    function setRelayer(address relayer_) external onlyOwner {
        if (relayer_ == address(0)) revert InvalidAddress();
        emit RelayerChanged(relayer, relayer_);
        relayer = relayer_;
    }

    /// Hand the factory to `next`, which takes it with {acceptOwnership}. address(0) cancels.
    function transferOwnership(address next) external onlyOwner {
        pendingOwner = next;
        emit OwnershipProposed(owner, next);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    function createAccount(address owner_, uint256 index) public returns (address account) {
        account = predictAccount(owner_, index);
        if (account.code.length != 0) return account;
        address made = Clones.cloneDeterministic(implementation, _salt(owner_, index));
        if (made != account) revert WrongAddress(account, made);
        BittyAccount(payable(made)).initialize(owner_);
        emit AccountCreated(made, owner_, index);
    }

    /**
     * @notice Create `owner_`'s account number `index` if it does not exist yet, then run the batch
     *         the owner signed for it ({BittyAccount-executeSigned}): a new user's first send, and the
     *         account's creation, in one relayed transaction. Anyone may send it; only the owner's
     *         signature makes the batch run.
     */
    function createAndExecute(
        address owner_,
        uint256 index,
        BittyAccount.Call[] calldata calls,
        uint256 deadline,
        bytes calldata signature
    ) external returns (address account, bytes[] memory results) {
        account = createAccount(owner_, index);
        results = BittyAccount(payable(account)).executeSigned(calls, deadline, signature);
    }

    /// The address of `owner_`'s account number `index`, created or not.
    function predictAccount(address owner_, uint256 index) public view returns (address) {
        return _create2(create2Prefix, _salt(owner_, index), _cloneCodeHash);
    }

    function _salt(address owner_, uint256 index) private pure returns (bytes32) {
        return keccak256(abi.encode(owner_, index));
    }

    function _create2(bytes1 prefix, bytes32 salt, bytes32 codeHash) private view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(prefix, address(this), salt, codeHash)))));
    }
}
