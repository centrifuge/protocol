// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {ERC6909Factory} from "src/ERC6909Factory.sol";

contract ERC6909FactoryTest is Test {
    ERC6909Factory factory;

    function setUp() public {
        factory = new ERC6909Factory(address(this));
    }

    function testAuthorizationRestriction() public {
        assertEq(factory.wards(address(this)), 1);
    }

    function testCreatingNewInstance() public {
        bytes32 salt = keccak256("salt me");

        vm.expectRevert("Auth/not-authorized");
        vm.prank(makeAddr("unauthorized"));
        factory.deploy(address(this), salt);

        address instance = factory.deploy(address(this), salt);
        assertTrue(instance != address(0));

        assertEq(factory.previewAddress(address(this), salt), instance);
    }

    function testDeterminism() public {
        bytes32 salt = keccak256("deterministic");
        address owner = address(0xdeadbeef);
        address instance = factory.deploy(owner, salt);
        assertEq(instance, factory.previewAddress(owner, salt));
    }
}
