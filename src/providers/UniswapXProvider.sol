// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IIntentProvider, ApprovalNotFound, OrderNotExpired} from "../interfaces/IIntentProvider.sol";
import {IERC1271} from "../libs/cow/IERC1271.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";

/**
 * @title UniswapX Provider
 * @notice IIntentProvider implementation for UniswapX using EIP-1271
 * @dev UniswapX uses Permit2 for token transfers. Orders are signed (EIP-1271 for contracts),
 *      submitted to the UniswapX API, and settled asynchronously by fillers.
 *      For use with AssetManager ammRebalance: an off-chain service must submit the order
 *      to the UniswapX API after swap() approves the hash. Settlement occurs when
 *      a filler executes the order via the reactor.
 */
contract UniswapXProvider is IIntentProvider, IERC1271, Ownable, Initializable {
    using SafeERC20 for IERC20;

    // @dev EIP-1271 magic value for valid signature
    bytes4 private constant MAGICVALUE = 0x1626ba7e;

    // @dev Default order validity (1 hour) when not specified in swap data
    uint32 private constant DEFAULT_VALID_TO_OFFSET = 3600;

    address public immutable reactor;
    address public immutable permit2;

    /**
     * @dev Approved hashes for EIP-1271 signing (owner => hash => approved)
     * @notice The hash is the full EIP-712 hash from Permit2's permitWitnessTransferFrom
     */
    mapping(address => mapping(bytes32 => bool)) public approvedHashes;

    /// @dev Sell token for a Permit2 witness hash (set when trade approves that hash) so cancelTrade can revoke Permit2 allowance
    mapping(bytes32 => address) private _hashToSellToken;

    /// @dev validTo for a given hash, used by cleanExpiredOrders
    mapping(bytes32 => uint32) private _hashToValidTo;

    /// @dev Sell amount for a given hash, used by cleanExpiredOrders to decrease allowance precisely
    mapping(bytes32 => uint256) private _hashToSellAmount;

    /**
     * @notice Constructor
     * @param reactor_ The address of the UniswapX reactor
     * @param permit2_ The address of the Permit2 contract
     */
    constructor(address reactor_, address permit2_) {
        reactor = reactor_;
        permit2 = permit2_;
    }

    function initialize(address newOwner) external override initializer {
        _transferOwnership(newOwner);
    }

    receive() external payable {}

    /**
     * @notice Swap via UniswapX using EIP-1271 (sign to sell/buy)
     * @dev Approves the given hash for Permit2 signature verification.
     *      Tokens are transferred to this contract and approved for Permit2.
     *      Order must be submitted to UniswapX API by an off-chain service.
     *      Settlement is asynchronous (filler executes the order).
     *      NOTE: Cannot be used with AssetManager.ammRebalance() as-is - settlement is async.
     * @param data Encoded: (sellToken, sellAmount, buyToken, buyAmountMin) or
     *             (sellToken, sellAmount, buyToken, buyAmountMin, validTo) or
     *             (sellToken, sellAmount, buyToken, buyAmountMin, validTo, hashToApprove) or
     *             (sellToken, sellAmount, buyToken, buyAmountMin, validTo, hashToApprove, isSellOrder)
     *             hashToApprove = full EIP-712 hash from Permit2 permitWitnessTransferFrom (computed off-chain)
     */
    function trade(bytes memory data) external override onlyOwner {
        (address sellToken, uint256 sellAmount,,,, bytes32 hashToApprove,) = _decodeSwapData(data);

        if (sellToken != address(0)) {
            IERC20(sellToken).safeTransferFrom(msg.sender, address(this), sellAmount);
            IERC20(sellToken).safeIncreaseAllowance(permit2, sellAmount);
        }

        if (hashToApprove != bytes32(0)) {
            approvedHashes[owner()][hashToApprove] = true;
            if (sellToken != address(0)) {
                _hashToSellToken[hashToApprove] = sellToken;
                _hashToSellAmount[hashToApprove] = sellAmount;
            }
            (,,,, uint32 validTo,,) = _decodeSwapData(data);
            _hashToValidTo[hashToApprove] = validTo;
        }

        emit Trade(data, msg.sender, address(this));

        // Note: Permit2 approval remains until cancelTrade or order fill; cancelTrade revokes allowance on the clone
    }

    /// @notice Cancel a trade/order and revoke Permit2 allowance for the sell token when known.
    /// @param data abi.encode(bytes32 hash) when hash was set in trade with hashToApprove, or
    ///        abi.encode(bytes32 hash, address sellToken) to revoke approval (e.g. trade had hashToApprove == 0).
    function cancelTrade(bytes memory data) external override onlyOwner {
        bytes32 hash;
        address sellToken;
        if (data.length == 32) {
            hash = abi.decode(data, (bytes32));
            sellToken = _hashToSellToken[hash];
            if (hash != bytes32(0)) {
                approvedHashes[owner()][hash] = false;
                delete _hashToSellToken[hash];
                delete _hashToValidTo[hash];
                delete _hashToSellAmount[hash];
            }
        } else {
            (hash, sellToken) = abi.decode(data, (bytes32, address));
            if (hash != bytes32(0)) {
                approvedHashes[owner()][hash] = false;
                delete _hashToSellToken[hash];
                delete _hashToValidTo[hash];
                delete _hashToSellAmount[hash];
            }
        }
        if (sellToken != address(0)) {
            IERC20(sellToken).safeApprove(permit2, 0);
            uint256 balance = IERC20(sellToken).balanceOf(address(this));
            if (balance > 0) IERC20(sellToken).safeTransfer(msg.sender, balance);
        }
        emit CancelTrade(data, msg.sender, address(this));
    }

    /**
     * @notice Approve a hash for EIP-1271 signing
     * @dev The hash must be the full EIP-712 hash from Permit2's permitWitnessTransferFrom.
     *      Used when submitting orders to UniswapX API with EIP-1271 scheme.
     * @param hash The Permit2 witness hash to approve
     */
    function approveHash(bytes32 hash) external onlyOwner {
        approvedHashes[owner()][hash] = true;
    }

    /**
     * @notice Revoke an approved hash
     * @param hash The hash to revoke
     */
    function revokeHash(bytes32 hash) external onlyOwner {
        approvedHashes[owner()][hash] = false;
    }

    /**
     * @notice EIP-1271: Verify signature for UniswapX/Permit2 orders
     * @dev Returns MAGICVALUE if the hash is approved by the owner
     * @param hash The Permit2 EIP-712 hash (permit + witness)
     */
    function isValidSignature(
        bytes32 hash,
        bytes memory /* signature */
    )
        external
        view
        override(IERC1271, IIntentProvider)
        returns (bytes4)
    {
        if (approvedHashes[owner()][hash]) {
            return MAGICVALUE;
        }
        return 0xffffffff;
    }

    function revokeApprovals(address[] calldata tokens) external override onlyOwner {
        for (uint256 i = 0; i < tokens.length; i++) {
            if (IERC20(tokens[i]).allowance(address(this), permit2) == 0) continue;
            IERC20(tokens[i]).safeApprove(permit2, 0);
        }
    }

    function cleanExpiredOrders(bytes32[] calldata hashes) external override {
        for (uint256 i = 0; i < hashes.length; i++) {
            bytes32 hash = hashes[i];
            if (_hashToValidTo[hash] == 0 || block.timestamp <= _hashToValidTo[hash]) revert OrderNotExpired();
            approvedHashes[owner()][hash] = false;
            address sellToken = _hashToSellToken[hash];
            if (sellToken != address(0)) {
                uint256 orderSellAmount = _hashToSellAmount[hash];
                uint256 currentAllowance = IERC20(sellToken).allowance(address(this), permit2);
                uint256 decreaseBy = orderSellAmount < currentAllowance ? orderSellAmount : currentAllowance;
                if (decreaseBy > 0) IERC20(sellToken).safeDecreaseAllowance(permit2, decreaseBy);
                uint256 balance = IERC20(sellToken).balanceOf(address(this));
                uint256 toReturn = orderSellAmount < balance ? orderSellAmount : balance;
                if (toReturn > 0) IERC20(sellToken).safeTransfer(owner(), toReturn);
                delete _hashToSellToken[hash];
                delete _hashToSellAmount[hash];
            }
            delete _hashToValidTo[hash];
        }
    }

    function _decodeSwapData(bytes memory data)
        internal
        view
        returns (
            address sellToken,
            uint256 sellAmount,
            address buyToken,
            uint256 buyAmountMin,
            uint32 validTo,
            bytes32 hashToApprove,
            bool isSellOrder
        )
    {
        if (data.length >= 224) {
            (sellToken, sellAmount, buyToken, buyAmountMin, validTo, hashToApprove, isSellOrder) =
                abi.decode(data, (address, uint256, address, uint256, uint32, bytes32, bool));
        } else if (data.length >= 192) {
            (sellToken, sellAmount, buyToken, buyAmountMin, validTo, hashToApprove) =
                abi.decode(data, (address, uint256, address, uint256, uint32, bytes32));
            isSellOrder = true;
        } else if (data.length >= 160) {
            (sellToken, sellAmount, buyToken, buyAmountMin, validTo) =
                abi.decode(data, (address, uint256, address, uint256, uint32));
            isSellOrder = true;
        } else {
            (sellToken, sellAmount, buyToken, buyAmountMin) = abi.decode(data, (address, uint256, address, uint256));
            validTo = uint32(block.timestamp + DEFAULT_VALID_TO_OFFSET);
            isSellOrder = true;
        }
    }
}
