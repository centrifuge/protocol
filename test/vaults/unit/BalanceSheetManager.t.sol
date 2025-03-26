// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "test/vaults/BaseTest.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {D18, d18} from "src/misc/types/D18.sol";

import {Meta, JournalEntry} from "src/common/types/JournalEntry.sol";
import {MessageLib} from "src/common/libraries/MessageLib.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {AccountId} from "src/common/types/AccountId.sol";

import {IBalanceSheetManager} from "src/vaults/interfaces/IBalanceSheetManager.sol";
import {BalanceSheetManager} from "src/vaults/BalanceSheetManager.sol";

contract BalanceSheetManagerTest is BaseTest {
    using MessageLib for *;
    using CastLib for *;

    uint128 defaultAmount;
    D18 defaultPricePerShare;
    AssetId assetId;
    PoolId defaultTypedPoolId;
    ShareClassId defaultTypedShareClassId;

    function setUp() public override {
        super.setUp();
        defaultAmount = 100;
        defaultPricePerShare = d18(1, 1);
        defaultTypedPoolId = PoolId.wrap(defaultPoolId);
        defaultTypedShareClassId = ShareClassId.wrap(defaultShareClassId);

        assetId = AssetId.wrap(poolManager.registerAsset(address(erc20), erc20TokenId, OTHER_CHAIN_ID));
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
            defaultTypedPoolId,
            defaultTypedShareClassId,
            address(erc20),
            erc20TokenId,
            address(this),
            defaultAmount,
            d18(100, 5),
            _defaultMeta()
        );

        vm.expectEmit();
        emit IBalanceSheetManager.Permission(defaultTypedPoolId, defaultTypedShareClassId, randomUser, true);

        balanceSheetManager.update(
            defaultPoolId,
            defaultShareClassId,
            MessageLib.UpdateContractPermission({who: randomUser, allowed: true}).serialize()
        );

        balanceSheetManager.deposit(
            defaultTypedPoolId,
            defaultTypedShareClassId,
            address(erc20),
            erc20TokenId,
            address(this),
            defaultAmount,
            d18(100, 5),
            _defaultMeta()
        );

        vm.expectEmit();
        emit IBalanceSheetManager.Permission(defaultTypedPoolId, defaultTypedShareClassId, randomUser, false);

        balanceSheetManager.update(
            defaultPoolId,
            defaultShareClassId,
            MessageLib.UpdateContractPermission({who: randomUser, allowed: false}).serialize()
        );

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheetManager.deposit(
            defaultTypedPoolId,
            defaultTypedShareClassId,
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
            defaultTypedPoolId,
            defaultTypedShareClassId,
            address(erc20),
            erc20TokenId,
            address(this),
            defaultAmount,
            d18(100, 5),
            _defaultMeta()
        );

        vm.expectRevert(SafeTransferLib.SafeTransferFromFailed.selector);
        balanceSheetManager.deposit(
            defaultTypedPoolId,
            defaultTypedShareClassId,
            address(erc20),
            erc20TokenId,
            address(this),
            defaultAmount,
            d18(100, 5),
            _defaultMeta()
        );

        erc20.mint(address(this), defaultAmount);
        erc20.approve(address(balanceSheetManager), defaultAmount);
        vm.expectEmit();
        emit IBalanceSheetManager.Deposit(
            defaultTypedPoolId,
            defaultTypedShareClassId,
            address(erc20),
            erc20TokenId,
            address(this),
            defaultAmount,
            d18(100, 5),
            block.timestamp,
            _defaultMeta().debits,
            _defaultMeta().credits
        );
        balanceSheetManager.deposit(
            defaultTypedPoolId,
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
        balanceSheetManager.withdraw(
            defaultTypedPoolId,
            defaultTypedShareClassId,
            address(erc20),
            erc20TokenId,
            address(this),
            defaultAmount,
            d18(100, 5),
            false,
            _defaultMeta()
        );

        assertEq(erc20.balanceOf(address(this)), 0);

        vm.expectEmit();
        emit IBalanceSheetManager.Withdraw(
            defaultTypedPoolId,
            defaultTypedShareClassId,
            address(erc20),
            erc20TokenId,
            address(this),
            defaultAmount,
            d18(100, 5),
            block.timestamp,
            _defaultMeta().debits,
            _defaultMeta().credits
        );
        balanceSheetManager.withdraw(
            defaultTypedPoolId,
            defaultTypedShareClassId,
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
            defaultTypedPoolId,
            defaultTypedShareClassId,
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
            defaultTypedPoolId,
            defaultTypedShareClassId,
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
        balanceSheetManager.issue(
            defaultTypedPoolId, defaultTypedShareClassId, address(this), defaultPricePerShare, defaultAmount, false
        );

        IERC20 token = IERC20(poolManager.tranche(defaultPoolId, defaultShareClassId));
        assertEq(token.balanceOf(address(this)), 0);

        vm.expectEmit();
        emit IBalanceSheetManager.Issue(
            defaultTypedPoolId, defaultTypedShareClassId, address(this), defaultPricePerShare, defaultAmount
        );
        balanceSheetManager.issue(
            defaultTypedPoolId, defaultTypedShareClassId, address(this), defaultPricePerShare, defaultAmount, false
        );

        assertEq(token.balanceOf(address(this)), defaultAmount);
    }

    function testIssueAsAllowance() public {
        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheetManager.issue(
            defaultTypedPoolId, defaultTypedShareClassId, address(this), defaultPricePerShare, defaultAmount, true
        );

        IERC20 token = IERC20(poolManager.tranche(defaultPoolId, defaultShareClassId));
        assertEq(token.balanceOf(address(this)), 0);

        balanceSheetManager.issue(
            defaultTypedPoolId, defaultTypedShareClassId, address(this), defaultPricePerShare, defaultAmount, true
        );

        token.transferFrom(address(balanceSheetManager), address(this), defaultAmount);
        assertEq(token.balanceOf(address(this)), defaultAmount);
    }

    function testRevoke() public {
        testIssue();
        IERC20 token = IERC20(poolManager.tranche(defaultPoolId, defaultShareClassId));
        assertEq(token.balanceOf(address(this)), defaultAmount);

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheetManager.revoke(
            defaultTypedPoolId, defaultTypedShareClassId, address(this), defaultPricePerShare, defaultAmount
        );

        vm.expectRevert(IERC20.InsufficientAllowance.selector);
        balanceSheetManager.revoke(
            defaultTypedPoolId, defaultTypedShareClassId, address(this), defaultPricePerShare, defaultAmount
        );

        token.approve(address(balanceSheetManager), defaultAmount);
        vm.expectEmit();
        emit IBalanceSheetManager.Revoke(
            defaultTypedPoolId, defaultTypedShareClassId, address(this), defaultPricePerShare, defaultAmount
        );
        balanceSheetManager.revoke(
            defaultTypedPoolId, defaultTypedShareClassId, address(this), defaultPricePerShare, defaultAmount
        );

        assertEq(token.balanceOf(address(this)), 0);
    }

    function testUpdateJournal() public {
        Meta memory meta = _defaultMeta();

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheetManager.journalEntry(defaultTypedPoolId, defaultTypedShareClassId, meta);

        vm.expectEmit();
        emit IBalanceSheetManager.UpdateEntry(defaultTypedPoolId, defaultTypedShareClassId, meta.debits, meta.credits);
        balanceSheetManager.journalEntry(defaultTypedPoolId, defaultTypedShareClassId, meta);
    }

    function testUpdateValue() public {
        (address asset, uint256 tokenId) = poolManager.idToAsset(assetId.raw());

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheetManager.updateValue(defaultTypedPoolId, defaultTypedShareClassId, asset, tokenId, d18(1, 3));

        vm.expectEmit();
        emit IBalanceSheetManager.UpdateValue(
            defaultTypedPoolId, defaultTypedShareClassId, asset, tokenId, d18(1, 3), block.timestamp
        );
        balanceSheetManager.updateValue(defaultTypedPoolId, defaultTypedShareClassId, asset, tokenId, d18(1, 3));
    }

    function testEnsureEntries() public {
        erc20.mint(address(this), defaultAmount);
        erc20.approve(address(balanceSheetManager), defaultAmount);
        vm.expectRevert(IBalanceSheetManager.EntriesUnbalanced.selector);
        balanceSheetManager.deposit(
            defaultTypedPoolId,
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
