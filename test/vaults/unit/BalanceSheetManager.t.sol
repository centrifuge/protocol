// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "test/vaults/BaseTest.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";
import {d18} from "src/misc/types/D18.sol";

import {Meta, JournalEntry} from "src/common/types/JournalEntry.sol";
import {MessageLib} from "src/common/libraries/MessageLib.sol";

import {BalanceSheetManager} from "src/vaults/BalanceSheetManager.sol";

contract BalanceSheetManagerTest is BaseTest {
    using MessageLib for *;

    uint128 defaultAmount;

    function setUp() public override {
        super.setUp();
        defaultAmount = 100;
    }

    function _defaultMeta() internal returns (Meta memory) {
        return Meta({timestamp: block.timestamp, debits: new JournalEntry[](0), credits: new JournalEntry[](0)});
    }

    // Deployment
    function testDeployment(address nonWard) public {
        vm.assume(
            nonWard != address(root) && nonWard != address(vaultFactory) && nonWard != address(gateway)
                && nonWard != address(this)
        );

        // redeploying within test to increase coverage
        new BalanceSheetManager(address(escrow));

        // values set correctly
        assertEq(address(balanceSheetManager.escrow()), address(escrow));
        assertEq(address(balanceSheetManager.gateway()), address(gateway));
        assertEq(address(balanceSheetManager.poolManager()), address(poolManager));
        assertEq(address(gateway.handler()), address(balanceSheetManager.sender()));

        // permissions set correctly
        assertEq(balanceSheetManager.wards(address(root)), 1);
        assertEq(balanceSheetManager.wards(address(messageProcessor)), 1);
        assertEq(balanceSheetManager.wards(nonWard), 0);
    }

    // --- Administration ---
    function testFile() public {
        // fail: unrecognized param
        vm.expectRevert(bytes("BalanceSheetManager/file-unrecognized-param"));
        balanceSheetManager.file("random", self);

        assertEq(address(balanceSheetManager.gateway()), address(gateway));
        // success
        balanceSheetManager.file("poolManager", randomUser);
        assertEq(address(balanceSheetManager.poolManager()), randomUser);
        balanceSheetManager.file("gateway", randomUser);
        assertEq(address(balanceSheetManager.gateway()), randomUser);
        balanceSheetManager.file("sender", randomUser);
        assertEq(address(balanceSheetManager.sender()), randomUser);

        // remove self from wards
        balanceSheetManager.deny(self);
        // auth fail
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheetManager.file("poolManager", randomUser);
    }

    // --- IRecoverable ---
    function testRecoverTokens() public {
        erc20.mint(address(balanceSheetManager), defaultAmount);
        erc6909.mint(address(balanceSheetManager), defaultErc6909TokenId, defaultAmount);
        address receiver = address(this);

        // fail: not auth
        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheetManager.recoverTokens(address(erc20), erc20TokenId, receiver, defaultAmount);

        vm.prank(address(root));
        balanceSheetManager.recoverTokens(address(erc20), erc20TokenId, receiver, defaultAmount);
        assertEq(erc20.balanceOf(receiver), defaultAmount);

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheetManager.recoverTokens(address(erc6909), defaultErc6909TokenId, receiver, defaultAmount);

        vm.prank(address(root));
        balanceSheetManager.recoverTokens(address(erc6909), defaultErc6909TokenId, receiver, defaultAmount);
        assertEq(erc6909.balanceOf(receiver, defaultErc6909TokenId), defaultAmount);
    }

    // --- IUpdateContract ---
    function testUpdate() public {
        erc20.mint(address(this), defaultAmount);
        erc20.approve(address(balanceSheetManager), defaultAmount);

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheetManager.deposit(
            defaultPoolId,
            defaultShareClassId,
            address(erc20),
            erc20TokenId,
            address(this),
            defaultAmount,
            d18(100, 5),
            _defaultMeta()
        );

        balanceSheetManager.update(
            defaultPoolId,
            defaultShareClassId,
            MessageLib.UpdateContractPermission({who: randomUser, allowed: true}).serialize()
        );

        balanceSheetManager.deposit(
            defaultPoolId,
            defaultShareClassId,
            address(erc20),
            erc20TokenId,
            address(this),
            defaultAmount,
            d18(100, 5),
            _defaultMeta()
        );
    }

    // --- IBalanceSheetManager ---
    function testDeposit() public {
        // fail: not auth
        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheetManager.deposit(
            defaultPoolId,
            defaultShareClassId,
            address(erc20),
            erc20TokenId,
            address(this),
            defaultAmount,
            d18(100, 5),
            _defaultMeta()
        );

        vm.expectRevert(IERC20.InsufficientBalance.selector);
        balanceSheetManager.deposit(
            defaultPoolId,
            defaultShareClassId,
            address(erc20),
            erc20TokenId,
            address(this),
            defaultAmount,
            d18(100, 5),
            _defaultMeta()
        );

        erc20.mint(address(this), defaultAmount);
        erc20.approve(address(balanceSheetManager), defaultAmount);
        balanceSheetManager.deposit(
            defaultPoolId,
            defaultShareClassId,
            address(erc20),
            erc20TokenId,
            address(this),
            defaultAmount,
            d18(100, 5),
            _defaultMeta()
        );

        assertEq(erc20.balanceOf(address(this)), 0);
    }

    function testWithdraw() public {}

    function testIssue() public {}

    function testRevoke() public {}

    function testUpdateJournal() public {}

    function testUpdateValue() public {}
}
