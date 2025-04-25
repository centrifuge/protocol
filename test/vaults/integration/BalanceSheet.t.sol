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

        assetId = poolManager.registerAsset{value: 0.1 ether}(OTHER_CHAIN_ID, address(erc20), erc20TokenId);
        poolManager.addPool(POOL_A);
        poolManager.addShareClass(
            POOL_A, defaultTypedShareClassId, "testShareClass", "tsc", defaultDecimals, bytes32(""), restrictedTransfers
        );
        poolManager.updatePricePoolPerShare(
            POOL_A, defaultTypedShareClassId, defaultPricePerShare.raw(), uint64(block.timestamp)
        );
        poolManager.updatePricePoolPerAsset(
            POOL_A, defaultTypedShareClassId, assetId, defaultPricePerShare.raw(), uint64(block.timestamp)
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
        IPoolEscrow escrow = poolEscrowFactory.escrow(POOL_A);
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
            POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, address(this), defaultAmount
        );

        vm.expectEmit();
        emit IBalanceSheet.UpdateManager(POOL_A, defaultTypedShareClassId, randomUser, true);

        balanceSheet.update(
            POOL_A,
            defaultTypedShareClassId,
            MessageLib.UpdateContractUpdateManager({who: bytes20(randomUser), canManage: true}).serialize()
        );

        balanceSheet.deposit(
            POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, address(this), defaultAmount
        );

        vm.expectEmit();
        emit IBalanceSheet.UpdateManager(POOL_A, defaultTypedShareClassId, randomUser, false);

        balanceSheet.update(
            POOL_A,
            defaultTypedShareClassId,
            MessageLib.UpdateContractUpdateManager({who: bytes20(randomUser), canManage: false}).serialize()
        );

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.deposit(
            POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, address(this), defaultAmount
        );
    }

    // --- IBalanceSheet ---
    function testDeposit() public {
        balanceSheet.setQueue(POOL_A, defaultTypedShareClassId, true);

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.deposit(
            POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, address(this), defaultAmount
        );

        vm.expectRevert(SafeTransferLib.SafeTransferFromFailed.selector);
        balanceSheet.deposit(
            POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, address(this), defaultAmount
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
            defaultPricePerShare,
            uint64(block.timestamp)
        );
        balanceSheet.deposit(
            POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, address(this), defaultAmount
        );

        assertEq(erc20.balanceOf(address(this)), 0);
        (uint128 increase,) = balanceSheet.queuedAssets(POOL_A, defaultTypedShareClassId, assetId);
        assertEq(increase, defaultAmount);
        assertEq(erc20.balanceOf(address(balanceSheet.poolEscrowProvider().escrow(POOL_A))), defaultAmount);
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
        assertEq(erc20.balanceOf(address(poolEscrowFactory.escrow(POOL_A))), 0);
        assertEq(
            poolEscrowFactory.escrow(POOL_A).availableBalanceOf(defaultTypedShareClassId, address(erc20), erc20TokenId),
            defaultAmount
        );
    }

    function testWithdraw() public {
        testDeposit();

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.withdraw(
            POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, address(this), defaultAmount
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
            defaultPricePerShare,
            uint64(block.timestamp)
        );
        balanceSheet.withdraw(
            POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, address(this), defaultAmount
        );

        (, uint128 decrease) = balanceSheet.queuedAssets(POOL_A, defaultTypedShareClassId, assetId);

        assertEq(erc20.balanceOf(address(this)), defaultAmount);
        assertEq(decrease, defaultAmount);
        assertEq(erc20.balanceOf(address(balanceSheet.poolEscrowProvider().escrow(POOL_A))), 0);
    }

    function testIssue() public {
        balanceSheet.setQueue(POOL_A, defaultTypedShareClassId, true);

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.issue(POOL_A, defaultTypedShareClassId, address(this), defaultAmount);

        IERC20 token = IERC20(poolManager.shareToken(POOL_A, defaultTypedShareClassId));
        assertEq(token.balanceOf(address(this)), 0);

        vm.expectEmit();
        emit IBalanceSheet.Issue(POOL_A, defaultTypedShareClassId, address(this), defaultPricePerShare, defaultAmount);
        balanceSheet.issue(POOL_A, defaultTypedShareClassId, address(this), defaultAmount);

        (uint128 increase,) = balanceSheet.queuedShares(POOL_A, defaultTypedShareClassId);
        assertEq(token.balanceOf(address(this)), defaultAmount);
        assertEq(increase, defaultAmount);

        balanceSheet.issue(POOL_A, defaultTypedShareClassId, address(this), defaultAmount * 2);

        (uint128 increase2,) = balanceSheet.queuedShares(POOL_A, defaultTypedShareClassId);
        assertEq(token.balanceOf(address(this)), defaultAmount * 3);
        assertEq(increase2, defaultAmount * 3);
    }

    function testRevoke() public {
        testIssue();
        IERC20 token = IERC20(poolManager.shareToken(POOL_A, defaultTypedShareClassId));
        assertEq(token.balanceOf(address(this)), defaultAmount * 3);

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.revoke(POOL_A, defaultTypedShareClassId, address(this), defaultAmount);

        vm.expectRevert(IERC20.InsufficientAllowance.selector);
        balanceSheet.revoke(POOL_A, defaultTypedShareClassId, address(this), defaultAmount);

        token.approve(address(balanceSheet), defaultAmount * 3);
        vm.expectEmit();
        emit IBalanceSheet.Revoke(POOL_A, defaultTypedShareClassId, address(this), defaultPricePerShare, defaultAmount);
        balanceSheet.revoke(POOL_A, defaultTypedShareClassId, address(this), defaultAmount);

        (, uint128 decrease) = balanceSheet.queuedShares(POOL_A, defaultTypedShareClassId);
        assertEq(token.balanceOf(address(this)), defaultAmount * 2);
        assertEq(decrease, defaultAmount);

        balanceSheet.revoke(POOL_A, defaultTypedShareClassId, address(this), defaultAmount * 2);

        (, uint128 decrease2) = balanceSheet.queuedShares(POOL_A, defaultTypedShareClassId);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(decrease2, defaultAmount * 3);
    }

    function testQueuedShares() public {
        testRevoke();

        DispatcherSpy dispatcherSpy = new DispatcherSpy();
        vm.mockFunction(
            address(balanceSheet.sender()),
            address(dispatcherSpy),
            abi.encodeWithSelector(DispatcherSpy.sendUpdateShares.selector)
        );
        vm.mockFunction(
            address(balanceSheet.sender()),
            address(dispatcherSpy),
            abi.encodeWithSelector(DispatcherSpy.sendUpdateShares_result.selector)
        );

        // Add extra issuance to have an unequal number
        balanceSheet.issue(POOL_A, defaultTypedShareClassId, address(this), defaultAmount);
        (uint128 increase, uint128 decrease) = balanceSheet.queuedShares(POOL_A, defaultTypedShareClassId);

        assertEq(increase, defaultAmount * 4);
        assertEq(decrease, defaultAmount * 3);

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.submitQueuedShares(POOL_A, defaultTypedShareClassId);

        balanceSheet.submitQueuedShares(POOL_A, defaultTypedShareClassId);

        (uint128 increaseAfter, uint128 decreaseAfter) = balanceSheet.queuedShares(POOL_A, defaultTypedShareClassId);
        assertEq(increaseAfter, 0);
        assertEq(decreaseAfter, 0);
        (uint128 shares, bool isIssuance) = DispatcherSpy(address(balanceSheet.sender())).sendUpdateShares_result();
        assertEq(shares, defaultAmount);
        assertEq(isIssuance, true);
    }

    function testQueuedAssets() public {
        testDeposit();

        DispatcherSpy dispatcherSpy = new DispatcherSpy();
        vm.mockFunction(
            address(balanceSheet.sender()),
            address(dispatcherSpy),
            abi.encodeWithSelector(DispatcherSpy.sendUpdateHoldingAmount.selector)
        );
        vm.mockFunction(
            address(balanceSheet.sender()),
            address(dispatcherSpy),
            abi.encodeWithSelector(DispatcherSpy.sendUpdateHoldingAmount_result.selector)
        );

        (uint128 increase,) = balanceSheet.queuedAssets(POOL_A, defaultTypedShareClassId, assetId);
        assertEq(increase, defaultAmount);

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.submitQueuedAssets(POOL_A, defaultTypedShareClassId, assetId);

        balanceSheet.submitQueuedAssets(POOL_A, defaultTypedShareClassId, assetId);

        (uint128 increaseAfter,) = balanceSheet.queuedAssets(POOL_A, defaultTypedShareClassId, assetId);
        assertEq(increaseAfter, 0);
        (uint128 amount, bool isIncrease) =
            DispatcherSpy(address(balanceSheet.sender())).sendUpdateHoldingAmount_result();
        assertEq(amount, defaultAmount);
        assertEq(isIncrease, true);
    }

    function testAssetsQueueDisabled() public {
        DispatcherSpy dispatcherSpy = new DispatcherSpy();
        vm.mockFunction(
            address(balanceSheet.sender()),
            address(dispatcherSpy),
            abi.encodeWithSelector(DispatcherSpy.sendUpdateHoldingAmount.selector)
        );
        vm.mockFunction(
            address(balanceSheet.sender()),
            address(dispatcherSpy),
            abi.encodeWithSelector(DispatcherSpy.sendUpdateHoldingAmount_result.selector)
        );

        erc20.mint(address(this), defaultAmount);
        erc20.approve(address(balanceSheet), defaultAmount);

        balanceSheet.deposit(
            POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, address(this), defaultAmount
        );

        (uint128 increase,) = balanceSheet.queuedAssets(POOL_A, defaultTypedShareClassId, assetId);
        assertEq(increase, 0);
        (uint128 amount, bool isIncrease) =
            DispatcherSpy(address(balanceSheet.sender())).sendUpdateHoldingAmount_result();
        assertEq(amount, defaultAmount);
        assertEq(isIncrease, true);

        balanceSheet.withdraw(
            POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, address(this), defaultAmount / 2
        );

        (, uint128 decrease) = balanceSheet.queuedAssets(POOL_A, defaultTypedShareClassId, assetId);
        assertEq(decrease, 0);
        (uint128 amount2, bool isIncrease2) =
            DispatcherSpy(address(balanceSheet.sender())).sendUpdateHoldingAmount_result();
        assertEq(amount2, defaultAmount / 2);
        assertEq(isIncrease2, false);
    }

    function testSharesQueueDisabled() public {
        DispatcherSpy dispatcherSpy = new DispatcherSpy();
        vm.mockFunction(
            address(balanceSheet.sender()),
            address(dispatcherSpy),
            abi.encodeWithSelector(DispatcherSpy.sendUpdateShares.selector)
        );
        vm.mockFunction(
            address(balanceSheet.sender()),
            address(dispatcherSpy),
            abi.encodeWithSelector(DispatcherSpy.sendUpdateShares_result.selector)
        );

        balanceSheet.issue(POOL_A, defaultTypedShareClassId, address(this), defaultAmount);

        (uint128 increase,) = balanceSheet.queuedShares(POOL_A, defaultTypedShareClassId);
        assertEq(increase, 0);
        (uint128 shares, bool isIssuance) = DispatcherSpy(address(balanceSheet.sender())).sendUpdateShares_result();
        assertEq(shares, defaultAmount);
        assertEq(isIssuance, true);
    }

    function testSubmitWithQueueDisabled() public {
        DispatcherSpy dispatcherSpy = new DispatcherSpy();
        vm.mockFunction(
            address(balanceSheet.sender()),
            address(dispatcherSpy),
            abi.encodeWithSelector(DispatcherSpy.sendUpdateShares.selector)
        );
        vm.mockFunction(
            address(balanceSheet.sender()),
            address(dispatcherSpy),
            abi.encodeWithSelector(DispatcherSpy.sendUpdateShares_result.selector)
        );

        // Issue with queue enabled
        balanceSheet.setQueue(POOL_A, defaultTypedShareClassId, true);
        balanceSheet.issue(POOL_A, defaultTypedShareClassId, address(this), defaultAmount);

        // Submit with queue disabled
        balanceSheet.setQueue(POOL_A, defaultTypedShareClassId, false);
        balanceSheet.submitQueuedShares(POOL_A, defaultTypedShareClassId);

        // Shares should remain in the queue and not be submitted
        (uint128 increase,) = balanceSheet.queuedShares(POOL_A, defaultTypedShareClassId);
        assertEq(increase, defaultAmount);
        (uint128 shares, bool isIssuance) = DispatcherSpy(address(balanceSheet.sender())).sendUpdateShares_result();
        assertEq(shares, 0);
        assertEq(isIssuance, false);
    }

    function testTransferSharesFrom() public {
        testIssue();

        IERC20 token = IERC20(poolManager.shareToken(POOL_A, defaultTypedShareClassId));

        assertEq(token.balanceOf(address(this)), defaultAmount * 3);

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.transferSharesFrom(POOL_A, defaultTypedShareClassId, address(this), address(1), defaultAmount);

        balanceSheet.transferSharesFrom(POOL_A, defaultTypedShareClassId, address(this), address(1), defaultAmount);

        assertEq(token.balanceOf(address(this)), defaultAmount * 2);
        assertEq(token.balanceOf(address(1)), defaultAmount);
    }
}

contract DispatcherSpy {
    function sendUpdateShares(PoolId, ShareClassId, uint128 shares, bool isIssuance) external {
        bytes32 slot = keccak256("dispatchedShares");
        bytes32 slot2 = keccak256("dispatchedSharesIsIssuance");
        assembly {
            sstore(slot, shares)
            sstore(slot2, isIssuance)
        }
    }

    function sendUpdateShares_result() external view returns (uint128 shares, bool isIssuance) {
        bytes32 slot = keccak256("dispatchedShares");
        bytes32 slot2 = keccak256("dispatchedSharesIsIssuance");
        assembly {
            shares := sload(slot)
            isIssuance := sload(slot2)
        }
    }

    function sendUpdateHoldingAmount(PoolId, ShareClassId, AssetId, address, uint128 amount, D18, bool isIncrease)
        external
    {
        bytes32 slot = keccak256("dispatchedHoldingAmount");
        bytes32 slot2 = keccak256("dispatchedHoldingAmountIsIncrease");
        assembly {
            sstore(slot, amount)
            sstore(slot2, isIncrease)
        }
    }

    function sendUpdateHoldingAmount_result() external view returns (uint128 amount, bool inIncrease) {
        bytes32 slot = keccak256("dispatchedHoldingAmount");
        bytes32 slot2 = keccak256("dispatchedHoldingAmountIsIncrease");
        assembly {
            amount := sload(slot)
            inIncrease := sload(slot2)
        }
    }
}
