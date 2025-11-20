// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.27;

import {Initializable} from "lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {IAssets} from "./interfaces/IAssets.sol";

contract Assets is IAssets, Initializable, Ownable {
    mapping(address => bool) public whiteListedAssets;

    constructor() {
        transferOwnership(tx.origin);
    }

    function add(address assetAddress) external override onlyOwner {
        whiteListedAssets[assetAddress] = true;
    }

    function remove(address assetAddress) external override onlyOwner {
        whiteListedAssets[assetAddress] = false;
    }

    function isWhiteListed(address assetAddress) external view override returns (bool) {
        return whiteListedAssets[assetAddress];
    }
}
