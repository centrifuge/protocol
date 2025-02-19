// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {ERC6909Factory} from "src/misc/ERC6909Factory.sol";

contract ERC6909FactoryTest is Test {
    ERC6909Factory factory;

    function setUp() public {
        factory = new ERC6909Factory();
    }

    function testCreatingNewInstance() public {
        bytes32 salt = keccak256("salt me");

        address instance = factory.deploy(address(this), salt);
        assertTrue(instance != address(0));

        assertEq(factory.previewAddress(address(this), salt), instance);
    }

    function testDeterminism(bytes32 salt, address owner) public {
        vm.assume(owner != address(0));
        vm.assume(salt != "");
        address instance = factory.deploy(owner, salt);
        assertEq(instance, factory.previewAddress(owner, salt));
    }
}
