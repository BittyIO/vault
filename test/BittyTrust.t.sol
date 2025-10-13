// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BittyTrust} from "../src/BittyTrust.sol";

// ENS interfaces for testing
interface ENS {
    function resolver(bytes32 node) external view returns (address);
}

interface Resolver {
    function addr(bytes32 node) external view returns (address);
}

contract BittyTrustTest is Test {
    BittyTrust public bittyTrust;

    function setUp() public {
        bittyTrust = new BittyTrust();
    }

    function test_InitErrorWithGrantorAddressZero() public {
        vm.expectRevert(BittyTrust.AddressZero.selector);
        bittyTrust.initialize(address(0));
    }

    function test_InitErrorWithAlreadyInitialized() public {
        bittyTrust.initialize(address(1));
        vm.expectRevert(BittyTrust.AlreadyInitialized.selector);
        bittyTrust.initialize(address(1));
    }

    function test_SetTrustToIrrevocable() public {
        bittyTrust.initialize(address(this));
        bittyTrust.setToIrrevocable();
        assertEq(bittyTrust.revocable(), false);
    }

    function test_AutoIrrevocableAfterNoPing() public {
        bittyTrust.initialize(address(this));
        bittyTrust.setAutoIrrevocableAfterNoPing(1);
        vm.warp(block.timestamp + 2);
        assertEq(bittyTrust.revocable(), false);
    }

    function test_RevocableAfterPing() public {
        bittyTrust.initialize(address(this));
        bittyTrust.setAutoIrrevocableAfterNoPing(2);
        bittyTrust.ping();
        vm.warp(block.timestamp + 1);
        assertEq(bittyTrust.revocable(), true);
    }

    function test_InitializeWithENS() public {
        address mockResolver = address(0x1234567890123456789012345678901234567890);
        address mockAddress = address(0xABcdEFABcdEFabcdEfAbCdefabcdeFABcDEFabCD);

        vm.mockCall(
            address(0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e),
            abi.encodeWithSelector(ENS.resolver.selector, namehash("test.eth")),
            abi.encode(mockResolver)
        );

        vm.mockCall(
            mockResolver, abi.encodeWithSelector(Resolver.addr.selector, namehash("test.eth")), abi.encode(mockAddress)
        );

        bittyTrust.initializeWithENS("test.eth");
        assertEq(bittyTrust.grantor(), mockAddress);
        assertEq(bittyTrust.grantorENS(), "test.eth");
        assertTrue(bittyTrust.isInitialized());
    }

    function test_SetTrusteeWithENS() public {
        bittyTrust.initialize(address(this));

        address mockResolver = address(0x1234567890123456789012345678901234567890);
        address mockTrustee = address(0xABcdEFABcdEFabcdEfAbCdefabcdeFABcDEFabCD);

        vm.mockCall(
            address(0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e),
            abi.encodeWithSelector(ENS.resolver.selector, namehash("trustee.eth")),
            abi.encode(mockResolver)
        );

        vm.mockCall(
            mockResolver,
            abi.encodeWithSelector(Resolver.addr.selector, namehash("trustee.eth")),
            abi.encode(mockTrustee)
        );

        bittyTrust.setTrusteeWithENS("trustee.eth");
        assertEq(bittyTrust.trustee(), mockTrustee);
        assertEq(bittyTrust.trusteeENS(), "trustee.eth");
        assertEq(bittyTrust.getCurrentTrustee(), mockTrustee);
    }

    function test_ENSResolutionFailure() public {
        vm.mockCall(
            address(0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e),
            abi.encodeWithSelector(ENS.resolver.selector, namehash("nonexistent.eth")),
            abi.encode(address(0))
        );

        vm.expectRevert(BittyTrust.ENSResolutionFailed.selector);
        bittyTrust.initializeWithENS("nonexistent.eth");
    }

    function test_InvalidENSName() public {
        vm.expectRevert(BittyTrust.InvalidENSName.selector);
        bittyTrust.initializeWithENS("");
    }

    function test_ENSNameStorage() public {
        address mockResolver = address(0x1234567890123456789012345678901234567890);
        address mockAddress = address(0xABcdEFABcdEFabcdEfAbCdefabcdeFABcDEFabCD);

        vm.mockCall(
            address(0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e),
            abi.encodeWithSelector(ENS.resolver.selector, namehash("alice.eth")),
            abi.encode(mockResolver)
        );

        vm.mockCall(
            mockResolver, abi.encodeWithSelector(Resolver.addr.selector, namehash("alice.eth")), abi.encode(mockAddress)
        );

        bittyTrust.initializeWithENS("alice.eth");

        assertEq(bittyTrust.grantorENS(), "alice.eth");
        assertEq(bittyTrust.grantor(), mockAddress);

        assertEq(bittyTrust.getCurrentGrantor(), mockAddress);
    }

    function test_ENSResolutionWhenAvailable() public {
        address mockResolver = address(0x1234567890123456789012345678901234567890);
        address mockAddress = address(0xABcdEFABcdEFabcdEfAbCdefabcdeFABcDEFabCD);

        vm.mockCall(
            address(0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e),
            abi.encodeWithSelector(ENS.resolver.selector, namehash("alice.eth")),
            abi.encode(mockResolver)
        );

        vm.mockCall(
            mockResolver, abi.encodeWithSelector(Resolver.addr.selector, namehash("alice.eth")), abi.encode(mockAddress)
        );

        bittyTrust.initializeWithENS("alice.eth");

        address newMockAddress = address(0x1234567890123456789012345678901234567890);
        vm.mockCall(
            mockResolver,
            abi.encodeWithSelector(Resolver.addr.selector, namehash("alice.eth")),
            abi.encode(newMockAddress)
        );

        assertEq(bittyTrust.getCurrentGrantor(), newMockAddress);
        assertEq(bittyTrust.grantor(), mockAddress);
    }

    function test_AddressFallbackWhenNoENS() public {
        address testAddress = address(0x1234567890123456789012345678901234567890);
        bittyTrust.initialize(testAddress);

        assertEq(bittyTrust.grantorENS(), "");

        assertEq(bittyTrust.getCurrentGrantor(), testAddress);
    }

    function test_ClearENSWhenSettingAddress() public {
        bittyTrust.initialize(address(this));

        address mockResolver = address(0x1234567890123456789012345678901234567890);
        address mockAddress = address(0xABcdEFABcdEFabcdEfAbCdefabcdeFABcDEFabCD);

        vm.mockCall(
            address(0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e),
            abi.encodeWithSelector(ENS.resolver.selector, namehash("trustee.eth")),
            abi.encode(mockResolver)
        );

        vm.mockCall(
            mockResolver,
            abi.encodeWithSelector(Resolver.addr.selector, namehash("trustee.eth")),
            abi.encode(mockAddress)
        );

        bittyTrust.setTrusteeWithENS("trustee.eth");
        assertEq(bittyTrust.trusteeENS(), "trustee.eth");
        assertEq(bittyTrust.trustee(), mockAddress);
        address newAddress = address(0x1234567890123456789012345678901234567890);
        vm.expectRevert(BittyTrust.ENSConfiguredUseENS.selector);
        bittyTrust.setTrustee(newAddress);
    }

    function test_ENSSetterDoesNotStoreAddress() public {
        bittyTrust.initialize(address(this));

        address mockResolver = address(0x1234567890123456789012345678901234567890);
        address mockAddress = address(0xABcdEFABcdEFabcdEfAbCdefabcdeFABcDEFabCD);

        vm.mockCall(
            address(0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e),
            abi.encodeWithSelector(ENS.resolver.selector, namehash("trustee.eth")),
            abi.encode(mockResolver)
        );

        vm.mockCall(
            mockResolver,
            abi.encodeWithSelector(Resolver.addr.selector, namehash("trustee.eth")),
            abi.encode(mockAddress)
        );

        bittyTrust.setTrusteeWithENS("trustee.eth");
        assertEq(bittyTrust.trusteeENS(), "trustee.eth");
        assertEq(bittyTrust.trustee(), mockAddress);
        assertEq(bittyTrust.getCurrentTrustee(), mockAddress);
    }

    function test_SetAddressRevertsWhenENSConfigured() public {
        bittyTrust.initialize(address(this));

        address mockResolver = address(0x1234567890123456789012345678901234567890);
        address mockAddress = address(0xABcdEFABcdEFabcdEfAbCdefabcdeFABcDEFabCD);

        vm.mockCall(
            address(0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e),
            abi.encodeWithSelector(ENS.resolver.selector, namehash("trustee.eth")),
            abi.encode(mockResolver)
        );

        vm.mockCall(
            mockResolver,
            abi.encodeWithSelector(Resolver.addr.selector, namehash("trustee.eth")),
            abi.encode(mockAddress)
        );

        bittyTrust.setTrusteeWithENS("trustee.eth");

        address newAddress = address(0x1234567890123456789012345678901234567890);
        vm.expectRevert(BittyTrust.ENSConfiguredUseENS.selector);
        bittyTrust.setTrustee(newAddress);
    }

    function test_SetBeneficiaryRevertsWhenENSConfigured() public {
        address mockResolver = address(0x1234567890123456789012345678901234567890);
        address mockAddress = address(0xABcdEFABcdEFabcdEfAbCdefabcdeFABcDEFabCD);

        vm.mockCall(
            address(0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e),
            abi.encodeWithSelector(ENS.resolver.selector, namehash("alice.eth")),
            abi.encode(mockResolver)
        );

        vm.mockCall(
            mockResolver, abi.encodeWithSelector(Resolver.addr.selector, namehash("alice.eth")), abi.encode(mockAddress)
        );

        bittyTrust.initializeWithENS("alice.eth");

        vm.mockCall(
            address(0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e),
            abi.encodeWithSelector(ENS.resolver.selector, namehash("bob.eth")),
            abi.encode(mockResolver)
        );

        vm.mockCall(
            mockResolver, abi.encodeWithSelector(Resolver.addr.selector, namehash("bob.eth")), abi.encode(mockAddress)
        );

        vm.prank(mockAddress);
        bittyTrust.setBeneficiaryWithENS("bob.eth");

        address newAddress = address(0x1234567890123456789012345678901234567890);
        vm.prank(mockAddress);
        vm.expectRevert(BittyTrust.ENSConfiguredUseENS.selector);
        bittyTrust.setBeneficiary(newAddress);
    }

    function test_SetProtectorRevertsWhenENSConfigured() public {
        address mockResolver = address(0x1234567890123456789012345678901234567890);
        address mockAddress = address(0xABcdEFABcdEFabcdEfAbCdefabcdeFABcDEFabCD);

        vm.mockCall(
            address(0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e),
            abi.encodeWithSelector(ENS.resolver.selector, namehash("alice.eth")),
            abi.encode(mockResolver)
        );

        vm.mockCall(
            mockResolver, abi.encodeWithSelector(Resolver.addr.selector, namehash("alice.eth")), abi.encode(mockAddress)
        );

        bittyTrust.initializeWithENS("alice.eth");

        vm.mockCall(
            address(0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e),
            abi.encodeWithSelector(ENS.resolver.selector, namehash("charlie.eth")),
            abi.encode(mockResolver)
        );

        vm.mockCall(
            mockResolver,
            abi.encodeWithSelector(Resolver.addr.selector, namehash("charlie.eth")),
            abi.encode(mockAddress)
        );

        vm.prank(mockAddress);
        bittyTrust.setProtectorWithENS("charlie.eth");

        address newAddress = address(0x1234567890123456789012345678901234567890);
        vm.prank(mockAddress);
        vm.expectRevert(BittyTrust.ENSConfiguredUseENS.selector);
        bittyTrust.setProtector(newAddress);
    }

    function test_ReplaceTrusteeRevertsWhenENSConfigured() public {
        bittyTrust.initialize(address(this));

        address mockResolver = address(0x1234567890123456789012345678901234567890);
        address mockAddress = address(0xABcdEFABcdEFabcdEfAbCdefabcdeFABcDEFabCD);

        vm.mockCall(
            address(0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e),
            abi.encodeWithSelector(ENS.resolver.selector, namehash("trustee.eth")),
            abi.encode(mockResolver)
        );

        vm.mockCall(
            mockResolver,
            abi.encodeWithSelector(Resolver.addr.selector, namehash("trustee.eth")),
            abi.encode(mockAddress)
        );

        bittyTrust.setTrusteeWithENS("trustee.eth");

        bittyTrust.setProtector(address(this));

        address newAddress = address(0x1234567890123456789012345678901234567890);
        vm.expectRevert(BittyTrust.ENSConfiguredUseENS.selector);
        bittyTrust.replaceTrustee(newAddress);
    }

    function test_ReplaceTrusteeENS() public {
        bittyTrust.initialize(address(this));

        address mockResolver = address(0x1234567890123456789012345678901234567890);
        address mockAddress = address(0xABcdEFABcdEFabcdEfAbCdefabcdeFABcDEFabCD);

        vm.mockCall(
            address(0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e),
            abi.encodeWithSelector(ENS.resolver.selector, namehash("trustee.eth")),
            abi.encode(mockResolver)
        );

        vm.mockCall(
            mockResolver,
            abi.encodeWithSelector(Resolver.addr.selector, namehash("trustee.eth")),
            abi.encode(mockAddress)
        );

        bittyTrust.setTrusteeWithENS("trustee.eth");

        bittyTrust.setProtector(address(this));

        address newMockAddress = address(0x1234567890123456789012345678901234567890);
        vm.mockCall(
            address(0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e),
            abi.encodeWithSelector(ENS.resolver.selector, namehash("new-trustee.eth")),
            abi.encode(mockResolver)
        );

        vm.mockCall(
            mockResolver,
            abi.encodeWithSelector(Resolver.addr.selector, namehash("new-trustee.eth")),
            abi.encode(newMockAddress)
        );

        bittyTrust.replaceTrusteeENS("new-trustee.eth");

        assertEq(bittyTrust.trusteeENS(), "new-trustee.eth");
        assertEq(bittyTrust.trustee(), newMockAddress);
        assertEq(bittyTrust.getCurrentTrustee(), newMockAddress);
    }

    function test_ReplaceTrusteeENSAccessControl() public {
        bittyTrust.initialize(address(this));

        bittyTrust.setProtector(address(this));

        address mockResolver = address(0x1234567890123456789012345678901234567890);
        address newMockAddress = address(0x1234567890123456789012345678901234567890);

        vm.mockCall(
            address(0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e),
            abi.encodeWithSelector(ENS.resolver.selector, namehash("new-trustee.eth")),
            abi.encode(mockResolver)
        );

        vm.mockCall(
            mockResolver,
            abi.encodeWithSelector(Resolver.addr.selector, namehash("new-trustee.eth")),
            abi.encode(newMockAddress)
        );

        address nonProtector = address(0x9999999999999999999999999999999999999999);
        vm.prank(nonProtector);
        vm.expectRevert("Only protector");
        bittyTrust.replaceTrusteeENS("new-trustee.eth");

        bittyTrust.replaceTrusteeENS("new-trustee.eth");
        assertEq(bittyTrust.trusteeENS(), "new-trustee.eth");
    }

    function test_ENSExpirationFallback() public {
        address mockResolver = address(0x1234567890123456789012345678901234567890);
        address mockAddress = address(0xABcdEFABcdEFabcdEfAbCdefabcdeFABcDEFabCD);

        vm.mockCall(
            address(0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e),
            abi.encodeWithSelector(ENS.resolver.selector, namehash("alice.eth")),
            abi.encode(mockResolver)
        );

        vm.mockCall(
            mockResolver, abi.encodeWithSelector(Resolver.addr.selector, namehash("alice.eth")), abi.encode(mockAddress)
        );

        bittyTrust.initializeWithENS("alice.eth");

        assertEq(bittyTrust.grantor(), mockAddress);
        assertEq(bittyTrust.grantorENS(), "alice.eth");

        vm.clearMockedCalls();
        assertEq(bittyTrust.getCurrentGrantor(), mockAddress);
    }

    function test_ENSExpirationFallbackForTrustee() public {
        bittyTrust.initialize(address(this));

        address mockResolver = address(0x1234567890123456789012345678901234567890);
        address mockAddress = address(0xABcdEFABcdEFabcdEfAbCdefabcdeFABcDEFabCD);

        vm.mockCall(
            address(0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e),
            abi.encodeWithSelector(ENS.resolver.selector, namehash("trustee.eth")),
            abi.encode(mockResolver)
        );

        vm.mockCall(
            mockResolver,
            abi.encodeWithSelector(Resolver.addr.selector, namehash("trustee.eth")),
            abi.encode(mockAddress)
        );

        bittyTrust.setTrusteeWithENS("trustee.eth");

        assertEq(bittyTrust.trustee(), mockAddress);
        assertEq(bittyTrust.trusteeENS(), "trustee.eth");

        vm.clearMockedCalls();
        assertEq(bittyTrust.getCurrentTrustee(), mockAddress);
    }

    function test_ENSExpirationFallbackForReplaceTrustee() public {
        bittyTrust.initialize(address(this));

        bittyTrust.setProtector(address(this));

        address mockResolver = address(0x1234567890123456789012345678901234567890);
        address newMockAddress = address(0x1234567890123456789012345678901234567890);

        vm.mockCall(
            address(0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e),
            abi.encodeWithSelector(ENS.resolver.selector, namehash("new-trustee.eth")),
            abi.encode(mockResolver)
        );

        vm.mockCall(
            mockResolver,
            abi.encodeWithSelector(Resolver.addr.selector, namehash("new-trustee.eth")),
            abi.encode(newMockAddress)
        );

        bittyTrust.replaceTrusteeENS("new-trustee.eth");

        assertEq(bittyTrust.trustee(), newMockAddress);
        assertEq(bittyTrust.trusteeENS(), "new-trustee.eth");

        vm.clearMockedCalls();
        assertEq(bittyTrust.getCurrentTrustee(), newMockAddress);
    }

    function namehash(string memory name) internal pure returns (bytes32) {
        bytes32 node = 0x0000000000000000000000000000000000000000000000000000000000000000;
        if (bytes(name).length > 0) {
            bytes[] memory nameParts = splitString(name, ".");
            for (uint256 i = nameParts.length; i > 0; i--) {
                node = keccak256(abi.encodePacked(node, keccak256(nameParts[i - 1])));
            }
        }
        return node;
    }

    function splitString(string memory str, string memory delimiter) internal pure returns (bytes[] memory) {
        bytes memory strBytes = bytes(str);
        bytes memory delimiterBytes = bytes(delimiter);

        uint256 count = 1;
        for (uint256 i = 0; i < strBytes.length; i++) {
            if (i + delimiterBytes.length <= strBytes.length) {
                bool isMatch = true;
                for (uint256 j = 0; j < delimiterBytes.length; j++) {
                    if (strBytes[i + j] != delimiterBytes[j]) {
                        isMatch = false;
                        break;
                    }
                }
                if (isMatch) {
                    count++;
                    i += delimiterBytes.length - 1;
                }
            }
        }

        bytes[] memory result = new bytes[](count);
        uint256 resultIndex = 0;
        uint256 start = 0;

        for (uint256 i = 0; i < strBytes.length; i++) {
            if (i + delimiterBytes.length <= strBytes.length) {
                bool isMatch = true;
                for (uint256 j = 0; j < delimiterBytes.length; j++) {
                    if (strBytes[i + j] != delimiterBytes[j]) {
                        isMatch = false;
                        break;
                    }
                }
                if (isMatch) {
                    result[resultIndex] = new bytes(i - start);
                    for (uint256 k = 0; k < i - start; k++) {
                        result[resultIndex][k] = strBytes[start + k];
                    }
                    resultIndex++;
                    start = i + delimiterBytes.length;
                    i += delimiterBytes.length - 1;
                }
            }
        }

        result[resultIndex] = new bytes(strBytes.length - start);
        for (uint256 k = 0; k < strBytes.length - start; k++) {
            result[resultIndex][k] = strBytes[start + k];
        }

        return result;
    }
}
