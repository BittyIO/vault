// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1IntentProtocol} from "protocol-contracts/src/interfaces/IBittyV1IntentProtocol.sol";

/// @dev Records register/cancel calls made by the vault during intent order lifecycle.
contract MockIntentRegistry {
    uint256 public registerCount;
    uint256 public cancelCount;
    bytes32 public lastRegistered;
    bytes32 public lastCancelled;

    function register(bytes32 orderId) external {
        registerCount++;
        lastRegistered = orderId;
    }

    function cancel(bytes32 orderId) external {
        cancelCount++;
        lastCancelled = orderId;
    }
}

/// @dev Minimal intent protocol used to exercise AssetManagerLogic's intent paths without
///      a real CoW/UniswapX integration. Works as an EIP-1167 clone: config lives in
///      immutables (read from implementation bytecode) while validHash lives in clone storage.
contract MockIntentProtocol is IBittyV1IntentProtocol {
    address public immutable registry;
    bool public immutable skipRegister; // when true, registerTarget/cancelTarget = address(0)
    bool public immutable skipApprove; // when true, approveTarget = address(0)

    address public owner;
    mapping(bytes32 => bool) public validHash;

    constructor(address registry_, bool skipRegister_, bool skipApprove_) {
        registry = registry_;
        skipRegister = skipRegister_;
        skipApprove = skipApprove_;
    }

    function initialize(address newOwner) external override {
        owner = newOwner;
    }

    /// @dev Mark a hash as a valid signature for this clone (call on the clone address).
    function setValid(bytes32 hash, bool ok) external {
        validHash[hash] = ok;
    }

    function buildLimitOrderInstructions(bytes memory data)
        external
        view
        override
        returns (OrderInstructions memory instr)
    {
        (address sellToken, uint256 sellAmount,,,,) =
            abi.decode(data, (address, uint256, address, uint256, uint32, bool));
        instr.orderId = keccak256(data);
        instr.sellToken = sellToken;
        instr.sellAmount = sellAmount;
        instr.approveTarget = skipApprove ? address(0) : registry;
        if (!skipRegister) {
            instr.registerTarget = registry;
            instr.registerCalldata = abi.encodeWithSignature("register(bytes32)", instr.orderId);
        }
    }

    function buildTwapInstructions(bytes memory data)
        external
        view
        override
        returns (OrderInstructions memory instr, uint256 expiresAt)
    {
        (address from, uint256 totalSellAmount,,, uint256 n, uint256 partDuration,) =
            abi.decode(data, (address, uint256, address, uint256, uint256, uint256, uint256));
        instr.orderId = keccak256(data);
        instr.sellToken = from;
        instr.sellAmount = totalSellAmount;
        instr.approveTarget = skipApprove ? address(0) : registry;
        if (!skipRegister) {
            instr.registerTarget = registry;
            instr.registerCalldata = abi.encodeWithSignature("register(bytes32)", instr.orderId);
        }
        expiresAt = block.timestamp + n * partDuration;
    }

    function buildCancelInstructions(bytes32 orderId) external view override returns (CancelInstructions memory instr) {
        instr.cancelTarget = skipRegister ? address(0) : registry;
        instr.cancelCalldata = abi.encodeWithSignature("cancel(bytes32)", orderId);
        instr.approveTarget = skipApprove ? address(0) : registry;
    }

    function isValidSignature(bytes32 hash, bytes memory) external view override returns (bytes4) {
        if (validHash[hash]) return 0x1626ba7e;
        revert("MockIntent: bad sig");
    }
}
