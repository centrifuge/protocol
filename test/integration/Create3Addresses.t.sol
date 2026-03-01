// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseDeployer} from "../../script/BaseDeployer.s.sol";
import "forge-std/Test.sol";

contract SimpleContract {
    uint256 public value;

    constructor(uint256 value_) {
        value = value_;
    }
}

contract Create3AddressesTest is Test, BaseDeployer {
    function setUp() public {
        _init("", address(this));
    }

    function testPreviewMatchesCreate3() public {
        address predicted = previewCreate3Address("testContract", "v3.1");
        address deployed = create3(
            createSalt("testContract", "v3.1"), abi.encodePacked(type(SimpleContract).creationCode, abi.encode(42))
        );

        assertEq(deployed, predicted, "CREATE3 address does not match preview");
        assertEq(SimpleContract(deployed).value(), 42);
    }

    function testPreviewMatchesCreate3WithSuffix() public {
        _init("rev2", address(this));

        address predicted = previewCreate3Address("testContract", "v3.1");
        address deployed = create3(
            createSalt("testContract", "v3.1"), abi.encodePacked(type(SimpleContract).creationCode, abi.encode(99))
        );

        assertEq(deployed, predicted, "CREATE3 address does not match preview with suffix");
        assertEq(SimpleContract(deployed).value(), 99);
    }

    function testSuffixProducesDifferentAddress() public {
        address withoutSuffix = previewCreate3Address("testContract", "v3.1");

        _init("rev2", address(this));
        address withSuffix = previewCreate3Address("testContract", "v3.1");

        assertTrue(withoutSuffix != withSuffix, "Suffix should produce a different address");
    }

    function testDifferentDeployersProduceDifferentAddresses() public {
        address addr1 = previewCreate3Address("testContract", "v3.1");

        _init("", makeAddr("otherDeployer"));
        address addr2 = previewCreate3Address("testContract", "v3.1");

        assertTrue(addr1 != addr2, "Different deployers should produce different addresses");
    }
}
