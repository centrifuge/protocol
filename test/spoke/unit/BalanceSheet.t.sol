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
import {IPoolEscrow, IEscrow} from "src/spoke/interfaces/IEscrow.sol";
import {IPoolEscrowProvider} from "src/spoke/factories/interfaces/IPoolEscrowFactory.sol";

// Need it to overpass a mockCall issue: https://github.com/foundry-rs/foundry/issues/10703
contract IsContract {}

contract BalanceSheetTest is Test {
    using UpdateRestrictionMessageLib for *;
    using CastLib for *;

    IRoot root = IRoot(makeAddr("Root"));
    ISpoke spoke = ISpoke(makeAddr("Spoke"));
    ISpokeMessageSender sender = ISpokeMessageSender(makeAddr("Sender"));
    address erc6909 = address(new IsContract());
    address erc20 = address(new IsContract());
    address share = address(new IsContract());
    address escrow = address(new IsContract());
    IPoolEscrowProvider escrowProvider = IPoolEscrowProvider(makeAddr("EscrowProvider"));

    address immutable AUTH = makeAddr("AUTH");
    address immutable ANY = makeAddr("ANY");
    address immutable RECEIVER = makeAddr("RECEIVER");
    address immutable MANAGER = makeAddr("MANAGER");

    uint128 constant AMOUNT = 100;
    D18 immutable IDENTITY_PRICE = d18(1, 1);
    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("scId"));
    AssetId constant ASSET_20 = AssetId.wrap(3);
    AssetId constant ASSET_6909_1 = AssetId.wrap(4);
    uint256 constant TOKEN_ID = 1;
    bool constant IS_ISSUANCE = true;
    bool constant IS_DEPOSIT = true;
    bool constant IS_SNAPSHOT = true;

    D18 immutable ASSET_PRICE = d18(2, 1);
    D18 immutable SHARE_PRICE = d18(3, 1);

    BalanceSheet balanceSheet = new BalanceSheet(root, AUTH);

    function setUp() public {
        vm.mockCall(address(spoke), abi.encodeWithSelector(ISpoke.assetToId.selector, erc20, 0), abi.encode(ASSET_20));
        vm.mockCall(
            address(spoke),
            abi.encodeWithSelector(ISpoke.assetToId.selector, erc6909, TOKEN_ID),
            abi.encode(ASSET_6909_1)
        );
        vm.mockCall(address(spoke), abi.encodeWithSelector(ISpoke.shareToken.selector, POOL_A, SC_1), abi.encode(share));
        vm.mockCall(
            address(spoke),
            abi.encodeWithSelector(ISpoke.pricePoolPerAsset.selector, POOL_A, SC_1, ASSET_20, true),
            abi.encode(ASSET_PRICE)
        );
        vm.mockCall(
            address(spoke),
            abi.encodeWithSelector(ISpoke.pricePoolPerAsset.selector, POOL_A, SC_1, ASSET_6909_1, true),
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
    }

    function _mockEscrowDeposit(address asset, uint256 tokenId, uint128 amount) internal {
        vm.mockCall(
            escrow, abi.encodeWithSelector(IPoolEscrow.deposit.selector, SC_1, asset, tokenId, amount), abi.encode()
        );
    }

    function _mockEscrowWithdraw(address asset, uint256 tokenId, uint128 amount) internal {
        vm.mockCall(
            escrow, abi.encodeWithSelector(IPoolEscrow.withdraw.selector, SC_1, asset, tokenId, amount), abi.encode()
        );
        vm.mockCall(
            escrow,
            abi.encodeWithSelector(IEscrow.authTransferTo.selector, asset, tokenId, RECEIVER, amount),
            abi.encode()
        );
    }

    function _mockShareMint(uint128 amount) internal {
        vm.mockCall(share, abi.encodeWithSelector(IShareToken.mint.selector, RECEIVER, amount), abi.encode());
    }

    function _mockShareBurn(uint128 amount) internal {
        vm.mockCall(share, abi.encodeWithSelector(IShareToken.burn.selector, balanceSheet, amount), abi.encode());
    }

    function _mockShareAuthTransferFrom(address from, address to, uint128 amount) internal {
        vm.mockCall(
            share,
            abi.encodeWithSelector(IShareToken.authTransferFrom.selector, from, from, to, amount),
            abi.encode(true)
        );
    }

    function _mockSendUpdateHoldingAmount(
        AssetId assetId,
        uint128 amount,
        D18 price,
        bool isDeposit,
        bool isSnapshot,
        uint64 nonce
    ) internal {
        vm.mockCall(
            address(sender),
            abi.encodeWithSelector(
                ISpokeMessageSender.sendUpdateHoldingAmount.selector,
                POOL_A,
                SC_1,
                assetId,
                amount,
                price,
                isDeposit,
                isSnapshot,
                nonce
            ),
            abi.encode()
        );
    }

    function _mockSendUpdateShares(uint128 delta, bool isPositive, bool isSnapshot, uint64 nonce) internal {
        vm.mockCall(
            address(sender),
            abi.encodeWithSelector(
                ISpokeMessageSender.sendUpdateShares.selector, POOL_A, SC_1, delta, isPositive, isSnapshot, nonce
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
        balanceSheet.deposit(POOL_A, SC_1, erc20, 0, AMOUNT);
    }

    function testNoteDeposit(bool managerOrAuth) public {
        _mockEscrowDeposit(erc20, 0, AMOUNT);

        vm.prank(managerOrAuth ? MANAGER : AUTH);
        vm.expectEmit();
        emit IBalanceSheet.NoteDeposit(POOL_A, SC_1, erc20, 0, AMOUNT, ASSET_PRICE);
        balanceSheet.noteDeposit(POOL_A, SC_1, erc20, 0, AMOUNT);

        (,, uint32 queuedAssetCounter,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 1);

        (uint128 deposits,) = balanceSheet.queuedAssets(POOL_A, SC_1, ASSET_20);
        assertEq(deposits, AMOUNT);
    }

    function testNoteDepositTwice() public {
        _mockEscrowDeposit(erc20, 0, AMOUNT);

        vm.startPrank(AUTH);
        balanceSheet.noteDeposit(POOL_A, SC_1, erc20, 0, AMOUNT);
        balanceSheet.noteDeposit(POOL_A, SC_1, erc20, 0, AMOUNT);

        (,, uint32 queuedAssetCounter,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 1);

        (uint128 deposits,) = balanceSheet.queuedAssets(POOL_A, SC_1, ASSET_20);
        assertEq(deposits, AMOUNT * 2);
    }
}

contract BalanceSheetTestDeposit is BalanceSheetTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.deposit(POOL_A, SC_1, erc20, 0, AMOUNT);
    }

    function testDepositERC20(bool managerOrAuth) public {
        _mockEscrowDeposit(erc20, 0, AMOUNT);

        vm.mockCall(
            erc20,
            abi.encodeWithSelector(IERC20.transferFrom.selector, managerOrAuth ? MANAGER : AUTH, escrow, AMOUNT),
            abi.encode(true)
        );

        vm.prank(managerOrAuth ? MANAGER : AUTH);
        vm.expectEmit();
        emit IBalanceSheet.NoteDeposit(POOL_A, SC_1, erc20, 0, AMOUNT, ASSET_PRICE);
        vm.expectEmit();
        emit IBalanceSheet.Deposit(POOL_A, SC_1, erc20, 0, AMOUNT);
        balanceSheet.deposit(POOL_A, SC_1, erc20, 0, AMOUNT);
    }

    function testDepositERC6909() public {
        _mockEscrowDeposit(erc6909, TOKEN_ID, AMOUNT);

        vm.mockCall(
            address(erc6909),
            abi.encodeWithSelector(IERC6909.transferFrom.selector, AUTH, escrow, TOKEN_ID, AMOUNT),
            abi.encode(true)
        );

        vm.prank(AUTH);
        balanceSheet.deposit(POOL_A, SC_1, address(erc6909), TOKEN_ID, AMOUNT);
    }
}

contract BalanceSheetTestWithdraw is BalanceSheetTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.withdraw(POOL_A, SC_1, erc20, 0, RECEIVER, AMOUNT);
    }

    function testWithdraw(bool managerOrAuth) public {
        _mockEscrowWithdraw(erc20, 0, AMOUNT);

        vm.prank(managerOrAuth ? MANAGER : AUTH);
        vm.expectEmit();
        emit IBalanceSheet.Withdraw(POOL_A, SC_1, erc20, 0, RECEIVER, AMOUNT, ASSET_PRICE);
        balanceSheet.withdraw(POOL_A, SC_1, erc20, 0, RECEIVER, AMOUNT);

        (,, uint32 queuedAssetCounter,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 1);

        (, uint128 withdrawals) = balanceSheet.queuedAssets(POOL_A, SC_1, ASSET_20);
        assertEq(withdrawals, AMOUNT);
    }

    function testWithdrawTwice() public {
        _mockEscrowWithdraw(erc20, 0, AMOUNT);

        vm.startPrank(AUTH);
        balanceSheet.withdraw(POOL_A, SC_1, erc20, 0, RECEIVER, AMOUNT);
        balanceSheet.withdraw(POOL_A, SC_1, erc20, 0, RECEIVER, AMOUNT);

        (,, uint32 queuedAssetCounter,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 1);

        (, uint128 withdrawals) = balanceSheet.queuedAssets(POOL_A, SC_1, ASSET_20);
        assertEq(withdrawals, AMOUNT * 2);
    }
}

contract BalanceSheetTestIssue is BalanceSheetTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.issue(POOL_A, SC_1, RECEIVER, AMOUNT);
    }

    function testIssue(bool managerOrAuth) public {
        _mockShareMint(AMOUNT);

        vm.prank(managerOrAuth ? MANAGER : AUTH);
        vm.expectEmit();
        emit IBalanceSheet.Issue(POOL_A, SC_1, RECEIVER, SHARE_PRICE, AMOUNT);
        balanceSheet.issue(POOL_A, SC_1, RECEIVER, AMOUNT);

        (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(delta, AMOUNT);
        assertEq(isPositive, true);
    }

    function testIssueTwice() public {
        _mockShareMint(AMOUNT);

        vm.startPrank(AUTH);
        balanceSheet.issue(POOL_A, SC_1, RECEIVER, AMOUNT);
        balanceSheet.issue(POOL_A, SC_1, RECEIVER, AMOUNT);

        (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(delta, AMOUNT * 2);
        assertEq(isPositive, true);
    }
}

contract BalanceSheetTestRevoke is BalanceSheetTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.revoke(POOL_A, SC_1, AMOUNT);
    }

    function testRevoke(bool managerOrAuth) public {
        _mockShareBurn(AMOUNT);
        _mockShareAuthTransferFrom(managerOrAuth ? MANAGER : AUTH, address(balanceSheet), AMOUNT);

        vm.prank(managerOrAuth ? MANAGER : AUTH);
        vm.expectEmit();
        emit IBalanceSheet.Revoke(POOL_A, SC_1, managerOrAuth ? MANAGER : AUTH, SHARE_PRICE, AMOUNT);
        balanceSheet.revoke(POOL_A, SC_1, AMOUNT);

        (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(delta, AMOUNT);
        assertEq(isPositive, false);
    }

    function testRevokeTwice() public {
        _mockShareBurn(AMOUNT);
        _mockShareAuthTransferFrom(AUTH, address(balanceSheet), AMOUNT);

        vm.startPrank(AUTH);
        balanceSheet.revoke(POOL_A, SC_1, AMOUNT);
        balanceSheet.revoke(POOL_A, SC_1, AMOUNT);

        (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(delta, AMOUNT * 2);
        assertEq(isPositive, false);
    }
}

contract BalanceSheetTestSubmitQueuedAssets is BalanceSheetTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.submitQueuedAssets(POOL_A, SC_1, ASSET_20);
    }

    function testSubmitQueuedAssetsEmpty(bool managerOrAuth) public {
        // Does nothing, no mocks required
        vm.prank(managerOrAuth ? MANAGER : AUTH);
        balanceSheet.submitQueuedAssets(POOL_A, SC_1, ASSET_20);

        (,, uint32 queuedAssetCounter, uint64 nonce) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 0);
        assertEq(nonce, 0);
    }

    function testSubmitQueuedAssetsWithMoreDepositAmount() public {
        _mockEscrowDeposit(erc20, 0, AMOUNT * 3);
        _mockEscrowWithdraw(erc20, 0, AMOUNT);
        _mockSendUpdateHoldingAmount(ASSET_20, AMOUNT * 2, ASSET_PRICE, IS_DEPOSIT, IS_SNAPSHOT, 0);

        vm.startPrank(AUTH);
        balanceSheet.noteDeposit(POOL_A, SC_1, erc20, 0, AMOUNT * 3);
        balanceSheet.withdraw(POOL_A, SC_1, erc20, 0, RECEIVER, AMOUNT);
        balanceSheet.submitQueuedAssets(POOL_A, SC_1, ASSET_20);

        (uint128 deposits, uint128 withdrawals) = balanceSheet.queuedAssets(POOL_A, SC_1, ASSET_20);
        assertEq(deposits, 0);
        assertEq(withdrawals, 0);

        (,, uint32 queuedAssetCounter, uint64 nonce) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 0);
        assertEq(nonce, 1);
    }

    function testSubmitQueuedAssetsWithMoreWithdrawAmount() public {
        _mockEscrowDeposit(erc20, 0, AMOUNT);
        _mockEscrowWithdraw(erc20, 0, AMOUNT * 3);
        _mockSendUpdateHoldingAmount(ASSET_20, AMOUNT * 2, ASSET_PRICE, !IS_DEPOSIT, IS_SNAPSHOT, 0);

        vm.startPrank(AUTH);
        balanceSheet.noteDeposit(POOL_A, SC_1, erc20, 0, AMOUNT);
        balanceSheet.withdraw(POOL_A, SC_1, erc20, 0, RECEIVER, AMOUNT * 3);
        balanceSheet.submitQueuedAssets(POOL_A, SC_1, ASSET_20);

        (uint128 deposits, uint128 withdrawals) = balanceSheet.queuedAssets(POOL_A, SC_1, ASSET_20);
        assertEq(deposits, 0);
        assertEq(withdrawals, 0);

        (,, uint32 queuedAssetCounter, uint64 nonce) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 0);
        assertEq(nonce, 1);
    }

    function testSubmitQueuedAssetsWithSameAmount() public {
        _mockEscrowDeposit(erc20, 0, AMOUNT);
        _mockEscrowWithdraw(erc20, 0, AMOUNT);
        _mockSendUpdateHoldingAmount(ASSET_20, AMOUNT, ASSET_PRICE, IS_DEPOSIT, IS_SNAPSHOT, 0);

        vm.startPrank(AUTH);
        balanceSheet.noteDeposit(POOL_A, SC_1, erc20, 0, AMOUNT);
        balanceSheet.withdraw(POOL_A, SC_1, erc20, 0, RECEIVER, AMOUNT);
        balanceSheet.submitQueuedAssets(POOL_A, SC_1, ASSET_20);

        (uint128 deposits, uint128 withdrawals) = balanceSheet.queuedAssets(POOL_A, SC_1, ASSET_20);
        assertEq(deposits, 0);
        assertEq(withdrawals, 0);

        (,, uint32 queuedAssetCounter, uint64 nonce) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 0);
        assertEq(nonce, 1);
    }

    function testSubmitQueuedAssetsWithDifferentAssets() public {
        _mockEscrowDeposit(erc20, 0, AMOUNT);
        _mockEscrowDeposit(erc6909, TOKEN_ID, AMOUNT);
        _mockSendUpdateHoldingAmount(ASSET_20, AMOUNT, ASSET_PRICE, IS_DEPOSIT, !IS_SNAPSHOT, 0);

        vm.startPrank(AUTH);
        balanceSheet.noteDeposit(POOL_A, SC_1, erc20, 0, AMOUNT);
        balanceSheet.noteDeposit(POOL_A, SC_1, erc6909, TOKEN_ID, AMOUNT);
        balanceSheet.submitQueuedAssets(POOL_A, SC_1, ASSET_20);

        (uint128 deposits, uint128 withdrawals) = balanceSheet.queuedAssets(POOL_A, SC_1, ASSET_20);
        assertEq(deposits, 0);
        assertEq(withdrawals, 0);

        (,, uint32 queuedAssetCounter, uint64 nonce) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 1);
        assertEq(nonce, 1);
    }

    function testSubmitQueuedAssetsTwice() public {
        _mockEscrowDeposit(erc20, 0, AMOUNT);
        _mockEscrowWithdraw(erc20, 0, AMOUNT);
        _mockSendUpdateHoldingAmount(ASSET_20, AMOUNT, ASSET_PRICE, IS_DEPOSIT, IS_SNAPSHOT, 1);

        vm.startPrank(AUTH);
        balanceSheet.noteDeposit(POOL_A, SC_1, erc20, 0, AMOUNT);
        balanceSheet.withdraw(POOL_A, SC_1, erc20, 0, RECEIVER, AMOUNT);
        balanceSheet.submitQueuedAssets(POOL_A, SC_1, ASSET_20); // No message sent

        balanceSheet.noteDeposit(POOL_A, SC_1, erc20, 0, AMOUNT);
        balanceSheet.submitQueuedAssets(POOL_A, SC_1, ASSET_20);

        (uint128 deposits, uint128 withdrawals) = balanceSheet.queuedAssets(POOL_A, SC_1, ASSET_20);
        assertEq(deposits, 0);
        assertEq(withdrawals, 0);

        (,, uint32 queuedAssetCounter, uint64 nonce) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 0);
        assertEq(nonce, 2);
    }
}

contract BalanceSheetTestSubmitQueuedShares is BalanceSheetTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.submitQueuedShares(POOL_A, SC_1);
    }

    function testSubmitQueuedSharesEmpty(bool managerOrAuth) public {
        // Does nothing, no mocks required
        vm.prank(managerOrAuth ? MANAGER : AUTH);
        balanceSheet.submitQueuedShares(POOL_A, SC_1);

        (,, uint32 queuedAssetCounter, uint64 nonce) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 0);
        assertEq(nonce, 0);
    }

    function testSubmitQueuedSharesWithDeltaPositive() public {
        _mockShareMint(AMOUNT);
        _mockSendUpdateShares(AMOUNT, IS_ISSUANCE, IS_SNAPSHOT, 0);

        vm.startPrank(AUTH);
        balanceSheet.issue(POOL_A, SC_1, RECEIVER, AMOUNT);
        balanceSheet.submitQueuedShares(POOL_A, SC_1);

        (uint128 delta,,, uint64 nonce) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(delta, 0);
        assertEq(nonce, 1);
    }
}
