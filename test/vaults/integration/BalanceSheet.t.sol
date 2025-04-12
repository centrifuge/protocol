// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "test/vaults/BaseTest.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {D18, d18} from "src/misc/types/D18.sol";

import {Meta, JournalEntry} from "src/common/libraries/JournalEntryLib.sol";
import {MessageLib} from "src/common/libraries/MessageLib.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {AccountId} from "src/common/types/AccountId.sol";

import {IBalanceSheet} from "src/vaults/interfaces/IBalanceSheet.sol";
import {BalanceSheet} from "src/vaults/BalanceSheet.sol";

contract BalanceSheetTest is BaseTest {
    using MessageLib for *;
    using CastLib for *;

    uint128 defaultAmount;
    D18 defaultPricePerShare;
    AssetId assetId;
    ShareClassId defaultTypedShareClassId;

    function setUp() public override {
        super.setUp();
        defaultAmount = 100;
        defaultPricePerShare = d18(1, 1);
        defaultTypedShareClassId = ShareClassId.wrap(defaultShareClassId);

        assetId = AssetId.wrap(poolManager.registerAsset(OTHER_CHAIN_ID, address(erc20), erc20TokenId));
        poolManager.addPool(POOL_A.raw());
        poolManager.addShareClass(
            POOL_A.raw(),
            defaultShareClassId,
            "testShareClass",
            "tsc",
            defaultDecimals,
            bytes32(""),
            restrictedTransfers
        );
        poolManager.updateRestriction(
            POOL_A.raw(),
            defaultShareClassId,
            MessageLib.UpdateRestrictionMember({user: address(this).toBytes32(), validUntil: MAX_UINT64}).serialize()
        );
        // In order for allowances to work during issuance, the balanceSheet must be allowed to transfer
        poolManager.updateRestriction(
            POOL_A.raw(),
            defaultShareClassId,
            MessageLib.UpdateRestrictionMember({user: address(balanceSheet).toBytes32(), validUntil: MAX_UINT64})
                .serialize()
        );
    }

    function _defaultMeta() internal pure returns (Meta memory) {
        JournalEntry[] memory debits = new JournalEntry[](1);
        debits[0] = JournalEntry({amount: 100, accountId: AccountId.wrap(1)});
        JournalEntry[] memory credits = new JournalEntry[](3);
        credits[0] = JournalEntry({amount: 9, accountId: AccountId.wrap(2)});
        credits[1] = JournalEntry({amount: 5, accountId: AccountId.wrap(2)});
        credits[2] = JournalEntry({amount: 5, accountId: AccountId.wrap(3)});

        return Meta({debits: debits, credits: credits});
    }

    // Deployment
    function testDeployment(address nonWard) public {
        vm.assume(
            nonWard != address(root) && nonWard != address(syncRequests) && nonWard != address(gateway)
                && nonWard != address(messageProcessor) && nonWard != address(messageDispatcher) && nonWard != address(this)
        );

        // redeploying within test to increase coverage
        new BalanceSheet(address(escrow));

        // values set correctly
        assertEq(address(balanceSheet.escrow()), address(escrow));
        assertEq(address(balanceSheet.gateway()), address(gateway));
        assertEq(address(balanceSheet.poolManager()), address(poolManager));

        // permissions set correctly
        assertEq(balanceSheet.wards(address(root)), 1);
        assertEq(balanceSheet.wards(address(messageProcessor)), 1);
        assertEq(balanceSheet.wards(nonWard), 0);
    }

    // --- Administration ---
    function testFile() public {
        // fail: unrecognized param
        vm.expectRevert(IBalanceSheet.FileUnrecognizedParam.selector);
        balanceSheet.file("random", self);

        assertEq(address(balanceSheet.gateway()), address(gateway));
        // success
        balanceSheet.file("poolManager", randomUser);
        assertEq(address(balanceSheet.poolManager()), randomUser);
        balanceSheet.file("gateway", randomUser);
        assertEq(address(balanceSheet.gateway()), randomUser);
        balanceSheet.file("sender", randomUser);
        assertEq(address(balanceSheet.sender()), randomUser);

        // remove self from wards
        balanceSheet.deny(self);
        // auth fail
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.file("poolManager", randomUser);
    }

    // --- IUpdateContract ---
    function testUpdate() public {
        erc20.mint(address(this), defaultAmount);
        erc20.approve(address(balanceSheet), defaultAmount);

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.deposit(
            POOL_A,
            defaultTypedShareClassId,
            address(erc20),
            erc20TokenId,
            address(this),
            defaultAmount,
            d18(100, 5),
            _defaultMeta()
        );

        vm.expectEmit();
        emit IBalanceSheet.Permission(POOL_A, defaultTypedShareClassId, randomUser, true);

        balanceSheet.update(
            POOL_A.raw(),
            defaultShareClassId,
            MessageLib.UpdateContractPermission({who: bytes20(randomUser), allowed: true}).serialize()
        );

        balanceSheet.deposit(
            POOL_A,
            defaultTypedShareClassId,
            address(erc20),
            erc20TokenId,
            address(this),
            defaultAmount,
            d18(100, 5),
            _defaultMeta()
        );

        vm.expectEmit();
        emit IBalanceSheet.Permission(POOL_A, defaultTypedShareClassId, randomUser, false);

        balanceSheet.update(
            POOL_A.raw(),
            defaultShareClassId,
            MessageLib.UpdateContractPermission({who: bytes20(randomUser), allowed: false}).serialize()
        );

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.deposit(
            POOL_A,
            defaultTypedShareClassId,
            address(erc20),
            erc20TokenId,
            address(this),
            defaultAmount,
            d18(100, 5),
            _defaultMeta()
        );
    }

    // --- IBalanceSheet ---
    function testDeposit() public {
        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.deposit(
            POOL_A,
            defaultTypedShareClassId,
            address(erc20),
            erc20TokenId,
            address(this),
            defaultAmount,
            d18(100, 5),
            _defaultMeta()
        );

        vm.expectRevert(SafeTransferLib.SafeTransferFromFailed.selector);
        balanceSheet.deposit(
            POOL_A,
            defaultTypedShareClassId,
            address(erc20),
            erc20TokenId,
            address(this),
            defaultAmount,
            d18(100, 5),
            _defaultMeta()
        );

        erc20.mint(address(this), defaultAmount);
        erc20.approve(address(balanceSheet), defaultAmount);
        vm.expectEmit();
        emit IBalanceSheet.Deposit(
            POOL_A,
            defaultTypedShareClassId,
            address(erc20),
            erc20TokenId,
            address(this),
            defaultAmount,
            d18(100, 5),
            uint64(block.timestamp),
            _defaultMeta().debits,
            _defaultMeta().credits
        );
        balanceSheet.deposit(
            POOL_A,
            defaultTypedShareClassId,
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
        balanceSheet.withdraw(
            POOL_A,
            defaultTypedShareClassId,
            address(erc20),
            erc20TokenId,
            address(this),
            defaultAmount,
            d18(100, 5),
            _defaultMeta()
        );

        assertEq(erc20.balanceOf(address(this)), 0);

        vm.expectEmit();
        emit IBalanceSheet.Withdraw(
            POOL_A,
            defaultTypedShareClassId,
            address(erc20),
            erc20TokenId,
            address(this),
            defaultAmount,
            d18(100, 5),
            uint64(block.timestamp),
            _defaultMeta().debits,
            _defaultMeta().credits
        );
        balanceSheet.withdraw(
            POOL_A,
            defaultTypedShareClassId,
            address(erc20),
            erc20TokenId,
            address(this),
            defaultAmount,
            d18(100, 5),
            _defaultMeta()
        );

        assertEq(erc20.balanceOf(address(this)), defaultAmount);
    }

    function testIssue() public {
        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.issue(POOL_A, defaultTypedShareClassId, address(this), defaultPricePerShare, defaultAmount);

        IERC20 token = IERC20(poolManager.shareToken(POOL_A.raw(), defaultShareClassId));
        assertEq(token.balanceOf(address(this)), 0);

        vm.expectEmit();
        emit IBalanceSheet.Issue(POOL_A, defaultTypedShareClassId, address(this), defaultPricePerShare, defaultAmount);
        balanceSheet.issue(POOL_A, defaultTypedShareClassId, address(this), defaultPricePerShare, defaultAmount);

        assertEq(token.balanceOf(address(this)), defaultAmount);
    }

    function testRevoke() public {
        testIssue();
        IERC20 token = IERC20(poolManager.shareToken(POOL_A.raw(), defaultShareClassId));
        assertEq(token.balanceOf(address(this)), defaultAmount);

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.revoke(POOL_A, defaultTypedShareClassId, address(this), defaultPricePerShare, defaultAmount);

        vm.expectRevert(IERC20.InsufficientAllowance.selector);
        balanceSheet.revoke(POOL_A, defaultTypedShareClassId, address(this), defaultPricePerShare, defaultAmount);

        token.approve(address(balanceSheet), defaultAmount);
        vm.expectEmit();
        emit IBalanceSheet.Revoke(POOL_A, defaultTypedShareClassId, address(this), defaultPricePerShare, defaultAmount);
        balanceSheet.revoke(POOL_A, defaultTypedShareClassId, address(this), defaultPricePerShare, defaultAmount);

        assertEq(token.balanceOf(address(this)), 0);
    }

    function testUpdateJournal() public {
        Meta memory meta = _defaultMeta();

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.journalEntry(POOL_A, defaultTypedShareClassId, meta);

        vm.expectEmit();
        emit IBalanceSheet.UpdateEntry(POOL_A, defaultTypedShareClassId, meta.debits, meta.credits);
        balanceSheet.journalEntry(POOL_A, defaultTypedShareClassId, meta);
    }

    function testUpdateValue() public {
        (address asset, uint256 tokenId) = poolManager.idToAsset(assetId.raw());

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.updateValue(POOL_A, defaultTypedShareClassId, asset, tokenId, d18(1, 3));

        vm.expectEmit();
        emit IBalanceSheet.UpdateValue(
            POOL_A, defaultTypedShareClassId, asset, tokenId, d18(1, 3), uint64(block.timestamp)
        );
        balanceSheet.updateValue(POOL_A, defaultTypedShareClassId, asset, tokenId, d18(1, 3));
    }

    function testEnsureEntries() public {
        erc20.mint(address(this), defaultAmount);
        erc20.approve(address(balanceSheet), defaultAmount);
        vm.expectRevert(IBalanceSheet.EntriesUnbalanced.selector);
        balanceSheet.deposit(
            POOL_A,
            defaultTypedShareClassId,
            address(erc20),
            erc20TokenId,
            address(this),
            defaultAmount,
            d18(0),
            _defaultMeta()
        );
    }
}
