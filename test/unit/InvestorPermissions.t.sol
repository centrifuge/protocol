// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {InvestorPermissions} from "src/InvestorPermissions.sol";
import {IInvestorPermissions} from "src/interfaces/IInvestorPermissions.sol";

contract InvestorPermissionsTest is Test {
    InvestorPermissions public investorPermissions;

    bytes16 shareClassId = bytes16("shareClass");
    address investor = makeAddr("investor");
    address deployer = makeAddr("deployer");

    function setUp() public {
        investorPermissions = new InvestorPermissions(deployer);
    }

    function testAddInvestorPermission() public {
        investorPermissions.add(shareClassId, investor);

        (uint64 validUntil, bool frozen) = investorPermissions.permissions(shareClassId, investor);

        assertEq(validUntil, type(uint64).max);
        assertEq(frozen, false);
    }

    function testRemoveInvestorPermission() public {
        investorPermissions.add(shareClassId, investor);

        investorPermissions.remove(shareClassId, investor);

        (uint64 validUntil, bool frozen) = investorPermissions.permissions(shareClassId, investor);
        assertEq(validUntil, 0);
        assertEq(frozen, false);
    }

    function testFreezeInvestorPermission() public {
        investorPermissions.add(shareClassId, investor);

        investorPermissions.freeze(shareClassId, investor);

        (uint64 validUntil, bool frozen) = investorPermissions.permissions(shareClassId, investor);
        assertEq(validUntil, type(uint64).max);
        assertEq(frozen, true);
    }

    function testUnfreezeInvestorPermission() public {
        investorPermissions.add(shareClassId, investor);

        investorPermissions.freeze(shareClassId, investor);

        investorPermissions.unfreeze(shareClassId, investor);

        (uint64 validUntil, bool frozen) = investorPermissions.permissions(shareClassId, investor);
        assertEq(validUntil, type(uint64).max);
        assertEq(frozen, false);
    }

    function testIsFrozenInvestor() public {
        investorPermissions.add(shareClassId, investor);

        investorPermissions.freeze(shareClassId, investor);

        bool isFrozen = investorPermissions.isFrozenInvestor(shareClassId, investor);
        assertEq(isFrozen, true);
    }

    function testIsUnfrozenInvestor() public {
        investorPermissions.add(shareClassId, investor);

        bool isUnfrozen = investorPermissions.isUnfrozenInvestor(shareClassId, investor);
        assertEq(isUnfrozen, true);
    }

    function testFreezeNonExistentInvestorReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IInvestorPermissions.Missing.selector));
        investorPermissions.freeze(shareClassId, investor);
    }

    function testUnfreezeNonExistentInvestorReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IInvestorPermissions.Missing.selector));
        investorPermissions.unfreeze(shareClassId, investor);
    }

    function testFreezeAlreadyFrozenInvestorReverts() public {
        investorPermissions.add(shareClassId, investor);

        investorPermissions.freeze(shareClassId, investor);

        vm.expectRevert(abi.encodeWithSelector(IInvestorPermissions.AlreadyFrozen.selector));
        investorPermissions.freeze(shareClassId, investor);
    }

    function testUnfreezeNotFrozenInvestorReverts() public {
        investorPermissions.add(shareClassId, investor);

        vm.expectRevert(abi.encodeWithSelector(IInvestorPermissions.NotFrozen.selector));
        investorPermissions.unfreeze(shareClassId, investor);
    }
}
