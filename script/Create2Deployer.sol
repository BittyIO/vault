// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {console2} from "forge-std/console2.sol";

abstract contract Create2Deployer {
    address internal constant SIMPLE_CREATE2 = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 internal constant LOGIC_SALT = bytes32(0);

    function _predictCreate2(bytes memory initCode) internal pure returns (address predicted) {
        predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), SIMPLE_CREATE2, LOGIC_SALT, keccak256(initCode)))))
        );
    }

    function _deployCreate2(string memory name, bytes memory initCode) internal returns (address deployed) {
        deployed = _predictCreate2(initCode);
        if (deployed.code.length > 0) {
            console2.log(name, "already deployed at", deployed);
            return deployed;
        }
        (bool ok, bytes memory ret) = SIMPLE_CREATE2.call(abi.encodePacked(LOGIC_SALT, initCode));
        require(ok && ret.length == 20, "CREATE2 deploy failed");
        deployed = address(bytes20(ret));
        console2.log(name, "deployed at", deployed);
    }
}
