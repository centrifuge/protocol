// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "../../../src/misc/types/D18.sol";
import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {MathLib} from "../../../src/misc/libraries/MathLib.sol";
import {IEscrow} from "../../../src/misc/interfaces/IEscrow.sol";
import {IERC7575} from "../../../src/misc/interfaces/IERC7575.sol";
import {IERC20Metadata} from "../../../src/misc/interfaces/IERC20.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {ISpoke} from "../../../src/core/spoke/interfaces/ISpoke.sol";
import {IVault} from "../../../src/core/spoke/interfaces/IVault.sol";
import {PricingLib} from "../../../src/core/libraries/PricingLib.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../../src/core/types/AssetId.sol";
import {IGateway} from "../../../src/core/messaging/interfaces/IGateway.sol";
import {IPoolEscrow} from "../../../src/core/spoke/interfaces/IPoolEscrow.sol";
import {IShareToken} from "../../../src/core/spoke/interfaces/IShareToken.sol";
import {IBalanceSheet} from "../../../src/core/spoke/interfaces/IBalanceSheet.sol";
import {VaultDetails, IVaultRegistry} from "../../../src/core/spoke/interfaces/IVaultRegistry.sol";

import {IBaseVault} from "../../../src/vaults/interfaces/IBaseVault.sol";
import {IAsyncVault} from "../../../src/vaults/interfaces/IAsyncVault.sol";
import {AsyncRequestManager} from "../../../src/vaults/AsyncRequestManager.sol";
import {IAsyncRequestManager} from "../../../src/vaults/interfaces/IVaultManagers.sol";
import {IBaseRequestManager} from "../../../src/vaults/interfaces/IBaseRequestManager.sol";
import {IRefundEscrowFactory, IRefundEscrow} from "../../../src/vaults/factories/RefundEscrowFactory.sol";

import "forge-std/Test.sol";

contract IsContract {}

contract AsyncRequestManagerHarness is AsyncRequestManager {
    constructor(IEscrow globalEscrow, IRefundEscrowFactory refundEscrowFactory, address deployer)
        AsyncRequestManager(globalEscrow, refundEscrowFactory, deployer)
    {}

    function calculatePriceAssetPerShare(IBaseVault vault, uint128 shares, uint128 assets)
        external
        view
        returns (D18 price)
    {
        return _calculatePriceAssetPerShare(vault, shares, assets, MathLib.Rounding.Down);
    }
}

contract AsyncRequestManagerTest is Test {
    uint16 constant LOCAL_CENTRIFUGE_ID = 1;

    address immutable AUTH = makeAddr("AUTH");
    address immutable ANY = makeAddr("ANY");
    address immutable USER = makeAddr("USER");
    address immutable RECEIVER = makeAddr("RECEIVER");
    address immutable CONTROLLER = makeAddr("CONTROLLER");

    IEscrow globalEscrow = IEscrow(makeAddr("globalEscrow"));
    ISpoke spoke = ISpoke(address(new IsContract()));
    IBalanceSheet balanceSheet = IBalanceSheet(address(new IsContract()));
    IVaultRegistry vaultRegistry = IVaultRegistry(address(new IsContract()));
    IRefundEscrowFactory refundEscrowFactory = IRefundEscrowFactory(address(new IsContract()));
    IRefundEscrow refundEscrow = IRefundEscrow(address(new IsContract()));
    IShareToken shareToken = IShareToken(address(new IsContract()));
    IPoolEscrow poolEscrow = IPoolEscrow(address(new IsContract()));
    IAsyncVault asyncVault = IAsyncVault(address(new IsContract()));
    IGateway gateway = IGateway(address(new IsContract()));

    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("sc1"));
    AssetId immutable ASSET_ID = newAssetId(LOCAL_CENTRIFUGE_ID, 1);

    address asset = address(new IsContract());
    uint256 constant TOKEN_ID = 0;
    uint128 constant ASSETS = 1000e6;
    uint128 constant SHARES = 2000e18;
    D18 immutable PRICE = d18(0.5e18); // 0.5 assets per share
    uint256 constant SUBSIDY_AMOUNT = 1 ether;

    AsyncRequestManager manager;

    function setUp() public virtual {
        vm.deal(ANY, 1 ether);
        vm.deal(AUTH, 1 ether);
        vm.deal(address(refundEscrow), 1 ether);

        manager = new AsyncRequestManager(globalEscrow, refundEscrowFactory, AUTH);

        vm.startPrank(AUTH);
        manager.file("spoke", address(spoke));
        manager.file("balanceSheet", address(balanceSheet));
        manager.file("vaultRegistry", address(vaultRegistry));
        manager.file("refundEscrowFactory", address(refundEscrowFactory));
        vm.stopPrank();

        _setupMocks();
    }

    function _setupMocks() internal {
        vm.mockCall(
            address(spoke), abi.encodeWithSelector(spoke.shareToken.selector, POOL_A, SC_1), abi.encode(shareToken)
        );
        vm.mockCall(
            address(spoke), abi.encodeWithSelector(spoke.idToAsset.selector, ASSET_ID), abi.encode(asset, TOKEN_ID)
        );
        vm.mockCall(
            address(spoke), abi.encodeWithSelector(spoke.pricesPoolPer.selector), abi.encode(d18(1e18), d18(1e18))
        );

        vm.mockCall(
            address(balanceSheet), abi.encodeWithSelector(balanceSheet.escrow.selector, POOL_A), abi.encode(poolEscrow)
        );
        vm.mockCall(address(balanceSheet), abi.encodeWithSelector(balanceSheet.gateway.selector), abi.encode(gateway));

        vm.mockCall(
            address(vaultRegistry),
            abi.encodeWithSelector(vaultRegistry.isLinked.selector, asyncVault),
            abi.encode(true)
        );
        VaultDetails memory vd = VaultDetails(ASSET_ID, asset, TOKEN_ID, true);
        vm.mockCall(
            address(vaultRegistry),
            abi.encodeWithSelector(vaultRegistry.vaultDetails.selector, asyncVault),
            abi.encode(vd)
        );
        vm.mockCall(
            address(vaultRegistry),
            abi.encodeWithSelector(vaultRegistry.vault.selector, POOL_A, SC_1, ASSET_ID, manager),
            abi.encode(asyncVault)
        );

        vm.mockCall(address(asyncVault), abi.encodeWithSelector(IVault.poolId.selector), abi.encode(POOL_A));
        vm.mockCall(address(asyncVault), abi.encodeWithSelector(IVault.scId.selector), abi.encode(SC_1));
        vm.mockCall(address(asyncVault), abi.encodeWithSelector(IERC7575.share.selector), abi.encode(shareToken));

        vm.mockCall(address(asyncVault), abi.encodeWithSelector(asyncVault.onDepositClaimable.selector), abi.encode());
        vm.mockCall(address(asyncVault), abi.encodeWithSelector(asyncVault.onRedeemClaimable.selector), abi.encode());
        vm.mockCall(
            address(asyncVault), abi.encodeWithSelector(asyncVault.onCancelDepositClaimable.selector), abi.encode()
        );
        vm.mockCall(
            address(asyncVault), abi.encodeWithSelector(asyncVault.onCancelRedeemClaimable.selector), abi.encode()
        );

        vm.mockCall(
            address(shareToken), abi.encodeWithSelector(shareToken.checkTransferRestriction.selector), abi.encode(true)
        );
        vm.mockCall(asset, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(uint8(6)));
        vm.mockCall(
            address(shareToken), abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(uint8(18))
        );

        vm.mockCall(address(globalEscrow), abi.encodeWithSelector(globalEscrow.authTransferTo.selector), abi.encode());
    }

    function testConstructor() public view {
        assertEq(address(manager.globalEscrow()), address(globalEscrow));
        assertEq(address(manager.refundEscrowFactory()), address(refundEscrowFactory));
    }
}

contract AsyncRequestManagerTestFile is AsyncRequestManagerTest {
    function testErrFileUnrecognizedParam() public {
        vm.prank(AUTH);
        vm.expectRevert(IBaseRequestManager.FileUnrecognizedParam.selector);
        manager.file("random", address(1));
    }

    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        manager.file("spoke", address(1));
    }

    function testFile() public {
        vm.startPrank(AUTH);

        vm.expectEmit();
        emit IBaseRequestManager.File("spoke", address(11));
        manager.file("spoke", address(11));
        assertEq(address(manager.spoke()), address(11));

        manager.file("vaultRegistry", address(22));
        assertEq(address(manager.vaultRegistry()), address(22));

        manager.file("balanceSheet", address(33));
        assertEq(address(manager.balanceSheet()), address(33));

        manager.file("refundEscrowFactory", address(44));
        assertEq(address(manager.refundEscrowFactory()), address(44));

        vm.stopPrank();
    }
}

contract AsyncRequestManagerTestDepositSubsidy is AsyncRequestManagerTest {
    function testDepositSubsidyNewEscrow() public {
        vm.mockCall(
            address(refundEscrowFactory),
            abi.encodeWithSelector(refundEscrowFactory.get.selector, POOL_A),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(refundEscrowFactory),
            abi.encodeWithSelector(refundEscrowFactory.newEscrow.selector, POOL_A),
            abi.encode(refundEscrow)
        );
        vm.mockCall(
            address(refundEscrow),
            SUBSIDY_AMOUNT,
            abi.encodeWithSelector(refundEscrow.depositFunds.selector),
            abi.encode()
        );

        vm.prank(ANY);
        vm.expectCall(
            address(refundEscrow), SUBSIDY_AMOUNT, abi.encodeWithSelector(IRefundEscrow.depositFunds.selector)
        );
        vm.expectEmit();
        emit IAsyncRequestManager.DepositSubsidy(POOL_A, ANY, SUBSIDY_AMOUNT);
        manager.depositSubsidy{value: SUBSIDY_AMOUNT}(POOL_A);
    }

    function testDepositSubsidyExistingEscrow() public {
        vm.mockCall(
            address(refundEscrowFactory),
            abi.encodeWithSelector(refundEscrowFactory.get.selector, POOL_A),
            abi.encode(refundEscrow)
        );
        vm.mockCall(
            address(refundEscrow),
            SUBSIDY_AMOUNT,
            abi.encodeWithSelector(refundEscrow.depositFunds.selector),
            abi.encode()
        );

        vm.prank(ANY);
        vm.expectCall(
            address(refundEscrow), SUBSIDY_AMOUNT, abi.encodeWithSelector(IRefundEscrow.depositFunds.selector)
        );
        vm.expectEmit();
        emit IAsyncRequestManager.DepositSubsidy(POOL_A, ANY, SUBSIDY_AMOUNT);
        manager.depositSubsidy{value: SUBSIDY_AMOUNT}(POOL_A);
    }
}

contract AsyncRequestManagerTestWithdrawSubsidy is AsyncRequestManagerTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        manager.withdrawSubsidy(POOL_A, RECEIVER, SUBSIDY_AMOUNT);
    }

    function testErrRefundEscrowNotDeployed() public {
        vm.mockCall(
            address(refundEscrowFactory),
            abi.encodeWithSelector(refundEscrowFactory.get.selector, POOL_A),
            abi.encode(address(0))
        );

        vm.prank(AUTH);
        vm.expectRevert(IAsyncRequestManager.RefundEscrowNotDeployed.selector);
        manager.withdrawSubsidy(POOL_A, RECEIVER, SUBSIDY_AMOUNT);
    }

    function testErrNotEnoughToWithdraw() public {
        address emptyRefund = address(new IsContract());
        vm.mockCall(
            address(refundEscrowFactory),
            abi.encodeWithSelector(refundEscrowFactory.get.selector, POOL_A),
            abi.encode(emptyRefund)
        );

        vm.prank(AUTH);
        vm.expectRevert(IAsyncRequestManager.NotEnoughToWithdraw.selector);
        manager.withdrawSubsidy(POOL_A, RECEIVER, SUBSIDY_AMOUNT);
    }

    function testWithdrawSubsidy() public {
        vm.mockCall(
            address(refundEscrowFactory),
            abi.encodeWithSelector(refundEscrowFactory.get.selector, POOL_A),
            abi.encode(refundEscrow)
        );
        vm.mockCall(
            address(refundEscrow),
            abi.encodeWithSelector(refundEscrow.withdrawFunds.selector, RECEIVER, SUBSIDY_AMOUNT),
            abi.encode()
        );

        vm.prank(AUTH);
        vm.expectEmit();
        emit IAsyncRequestManager.WithdrawSubsidy(POOL_A, RECEIVER, SUBSIDY_AMOUNT);
        manager.withdrawSubsidy(POOL_A, RECEIVER, SUBSIDY_AMOUNT);
    }
}

contract AsyncRequestManagerTestRequestDeposit is AsyncRequestManagerTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        manager.requestDeposit(asyncVault, ASSETS, CONTROLLER, address(0), address(0));
    }

    function testErrVaultNotLinked() public {
        vm.mockCall(
            address(vaultRegistry),
            abi.encodeWithSelector(vaultRegistry.isLinked.selector, asyncVault),
            abi.encode(false)
        );

        vm.prank(AUTH);
        vm.expectRevert(IAsyncRequestManager.VaultNotLinked.selector);
        manager.requestDeposit(asyncVault, ASSETS, CONTROLLER, address(0), address(0));
    }

    function testErrZeroAmountNotAllowed() public {
        vm.prank(AUTH);
        vm.expectRevert(IAsyncRequestManager.ZeroAmountNotAllowed.selector);
        manager.requestDeposit(asyncVault, 0, CONTROLLER, address(0), address(0));
    }

    function testErrTransferNotAllowed() public {
        vm.mockCall(
            address(shareToken),
            abi.encodeWithSelector(shareToken.checkTransferRestriction.selector, address(0), CONTROLLER),
            abi.encode(false)
        );

        vm.prank(AUTH);
        vm.expectRevert(IAsyncRequestManager.TransferNotAllowed.selector);
        manager.requestDeposit(asyncVault, ASSETS, CONTROLLER, address(0), address(0));
    }

    function testErrCancellationIsPending() public {
        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.isBatching.selector), abi.encode(true));
        vm.mockCall(address(spoke), abi.encodeWithSelector(spoke.request.selector), abi.encode());

        vm.prank(AUTH);
        manager.requestDeposit(asyncVault, ASSETS, CONTROLLER, address(0), address(0));

        vm.prank(AUTH);
        manager.cancelDepositRequest(asyncVault, CONTROLLER, address(0));

        vm.prank(AUTH);
        vm.expectRevert(IAsyncRequestManager.CancellationIsPending.selector);
        manager.requestDeposit(asyncVault, ASSETS, CONTROLLER, address(0), address(0));
    }

    function testRequestDeposit() public {
        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.isBatching.selector), abi.encode(true));
        vm.mockCall(address(spoke), abi.encodeWithSelector(spoke.request.selector), abi.encode());

        vm.prank(AUTH);
        manager.requestDeposit(asyncVault, ASSETS, CONTROLLER, address(0), address(0));

        assertEq(manager.pendingDepositRequest(asyncVault, CONTROLLER), ASSETS);
    }
}

contract AsyncRequestManagerTestRequestRedeem is AsyncRequestManagerTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        manager.requestRedeem(asyncVault, SHARES, CONTROLLER, USER, address(0), false);
    }

    function testErrVaultNotLinked() public {
        vm.mockCall(
            address(vaultRegistry),
            abi.encodeWithSelector(vaultRegistry.isLinked.selector, asyncVault),
            abi.encode(false)
        );

        vm.prank(AUTH);
        vm.expectRevert(IAsyncRequestManager.VaultNotLinked.selector);
        manager.requestRedeem(asyncVault, SHARES, CONTROLLER, USER, address(0), false);
    }

    function testErrZeroAmountNotAllowed() public {
        vm.prank(AUTH);
        vm.expectRevert(IAsyncRequestManager.ZeroAmountNotAllowed.selector);
        manager.requestRedeem(asyncVault, 0, CONTROLLER, USER, address(0), false);
    }

    function testErrTransferNotAllowed() public {
        vm.mockCall(
            address(shareToken), abi.encodeWithSelector(shareToken.checkTransferRestriction.selector), abi.encode(false)
        );

        vm.prank(AUTH);
        vm.expectRevert(IAsyncRequestManager.TransferNotAllowed.selector);
        manager.requestRedeem(asyncVault, SHARES, CONTROLLER, USER, address(0), false);
    }

    function testErrCancellationIsPending() public {
        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.isBatching.selector), abi.encode(true));
        vm.mockCall(address(spoke), abi.encodeWithSelector(spoke.request.selector), abi.encode());

        vm.prank(AUTH);
        manager.requestRedeem(asyncVault, SHARES, CONTROLLER, USER, address(0), false);

        vm.mockCall(address(spoke), abi.encodeWithSelector(spoke.pricesPoolPer.selector), abi.encode(d18(1), d18(1)));

        vm.prank(AUTH);
        manager.cancelRedeemRequest(asyncVault, CONTROLLER, address(0));

        vm.prank(AUTH);
        vm.expectRevert(IAsyncRequestManager.CancellationIsPending.selector);
        manager.requestRedeem(asyncVault, SHARES, CONTROLLER, USER, address(0), false);
    }

    function testRequestRedeem() public {
        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.isBatching.selector), abi.encode(true));
        vm.mockCall(address(spoke), abi.encodeWithSelector(spoke.request.selector), abi.encode());

        vm.prank(AUTH);
        manager.requestRedeem(asyncVault, SHARES, CONTROLLER, USER, address(0), false);

        assertEq(manager.pendingRedeemRequest(asyncVault, CONTROLLER), SHARES);
    }

    function testRequestRedeemWithTransfer() public {
        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.isBatching.selector), abi.encode(true));
        vm.mockCall(address(spoke), abi.encodeWithSelector(spoke.request.selector), abi.encode());
        vm.mockCall(
            address(balanceSheet),
            abi.encodeWithSelector(
                balanceSheet.transferSharesFrom.selector, POOL_A, SC_1, address(0), USER, address(globalEscrow), SHARES
            ),
            abi.encode()
        );

        vm.prank(AUTH);
        vm.expectCall(
            address(balanceSheet),
            0,
            abi.encodeWithSelector(
                balanceSheet.transferSharesFrom.selector, POOL_A, SC_1, address(0), USER, address(globalEscrow), SHARES
            )
        );
        manager.requestRedeem(asyncVault, SHARES, CONTROLLER, USER, address(0), true);

        assertEq(manager.pendingRedeemRequest(asyncVault, CONTROLLER), SHARES);
    }
}

contract AsyncRequestManagerTestCancelDepositRequest is AsyncRequestManagerTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        manager.cancelDepositRequest(asyncVault, CONTROLLER, address(0));
    }

    function testErrVaultNotLinked() public {
        vm.mockCall(
            address(vaultRegistry),
            abi.encodeWithSelector(vaultRegistry.isLinked.selector, asyncVault),
            abi.encode(false)
        );

        vm.prank(AUTH);
        vm.expectRevert(IAsyncRequestManager.VaultNotLinked.selector);
        manager.cancelDepositRequest(asyncVault, CONTROLLER, address(0));
    }

    function testErrNoPendingRequest() public {
        vm.prank(AUTH);
        vm.expectRevert(IAsyncRequestManager.NoPendingRequest.selector);
        manager.cancelDepositRequest(asyncVault, CONTROLLER, address(0));
    }

    function testErrCancellationIsPending() public {
        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.isBatching.selector), abi.encode(true));
        vm.mockCall(address(spoke), abi.encodeWithSelector(spoke.request.selector), abi.encode());

        vm.prank(AUTH);
        manager.requestDeposit(asyncVault, ASSETS, CONTROLLER, address(0), address(0));

        vm.prank(AUTH);
        manager.cancelDepositRequest(asyncVault, CONTROLLER, address(0));

        vm.prank(AUTH);
        vm.expectRevert(IAsyncRequestManager.CancellationIsPending.selector);
        manager.cancelDepositRequest(asyncVault, CONTROLLER, address(0));
    }

    function testCancelDepositRequest() public {
        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.isBatching.selector), abi.encode(true));
        vm.mockCall(address(spoke), abi.encodeWithSelector(spoke.request.selector), abi.encode());

        vm.prank(AUTH);
        manager.requestDeposit(asyncVault, ASSETS, CONTROLLER, address(0), address(0));

        vm.prank(AUTH);
        manager.cancelDepositRequest(asyncVault, CONTROLLER, address(0));

        assertTrue(manager.pendingCancelDepositRequest(asyncVault, CONTROLLER));
    }
}

contract AsyncRequestManagerTestCancelRedeemRequest is AsyncRequestManagerTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        manager.cancelRedeemRequest(asyncVault, CONTROLLER, address(0));
    }

    function testErrVaultNotLinked() public {
        vm.mockCall(
            address(vaultRegistry),
            abi.encodeWithSelector(vaultRegistry.isLinked.selector, asyncVault),
            abi.encode(false)
        );

        vm.prank(AUTH);
        vm.expectRevert(IAsyncRequestManager.VaultNotLinked.selector);
        manager.cancelRedeemRequest(asyncVault, CONTROLLER, address(0));
    }

    function testErrNoPendingRequest() public {
        vm.prank(AUTH);
        vm.expectRevert(IAsyncRequestManager.NoPendingRequest.selector);
        manager.cancelRedeemRequest(asyncVault, CONTROLLER, address(0));
    }

    function testErrTransferNotAllowed() public {
        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.isBatching.selector), abi.encode(true));
        vm.mockCall(address(spoke), abi.encodeWithSelector(spoke.request.selector), abi.encode());

        vm.prank(AUTH);
        manager.requestRedeem(asyncVault, SHARES, CONTROLLER, USER, address(0), false);

        vm.mockCall(
            address(shareToken), abi.encodeWithSelector(shareToken.checkTransferRestriction.selector), abi.encode(false)
        );

        vm.prank(AUTH);
        vm.expectRevert(IAsyncRequestManager.TransferNotAllowed.selector);
        manager.cancelRedeemRequest(asyncVault, CONTROLLER, address(0));
    }

    function testErrCancellationIsPending() public {
        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.isBatching.selector), abi.encode(true));
        vm.mockCall(address(spoke), abi.encodeWithSelector(spoke.request.selector), abi.encode());

        vm.prank(AUTH);
        manager.requestRedeem(asyncVault, SHARES, CONTROLLER, USER, address(0), false);

        vm.mockCall(address(spoke), abi.encodeWithSelector(spoke.pricesPoolPer.selector), abi.encode(d18(1), d18(1)));

        vm.prank(AUTH);
        manager.cancelRedeemRequest(asyncVault, CONTROLLER, address(0));

        vm.prank(AUTH);
        vm.expectRevert(IAsyncRequestManager.CancellationIsPending.selector);
        manager.cancelRedeemRequest(asyncVault, CONTROLLER, address(0));
    }

    function testCancelRedeemRequest() public {
        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.isBatching.selector), abi.encode(true));
        vm.mockCall(address(spoke), abi.encodeWithSelector(spoke.request.selector), abi.encode());

        vm.prank(AUTH);
        manager.requestRedeem(asyncVault, SHARES, CONTROLLER, USER, address(0), false);

        vm.mockCall(address(spoke), abi.encodeWithSelector(spoke.pricesPoolPer.selector), abi.encode(d18(1), d18(1)));

        vm.prank(AUTH);
        manager.cancelRedeemRequest(asyncVault, CONTROLLER, address(0));

        assertTrue(manager.pendingCancelRedeemRequest(asyncVault, CONTROLLER));
    }
}

contract AsyncRequestManagerTestApprovedDeposits is AsyncRequestManagerTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        manager.approvedDeposits(POOL_A, SC_1, ASSET_ID, ASSETS, PRICE);
    }

    function testApprovedDeposits() public {
        vm.mockCall(
            address(balanceSheet),
            abi.encodeWithSelector(balanceSheet.overridePricePoolPerAsset.selector, POOL_A, SC_1, ASSET_ID, PRICE),
            abi.encode()
        );
        vm.mockCall(
            address(balanceSheet),
            abi.encodeWithSelector(balanceSheet.noteDeposit.selector, POOL_A, SC_1, asset, TOKEN_ID, ASSETS),
            abi.encode()
        );
        vm.mockCall(
            address(balanceSheet),
            abi.encodeWithSelector(balanceSheet.resetPricePoolPerAsset.selector, POOL_A, SC_1, ASSET_ID),
            abi.encode()
        );

        vm.prank(AUTH);
        manager.approvedDeposits(POOL_A, SC_1, ASSET_ID, ASSETS, PRICE);
    }
}

contract AsyncRequestManagerTestIssuedShares is AsyncRequestManagerTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        manager.issuedShares(POOL_A, SC_1, SHARES, PRICE);
    }

    function testIssuedShares() public {
        vm.mockCall(
            address(balanceSheet),
            abi.encodeWithSelector(balanceSheet.overridePricePoolPerShare.selector, POOL_A, SC_1, PRICE),
            abi.encode()
        );
        vm.mockCall(
            address(balanceSheet),
            abi.encodeWithSelector(balanceSheet.issue.selector, POOL_A, SC_1, address(globalEscrow), SHARES),
            abi.encode()
        );
        vm.mockCall(
            address(balanceSheet),
            abi.encodeWithSelector(balanceSheet.resetPricePoolPerShare.selector, POOL_A, SC_1),
            abi.encode()
        );

        vm.prank(AUTH);
        manager.issuedShares(POOL_A, SC_1, SHARES, PRICE);
    }
}

contract AsyncRequestManagerTestRevokedShares is AsyncRequestManagerTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        manager.revokedShares(POOL_A, SC_1, ASSET_ID, ASSETS, SHARES, PRICE);
    }

    function testRevokedShares() public {
        vm.mockCall(
            address(balanceSheet),
            abi.encodeWithSelector(balanceSheet.reserve.selector, POOL_A, SC_1, asset, TOKEN_ID, ASSETS),
            abi.encode()
        );
        vm.mockCall(
            address(balanceSheet),
            abi.encodeWithSelector(balanceSheet.overridePricePoolPerShare.selector, POOL_A, SC_1, PRICE),
            abi.encode()
        );
        vm.mockCall(
            address(balanceSheet),
            abi.encodeWithSelector(balanceSheet.revoke.selector, POOL_A, SC_1, SHARES),
            abi.encode()
        );
        vm.mockCall(
            address(balanceSheet),
            abi.encodeWithSelector(balanceSheet.resetPricePoolPerShare.selector, POOL_A, SC_1),
            abi.encode()
        );

        vm.prank(AUTH);
        manager.revokedShares(POOL_A, SC_1, ASSET_ID, ASSETS, SHARES, PRICE);
    }
}

contract AsyncRequestManagerTestFulfillDepositRequest is AsyncRequestManagerTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        manager.fulfillDepositRequest(POOL_A, SC_1, USER, ASSET_ID, ASSETS, SHARES, 0);
    }

    function testErrNoPendingRequest() public {
        vm.prank(AUTH);
        vm.expectRevert(IAsyncRequestManager.NoPendingRequest.selector);
        manager.fulfillDepositRequest(POOL_A, SC_1, USER, ASSET_ID, ASSETS, SHARES, 0);
    }

    function testFulfillDepositRequest() public {
        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.isBatching.selector), abi.encode(true));
        vm.mockCall(address(spoke), abi.encodeWithSelector(spoke.request.selector), abi.encode());

        vm.prank(AUTH);
        manager.requestDeposit(IBaseVault(address(asyncVault)), ASSETS, USER, address(0), address(0));

        vm.prank(AUTH);
        manager.fulfillDepositRequest(POOL_A, SC_1, USER, ASSET_ID, ASSETS, SHARES, 0);

        assertEq(manager.maxMint(IBaseVault(address(asyncVault)), USER), SHARES);
        assertEq(manager.pendingDepositRequest(IBaseVault(address(asyncVault)), USER), 0);
    }

    function testFulfillDepositRequestWithCancellation() public {
        uint128 cancelledAmount = 200;
        uint128 fulfilledAmount = ASSETS - cancelledAmount;

        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.isBatching.selector), abi.encode(true));
        vm.mockCall(address(spoke), abi.encodeWithSelector(spoke.request.selector), abi.encode());

        vm.prank(AUTH);
        manager.requestDeposit(IBaseVault(address(asyncVault)), ASSETS, USER, address(0), address(0));

        vm.prank(AUTH);
        manager.cancelDepositRequest(IBaseVault(address(asyncVault)), USER, address(0));

        vm.prank(AUTH);
        manager.fulfillDepositRequest(POOL_A, SC_1, USER, ASSET_ID, fulfilledAmount, SHARES, cancelledAmount);

        assertEq(manager.claimableCancelDepositRequest(IBaseVault(address(asyncVault)), USER), cancelledAmount);
        assertFalse(manager.pendingCancelDepositRequest(IBaseVault(address(asyncVault)), USER));

        vm.prank(AUTH);
        manager.claimCancelDepositRequest(IBaseVault(address(asyncVault)), USER, USER);

        assertEq(manager.claimableCancelDepositRequest(IBaseVault(address(asyncVault)), USER), 0);
    }

    function testMultipleFulfillDepositRequests() public {
        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.isBatching.selector), abi.encode(true));
        vm.mockCall(address(spoke), abi.encodeWithSelector(spoke.request.selector), abi.encode());

        vm.prank(AUTH);
        manager.requestDeposit(IBaseVault(address(asyncVault)), ASSETS, USER, address(0), address(0));

        // Partial fulfillment of 500 assets for 500 shares at price 1
        vm.prank(AUTH);
        manager.fulfillDepositRequest(POOL_A, SC_1, USER, ASSET_ID, ASSETS / 2, 500e18, 0);

        // Second fulfillment of 500 assets for 250 shares at price 2
        vm.prank(AUTH);
        manager.fulfillDepositRequest(POOL_A, SC_1, USER, ASSET_ID, ASSETS / 2, 250e18, 0);

        (,, D18 depositPrice,,,,,,,) = manager.investments(IBaseVault(address(asyncVault)), USER);

        // Expected price: (500 + 500) / (500 + 250) = 1.333...
        uint128 totalShares = 750e18;
        D18 expectedPrice = PricingLib.calculatePriceAssetPerShare(
            address(shareToken), totalShares, asset, 0, ASSETS, MathLib.Rounding.Down
        );

        assertEq(depositPrice.raw(), expectedPrice.raw());
    }
}

contract AsyncRequestManagerTestFulfillRedeemRequest is AsyncRequestManagerTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        manager.fulfillRedeemRequest(POOL_A, SC_1, USER, ASSET_ID, ASSETS, SHARES, 0);
    }

    function testErrNoPendingRequest() public {
        vm.prank(AUTH);
        vm.expectRevert(IAsyncRequestManager.NoPendingRequest.selector);
        manager.fulfillRedeemRequest(POOL_A, SC_1, USER, ASSET_ID, ASSETS, SHARES, 0);
    }

    function testFulfillRedeemRequest() public {
        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.isBatching.selector), abi.encode(true));
        vm.mockCall(address(spoke), abi.encodeWithSelector(spoke.request.selector), abi.encode());

        vm.prank(AUTH);
        manager.requestRedeem(IBaseVault(address(asyncVault)), SHARES, USER, USER, address(0), false);

        vm.mockCall(
            address(asyncVault),
            abi.encodeWithSelector(asyncVault.onRedeemClaimable.selector, USER, ASSETS, SHARES),
            abi.encode()
        );

        vm.prank(AUTH);
        manager.fulfillRedeemRequest(POOL_A, SC_1, USER, ASSET_ID, ASSETS, SHARES, 0);

        assertEq(manager.maxWithdraw(IBaseVault(address(asyncVault)), USER), ASSETS);
        assertEq(manager.pendingRedeemRequest(IBaseVault(address(asyncVault)), USER), 0);
    }

    function testFulfillRedeemRequestWithCancellation() public {
        uint128 cancelledShares = 500;
        uint128 fulfilledShares = SHARES - cancelledShares;
        uint128 fulfilledAssets = 750;

        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.isBatching.selector), abi.encode(true));
        vm.mockCall(address(spoke), abi.encodeWithSelector(spoke.request.selector), abi.encode());

        vm.prank(AUTH);
        manager.requestRedeem(IBaseVault(address(asyncVault)), SHARES, USER, USER, address(0), false);

        vm.mockCall(address(spoke), abi.encodeWithSelector(spoke.pricesPoolPer.selector), abi.encode(d18(1), d18(1)));

        vm.prank(AUTH);
        manager.cancelRedeemRequest(IBaseVault(address(asyncVault)), USER, address(0));

        vm.mockCall(
            address(asyncVault),
            abi.encodeWithSelector(asyncVault.onRedeemClaimable.selector, USER, fulfilledAssets, fulfilledShares),
            abi.encode()
        );
        vm.mockCall(
            address(asyncVault),
            abi.encodeWithSelector(asyncVault.onCancelRedeemClaimable.selector, USER, cancelledShares),
            abi.encode()
        );

        vm.prank(AUTH);
        manager.fulfillRedeemRequest(POOL_A, SC_1, USER, ASSET_ID, fulfilledAssets, fulfilledShares, cancelledShares);

        assertEq(manager.claimableCancelRedeemRequest(IBaseVault(address(asyncVault)), USER), cancelledShares);
        assertFalse(manager.pendingCancelRedeemRequest(IBaseVault(address(asyncVault)), USER));
    }
}

contract AsyncRequestManagerTestPriceCalculations is AsyncRequestManagerTest {
    function testCalculatePriceAssetPerShare() public {
        AsyncRequestManagerHarness harness = new AsyncRequestManagerHarness(globalEscrow, refundEscrowFactory, AUTH);

        vm.prank(AUTH);
        harness.file("vaultRegistry", address(vaultRegistry));

        // Zero shares
        assert(harness.calculatePriceAssetPerShare(asyncVault, 0, 1).isZero());

        // Zero assets
        assert(harness.calculatePriceAssetPerShare(asyncVault, 1, 0).isZero());

        // Non-zero assets and shares
        assertGt(harness.calculatePriceAssetPerShare(asyncVault, 100, 50).raw(), 0);
    }
}
