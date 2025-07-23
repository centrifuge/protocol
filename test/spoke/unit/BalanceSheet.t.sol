// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "../../../src/misc/types/D18.sol";
import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {IERC20} from "../../../src/misc/interfaces/IERC20.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";
import {IEscrow} from "../../../src/misc/interfaces/IEscrow.sol";
import {IERC6909} from "../../../src/misc/interfaces/IERC6909.sol";

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {AssetId} from "../../../src/common/types/AssetId.sol";
import {IRoot} from "../../../src/common/interfaces/IRoot.sol";
import {IGateway} from "../../../src/common/interfaces/IGateway.sol";
import {ShareClassId} from "../../../src/common/types/ShareClassId.sol";
import {IPoolEscrow} from "../../../src/common/interfaces/IPoolEscrow.sol";
import {ISpokeMessageSender} from "../../../src/common/interfaces/IGatewaySenders.sol";
import {IPoolEscrowProvider} from "../../../src/common/factories/interfaces/IPoolEscrowFactory.sol";

import {ISpoke} from "../../../src/spoke/interfaces/ISpoke.sol";
import {IShareToken} from "../../../src/spoke/interfaces/IShareToken.sol";
import {BalanceSheet, IBalanceSheet} from "../../../src/spoke/BalanceSheet.sol";

import {UpdateRestrictionMessageLib} from "../../../src/hooks/libraries/UpdateRestrictionMessageLib.sol";

import "forge-std/Test.sol";

// Need it to overpass a mockCall issue: https://github.com/foundry-rs/foundry/issues/10703
contract IsContract {}

contract BalanceSheetExt is BalanceSheet {
    constructor(IRoot root_, address deployer) BalanceSheet(root_, deployer) {}

    function pricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId) public view returns (D18) {
        return super._pricePoolPerAsset(poolId, scId, assetId);
    }

    function pricePoolPerShare(PoolId poolId, ShareClassId scId) public view returns (D18) {
        return super._pricePoolPerShare(poolId, scId);
    }
}

contract BalanceSheetTest is Test {
    using UpdateRestrictionMessageLib for *;
    using CastLib for *;

    IRoot root = IRoot(makeAddr("Root"));
    ISpoke spoke = ISpoke(makeAddr("Spoke"));
    IGateway gateway = IGateway(makeAddr("Gateway"));
    ISpokeMessageSender sender = ISpokeMessageSender(address(new IsContract()));
    address erc6909 = address(new IsContract());
    address erc20 = address(new IsContract());
    address share = address(new IsContract());
    address escrow = address(new IsContract());
    IPoolEscrowProvider escrowProvider = IPoolEscrowProvider(makeAddr("EscrowProvider"));

    address immutable AUTH = makeAddr("AUTH");
    address immutable ANY = makeAddr("ANY");
    address immutable SENDER = makeAddr("SENDER");
    address immutable FROM = makeAddr("FROM");
    address immutable TO = makeAddr("TO");
    address immutable MANAGER = makeAddr("MANAGER");

    uint128 constant AMOUNT = 100;
    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("scId"));
    AssetId constant ASSET_20 = AssetId.wrap(3);
    AssetId constant ASSET_6909_1 = AssetId.wrap(4);
    uint256 constant TOKEN_ID = 1;
    bool constant IS_ISSUANCE = true;
    bool constant IS_DEPOSIT = true;
    bool constant IS_SNAPSHOT = true;
    uint128 constant EXTRA_GAS = 0;

    D18 immutable IDENTITY_PRICE = d18(1, 1);
    D18 immutable ASSET_PRICE = d18(2, 1);
    D18 immutable SHARE_PRICE = d18(3, 1);

    BalanceSheetExt balanceSheet = new BalanceSheetExt(root, AUTH);

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
        balanceSheet.file("gateway", address(gateway));
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
            escrow, abi.encodeWithSelector(IEscrow.authTransferTo.selector, asset, tokenId, TO, amount), abi.encode()
        );
    }

    function _mockShareMint(uint128 amount) internal {
        vm.mockCall(share, abi.encodeWithSelector(IShareToken.mint.selector, TO, amount), abi.encode());
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
                ISpokeMessageSender.UpdateData({
                    netAmount: amount,
                    isIncrease: isDeposit,
                    isSnapshot: isSnapshot,
                    nonce: nonce
                }),
                price,
                EXTRA_GAS
            ),
            abi.encode()
        );
    }

    function _mockSendUpdateShares(uint128 delta, bool isPositive, bool isSnapshot, uint64 nonce) internal {
        vm.mockCall(
            address(sender),
            abi.encodeWithSelector(
                ISpokeMessageSender.sendUpdateShares.selector,
                POOL_A,
                SC_1,
                ISpokeMessageSender.UpdateData({
                    netAmount: delta,
                    isIncrease: isPositive,
                    isSnapshot: isSnapshot,
                    nonce: nonce
                }),
                EXTRA_GAS
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
        assertEq(address(balanceSheet.gateway()), address(gateway));
    }
}

contract BalanceSheetTestMulticall is BalanceSheetTest {
    function testMulticall() public {
        vm.mockCall(address(gateway), abi.encodeWithSelector(IGateway.isBatching.selector), abi.encode(false));
        vm.mockCall(address(gateway), abi.encodeWithSelector(IGateway.startBatching.selector), abi.encode());
        vm.mockCall(address(gateway), abi.encodeWithSelector(IGateway.endBatching.selector), abi.encode());
        _mockEscrowDeposit(erc20, 0, AMOUNT);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(IBalanceSheet.noteDeposit.selector, POOL_A, SC_1, erc20, 0, AMOUNT);
        calls[1] = abi.encodeWithSelector(IBalanceSheet.noteDeposit.selector, POOL_A, SC_1, erc20, 0, AMOUNT);

        vm.startPrank(AUTH);
        balanceSheet.multicall(calls);

        (uint128 deposits,) = balanceSheet.queuedAssets(POOL_A, SC_1, ASSET_20);
        assertEq(deposits, AMOUNT * 2);
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

    function testNoteDepositZero() public {
        _mockEscrowDeposit(erc20, 0, 0);

        vm.startPrank(AUTH);
        balanceSheet.noteDeposit(POOL_A, SC_1, erc20, 0, 0);

        (,, uint32 queuedAssetCounter,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 0);
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

    function testNoteDepositPriceOverridingPrice() public {
        _mockEscrowDeposit(erc20, 0, AMOUNT);

        vm.startPrank(AUTH);
        balanceSheet.overridePricePoolPerAsset(POOL_A, SC_1, ASSET_20, IDENTITY_PRICE);

        vm.expectEmit();
        emit IBalanceSheet.NoteDeposit(POOL_A, SC_1, erc20, 0, AMOUNT, IDENTITY_PRICE); // <- override
        balanceSheet.noteDeposit(POOL_A, SC_1, erc20, 0, AMOUNT);
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
        balanceSheet.withdraw(POOL_A, SC_1, erc20, 0, TO, AMOUNT);
    }

    function testWithdraw(bool managerOrAuth) public {
        _mockEscrowWithdraw(erc20, 0, AMOUNT);

        vm.prank(managerOrAuth ? MANAGER : AUTH);
        vm.expectEmit();
        emit IBalanceSheet.Withdraw(POOL_A, SC_1, erc20, 0, TO, AMOUNT, ASSET_PRICE);
        balanceSheet.withdraw(POOL_A, SC_1, erc20, 0, TO, AMOUNT);

        (,, uint32 queuedAssetCounter,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 1);

        (, uint128 withdrawals) = balanceSheet.queuedAssets(POOL_A, SC_1, ASSET_20);
        assertEq(withdrawals, AMOUNT);
    }

    function testWithdrawZero() public {
        _mockEscrowWithdraw(erc20, 0, 0);

        vm.startPrank(AUTH);
        balanceSheet.withdraw(POOL_A, SC_1, erc20, 0, TO, 0);

        (,, uint32 queuedAssetCounter,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 0);
    }

    function testWithdrawTwice() public {
        _mockEscrowWithdraw(erc20, 0, AMOUNT);

        vm.startPrank(AUTH);
        balanceSheet.withdraw(POOL_A, SC_1, erc20, 0, TO, AMOUNT);
        balanceSheet.withdraw(POOL_A, SC_1, erc20, 0, TO, AMOUNT);

        (,, uint32 queuedAssetCounter,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 1);

        (, uint128 withdrawals) = balanceSheet.queuedAssets(POOL_A, SC_1, ASSET_20);
        assertEq(withdrawals, AMOUNT * 2);
    }

    function testWithdrawOverridingPrice() public {
        _mockEscrowWithdraw(erc20, 0, AMOUNT);

        vm.startPrank(AUTH);
        balanceSheet.overridePricePoolPerAsset(POOL_A, SC_1, ASSET_20, IDENTITY_PRICE);

        vm.expectEmit();
        emit IBalanceSheet.Withdraw(POOL_A, SC_1, erc20, 0, TO, AMOUNT, IDENTITY_PRICE); // override
        balanceSheet.withdraw(POOL_A, SC_1, erc20, 0, TO, AMOUNT);
    }
}

contract BalanceSheetTestReserve is BalanceSheetTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.reserve(POOL_A, SC_1, erc20, 0, AMOUNT);
    }

    function testReserve(bool managerOrAuth) public {
        vm.mockCall(escrow, abi.encodeWithSelector(IPoolEscrow.reserve.selector, SC_1, erc20, 0, AMOUNT), abi.encode());

        vm.prank(managerOrAuth ? MANAGER : AUTH);
        balanceSheet.reserve(POOL_A, SC_1, erc20, 0, AMOUNT);
    }
}

contract BalanceSheetTestUnreserve is BalanceSheetTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.unreserve(POOL_A, SC_1, erc20, 0, AMOUNT);
    }

    function testReserve(bool managerOrAuth) public {
        vm.mockCall(
            escrow, abi.encodeWithSelector(IPoolEscrow.unreserve.selector, SC_1, erc20, 0, AMOUNT), abi.encode()
        );

        vm.prank(managerOrAuth ? MANAGER : AUTH);
        balanceSheet.unreserve(POOL_A, SC_1, erc20, 0, AMOUNT);
    }
}

contract BalanceSheetTestIssue is BalanceSheetTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.issue(POOL_A, SC_1, TO, AMOUNT);
    }

    function testIssue(bool managerOrAuth) public {
        _mockShareMint(AMOUNT);

        vm.prank(managerOrAuth ? MANAGER : AUTH);
        vm.expectEmit();
        emit IBalanceSheet.Issue(POOL_A, SC_1, TO, SHARE_PRICE, AMOUNT);
        balanceSheet.issue(POOL_A, SC_1, TO, AMOUNT);

        (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(delta, AMOUNT);
        assertEq(isPositive, true);
    }

    function testIssueTwice() public {
        _mockShareMint(AMOUNT);

        vm.startPrank(AUTH);
        balanceSheet.issue(POOL_A, SC_1, TO, AMOUNT);
        balanceSheet.issue(POOL_A, SC_1, TO, AMOUNT);

        (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(delta, AMOUNT * 2);
        assertEq(isPositive, true);
    }

    function testIssueOverridingPrice() public {
        _mockShareMint(AMOUNT);

        vm.startPrank(AUTH);
        balanceSheet.overridePricePoolPerShare(POOL_A, SC_1, IDENTITY_PRICE);

        vm.expectEmit();
        emit IBalanceSheet.Issue(POOL_A, SC_1, TO, IDENTITY_PRICE, AMOUNT);
        balanceSheet.issue(POOL_A, SC_1, TO, AMOUNT);
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

    function testRevokeOverridingPrice() public {
        _mockShareBurn(AMOUNT);
        _mockShareAuthTransferFrom(AUTH, address(balanceSheet), AMOUNT);

        vm.startPrank(AUTH);
        balanceSheet.overridePricePoolPerShare(POOL_A, SC_1, IDENTITY_PRICE);

        vm.expectEmit();
        emit IBalanceSheet.Revoke(POOL_A, SC_1, AUTH, IDENTITY_PRICE, AMOUNT);
        balanceSheet.revoke(POOL_A, SC_1, AMOUNT);
    }
}

contract BalanceSheetTestIssueAndRevokeCombinations is BalanceSheetTest {
    function testIssueAndThenRevokeSameAmount() public {
        _mockShareMint(AMOUNT);
        _mockShareBurn(AMOUNT);
        _mockShareAuthTransferFrom(AUTH, address(balanceSheet), AMOUNT);

        vm.startPrank(AUTH);
        balanceSheet.issue(POOL_A, SC_1, TO, AMOUNT);
        balanceSheet.revoke(POOL_A, SC_1, AMOUNT);

        (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(delta, 0);
        assertEq(isPositive, false);
    }

    function testIssueAndThenRevokeAndThenIssueSameAmount() public {
        _mockShareMint(AMOUNT);
        _mockShareBurn(AMOUNT);
        _mockShareAuthTransferFrom(AUTH, address(balanceSheet), AMOUNT);

        vm.startPrank(AUTH);
        balanceSheet.issue(POOL_A, SC_1, TO, AMOUNT);
        balanceSheet.revoke(POOL_A, SC_1, AMOUNT);
        balanceSheet.issue(POOL_A, SC_1, TO, AMOUNT);

        (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(delta, AMOUNT);
        assertEq(isPositive, true);
    }

    function testIssueAndThenRevokeWithLessAmount() public {
        _mockShareMint(AMOUNT);
        _mockShareBurn(AMOUNT / 4);
        _mockShareAuthTransferFrom(AUTH, address(balanceSheet), AMOUNT / 4);

        vm.startPrank(AUTH);
        balanceSheet.issue(POOL_A, SC_1, TO, AMOUNT);
        balanceSheet.revoke(POOL_A, SC_1, AMOUNT / 4);

        (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(delta, AMOUNT * 3 / 4);
        assertEq(isPositive, true);
    }

    function testIssueAndThenRevokeWithMoreAmount() public {
        _mockShareMint(AMOUNT);
        _mockShareBurn(2 * AMOUNT);
        _mockShareAuthTransferFrom(AUTH, address(balanceSheet), 2 * AMOUNT);

        vm.startPrank(AUTH);
        balanceSheet.issue(POOL_A, SC_1, TO, AMOUNT);
        balanceSheet.revoke(POOL_A, SC_1, 2 * AMOUNT);

        (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(delta, AMOUNT);
        assertEq(isPositive, false);
    }

    function testRevokeAndThenIssueAndThenRevokeSameAmount() public {
        _mockShareBurn(AMOUNT);
        _mockShareAuthTransferFrom(AUTH, address(balanceSheet), AMOUNT);
        _mockShareMint(AMOUNT);

        vm.startPrank(AUTH);
        balanceSheet.revoke(POOL_A, SC_1, AMOUNT);
        balanceSheet.issue(POOL_A, SC_1, TO, AMOUNT);
        balanceSheet.revoke(POOL_A, SC_1, AMOUNT);

        (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(delta, AMOUNT);
        assertEq(isPositive, false);
    }

    function testRevokeAndThenIssueSameAmount() public {
        _mockShareBurn(AMOUNT);
        _mockShareAuthTransferFrom(AUTH, address(balanceSheet), AMOUNT);
        _mockShareMint(AMOUNT);

        vm.startPrank(AUTH);
        balanceSheet.revoke(POOL_A, SC_1, AMOUNT);
        balanceSheet.issue(POOL_A, SC_1, TO, AMOUNT);

        (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(delta, 0);
        assertEq(isPositive, false);
    }

    function testRevokeAndThenIssueWithLessAmount() public {
        _mockShareBurn(AMOUNT / 4);
        _mockShareAuthTransferFrom(AUTH, address(balanceSheet), AMOUNT / 4);
        _mockShareMint(AMOUNT);

        vm.startPrank(AUTH);
        balanceSheet.revoke(POOL_A, SC_1, AMOUNT / 4);
        balanceSheet.issue(POOL_A, SC_1, TO, AMOUNT);

        (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(delta, AMOUNT * 3 / 4);
        assertEq(isPositive, true);
    }

    function testRevokeAndThenIssueWithMoreAmount() public {
        _mockShareBurn(2 * AMOUNT);
        _mockShareAuthTransferFrom(AUTH, address(balanceSheet), 2 * AMOUNT);
        _mockShareMint(AMOUNT);

        vm.startPrank(AUTH);
        balanceSheet.revoke(POOL_A, SC_1, 2 * AMOUNT);
        balanceSheet.issue(POOL_A, SC_1, TO, AMOUNT);

        (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(delta, AMOUNT);
        assertEq(isPositive, false);
    }
}

contract BalanceSheetTestSubmitQueuedAssets is BalanceSheetTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.submitQueuedAssets(POOL_A, SC_1, ASSET_20, EXTRA_GAS);
    }

    function testSubmitQueuedAssets(bool managerOrAuth) public {
        _mockSendUpdateHoldingAmount(ASSET_20, 0, ASSET_PRICE, IS_DEPOSIT, IS_SNAPSHOT, 0);

        vm.prank(managerOrAuth ? MANAGER : AUTH);
        balanceSheet.submitQueuedAssets(POOL_A, SC_1, ASSET_20, EXTRA_GAS);

        (,,, uint64 nonce) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(nonce, 1);
    }

    function testSubmitQueuedAssetsOverridingPrice() public {
        _mockSendUpdateHoldingAmount(ASSET_20, 0, IDENTITY_PRICE, IS_DEPOSIT, IS_SNAPSHOT, 0);

        vm.startPrank(AUTH);
        balanceSheet.overridePricePoolPerAsset(POOL_A, SC_1, ASSET_20, IDENTITY_PRICE);

        vm.expectEmit();
        emit IBalanceSheet.SubmitQueuedAssets(
            POOL_A, SC_1, ASSET_20, ISpokeMessageSender.UpdateData(0, IS_DEPOSIT, IS_SNAPSHOT, 0), IDENTITY_PRICE
        );
        balanceSheet.submitQueuedAssets(POOL_A, SC_1, ASSET_20, EXTRA_GAS);
    }

    function testSubmitQueuedAssetsWithMoreDepositAmount() public {
        _mockEscrowDeposit(erc20, 0, AMOUNT * 3);
        _mockEscrowWithdraw(erc20, 0, AMOUNT);
        _mockSendUpdateHoldingAmount(ASSET_20, AMOUNT * 2, ASSET_PRICE, IS_DEPOSIT, IS_SNAPSHOT, 0);

        vm.startPrank(AUTH);
        balanceSheet.noteDeposit(POOL_A, SC_1, erc20, 0, AMOUNT * 3);
        balanceSheet.withdraw(POOL_A, SC_1, erc20, 0, TO, AMOUNT);

        vm.expectEmit();
        emit IBalanceSheet.SubmitQueuedAssets(
            POOL_A, SC_1, ASSET_20, ISpokeMessageSender.UpdateData(AMOUNT * 2, IS_DEPOSIT, IS_SNAPSHOT, 0), ASSET_PRICE
        );
        balanceSheet.submitQueuedAssets(POOL_A, SC_1, ASSET_20, EXTRA_GAS);

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
        balanceSheet.withdraw(POOL_A, SC_1, erc20, 0, TO, AMOUNT * 3);
        balanceSheet.submitQueuedAssets(POOL_A, SC_1, ASSET_20, EXTRA_GAS);

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
        _mockSendUpdateHoldingAmount(ASSET_20, 0, ASSET_PRICE, IS_DEPOSIT, IS_SNAPSHOT, 0);

        vm.startPrank(AUTH);
        balanceSheet.noteDeposit(POOL_A, SC_1, erc20, 0, AMOUNT);
        balanceSheet.withdraw(POOL_A, SC_1, erc20, 0, TO, AMOUNT);
        balanceSheet.submitQueuedAssets(POOL_A, SC_1, ASSET_20, EXTRA_GAS);

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
        balanceSheet.submitQueuedAssets(POOL_A, SC_1, ASSET_20, EXTRA_GAS);

        (uint128 deposits, uint128 withdrawals) = balanceSheet.queuedAssets(POOL_A, SC_1, ASSET_20);
        assertEq(deposits, 0);
        assertEq(withdrawals, 0);

        (,, uint32 queuedAssetCounter, uint64 nonce) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 1);
        assertEq(nonce, 1);
    }

    function testSubmitQueuedAssetsTwice() public {
        vm.startPrank(AUTH);
        _mockSendUpdateHoldingAmount(ASSET_20, 0, ASSET_PRICE, IS_DEPOSIT, IS_SNAPSHOT, 0);
        balanceSheet.submitQueuedAssets(POOL_A, SC_1, ASSET_20, EXTRA_GAS);

        _mockSendUpdateHoldingAmount(ASSET_20, 0, ASSET_PRICE, IS_DEPOSIT, IS_SNAPSHOT, 1);
        balanceSheet.submitQueuedAssets(POOL_A, SC_1, ASSET_20, EXTRA_GAS);

        (,,, uint64 nonce) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(nonce, 2);
    }
}

contract BalanceSheetTestSubmitQueuedShares is BalanceSheetTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.submitQueuedShares(POOL_A, SC_1, EXTRA_GAS);
    }

    function testSubmitQueuedShares(bool managerOrAuth) public {
        _mockSendUpdateShares(0, !IS_ISSUANCE, IS_SNAPSHOT, 0);

        vm.prank(managerOrAuth ? MANAGER : AUTH);
        balanceSheet.submitQueuedShares(POOL_A, SC_1, EXTRA_GAS);

        (,,, uint64 nonce) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(nonce, 1);
    }

    function testSubmitQueuedSharesWithDeltaPositive() public {
        _mockShareMint(AMOUNT);
        _mockSendUpdateShares(AMOUNT, IS_ISSUANCE, IS_SNAPSHOT, 0);

        vm.startPrank(AUTH);
        balanceSheet.issue(POOL_A, SC_1, TO, AMOUNT);

        vm.expectEmit();
        emit IBalanceSheet.SubmitQueuedShares(
            POOL_A, SC_1, ISpokeMessageSender.UpdateData(AMOUNT, IS_ISSUANCE, IS_SNAPSHOT, 0)
        );
        balanceSheet.submitQueuedShares(POOL_A, SC_1, EXTRA_GAS);

        (uint128 delta, bool isPositive,, uint64 nonce) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(delta, 0);
        assertEq(isPositive, false);
        assertEq(nonce, 1);
    }

    function testSubmitQueuedSharesWithDeltaNegative() public {
        _mockShareBurn(AMOUNT);
        _mockShareAuthTransferFrom(AUTH, address(balanceSheet), AMOUNT);
        _mockSendUpdateShares(AMOUNT, !IS_ISSUANCE, IS_SNAPSHOT, 0);

        vm.startPrank(AUTH);
        balanceSheet.revoke(POOL_A, SC_1, AMOUNT);
        balanceSheet.submitQueuedShares(POOL_A, SC_1, EXTRA_GAS);
    }

    function testSubmitQueuedSharesAfterUpdateAssets() public {
        _mockShareMint(AMOUNT);
        _mockSendUpdateShares(AMOUNT, IS_ISSUANCE, !IS_SNAPSHOT, 0);
        _mockEscrowDeposit(erc20, 0, AMOUNT);

        vm.startPrank(AUTH);
        balanceSheet.noteDeposit(POOL_A, SC_1, erc20, 0, AMOUNT);
        balanceSheet.issue(POOL_A, SC_1, TO, AMOUNT);
        balanceSheet.submitQueuedShares(POOL_A, SC_1, EXTRA_GAS);
    }

    function testSubmitQueuedSharesTwice() public {
        _mockSendUpdateShares(0, IS_ISSUANCE, IS_SNAPSHOT, 2);

        vm.startPrank(AUTH);
        _mockSendUpdateShares(0, !IS_ISSUANCE, IS_SNAPSHOT, 0);
        balanceSheet.submitQueuedShares(POOL_A, SC_1, EXTRA_GAS);
        _mockSendUpdateShares(0, !IS_ISSUANCE, IS_SNAPSHOT, 1);
        balanceSheet.submitQueuedShares(POOL_A, SC_1, EXTRA_GAS);

        (,,, uint64 nonce) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(nonce, 2);
    }
}

contract BalanceSheetTestTransferSharesFrom is BalanceSheetTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.transferSharesFrom(POOL_A, SC_1, SENDER, FROM, TO, AMOUNT);
    }

    function testErrCannotTransferFromEndorsedContract() public {
        vm.mockCall(address(root), abi.encodeWithSelector(IRoot.endorsed.selector, FROM), abi.encode(true));

        vm.prank(AUTH);
        vm.expectRevert(IBalanceSheet.CannotTransferFromEndorsedContract.selector);
        balanceSheet.transferSharesFrom(POOL_A, SC_1, SENDER, FROM, TO, AMOUNT);
    }

    function testOverrideAsset(bool managerOrAuth) public {
        vm.mockCall(address(root), abi.encodeWithSelector(IRoot.endorsed.selector, FROM), abi.encode(false));
        vm.mockCall(
            share,
            abi.encodeWithSelector(IShareToken.authTransferFrom.selector, SENDER, FROM, TO, AMOUNT),
            abi.encode(true)
        );

        vm.prank(managerOrAuth ? MANAGER : AUTH);
        vm.expectEmit();
        emit IBalanceSheet.TransferSharesFrom(POOL_A, SC_1, SENDER, FROM, TO, AMOUNT);
        balanceSheet.transferSharesFrom(POOL_A, SC_1, SENDER, FROM, TO, AMOUNT);
    }
}

contract BalanceSheetTestOverridePricePoolPerAsset is BalanceSheetTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.overridePricePoolPerAsset(POOL_A, SC_1, ASSET_20, IDENTITY_PRICE);
    }

    function testOverrideAsset(bool managerOrAuth) public {
        vm.prank(managerOrAuth ? MANAGER : AUTH);
        balanceSheet.overridePricePoolPerAsset(POOL_A, SC_1, ASSET_20, IDENTITY_PRICE);

        assertEq(balanceSheet.pricePoolPerAsset(POOL_A, SC_1, ASSET_20).raw(), IDENTITY_PRICE.raw());
    }
}

contract BalanceSheetTestOverridePricePoolPerShare is BalanceSheetTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.overridePricePoolPerShare(POOL_A, SC_1, IDENTITY_PRICE);
    }

    function testOverrideShare(bool managerOrAuth) public {
        vm.prank(managerOrAuth ? MANAGER : AUTH);
        balanceSheet.overridePricePoolPerShare(POOL_A, SC_1, IDENTITY_PRICE);

        assertEq(balanceSheet.pricePoolPerShare(POOL_A, SC_1).raw(), IDENTITY_PRICE.raw());
    }
}

contract BalanceSheetTestResetPricePoolPerAsset is BalanceSheetTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.resetPricePoolPerAsset(POOL_A, SC_1, ASSET_20);
    }

    function testResetAsset(bool managerOrAuth) public {
        vm.startPrank(managerOrAuth ? MANAGER : AUTH);
        balanceSheet.overridePricePoolPerAsset(POOL_A, SC_1, ASSET_20, IDENTITY_PRICE);
        balanceSheet.resetPricePoolPerAsset(POOL_A, SC_1, ASSET_20);

        assertEq(balanceSheet.pricePoolPerAsset(POOL_A, SC_1, ASSET_20).raw(), ASSET_PRICE.raw());
    }
}

contract BalanceSheetTestResetPricePoolPerShare is BalanceSheetTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.resetPricePoolPerShare(POOL_A, SC_1);
    }

    function testResetShare(bool managerOrAuth) public {
        vm.startPrank(managerOrAuth ? MANAGER : AUTH);
        balanceSheet.overridePricePoolPerShare(POOL_A, SC_1, IDENTITY_PRICE);
        balanceSheet.resetPricePoolPerShare(POOL_A, SC_1);

        assertEq(balanceSheet.pricePoolPerShare(POOL_A, SC_1).raw(), SHARE_PRICE.raw());
    }
}
