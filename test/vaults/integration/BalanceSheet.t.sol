// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "test/vaults/BaseTest.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {D18, d18} from "src/misc/types/D18.sol";

import {MessageLib} from "src/common/libraries/MessageLib.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {AccountId} from "src/common/types/AccountId.sol";

import {IBalanceSheet} from "src/vaults/interfaces/IBalanceSheet.sol";
import {BalanceSheet} from "src/vaults/BalanceSheet.sol";
import {IPoolEscrow} from "src/vaults/interfaces/IEscrow.sol";

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

        assetId =
            AssetId.wrap(poolManager.registerAsset{value: 0.1 ether}(OTHER_CHAIN_ID, address(erc20), erc20TokenId));
        poolManager.addPool(POOL_A);
        poolManager.addShareClass(
            POOL_A, defaultTypedShareClassId, "testShareClass", "tsc", defaultDecimals, bytes32(""), restrictedTransfers
        );
        poolManager.updateRestriction(
            POOL_A,
            defaultTypedShareClassId,
            MessageLib.UpdateRestrictionMember({user: address(this).toBytes32(), validUntil: MAX_UINT64}).serialize()
        );
        // In order for allowances to work during issuance, the balanceSheet must be canManage to transfer
        poolManager.updateRestriction(
            POOL_A,
            defaultTypedShareClassId,
            MessageLib.UpdateRestrictionMember({user: address(balanceSheet).toBytes32(), validUntil: MAX_UINT64})
                .serialize()
        );
        // Manually set necessary escrow allowance which are naturally part of poolManager.addVault
        IPoolEscrow escrow = poolEscrowFactory.escrow(POOL_A.raw());
        vm.prank(address(poolManager));
        escrow.approveMax(address(erc20), erc20TokenId, address(balanceSheet));
    }

    // Deployment
    function testDeployment(address nonWard) public {
        vm.assume(
            nonWard != address(root) && nonWard != address(asyncRequests) && nonWard != address(syncRequests)
                && nonWard != address(gateway) && nonWard != address(messageProcessor)
                && nonWard != address(messageDispatcher) && nonWard != address(this)
        );

        // redeploying within test to increase coverage
        new BalanceSheet(address(this));

        // values set correctly
        assertEq(address(balanceSheet.gateway()), address(gateway));
        assertEq(address(balanceSheet.poolManager()), address(poolManager));
        assertEq(address(balanceSheet.sender()), address(messageDispatcher));
        assertEq(address(balanceSheet.sharePriceProvider()), address(syncRequests));
        assertEq(address(balanceSheet.poolEscrowProvider()), address(poolEscrowFactory));

        // permissions set correctly
        assertEq(balanceSheet.wards(address(root)), 1);
        assertEq(balanceSheet.wards(address(asyncRequests)), 1);
        assertEq(balanceSheet.wards(address(syncRequests)), 1);
        assertEq(balanceSheet.wards(address(messageProcessor)), 1);
        assertEq(balanceSheet.wards(address(messageDispatcher)), 1);
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
        balanceSheet.file("sharePriceProvider", randomUser);
        assertEq(address(balanceSheet.sharePriceProvider()), randomUser);
        balanceSheet.file("poolEscrowProvider", randomUser);
        assertEq(address(balanceSheet.poolEscrowProvider()), randomUser);

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
            POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, address(this), defaultAmount, d18(100, 5)
        );

        vm.expectEmit();
        emit IBalanceSheet.UpdateManager(POOL_A, defaultTypedShareClassId, randomUser, true);

        balanceSheet.update(
            POOL_A.raw(),
            defaultShareClassId,
            MessageLib.UpdateContractUpdateManager({who: bytes20(randomUser), canManage: true}).serialize()
        );

        balanceSheet.deposit(
            POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, address(this), defaultAmount, d18(100, 5)
        );

        vm.expectEmit();
        emit IBalanceSheet.UpdateManager(POOL_A, defaultTypedShareClassId, randomUser, false);

        balanceSheet.update(
            POOL_A.raw(),
            defaultShareClassId,
            MessageLib.UpdateContractUpdateManager({who: bytes20(randomUser), canManage: false}).serialize()
        );

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.deposit(
            POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, address(this), defaultAmount, d18(100, 5)
        );
    }

    // --- IBalanceSheet ---
    function testDeposit() public {
        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.deposit(
            POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, address(this), defaultAmount, d18(100, 5)
        );

        vm.expectRevert(SafeTransferLib.SafeTransferFromFailed.selector);
        balanceSheet.deposit(
            POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, address(this), defaultAmount, d18(100, 5)
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
            uint64(block.timestamp)
        );
        balanceSheet.deposit(
            POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, address(this), defaultAmount, d18(100, 5)
        );

        assertEq(erc20.balanceOf(address(this)), 0);
    }

    function testNoteDeposit() public {
        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.deposit(
            POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, address(this), defaultAmount, d18(100, 5)
        );

        vm.expectEmit();
        emit IBalanceSheet.Deposit(
            POOL_A,
            defaultTypedShareClassId,
            address(erc20),
            erc20TokenId,
            address(this),
            defaultAmount,
            d18(100, 5),
            uint64(block.timestamp)
        );
        balanceSheet.noteDeposit(
            POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, address(this), defaultAmount, d18(100, 5)
        );

        // Ensure no balance transfer occurred but escrow holding was incremented nevertheless
        assertEq(erc20.balanceOf(address(this)), 0);
        assertEq(erc20.balanceOf(address(poolEscrowFactory.escrow(POOL_A.raw()))), 0);
        assertEq(
            poolEscrowFactory.escrow(POOL_A.raw()).availableBalanceOf(
                defaultTypedShareClassId.raw(), address(erc20), erc20TokenId
            ),
            defaultAmount
        );
    }

    function testWithdraw() public {
        testDeposit();

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.withdraw(
            POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, address(this), defaultAmount, d18(100, 5)
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
            uint64(block.timestamp)
        );
        balanceSheet.withdraw(
            POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, address(this), defaultAmount, d18(100, 5)
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
}
