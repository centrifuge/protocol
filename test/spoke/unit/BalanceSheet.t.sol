// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {IERC7751} from "src/misc/interfaces/IERC7751.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {IERC6909} from "src/misc/interfaces/IERC6909.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";

import {UpdateRestrictionMessageLib} from "src/hooks/libraries/UpdateRestrictionMessageLib.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {IRoot} from "src/common/interfaces/IRoot.sol";
import {ISpokeMessageSender} from "src/common/interfaces/IGatewaySenders.sol";

import {BalanceSheet, IBalanceSheet} from "src/spoke/BalanceSheet.sol";
import {ISpoke} from "src/spoke/interfaces/ISpoke.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";
import {IPoolEscrow} from "src/spoke/interfaces/IEscrow.sol";
import {IPoolEscrowProvider} from "src/spoke/factories/interfaces/IPoolEscrowFactory.sol";

contract ContractWithCode {}

contract BalanceSheetTest is Test {
    using UpdateRestrictionMessageLib for *;
    using CastLib for *;

    IRoot root = IRoot(makeAddr("Root"));
    ISpoke spoke = ISpoke(makeAddr("Spoke"));
    ISpokeMessageSender sender = ISpokeMessageSender(makeAddr("Sender"));
    IERC6909 erc6909 = IERC6909(makeAddr("ERC6909"));
    IERC20 erc20 = IERC20(address(new ContractWithCode()));
    IShareToken share = IShareToken(makeAddr("ShareToken"));
    address escrow = makeAddr("Escrow");
    IPoolEscrowProvider escrowProvider = IPoolEscrowProvider(makeAddr("EscrowProvider"));

    address immutable AUTH = makeAddr("AUTH");
    address immutable ANY = makeAddr("ANY");
    address immutable RECEIVER = makeAddr("RECEIVER");
    address immutable MANAGER = makeAddr("MANAGER");

    uint128 constant AMOUNT = 100;
    D18 immutable IDENTITY_PRICE = d18(1, 1);
    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("scId"));
    AssetId constant ASSET_ID = AssetId.wrap(3);
    bool constant IS_DEPOSIT = true;
    bool constant IS_SNAPSHOT = true;

    D18 immutable ASSET_PRICE = d18(2, 1);
    D18 immutable SHARE_PRICE = d18(3, 1);

    BalanceSheet balanceSheet = new BalanceSheet(root, AUTH);

    function setUp() public {
        vm.mockCall(address(spoke), abi.encodeWithSelector(ISpoke.assetToId.selector, erc20, 0), abi.encode(ASSET_ID));
        vm.mockCall(address(spoke), abi.encodeWithSelector(ISpoke.shareToken.selector, erc20, 0), abi.encode(share));
        vm.mockCall(
            address(spoke),
            abi.encodeWithSelector(ISpoke.pricePoolPerAsset.selector, POOL_A, SC_1, ASSET_ID, true),
            abi.encode(ASSET_PRICE)
        );
        vm.mockCall(
            address(spoke),
            abi.encodeWithSelector(ISpoke.pricePoolPerShare.selector, POOL_A, SC_1, true),
            abi.encode(SHARE_PRICE)
        );
        vm.mockCall(
            address(escrowProvider),
            abi.encodeWithSelector(IPoolEscrowProvider.escrow.selector, POOL_A),
            abi.encode(escrow)
        );

        vm.startPrank(AUTH);
        balanceSheet.file("spoke", address(spoke));
        balanceSheet.file("sender", address(sender));
        balanceSheet.file("poolEscrowProvider", address(escrowProvider));
        balanceSheet.updateManager(POOL_A, MANAGER, true);
        vm.stopPrank();

        // mock poolEscrow.deposit()
        // mock poolEscrow.withdraw()
        // mock poolEscrow.authTransferTo()
        // mock shareToken.mint
        // mock shareToken.burn
        // mock shareToken.authTransferTo()

        // TODO: mock sender in each method
        // TODO: mock root.endorsed
    }

    function _mockEscrowDeposit(uint128 amount) internal {
        vm.mockCall(escrow, abi.encodeWithSelector(IPoolEscrow.deposit.selector, SC_1, erc20, 0, amount), abi.encode());
    }

    function _mockEscrowWithdraw(uint128 amount) internal {
        vm.mockCall(escrow, abi.encodeWithSelector(IPoolEscrow.withdraw.selector, SC_1, erc20, 0, amount), abi.encode());
    }

    function _mockUpdateHoldingAmount(uint128 amount, D18 price, bool isDeposit, bool isSnapshot, uint64 nonce)
        internal
    {
        vm.mockCall(
            address(sender),
            abi.encodeWithSelector(
                ISpokeMessageSender.sendUpdateHoldingAmount.selector,
                POOL_A,
                SC_1,
                ASSET_ID,
                amount,
                price,
                isDeposit,
                isSnapshot,
                nonce
            ),
            abi.encode()
        );
    }
}

contract BalanceSheetTestFile is BalanceSheetTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.file("any", address(0));
    }

    function testErrFileUnrecognizedParam() public {
        vm.prank(AUTH);
        vm.expectRevert(IBalanceSheet.FileUnrecognizedParam.selector);
        balanceSheet.file("unknown", address(1));
    }

    function testFile() public view {
        // Data initialized in setUp
        assertEq(address(balanceSheet.spoke()), address(spoke));
        assertEq(address(balanceSheet.sender()), address(sender));
        assertEq(address(balanceSheet.poolEscrowProvider()), address(escrowProvider));
    }
}

contract BalanceSheetTestUpdateManager is BalanceSheetTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.updateManager(POOL_A, MANAGER, true);
    }

    function testUpdateManager() public view {
        // Data initialized in setUp
        assertEq(balanceSheet.manager(POOL_A, MANAGER), true);
    }
}

contract BalanceSheetTestNoteDeposit is BalanceSheetTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.deposit(POOL_A, SC_1, address(erc20), 0, AMOUNT);
    }

    function testNoteDeposit(bool managerOrAuth) public {
        _mockEscrowDeposit(AMOUNT);
        _mockUpdateHoldingAmount(AMOUNT, ASSET_PRICE, IS_DEPOSIT, IS_SNAPSHOT, 0);

        vm.prank(managerOrAuth ? MANAGER : AUTH);
        vm.expectEmit();
        emit IBalanceSheet.Deposit(POOL_A, SC_1, address(erc20), 0, AMOUNT, ASSET_PRICE);
        balanceSheet.noteDeposit(POOL_A, SC_1, address(erc20), 0, AMOUNT);
    }
}

contract BalanceSheetTestDeposit is BalanceSheetTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.deposit(POOL_A, SC_1, address(erc20), 0, AMOUNT);
    }

    function testErrTransferFrom() public {
        _mockEscrowDeposit(AMOUNT);
        _mockUpdateHoldingAmount(AMOUNT, ASSET_PRICE, IS_DEPOSIT, IS_SNAPSHOT, 0);

        vm.mockCallRevert(
            address(erc20),
            abi.encodeWithSelector(IERC20.transferFrom.selector, AUTH, escrow, AMOUNT),
            abi.encode("err")
        );

        vm.prank(AUTH);
        vm.expectPartialRevert(IERC7751.WrappedError.selector);
        balanceSheet.deposit(POOL_A, SC_1, address(erc20), 0, AMOUNT);
    }

    function testDeposit(bool managerOrAuth) public {
        _mockEscrowDeposit(AMOUNT);
        _mockUpdateHoldingAmount(AMOUNT, ASSET_PRICE, IS_DEPOSIT, IS_SNAPSHOT, 0);

        vm.mockCall(
            address(erc20),
            abi.encodeWithSelector(IERC20.transferFrom.selector, managerOrAuth ? MANAGER : AUTH, escrow, AMOUNT),
            abi.encode(true)
        );

        vm.prank(managerOrAuth ? MANAGER : AUTH);
        vm.expectEmit();
        emit IBalanceSheet.Deposit(POOL_A, SC_1, address(erc20), 0, AMOUNT, ASSET_PRICE);
        balanceSheet.deposit(POOL_A, SC_1, address(erc20), 0, AMOUNT);
    }
}

contract BalanceSheetTestWithdraw is BalanceSheetTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.withdraw(POOL_A, SC_1, address(erc20), 0, RECEIVER, AMOUNT);
    }

    function testWithdraw(bool managerOrAuth) public {
        _mockEscrowWithdraw(AMOUNT);
        _mockUpdateHoldingAmount(AMOUNT, ASSET_PRICE, !IS_DEPOSIT, IS_SNAPSHOT, 0);

        vm.mockCall(
            address(erc20),
            abi.encodeWithSelector(IERC20.transferFrom.selector, managerOrAuth ? MANAGER : AUTH, escrow, AMOUNT),
            abi.encode(true)
        );

        vm.prank(managerOrAuth ? MANAGER : AUTH);
        vm.expectEmit();
        emit IBalanceSheet.Withdraw(POOL_A, SC_1, address(erc20), 0, RECEIVER, AMOUNT, ASSET_PRICE);
        balanceSheet.withdraw(POOL_A, SC_1, address(erc20), 0, RECEIVER, AMOUNT);
    }
}

/*

    function testDeposit() public {
        balanceSheet.setQueue(POOL_A, SC_1, true);

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.deposit(POOL_A, SC_1, address(erc20), 0, AMOUNT);

        vm.expectPartialRevert(IERC7751.WrappedError.selector);
        balanceSheet.deposit(POOL_A, SC_1, address(erc20), 0, AMOUNT);

        erc20.mint(address(this), AMOUNT);
        erc20.approve(address(balanceSheet), AMOUNT);

        vm.expectEmit();
        emit IBalanceSheet.Deposit(POOL_A, SC_1, address(erc20), 0, AMOUNT, SC_1);
        balanceSheet.deposit(POOL_A, SC_1, address(erc20), 0, AMOUNT);

        assertEq(erc20.balanceOf(address(this)), 0);
        (uint128 increase,) = balanceSheet.queuedAssets(POOL_A, SC_1, ASSET_ID);
        assertEq(increase, AMOUNT);
        assertEq(erc20.balanceOf(address(balanceSheet.poolEscrowProvider().escrow(POOL_A))), AMOUNT);
    }

    function testNoteDeposit() public {
        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.deposit(POOL_A, SC_1, address(erc20), 0, AMOUNT);

        vm.expectEmit();
        emit IBalanceSheet.Deposit(POOL_A, SC_1, address(erc20), 0, AMOUNT, SC_1);
        balanceSheet.noteDeposit(POOL_A, SC_1, address(erc20), 0, AMOUNT);

        // Ensure no balance transfer occurred but escrow holding was incremented nevertheless
        assertEq(erc20.balanceOf(address(this)), 0);
        assertEq(erc20.balanceOf(address(poolEscrowFactory.escrow(POOL_A))), 0);
        assertEq(poolEscrowFactory.escrow(POOL_A).availableBalanceOf(SC_1, address(erc20), 0), AMOUNT);
    }

    function testWithdraw() public {
        testDeposit();

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.withdraw(POOL_A, SC_1, address(erc20), 0, address(this), AMOUNT);

        assertEq(erc20.balanceOf(address(this)), 0);

        balanceSheet.overridePricePoolPerShare(POOL_A, SC_1, IDENTITY_PRICE);

        vm.expectEmit();
        emit IBalanceSheet.Withdraw(POOL_A, SC_1, address(erc20), 0, address(this), AMOUNT, SC_1);
        balanceSheet.withdraw(POOL_A, SC_1, address(erc20), 0, address(this), AMOUNT);

        (, uint128 decrease) = balanceSheet.queuedAssets(POOL_A, SC_1, ASSET_ID);

        assertEq(erc20.balanceOf(address(this)), AMOUNT);
        assertEq(decrease, AMOUNT);
        assertEq(erc20.balanceOf(address(balanceSheet.poolEscrowProvider().escrow(POOL_A))), 0);
    }

    function testIssue() public {
        balanceSheet.setQueue(POOL_A, SC_1, true);

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.issue(POOL_A, SC_1, address(this), AMOUNT);

        IERC20 token = IERC20(spoke.shareToken(POOL_A, SC_1));
        assertEq(token.balanceOf(address(this)), 0);

        balanceSheet.overridePricePoolPerShare(POOL_A, SC_1, IDENTITY_PRICE);

        vm.expectEmit();
        emit IBalanceSheet.Issue(POOL_A, SC_1, address(this), IDENTITY_PRICE, AMOUNT);
        balanceSheet.issue(POOL_A, SC_1, address(this), AMOUNT);

        (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(token.balanceOf(address(this)), AMOUNT);
        assertEq(delta, AMOUNT);
        assertEq(isPositive, true);

        balanceSheet.issue(POOL_A, SC_1, address(this), AMOUNT * 2);

        (uint128 deltaAfter, bool isPositive2,,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(token.balanceOf(address(this)), AMOUNT * 3);
        assertEq(deltaAfter, AMOUNT * 3);
        assertEq(isPositive2, true);
    }

    function testRevoke() public {
        testIssue();
        IShareToken token = IShareToken(spoke.shareToken(POOL_A, SC_1));
        assertEq(token.balanceOf(address(this)), AMOUNT * 3);

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.revoke(POOL_A, SC_1, AMOUNT);

        balanceSheet.overridePricePoolPerShare(POOL_A, SC_1, IDENTITY_PRICE);

        vm.expectEmit();
        emit IBalanceSheet.Revoke(POOL_A, SC_1, address(this), IDENTITY_PRICE, AMOUNT * 2);
        balanceSheet.revoke(POOL_A, SC_1, AMOUNT * 2);

        (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(token.balanceOf(address(this)), AMOUNT);
        assertEq(delta, AMOUNT);
        assertEq(isPositive, true);

        // Mint directly to avoid issuance call
        vm.prank(address(root));
        token.mint(address(this), AMOUNT * 3);

        balanceSheet.revoke(POOL_A, SC_1, AMOUNT * 3);

        (uint128 delta2, bool isPositive2,,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(token.balanceOf(address(this)), AMOUNT);
        assertEq(delta2, AMOUNT * 2);
        assertEq(isPositive2, false);
    }

    function testQueuedShares() public {
        testRevoke();

        vm.mockCall(
            address(balanceSheet.sender()),
            abi.encodeWithSelector(ISpokeMessageSender.sendUpdateShares.selector, AMOUNT, true),
            abi.encode()
        );

        balanceSheet.issue(POOL_A, SC_1, address(this), AMOUNT * 3);
        (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(delta, AMOUNT);
        assertEq(isPositive, true);

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.submitQueuedShares(POOL_A, SC_1);

        balanceSheet.submitQueuedShares(POOL_A, SC_1);

        (uint128 deltaAfter, bool isPositiveAfter,,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(deltaAfter, 0);
        assertEq(isPositiveAfter, true);
    }

    function testQueuedAssets() public {
        testDeposit();

        vm.mockCall(
            address(balanceSheet.sender()),
            abi.encodeWithSelector(ISpokeMessageSender.sendUpdateHoldingAmount.selector, AMOUNT, true),
            abi.encode()
        );

        (uint128 increase,) = balanceSheet.queuedAssets(POOL_A, SC_1, ASSET_ID);
        assertEq(increase, AMOUNT);

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.submitQueuedAssets(POOL_A, SC_1, ASSET_ID);

        balanceSheet.submitQueuedAssets(POOL_A, SC_1, ASSET_ID);

        (uint128 increaseAfter,) = balanceSheet.queuedAssets(POOL_A, SC_1, ASSET_ID);
        assertEq(increaseAfter, 0);
    }

    function testAssetsQueueDisabled() public {
        vm.mockCall(
            address(balanceSheet.sender()),
            abi.encodeWithSelector(ISpokeMessageSender.sendUpdateHoldingAmount.selector, AMOUNT, true),
            abi.encode()
        );

        erc20.mint(address(this), AMOUNT);
        erc20.approve(address(balanceSheet), AMOUNT);

        balanceSheet.setQueue(POOL_A, SC_1, false);
        balanceSheet.deposit(POOL_A, SC_1, address(erc20), 0, AMOUNT);

        (uint128 increase,) = balanceSheet.queuedAssets(POOL_A, SC_1, ASSET_ID);
        assertEq(increase, 0);

        vm.mockCall(
            address(balanceSheet.sender()),
            abi.encodeWithSelector(ISpokeMessageSender.sendUpdateHoldingAmount.selector, AMOUNT / 2, false),
            abi.encode()
        );

        balanceSheet.withdraw(POOL_A, SC_1, address(erc20), 0, address(this), AMOUNT / 2);

        (, uint128 decrease) = balanceSheet.queuedAssets(POOL_A, SC_1, ASSET_ID);
        assertEq(decrease, 0);
    }

    function testSharesQueueDisabled() public {
        vm.mockCall(
            address(balanceSheet.sender()),
            abi.encodeWithSelector(ISpokeMessageSender.sendUpdateShares.selector, AMOUNT, true),
            abi.encode()
        );

        balanceSheet.setQueue(POOL_A, SC_1, false);
        balanceSheet.issue(POOL_A, SC_1, address(this), AMOUNT);

        (uint128 increase,,,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(increase, 0);
    }

    function testSubmitWithQueueDisabled() public {
        vm.mockCall(
            address(balanceSheet.sender()),
            abi.encodeWithSelector(ISpokeMessageSender.sendUpdateShares.selector, AMOUNT, true),
            abi.encode()
        );

        // Issue with queue enabled
        balanceSheet.setQueue(POOL_A, SC_1, true);
        balanceSheet.issue(POOL_A, SC_1, address(this), AMOUNT);

        (uint128 increase,,,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(increase, AMOUNT);

        // Submit with queue disabled
        balanceSheet.setQueue(POOL_A, SC_1, false);
        balanceSheet.submitQueuedShares(POOL_A, SC_1);

        // Shares should be submitted even if disabled
        (increase,,,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(increase, 0);
    }

    function testTransferSharesFrom() public {
        testIssue();

        IERC20 token = IERC20(spoke.shareToken(POOL_A, SC_1));

        assertEq(token.balanceOf(address(this)), AMOUNT * 3);

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.transferSharesFrom(POOL_A, SC_1, address(this), address(1), AMOUNT);

        vm.expectRevert(IBalanceSheet.CannotTransferFromEndorsedContract.selector);
        balanceSheet.transferSharesFrom(POOL_A, SC_1, address(globalEscrow), address(1), AMOUNT);

        balanceSheet.transferSharesFrom(POOL_A, SC_1, address(this), address(1), AMOUNT);

        assertEq(token.balanceOf(address(this)), AMOUNT * 2);
        assertEq(token.balanceOf(address(1)), AMOUNT);
    }

    function testPriceOverride() public {
        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.overridePricePoolPerShare(POOL_A, SC_1, IDENTITY_PRICE);

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.overridePricePoolPerAsset(POOL_A, SC_1, ASSET_ID, SC_1);

        D18 pricePerAsset = d18(3, 1);
        D18 pricePerShare = d18(2, 1);

        balanceSheet.overridePricePoolPerAsset(POOL_A, SC_1, ASSET_ID, pricePerAsset);
        balanceSheet.overridePricePoolPerShare(POOL_A, SC_1, pricePerShare);

        vm.expectEmit();
        emit IBalanceSheet.Deposit(POOL_A, SC_1, address(erc20), 0, AMOUNT, pricePerAsset);
        balanceSheet.noteDeposit(POOL_A, SC_1, address(erc20), 0, AMOUNT);

        balanceSheet.issue(POOL_A, SC_1, address(this), AMOUNT);

        vm.expectEmit();
        emit IBalanceSheet.Revoke(POOL_A, SC_1, address(this), pricePerShare, AMOUNT);
        balanceSheet.revoke(POOL_A, SC_1, AMOUNT);

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.resetPricePoolPerShare(POOL_A, SC_1);

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.resetPricePoolPerAsset(POOL_A, SC_1, ASSET_ID);

        balanceSheet.resetPricePoolPerAsset(POOL_A, SC_1, ASSET_ID);
        balanceSheet.resetPricePoolPerShare(POOL_A, SC_1);

        vm.expectEmit();
        emit IBalanceSheet.Deposit(POOL_A, SC_1, address(erc20), 0, AMOUNT, SC_1);
        balanceSheet.noteDeposit(POOL_A, SC_1, address(erc20), 0, AMOUNT);

        balanceSheet.issue(POOL_A, SC_1, address(this), AMOUNT);

        vm.expectEmit();
        emit IBalanceSheet.Revoke(POOL_A, SC_1, address(this), IDENTITY_PRICE, AMOUNT);
        balanceSheet.revoke(POOL_A, SC_1, AMOUNT);
    }
}
*/
