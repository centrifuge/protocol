// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "test/spokes/BaseTest.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {D18, d18} from "src/misc/types/D18.sol";

import {MessageLib} from "src/common/libraries/MessageLib.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";

import {IBalanceSheet} from "src/spokes/interfaces/IBalanceSheet.sol";
import {BalanceSheet} from "src/spokes/BalanceSheet.sol";

contract BalanceSheetTest is BaseTest {
    using MessageLib for *;
    using CastLib for *;

    uint128 defaultAmount;
    D18 defaultPricePoolPerShare;
    D18 defaultPricePoolPerAsset;
    AssetId assetId;
    ShareClassId defaultTypedShareClassId;

    function setUp() public override {
        super.setUp();
        defaultAmount = 100;
        defaultPricePoolPerShare = d18(1, 1);
        defaultPricePoolPerAsset = d18(1, 1);
        defaultTypedShareClassId = ShareClassId.wrap(defaultShareClassId);

        assetId = spoke.registerAsset{value: 0.1 ether}(OTHER_CHAIN_ID, address(erc20), erc20TokenId);
        spoke.addPool(POOL_A);
        spoke.addShareClass(
            POOL_A,
            defaultTypedShareClassId,
            "testShareClass",
            "tsc",
            defaultDecimals,
            bytes32(""),
            fullRestrictionsHook
        );
        spoke.updatePricePoolPerShare(
            POOL_A, defaultTypedShareClassId, defaultPricePoolPerShare.raw(), uint64(block.timestamp)
        );
        spoke.updatePricePoolPerAsset(
            POOL_A, defaultTypedShareClassId, assetId, defaultPricePoolPerShare.raw(), uint64(block.timestamp)
        );
        spoke.updateRestriction(
            POOL_A,
            defaultTypedShareClassId,
            MessageLib.UpdateRestrictionMember({user: address(this).toBytes32(), validUntil: MAX_UINT64}).serialize()
        );
    }

    // Deployment
    function testDeployment(address nonWard) public {
        vm.assume(
            nonWard != address(root) && nonWard != address(asyncRequestManager)
                && nonWard != address(syncRequestManager) && nonWard != address(messageProcessor)
                && nonWard != address(messageDispatcher) && nonWard != address(this)
        );

        // redeploying within test to increase coverage
        new BalanceSheet(root, address(this));

        // values set correctly
        assertEq(address(balanceSheet.root()), address(root));
        assertEq(address(balanceSheet.spoke()), address(spoke));
        assertEq(address(balanceSheet.sender()), address(messageDispatcher));
        assertEq(address(balanceSheet.poolEscrowProvider()), address(poolEscrowFactory));

        // permissions set correctly
        assertEq(balanceSheet.wards(address(root)), 1);
        assertEq(balanceSheet.wards(address(asyncRequestManager)), 1);
        assertEq(balanceSheet.wards(address(syncRequestManager)), 1);
        assertEq(balanceSheet.wards(address(messageProcessor)), 1);
        assertEq(balanceSheet.wards(address(messageDispatcher)), 1);
        assertEq(balanceSheet.wards(nonWard), 0);
    }

    // --- Administration ---
    function testFile() public {
        // fail: unrecognized param
        vm.expectRevert(IBalanceSheet.FileUnrecognizedParam.selector);
        balanceSheet.file("random", self);

        // success
        balanceSheet.file("spoke", randomUser);
        assertEq(address(balanceSheet.spoke()), randomUser);
        balanceSheet.file("sender", randomUser);
        assertEq(address(balanceSheet.sender()), randomUser);
        balanceSheet.file("poolEscrowProvider", randomUser);
        assertEq(address(balanceSheet.poolEscrowProvider()), randomUser);

        // remove self from wards
        balanceSheet.deny(self);
        // auth fail
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.file("spoke", randomUser);
    }

    // --- IUpdateContract ---
    function testUpdate() public {
        erc20.mint(address(this), defaultAmount);
        erc20.approve(address(balanceSheet), defaultAmount);

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.deposit(POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, defaultAmount);

        vm.expectEmit();
        emit IBalanceSheet.UpdateManager(POOL_A, randomUser, true);

        balanceSheet.update(
            POOL_A,
            defaultTypedShareClassId,
            MessageLib.UpdateContractUpdateManager({who: bytes20(randomUser), canManage: true}).serialize()
        );

        balanceSheet.deposit(POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, defaultAmount);

        vm.expectEmit();
        emit IBalanceSheet.UpdateManager(POOL_A, randomUser, false);

        balanceSheet.update(
            POOL_A,
            defaultTypedShareClassId,
            MessageLib.UpdateContractUpdateManager({who: bytes20(randomUser), canManage: false}).serialize()
        );

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.deposit(POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, defaultAmount);
    }

    // --- IBalanceSheet ---
    function testDeposit() public {
        balanceSheet.setQueue(POOL_A, defaultTypedShareClassId, true);

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.deposit(POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, defaultAmount);

        vm.expectRevert(SafeTransferLib.SafeTransferFromFailed.selector);
        balanceSheet.deposit(POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, defaultAmount);

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
            defaultPricePoolPerAsset
        );
        balanceSheet.deposit(POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, defaultAmount);

        assertEq(erc20.balanceOf(address(this)), 0);
        (uint128 increase,) = balanceSheet.queuedAssets(POOL_A, defaultTypedShareClassId, assetId);
        assertEq(increase, defaultAmount);
        assertEq(erc20.balanceOf(address(balanceSheet.poolEscrowProvider().escrow(POOL_A))), defaultAmount);
    }

    function testNoteDeposit() public {
        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.deposit(POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, defaultAmount);

        vm.expectEmit();
        emit IBalanceSheet.Deposit(
            POOL_A,
            defaultTypedShareClassId,
            address(erc20),
            erc20TokenId,
            address(this),
            defaultAmount,
            defaultPricePoolPerAsset
        );
        balanceSheet.noteDeposit(
            POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, address(this), defaultAmount
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

        balanceSheet.overridePricePoolPerShare(POOL_A, defaultTypedShareClassId, defaultPricePoolPerShare);

        vm.expectEmit();
        emit IBalanceSheet.Withdraw(
            POOL_A,
            defaultTypedShareClassId,
            address(erc20),
            erc20TokenId,
            address(this),
            defaultAmount,
            defaultPricePoolPerAsset
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

        IERC20 token = IERC20(spoke.shareToken(POOL_A, defaultTypedShareClassId));
        assertEq(token.balanceOf(address(this)), 0);

        balanceSheet.overridePricePoolPerShare(POOL_A, defaultTypedShareClassId, defaultPricePoolPerShare);

        vm.expectEmit();
        emit IBalanceSheet.Issue(
            POOL_A, defaultTypedShareClassId, address(this), defaultPricePoolPerShare, defaultAmount
        );
        balanceSheet.issue(POOL_A, defaultTypedShareClassId, address(this), defaultAmount);

        (uint128 delta, bool isPositive,) = balanceSheet.queuedShares(POOL_A, defaultTypedShareClassId);
        assertEq(token.balanceOf(address(this)), defaultAmount);
        assertEq(delta, defaultAmount);
        assertEq(isPositive, true);

        balanceSheet.issue(POOL_A, defaultTypedShareClassId, address(this), defaultAmount * 2);

        (uint128 deltaAfter, bool isPositive2,) = balanceSheet.queuedShares(POOL_A, defaultTypedShareClassId);
        assertEq(token.balanceOf(address(this)), defaultAmount * 3);
        assertEq(deltaAfter, defaultAmount * 3);
        assertEq(isPositive2, true);
    }

    function testRevoke() public {
        testIssue();
        IShareToken token = IShareToken(spoke.shareToken(POOL_A, defaultTypedShareClassId));
        assertEq(token.balanceOf(address(this)), defaultAmount * 3);

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.revoke(POOL_A, defaultTypedShareClassId, defaultAmount);

        balanceSheet.overridePricePoolPerShare(POOL_A, defaultTypedShareClassId, defaultPricePoolPerShare);

        vm.expectEmit();
        emit IBalanceSheet.Revoke(
            POOL_A, defaultTypedShareClassId, address(this), defaultPricePoolPerShare, defaultAmount * 2
        );
        balanceSheet.revoke(POOL_A, defaultTypedShareClassId, defaultAmount * 2);

        (uint128 delta, bool isPositive,) = balanceSheet.queuedShares(POOL_A, defaultTypedShareClassId);
        assertEq(token.balanceOf(address(this)), defaultAmount);
        assertEq(delta, defaultAmount);
        assertEq(isPositive, true);

        // Mint directly to avoid issuance call
        vm.prank(address(root));
        token.mint(address(this), defaultAmount * 3);

        balanceSheet.revoke(POOL_A, defaultTypedShareClassId, defaultAmount * 3);

        (uint128 delta2, bool isPositive2,) = balanceSheet.queuedShares(POOL_A, defaultTypedShareClassId);
        assertEq(token.balanceOf(address(this)), defaultAmount);
        assertEq(delta2, defaultAmount * 2);
        assertEq(isPositive2, false);
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

        balanceSheet.issue(POOL_A, defaultTypedShareClassId, address(this), defaultAmount * 3);
        (uint128 delta, bool isPositive,) = balanceSheet.queuedShares(POOL_A, defaultTypedShareClassId);
        assertEq(delta, defaultAmount);
        assertEq(isPositive, true);

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.submitQueuedShares(POOL_A, defaultTypedShareClassId);

        balanceSheet.submitQueuedShares(POOL_A, defaultTypedShareClassId);

        (uint128 deltaAfter, bool isPositiveAfter,) = balanceSheet.queuedShares(POOL_A, defaultTypedShareClassId);
        assertEq(deltaAfter, 0);
        assertEq(isPositiveAfter, true);
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

        balanceSheet.deposit(POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, defaultAmount);

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

        (uint128 increase,,) = balanceSheet.queuedShares(POOL_A, defaultTypedShareClassId);
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

        (uint128 increase,,) = balanceSheet.queuedShares(POOL_A, defaultTypedShareClassId);
        assertEq(increase, defaultAmount);

        // Submit with queue disabled
        balanceSheet.setQueue(POOL_A, defaultTypedShareClassId, false);
        balanceSheet.submitQueuedShares(POOL_A, defaultTypedShareClassId);

        // Shares should be submitted even if disabled
        (increase,,) = balanceSheet.queuedShares(POOL_A, defaultTypedShareClassId);
        assertEq(increase, 0);

        (uint128 shares, bool isIssuance) = DispatcherSpy(address(balanceSheet.sender())).sendUpdateShares_result();
        assertEq(shares, defaultAmount);
        assertEq(isIssuance, true);
    }

    function testTransferSharesFrom() public {
        testIssue();

        IERC20 token = IERC20(spoke.shareToken(POOL_A, defaultTypedShareClassId));

        assertEq(token.balanceOf(address(this)), defaultAmount * 3);

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.transferSharesFrom(POOL_A, defaultTypedShareClassId, address(this), address(1), defaultAmount);

        vm.expectRevert(IBalanceSheet.CannotTransferFromEndorsedContract.selector);
        balanceSheet.transferSharesFrom(
            POOL_A, defaultTypedShareClassId, address(globalEscrow), address(1), defaultAmount
        );

        balanceSheet.transferSharesFrom(POOL_A, defaultTypedShareClassId, address(this), address(1), defaultAmount);

        assertEq(token.balanceOf(address(this)), defaultAmount * 2);
        assertEq(token.balanceOf(address(1)), defaultAmount);
    }

    function testPriceOverride() public {
        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.overridePricePoolPerShare(POOL_A, defaultTypedShareClassId, defaultPricePoolPerShare);

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.overridePricePoolPerAsset(POOL_A, defaultTypedShareClassId, assetId, defaultPricePoolPerAsset);

        D18 pricePerAsset = d18(3, 1);
        D18 pricePerShare = d18(2, 1);

        balanceSheet.overridePricePoolPerAsset(POOL_A, defaultTypedShareClassId, assetId, pricePerAsset);
        balanceSheet.overridePricePoolPerShare(POOL_A, defaultTypedShareClassId, pricePerShare);

        vm.expectEmit();
        emit IBalanceSheet.Deposit(
            POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, address(this), defaultAmount, pricePerAsset
        );
        balanceSheet.noteDeposit(
            POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, address(this), defaultAmount
        );

        balanceSheet.issue(POOL_A, defaultTypedShareClassId, address(this), defaultAmount);

        vm.expectEmit();
        emit IBalanceSheet.Revoke(POOL_A, defaultTypedShareClassId, address(this), pricePerShare, defaultAmount);
        balanceSheet.revoke(POOL_A, defaultTypedShareClassId, defaultAmount);

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.resetPricePoolPerShare(POOL_A, defaultTypedShareClassId);

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.resetPricePoolPerAsset(POOL_A, defaultTypedShareClassId, assetId);

        balanceSheet.resetPricePoolPerAsset(POOL_A, defaultTypedShareClassId, assetId);
        balanceSheet.resetPricePoolPerShare(POOL_A, defaultTypedShareClassId);

        vm.expectEmit();
        emit IBalanceSheet.Deposit(
            POOL_A,
            defaultTypedShareClassId,
            address(erc20),
            erc20TokenId,
            address(this),
            defaultAmount,
            defaultPricePoolPerAsset
        );
        balanceSheet.noteDeposit(
            POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, address(this), defaultAmount
        );

        balanceSheet.issue(POOL_A, defaultTypedShareClassId, address(this), defaultAmount);

        vm.expectEmit();
        emit IBalanceSheet.Revoke(
            POOL_A, defaultTypedShareClassId, address(this), defaultPricePoolPerShare, defaultAmount
        );
        balanceSheet.revoke(POOL_A, defaultTypedShareClassId, defaultAmount);
    }
}

contract DispatcherSpy {
    function sendUpdateShares(PoolId, ShareClassId, uint128 shares, bool isIssuance, bool) external {
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

    function sendUpdateHoldingAmount(PoolId, ShareClassId, AssetId, uint128 amount, D18, bool isIncrease, bool)
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
