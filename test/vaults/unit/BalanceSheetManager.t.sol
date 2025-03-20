// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "test/vaults/BaseTest.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {d18} from "src/misc/types/D18.sol";

import {Meta, JournalEntry} from "src/common/types/JournalEntry.sol";
import {MessageLib} from "src/common/libraries/MessageLib.sol";

import {BalanceSheetManager} from "src/vaults/BalanceSheetManager.sol";

contract BalanceSheetManagerTest is BaseTest {
    using MessageLib for *;
    using CastLib for *;

    uint128 defaultAmount;

    function setUp() public override {
        super.setUp();
        defaultAmount = 100;
        poolManager.registerAsset(address(erc20), erc20TokenId, defaultChainId);
        poolManager.addPool(defaultPoolId);
        poolManager.addTranche(
            defaultPoolId,
            defaultShareClassId,
            "testShareClass",
            "tsc",
            defaultDecimals,
            bytes32(""),
            restrictionManager
        );
        poolManager.updateRestriction(
            defaultPoolId,
            defaultShareClassId,
            MessageLib.UpdateRestrictionMember({user: address(this).toBytes32(), validUntil: MAX_UINT64}).serialize()
        );
        // In order for allowances to work during issuance, the balanceSheetManager must be allowed to transfer
        poolManager.updateRestriction(
            defaultPoolId,
            defaultShareClassId,
            MessageLib.UpdateRestrictionMember({user: address(balanceSheetManager).toBytes32(), validUntil: MAX_UINT64})
                .serialize()
        );
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

        balanceSheetManager.update(
            defaultPoolId,
            defaultShareClassId,
            MessageLib.UpdateContractPermission({who: randomUser, allowed: false}).serialize()
        );

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
    }

    // --- IBalanceSheetManager ---
    function testDeposit() public {
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

        vm.expectRevert(SafeTransferLib.SafeTransferFromFailed.selector);
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

    function testWithdraw() public {
        testDeposit();

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheetManager.withdraw(
            defaultPoolId,
            defaultShareClassId,
            address(erc20),
            erc20TokenId,
            address(this),
            defaultAmount,
            d18(100, 5),
            false,
            _defaultMeta()
        );

        assertEq(erc20.balanceOf(address(this)), 0);

        balanceSheetManager.withdraw(
            defaultPoolId,
            defaultShareClassId,
            address(erc20),
            erc20TokenId,
            address(this),
            defaultAmount,
            d18(100, 5),
            false,
            _defaultMeta()
        );

        assertEq(erc20.balanceOf(address(this)), defaultAmount);
    }

    function testWithdrawWithAllowance() public {
        testDeposit();

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheetManager.withdraw(
            defaultPoolId,
            defaultShareClassId,
            address(erc20),
            erc20TokenId,
            address(this),
            defaultAmount,
            d18(100, 5),
            true,
            _defaultMeta()
        );

        assertEq(erc20.balanceOf(address(this)), 0);

        balanceSheetManager.withdraw(
            defaultPoolId,
            defaultShareClassId,
            address(erc20),
            erc20TokenId,
            address(this),
            defaultAmount,
            d18(100, 5),
            true,
            _defaultMeta()
        );

        erc20.transferFrom(address(balanceSheetManager), address(this), defaultAmount);
        assertEq(erc20.balanceOf(address(this)), defaultAmount);
    }

    function testIssue() public {
        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheetManager.issue(defaultPoolId, defaultShareClassId, address(this), defaultAmount, false);

        IERC20 token = IERC20(poolManager.tranche(defaultPoolId, defaultShareClassId));
        assertEq(token.balanceOf(address(this)), 0);

        balanceSheetManager.issue(defaultPoolId, defaultShareClassId, address(this), defaultAmount, false);

        assertEq(token.balanceOf(address(this)), defaultAmount);
    }

    function testIssueAsAllowance() public {
        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheetManager.issue(defaultPoolId, defaultShareClassId, address(this), defaultAmount, true);

        IERC20 token = IERC20(poolManager.tranche(defaultPoolId, defaultShareClassId));
        assertEq(token.balanceOf(address(this)), 0);

        balanceSheetManager.issue(defaultPoolId, defaultShareClassId, address(this), defaultAmount, true);

        token.transferFrom(address(balanceSheetManager), address(this), defaultAmount);
        assertEq(token.balanceOf(address(this)), defaultAmount);    }

    function testRevoke() public {}

    function testUpdateJournal() public {}

    function testUpdateValue() public {}
}
