// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {ISubscribe} from "./interfaces/ISubscribe.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Initializable} from "lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {AddressZero, InsufficientBalance} from "./interfaces/IVault.sol";
import {IWhiteList, NotWhiteListed} from "./interfaces/IWhiteList.sol";
import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

contract Subscribe is ISubscribe, Ownable, Initializable {
    using SafeERC20 for IERC20Metadata;
    uint256 public constant SUBSCRIPTION_FEE = 99;
    uint256 public constant SUBSCRIPTION_DURATION = 365 days;

    address private _whiteList;
    mapping(address => uint256) public expirationTimes;
    address subscriptionFeeReceiver;

    constructor() {}

    function initialize(address whiteListAddress_) external initializer {
        if (whiteListAddress_ == address(0)) {
            revert AddressZero();
        }
        _whiteList = whiteListAddress_;
    }

    function setSubscriptionFeeReceiver(address subscriptionFeeReceiver_) external override onlyOwner {
        if (subscriptionFeeReceiver_ == address(0)) {
            revert AddressZero();
        }
        subscriptionFeeReceiver = subscriptionFeeReceiver_;
    }

    function subscribe(address stableCoinAddress, uint8 yearCount) external override {
        if (!IWhiteList(_whiteList).isStableCoinWhiteListed(stableCoinAddress)) {
            revert NotWhiteListed();
        }
        uint256 startTimestamp = (expirationTimes[msg.sender] == 0 || expirationTimes[msg.sender] < block.timestamp)
            ? block.timestamp
            : expirationTimes[msg.sender];
        expirationTimes[msg.sender] = startTimestamp + SUBSCRIPTION_DURATION * yearCount;
        IERC20Metadata stableCoin = IERC20Metadata(stableCoinAddress);
        uint256 fee = SUBSCRIPTION_FEE * 10 ** stableCoin.decimals() * yearCount;
        if (stableCoin.balanceOf(msg.sender) < fee) {
            revert InsufficientBalance();
        }
        stableCoin.safeTransferFrom(msg.sender, subscriptionFeeReceiver, fee);
    }

    function getExpirationTime(address user) external view override returns (uint256) {
        return expirationTimes[user];
    }
}
