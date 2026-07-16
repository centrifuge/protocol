// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../../src/misc/interfaces/IAuth.sol";
import {IERC20} from "../../../../src/misc/interfaces/IERC20.sol";
import {IEscrow} from "../../../../src/misc/interfaces/IEscrow.sol";
import {IERC6909} from "../../../../src/misc/interfaces/IERC6909.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../../src/core/types/AssetId.sol";
import {BalanceSheet} from "../../../../src/core/spoke/BalanceSheet.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {IGateway} from "../../../../src/core/messaging/interfaces/IGateway.sol";
import {IRegistrar} from "../../../../src/core/spoke/interfaces/IRegistrar.sol";
import {IPoolEscrow} from "../../../../src/core/spoke/interfaces/IPoolEscrow.sol";
import {IBalanceSheet} from "../../../../src/core/spoke/interfaces/IBalanceSheet.sol";
import {IEndorsements} from "../../../../src/core/spoke/interfaces/IEndorsements.sol";
import {ISpokeRegistry} from "../../../../src/core/spoke/interfaces/ISpokeRegistry.sol";
import {ISpokeMessageSender} from "../../../../src/core/messaging/interfaces/IGatewaySenders.sol";
import {IPoolEscrowProvider} from "../../../../src/core/spoke/factories/interfaces/IPoolEscrowFactory.sol";

import "forge-std/Test.sol";

// Need it to overpass a mockCall issue: https://github.com/foundry-rs/foundry/issues/10703
contract IsContract {}

contract BalanceSheetTest is Test {
    // Disambiguates the price-less sendUpdateHoldingAmount overload from the ABI-compat one with D18 price.
    bytes4 constant SEND_UPDATE_HOLDING_AMOUNT_SELECTOR =
        bytes4(keccak256("sendUpdateHoldingAmount(uint64,bytes16,uint128,(uint128,bool,bool,uint64),uint128,address)"));

    IEndorsements endorsements = IEndorsements(makeAddr("Endorsements"));
    ISpokeRegistry spoke = ISpokeRegistry(makeAddr("SpokeRegistry"));
    IGateway gateway = IGateway(makeAddr("Gateway"));
    ISpokeMessageSender sender = ISpokeMessageSender(address(new IsContract()));
    address erc6909 = address(new IsContract());
    address erc20 = address(new IsContract());
    address share = address(new IsContract());
    address registrar = address(new IsContract());
    address escrow = address(new IsContract());
    IPoolEscrowProvider escrowProvider = IPoolEscrowProvider(makeAddr("EscrowProvider"));

    address immutable AUTH = makeAddr("AUTH");
    address immutable ANY = makeAddr("ANY");
    address immutable SENDER = makeAddr("SENDER");
    address immutable FROM = makeAddr("FROM");
    address immutable TO = makeAddr("TO");
    address immutable MANAGER = makeAddr("MANAGER");
    address immutable REFUND = makeAddr("REFUND");
    address immutable RESERVER = makeAddr("RESERVER");

    uint128 constant AMOUNT = 100;
    uint256 constant COST = 123;
    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("scId"));
    AssetId constant ASSET_20 = AssetId.wrap(3);
    AssetId constant ASSET_6909_1 = AssetId.wrap(4);
    uint256 constant TOKEN_ID = 1;
    bool constant IS_ISSUANCE = true;
    bool constant IS_DEPOSIT = true;
    bool constant IS_SNAPSHOT = true;
    uint128 constant EXTRA_GAS = 0;
    uint32 constant RESERVE_REASON = 1;

    BalanceSheet balanceSheet = new BalanceSheet(endorsements, AUTH);

    function setUp() public virtual {
        vm.mockCall(
            address(spoke), abi.encodeWithSelector(ISpokeRegistry.assetToId.selector, erc20, 0), abi.encode(ASSET_20)
        );
        vm.mockCall(
            address(spoke),
            abi.encodeWithSelector(ISpokeRegistry.assetToId.selector, erc6909, TOKEN_ID),
            abi.encode(ASSET_6909_1)
        );
        vm.mockCall(
            address(spoke),
            abi.encodeWithSelector(ISpokeRegistry.shareTokenAndRegistrar.selector, POOL_A, SC_1),
            abi.encode(share, registrar)
        );
        vm.mockCall(
            address(spoke), abi.encodeWithSelector(ISpokeRegistry.shareToken.selector, POOL_A, SC_1), abi.encode(share)
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

        vm.deal(ANY, 1 ether);
        vm.deal(MANAGER, 1 ether);
        vm.deal(AUTH, 1 ether);
    }

    function _mockEscrowDeposit(address asset, uint256 tokenId, uint128 amount) internal {
        vm.mockCall(
            escrow, abi.encodeWithSelector(IPoolEscrow.deposit.selector, SC_1, asset, tokenId, amount), abi.encode()
        );
    }

    function _mockEscrowWithdraw(address asset, uint256 tokenId, uint128 amount) internal {
        vm.mockCall(
            escrow,
            abi.encodeWithSelector(IPoolEscrow.withdraw.selector, SC_1, asset, tokenId, TO, amount),
            abi.encode()
        );
        vm.mockCall(
            escrow, abi.encodeWithSelector(IEscrow.authTransferTo.selector, asset, tokenId, TO, amount), abi.encode()
        );
    }

    function _mockEscrowWithdrawReserved(
        address asset,
        uint256 tokenId,
        uint128 amount,
        address reserver,
        uint32 reason
    ) internal {
        // BalanceSheet.withdrawReserved is implemented on the deployed escrow API: unreserve then withdraw.
        vm.mockCall(
            escrow,
            abi.encodeWithSelector(IPoolEscrow.unreserve.selector, SC_1, asset, tokenId, amount, reserver, reason),
            abi.encode()
        );
        vm.mockCall(
            escrow,
            abi.encodeWithSelector(IPoolEscrow.withdraw.selector, SC_1, asset, tokenId, TO, amount),
            abi.encode()
        );
        vm.mockCall(
            escrow, abi.encodeWithSelector(IEscrow.authTransferTo.selector, asset, tokenId, TO, amount), abi.encode()
        );
    }

    function _mockEscrowReserve(address asset, uint256 tokenId, uint128 amount, address reserver, uint32 reason)
        internal
    {
        vm.mockCall(
            escrow,
            abi.encodeWithSelector(IPoolEscrow.reserve.selector, SC_1, asset, tokenId, amount, reserver, reason),
            abi.encode()
        );
    }

    function _mockEscrowUnreserve(address asset, uint256 tokenId, uint128 amount, address reserver, uint32 reason)
        internal
    {
        vm.mockCall(
            escrow,
            abi.encodeWithSelector(IPoolEscrow.unreserve.selector, SC_1, asset, tokenId, amount, reserver, reason),
            abi.encode()
        );
    }

    function _mockShareMint(uint128 amount) internal {
        vm.mockCall(registrar, abi.encodeWithSelector(IRegistrar.mint.selector, share, TO, amount), abi.encode());
    }

    function _mockShareBurn(address from, uint128 amount) internal {
        vm.mockCall(
            share,
            abi.encodeWithSelector(IERC20.transferFrom.selector, from, address(balanceSheet), amount),
            abi.encode(true)
        );
        vm.mockCall(share, abi.encodeWithSelector(IERC20.approve.selector, registrar, amount), abi.encode(true));
        vm.mockCall(
            registrar,
            abi.encodeWithSelector(IRegistrar.burn.selector, share, address(balanceSheet), amount),
            abi.encode()
        );
    }

    function _mockSendUpdateHoldingAmount(
        AssetId assetId,
        uint128 amount,
        bool isDeposit,
        bool isSnapshot,
        uint64 nonce
    ) internal {
        vm.mockCall(
            address(sender),
            COST,
            abi.encodeWithSelector(
                SEND_UPDATE_HOLDING_AMOUNT_SELECTOR,
                POOL_A,
                SC_1,
                assetId,
                ISpokeMessageSender.UpdateData({
                    netAmount: amount, isIncrease: isDeposit, isSnapshot: isSnapshot, nonce: nonce
                }),
                EXTRA_GAS,
                REFUND
            ),
            abi.encode()
        );
    }

    function _mockSendUpdateShares(uint128 delta, bool isPositive, bool isSnapshot, uint64 nonce) internal {
        vm.mockCall(
            address(sender),
            COST,
            abi.encodeWithSelector(
                ISpokeMessageSender.sendUpdateShares.selector,
                POOL_A,
                SC_1,
                ISpokeMessageSender.UpdateData({
                    netAmount: delta, isIncrease: isPositive, isSnapshot: isSnapshot, nonce: nonce
                }),
                EXTRA_GAS,
                REFUND
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

contract BalanceSheetTestDeposit is BalanceSheetTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.deposit(POOL_A, SC_1, erc20, 0, AMOUNT);
    }

    function testDepositERC20() public {
        _mockEscrowDeposit(erc20, 0, AMOUNT);
        vm.mockCall(
            erc20, abi.encodeWithSelector(IERC20.transferFrom.selector, MANAGER, escrow, AMOUNT), abi.encode(true)
        );

        vm.expectCall(erc20, abi.encodeWithSelector(IERC20.transferFrom.selector, MANAGER, escrow, AMOUNT));
        vm.prank(MANAGER);
        vm.expectEmit();
        emit IBalanceSheet.Deposit(POOL_A, SC_1, MANAGER, erc20, 0, AMOUNT);
        balanceSheet.deposit(POOL_A, SC_1, erc20, 0, AMOUNT);

        (,, uint32 queuedAssetCounter,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 1);

        (uint128 deposits,) = balanceSheet.queuedAssets(POOL_A, SC_1, ASSET_20);
        assertEq(deposits, AMOUNT);
    }

    function testDepositERC6909() public {
        _mockEscrowDeposit(erc6909, TOKEN_ID, AMOUNT);
        vm.mockCall(
            address(erc6909),
            abi.encodeWithSelector(IERC6909.transferFrom.selector, MANAGER, escrow, TOKEN_ID, AMOUNT),
            abi.encode(true)
        );

        vm.expectCall(
            erc6909, abi.encodeWithSelector(IERC6909.transferFrom.selector, MANAGER, escrow, TOKEN_ID, AMOUNT)
        );
        vm.prank(MANAGER);
        balanceSheet.deposit(POOL_A, SC_1, address(erc6909), TOKEN_ID, AMOUNT);
    }
}

contract BalanceSheetTestNoteDeposit is BalanceSheetTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.noteDeposit(POOL_A, SC_1, erc20, 0, AMOUNT);
    }

    function testNoteDepositDoesNotPullTokens() public {
        _mockEscrowDeposit(erc20, 0, AMOUNT);
        // No transferFrom mock: any call to it would revert since it is not mocked, so success proves no pull.

        vm.prank(MANAGER);
        vm.expectEmit();
        emit IBalanceSheet.NoteDeposit(POOL_A, SC_1, MANAGER, erc20, 0, AMOUNT);
        balanceSheet.noteDeposit(POOL_A, SC_1, erc20, 0, AMOUNT);

        (,, uint32 queuedAssetCounter,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 1);

        (uint128 deposits,) = balanceSheet.queuedAssets(POOL_A, SC_1, ASSET_20);
        assertEq(deposits, AMOUNT);
    }

    function testNoteDepositZero() public {
        _mockEscrowDeposit(erc20, 0, 0);

        vm.startPrank(MANAGER);
        balanceSheet.noteDeposit(POOL_A, SC_1, erc20, 0, 0);

        (,, uint32 queuedAssetCounter,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 0);
    }

    function testNoteDepositTwice() public {
        _mockEscrowDeposit(erc20, 0, AMOUNT);

        vm.startPrank(MANAGER);
        balanceSheet.noteDeposit(POOL_A, SC_1, erc20, 0, AMOUNT);
        balanceSheet.noteDeposit(POOL_A, SC_1, erc20, 0, AMOUNT);

        (,, uint32 queuedAssetCounter,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 1);

        (uint128 deposits,) = balanceSheet.queuedAssets(POOL_A, SC_1, ASSET_20);
        assertEq(deposits, AMOUNT * 2);
    }
}

contract BalanceSheetTestWithdraw is BalanceSheetTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.withdraw(POOL_A, SC_1, erc20, 0, TO, AMOUNT);
    }

    function testWithdraw() public {
        _mockEscrowWithdraw(erc20, 0, AMOUNT);

        vm.prank(MANAGER);
        vm.expectEmit();
        emit IBalanceSheet.Withdraw(POOL_A, SC_1, erc20, 0, TO, AMOUNT);
        balanceSheet.withdraw(POOL_A, SC_1, erc20, 0, TO, AMOUNT);

        (,, uint32 queuedAssetCounter,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 1);

        (, uint128 withdrawals) = balanceSheet.queuedAssets(POOL_A, SC_1, ASSET_20);
        assertEq(withdrawals, AMOUNT);
    }

    function testWithdrawZero() public {
        _mockEscrowWithdraw(erc20, 0, 0);

        vm.startPrank(MANAGER);
        balanceSheet.withdraw(POOL_A, SC_1, erc20, 0, TO, 0);

        (,, uint32 queuedAssetCounter,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 0);
    }

    function testWithdrawTwice() public {
        _mockEscrowWithdraw(erc20, 0, AMOUNT);

        vm.startPrank(MANAGER);
        balanceSheet.withdraw(POOL_A, SC_1, erc20, 0, TO, AMOUNT);
        balanceSheet.withdraw(POOL_A, SC_1, erc20, 0, TO, AMOUNT);

        (,, uint32 queuedAssetCounter,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 1);

        (, uint128 withdrawals) = balanceSheet.queuedAssets(POOL_A, SC_1, ASSET_20);
        assertEq(withdrawals, AMOUNT * 2);
    }

    function testWithdrawGatedByEscrow() public {
        // The escrow itself enforces total - reserved >= amount; here we simulate that gating reverting.
        vm.mockCallRevert(
            escrow,
            abi.encodeWithSelector(IPoolEscrow.withdraw.selector, SC_1, erc20, 0, TO, AMOUNT),
            abi.encodeWithSelector(IEscrow.InsufficientBalance.selector, erc20, 0, AMOUNT, 0)
        );

        vm.prank(MANAGER);
        vm.expectRevert(abi.encodeWithSelector(IEscrow.InsufficientBalance.selector, erc20, 0, AMOUNT, 0));
        balanceSheet.withdraw(POOL_A, SC_1, erc20, 0, TO, AMOUNT);
    }
}

contract BalanceSheetTestWithdrawReserved is BalanceSheetTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.withdrawReserved(POOL_A, SC_1, erc20, 0, TO, AMOUNT, RESERVER, RESERVE_REASON);
    }

    function testWithdrawReserved() public {
        _mockEscrowWithdrawReserved(erc20, 0, AMOUNT, RESERVER, RESERVE_REASON);

        vm.prank(MANAGER);
        vm.expectEmit();
        emit IBalanceSheet.Withdraw(POOL_A, SC_1, erc20, 0, TO, AMOUNT);
        balanceSheet.withdrawReserved(POOL_A, SC_1, erc20, 0, TO, AMOUNT, RESERVER, RESERVE_REASON);

        // No queueing: the holding decrease was already queued when the funds were reserved.
        (,, uint32 queuedAssetCounter,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 0);
        (uint128 deposits, uint128 withdrawals) = balanceSheet.queuedAssets(POOL_A, SC_1, ASSET_20);
        assertEq(deposits, 0);
        assertEq(withdrawals, 0);
    }

    function testErrNoMatchingReservation() public {
        // The unreserve step enforces the reservation bucket has enough funds.
        vm.mockCallRevert(
            escrow,
            abi.encodeWithSelector(IPoolEscrow.unreserve.selector, SC_1, erc20, 0, AMOUNT, RESERVER, RESERVE_REASON),
            abi.encodeWithSelector(IPoolEscrow.InsufficientReserve.selector)
        );

        vm.prank(MANAGER);
        vm.expectRevert(IPoolEscrow.InsufficientReserve.selector);
        balanceSheet.withdrawReserved(POOL_A, SC_1, erc20, 0, TO, AMOUNT, RESERVER, RESERVE_REASON);
    }
}

contract BalanceSheetTestReserve is BalanceSheetTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.reserve(POOL_A, SC_1, erc20, 0, AMOUNT, MANAGER, RESERVE_REASON);
    }

    function testReserveQueuesWithdrawal() public {
        _mockEscrowReserve(erc20, 0, AMOUNT, MANAGER, RESERVE_REASON);

        vm.prank(MANAGER);
        balanceSheet.reserve(POOL_A, SC_1, erc20, 0, AMOUNT, MANAGER, RESERVE_REASON);

        (,, uint32 queuedAssetCounter,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 1);

        (uint128 deposits, uint128 withdrawals) = balanceSheet.queuedAssets(POOL_A, SC_1, ASSET_20);
        assertEq(deposits, 0);
        assertEq(withdrawals, AMOUNT);
    }
}

contract BalanceSheetTestUnreserve is BalanceSheetTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.unreserve(POOL_A, SC_1, erc20, 0, AMOUNT, MANAGER, RESERVE_REASON);
    }

    function testUnreserveQueuesDeposit() public {
        _mockEscrowUnreserve(erc20, 0, AMOUNT, MANAGER, RESERVE_REASON);

        vm.prank(MANAGER);
        balanceSheet.unreserve(POOL_A, SC_1, erc20, 0, AMOUNT, MANAGER, RESERVE_REASON);

        (,, uint32 queuedAssetCounter,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 1);

        (uint128 deposits, uint128 withdrawals) = balanceSheet.queuedAssets(POOL_A, SC_1, ASSET_20);
        assertEq(deposits, AMOUNT);
        assertEq(withdrawals, 0);
    }

    function testReserveThenUnreserveIsNetZero() public {
        _mockEscrowReserve(erc20, 0, AMOUNT, MANAGER, RESERVE_REASON);
        _mockEscrowUnreserve(erc20, 0, AMOUNT, MANAGER, RESERVE_REASON);

        vm.startPrank(MANAGER);
        balanceSheet.reserve(POOL_A, SC_1, erc20, 0, AMOUNT, MANAGER, RESERVE_REASON);
        balanceSheet.unreserve(POOL_A, SC_1, erc20, 0, AMOUNT, MANAGER, RESERVE_REASON);

        (uint128 deposits, uint128 withdrawals) = balanceSheet.queuedAssets(POOL_A, SC_1, ASSET_20);
        assertEq(deposits, AMOUNT);
        assertEq(withdrawals, AMOUNT);
        assertEq(deposits, withdrawals);
    }
}

contract BalanceSheetTestCrossManagerReserveRecovery is BalanceSheetTest {
    address constant OTHER_MANAGER = address(0x999);

    function setUp() public override {
        super.setUp();
        vm.prank(AUTH);
        balanceSheet.updateManager(POOL_A, OTHER_MANAGER, true);
    }

    /// @notice One manager can unreserve another manager's funds (recovery scenario)
    function testCrossManagerUnreserve() public {
        _mockEscrowReserve(erc20, 0, AMOUNT, MANAGER, RESERVE_REASON);
        vm.prank(MANAGER);
        balanceSheet.reserve(POOL_A, SC_1, erc20, 0, AMOUNT, MANAGER, RESERVE_REASON);

        _mockEscrowUnreserve(erc20, 0, AMOUNT, MANAGER, RESERVE_REASON);
        vm.prank(OTHER_MANAGER);
        balanceSheet.unreserve(POOL_A, SC_1, erc20, 0, AMOUNT, MANAGER, RESERVE_REASON);
    }

    /// @notice A manager can reserve on behalf of a different address
    function testReserveWithDifferentReserver() public {
        _mockEscrowReserve(erc20, 0, AMOUNT, OTHER_MANAGER, RESERVE_REASON);
        vm.prank(MANAGER);
        balanceSheet.reserve(POOL_A, SC_1, erc20, 0, AMOUNT, OTHER_MANAGER, RESERVE_REASON);
    }
}

contract BalanceSheetTestWithdrawShares is BalanceSheetTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.withdrawShares(POOL_A, SC_1, TO, AMOUNT);
    }

    function testWithdrawShares() public {
        vm.mockCall(escrow, abi.encodeWithSelector(IEscrow.authTransferTo.selector, share, 0, TO, AMOUNT), abi.encode());

        vm.expectCall(escrow, abi.encodeWithSelector(IEscrow.authTransferTo.selector, share, 0, TO, AMOUNT));
        vm.prank(MANAGER);
        vm.expectEmit();
        emit IBalanceSheet.WithdrawShares(POOL_A, SC_1, TO, AMOUNT);
        balanceSheet.withdrawShares(POOL_A, SC_1, TO, AMOUNT);

        // No holding/queue accounting for share withdrawals.
        (uint128 delta, bool isPositive, uint32 queuedAssetCounter,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(delta, 0);
        assertEq(isPositive, false);
        assertEq(queuedAssetCounter, 0);
    }
}

contract BalanceSheetTestIssue is BalanceSheetTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.issue(POOL_A, SC_1, TO, AMOUNT);
    }

    function testIssue() public {
        _mockShareMint(AMOUNT);

        vm.prank(MANAGER);
        vm.expectEmit();
        emit IBalanceSheet.Issue(POOL_A, SC_1, MANAGER, TO, AMOUNT);
        balanceSheet.issue(POOL_A, SC_1, TO, AMOUNT);

        (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(delta, AMOUNT);
        assertEq(isPositive, true);
    }

    function testIssueTwice() public {
        _mockShareMint(AMOUNT);

        vm.startPrank(MANAGER);
        balanceSheet.issue(POOL_A, SC_1, TO, AMOUNT);
        balanceSheet.issue(POOL_A, SC_1, TO, AMOUNT);

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

    function testRevoke() public {
        _mockShareBurn(MANAGER, AMOUNT);

        vm.prank(MANAGER);
        vm.expectEmit();
        emit IBalanceSheet.Revoke(POOL_A, SC_1, MANAGER, MANAGER, AMOUNT);
        balanceSheet.revoke(POOL_A, SC_1, AMOUNT);

        (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(delta, AMOUNT);
        assertEq(isPositive, false);
    }

    function testRevokeTwice() public {
        _mockShareBurn(MANAGER, AMOUNT);

        vm.startPrank(MANAGER);
        balanceSheet.revoke(POOL_A, SC_1, AMOUNT);
        balanceSheet.revoke(POOL_A, SC_1, AMOUNT);

        (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(delta, AMOUNT * 2);
        assertEq(isPositive, false);
    }
}

contract BalanceSheetTestIssueAndRevokeCombinations is BalanceSheetTest {
    function testIssueAndThenRevokeSameAmount() public {
        _mockShareMint(AMOUNT);
        _mockShareBurn(MANAGER, AMOUNT);

        vm.startPrank(MANAGER);
        balanceSheet.issue(POOL_A, SC_1, TO, AMOUNT);
        balanceSheet.revoke(POOL_A, SC_1, AMOUNT);

        (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(delta, 0);
        assertEq(isPositive, false);
    }

    function testIssueAndThenRevokeAndThenIssueSameAmount() public {
        _mockShareMint(AMOUNT);
        _mockShareBurn(MANAGER, AMOUNT);

        vm.startPrank(MANAGER);
        balanceSheet.issue(POOL_A, SC_1, TO, AMOUNT);
        balanceSheet.revoke(POOL_A, SC_1, AMOUNT);
        balanceSheet.issue(POOL_A, SC_1, TO, AMOUNT);

        (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(delta, AMOUNT);
        assertEq(isPositive, true);
    }

    function testIssueAndThenRevokeWithLessAmount() public {
        _mockShareMint(AMOUNT);
        _mockShareBurn(MANAGER, AMOUNT / 4);

        vm.startPrank(MANAGER);
        balanceSheet.issue(POOL_A, SC_1, TO, AMOUNT);
        balanceSheet.revoke(POOL_A, SC_1, AMOUNT / 4);

        (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(delta, AMOUNT * 3 / 4);
        assertEq(isPositive, true);
    }

    function testIssueAndThenRevokeWithMoreAmount() public {
        _mockShareMint(AMOUNT);
        _mockShareBurn(MANAGER, 2 * AMOUNT);

        vm.startPrank(MANAGER);
        balanceSheet.issue(POOL_A, SC_1, TO, AMOUNT);
        balanceSheet.revoke(POOL_A, SC_1, 2 * AMOUNT);

        (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(delta, AMOUNT);
        assertEq(isPositive, false);
    }

    function testRevokeAndThenIssueAndThenRevokeSameAmount() public {
        _mockShareBurn(MANAGER, AMOUNT);
        _mockShareMint(AMOUNT);

        vm.startPrank(MANAGER);
        balanceSheet.revoke(POOL_A, SC_1, AMOUNT);
        balanceSheet.issue(POOL_A, SC_1, TO, AMOUNT);
        balanceSheet.revoke(POOL_A, SC_1, AMOUNT);

        (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(delta, AMOUNT);
        assertEq(isPositive, false);
    }

    function testRevokeAndThenIssueSameAmount() public {
        _mockShareBurn(MANAGER, AMOUNT);
        _mockShareMint(AMOUNT);

        vm.startPrank(MANAGER);
        balanceSheet.revoke(POOL_A, SC_1, AMOUNT);
        balanceSheet.issue(POOL_A, SC_1, TO, AMOUNT);

        (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(delta, 0);
        assertEq(isPositive, false);
    }

    function testRevokeAndThenIssueWithLessAmount() public {
        _mockShareBurn(MANAGER, AMOUNT / 4);
        _mockShareMint(AMOUNT);

        vm.startPrank(MANAGER);
        balanceSheet.revoke(POOL_A, SC_1, AMOUNT / 4);
        balanceSheet.issue(POOL_A, SC_1, TO, AMOUNT);

        (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(delta, AMOUNT * 3 / 4);
        assertEq(isPositive, true);
    }

    function testRevokeAndThenIssueWithMoreAmount() public {
        _mockShareBurn(MANAGER, 2 * AMOUNT);
        _mockShareMint(AMOUNT);

        vm.startPrank(MANAGER);
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
        balanceSheet.submitQueuedAssets{value: COST}(POOL_A, SC_1, ASSET_20, EXTRA_GAS, REFUND);
    }

    function testSubmitQueuedAssets() public {
        _mockSendUpdateHoldingAmount(ASSET_20, 0, !IS_DEPOSIT, IS_SNAPSHOT, 0);

        vm.prank(MANAGER);
        balanceSheet.submitQueuedAssets{value: COST}(POOL_A, SC_1, ASSET_20, EXTRA_GAS, REFUND);

        (,,, uint64 nonce) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(nonce, 1);
    }

    function testSubmitQueuedAssetsWithMoreDepositAmount() public {
        _mockEscrowDeposit(erc20, 0, AMOUNT * 3);
        _mockEscrowWithdraw(erc20, 0, AMOUNT);
        _mockSendUpdateHoldingAmount(ASSET_20, AMOUNT * 2, IS_DEPOSIT, IS_SNAPSHOT, 0);

        vm.startPrank(MANAGER);
        balanceSheet.noteDeposit(POOL_A, SC_1, erc20, 0, AMOUNT * 3);
        balanceSheet.withdraw(POOL_A, SC_1, erc20, 0, TO, AMOUNT);

        vm.expectEmit();
        emit IBalanceSheet.SubmitQueuedAssets(
            POOL_A, SC_1, ASSET_20, ISpokeMessageSender.UpdateData(AMOUNT * 2, IS_DEPOSIT, IS_SNAPSHOT, 0)
        );
        balanceSheet.submitQueuedAssets{value: COST}(POOL_A, SC_1, ASSET_20, EXTRA_GAS, REFUND);

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
        _mockSendUpdateHoldingAmount(ASSET_20, AMOUNT * 2, !IS_DEPOSIT, IS_SNAPSHOT, 0);

        vm.startPrank(MANAGER);
        balanceSheet.noteDeposit(POOL_A, SC_1, erc20, 0, AMOUNT);
        balanceSheet.withdraw(POOL_A, SC_1, erc20, 0, TO, AMOUNT * 3);
        balanceSheet.submitQueuedAssets{value: COST}(POOL_A, SC_1, ASSET_20, EXTRA_GAS, REFUND);

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
        _mockSendUpdateHoldingAmount(ASSET_20, 0, !IS_DEPOSIT, IS_SNAPSHOT, 0);

        vm.startPrank(MANAGER);
        balanceSheet.noteDeposit(POOL_A, SC_1, erc20, 0, AMOUNT);
        balanceSheet.withdraw(POOL_A, SC_1, erc20, 0, TO, AMOUNT);
        balanceSheet.submitQueuedAssets{value: COST}(POOL_A, SC_1, ASSET_20, EXTRA_GAS, REFUND);

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
        _mockSendUpdateHoldingAmount(ASSET_20, AMOUNT, IS_DEPOSIT, !IS_SNAPSHOT, 0);

        vm.startPrank(MANAGER);
        balanceSheet.noteDeposit(POOL_A, SC_1, erc20, 0, AMOUNT);
        balanceSheet.noteDeposit(POOL_A, SC_1, erc6909, TOKEN_ID, AMOUNT);
        balanceSheet.submitQueuedAssets{value: COST}(POOL_A, SC_1, ASSET_20, EXTRA_GAS, REFUND);

        (uint128 deposits, uint128 withdrawals) = balanceSheet.queuedAssets(POOL_A, SC_1, ASSET_20);
        assertEq(deposits, 0);
        assertEq(withdrawals, 0);

        (,, uint32 queuedAssetCounter, uint64 nonce) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 1);
        assertEq(nonce, 1);
    }

    function testSubmitQueuedAssetsTwice() public {
        vm.startPrank(MANAGER);
        _mockSendUpdateHoldingAmount(ASSET_20, 0, !IS_DEPOSIT, IS_SNAPSHOT, 0);
        balanceSheet.submitQueuedAssets{value: COST}(POOL_A, SC_1, ASSET_20, EXTRA_GAS, REFUND);

        _mockSendUpdateHoldingAmount(ASSET_20, 0, !IS_DEPOSIT, IS_SNAPSHOT, 1);
        balanceSheet.submitQueuedAssets{value: COST}(POOL_A, SC_1, ASSET_20, EXTRA_GAS, REFUND);

        (,,, uint64 nonce) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(nonce, 2);
    }
}

contract BalanceSheetTestSubmitQueuedShares is BalanceSheetTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        balanceSheet.submitQueuedShares{value: COST}(POOL_A, SC_1, EXTRA_GAS, REFUND);
    }

    function testSubmitQueuedShares() public {
        _mockSendUpdateShares(0, !IS_ISSUANCE, IS_SNAPSHOT, 0);

        vm.prank(MANAGER);
        balanceSheet.submitQueuedShares{value: COST}(POOL_A, SC_1, EXTRA_GAS, REFUND);

        (,,, uint64 nonce) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(nonce, 1);
    }

    function testSubmitQueuedSharesWithDeltaPositive() public {
        _mockShareMint(AMOUNT);
        _mockSendUpdateShares(AMOUNT, IS_ISSUANCE, IS_SNAPSHOT, 0);

        vm.startPrank(MANAGER);
        balanceSheet.issue(POOL_A, SC_1, TO, AMOUNT);

        vm.expectEmit();
        emit IBalanceSheet.SubmitQueuedShares(
            POOL_A, SC_1, ISpokeMessageSender.UpdateData(AMOUNT, IS_ISSUANCE, IS_SNAPSHOT, 0)
        );
        balanceSheet.submitQueuedShares{value: COST}(POOL_A, SC_1, EXTRA_GAS, REFUND);

        (uint128 delta, bool isPositive,, uint64 nonce) = balanceSheet.queuedShares(POOL_A, SC_1);
        assertEq(delta, 0);
        assertEq(isPositive, false);
        assertEq(nonce, 1);
    }

    function testSubmitQueuedSharesWithDeltaNegative() public {
        _mockShareBurn(MANAGER, AMOUNT);
        _mockSendUpdateShares(AMOUNT, !IS_ISSUANCE, IS_SNAPSHOT, 0);

        vm.startPrank(MANAGER);
        balanceSheet.revoke(POOL_A, SC_1, AMOUNT);
        balanceSheet.submitQueuedShares{value: COST}(POOL_A, SC_1, EXTRA_GAS, REFUND);
    }

    function testSubmitQueuedSharesAfterUpdateAssets() public {
        _mockShareMint(AMOUNT);
        _mockSendUpdateShares(AMOUNT, IS_ISSUANCE, !IS_SNAPSHOT, 0);
        _mockEscrowDeposit(erc20, 0, AMOUNT);

        vm.startPrank(MANAGER);
        balanceSheet.noteDeposit(POOL_A, SC_1, erc20, 0, AMOUNT);
        balanceSheet.issue(POOL_A, SC_1, TO, AMOUNT);
        balanceSheet.submitQueuedShares{value: COST}(POOL_A, SC_1, EXTRA_GAS, REFUND);
    }

    function testSubmitQueuedSharesTwice() public {
        _mockSendUpdateShares(0, IS_ISSUANCE, IS_SNAPSHOT, 2);

        vm.startPrank(MANAGER);
        _mockSendUpdateShares(0, !IS_ISSUANCE, IS_SNAPSHOT, 0);
        balanceSheet.submitQueuedShares{value: COST}(POOL_A, SC_1, EXTRA_GAS, REFUND);
        _mockSendUpdateShares(0, !IS_ISSUANCE, IS_SNAPSHOT, 1);
        balanceSheet.submitQueuedShares{value: COST}(POOL_A, SC_1, EXTRA_GAS, REFUND);

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
        vm.mockCall(
            address(endorsements), abi.encodeWithSelector(IEndorsements.endorsed.selector, FROM), abi.encode(true)
        );

        vm.prank(MANAGER);
        vm.expectRevert(IBalanceSheet.CannotTransferFromEndorsedContract.selector);
        balanceSheet.transferSharesFrom(POOL_A, SC_1, SENDER, FROM, TO, AMOUNT);
    }

    function testTransferSharesFrom() public {
        vm.mockCall(
            address(endorsements), abi.encodeWithSelector(IEndorsements.endorsed.selector, FROM), abi.encode(false)
        );
        vm.mockCall(
            registrar,
            abi.encodeWithSelector(IRegistrar.authTransferFrom.selector, share, SENDER, FROM, TO, AMOUNT),
            abi.encode()
        );

        vm.prank(MANAGER);
        vm.expectEmit();
        emit IBalanceSheet.TransferSharesFrom(POOL_A, SC_1, SENDER, FROM, TO, AMOUNT);
        balanceSheet.transferSharesFrom(POOL_A, SC_1, SENDER, FROM, TO, AMOUNT);
    }
}

contract BalanceSheetTestAvailableBalanceOf is BalanceSheetTest {
    function testAvailableBalanceOfERC20() public {
        uint128 expectedBalance = 1000;

        vm.mockCall(
            escrow,
            abi.encodeWithSelector(IPoolEscrow.availableBalanceOf.selector, SC_1, erc20, 0),
            abi.encode(expectedBalance)
        );

        uint128 balance = balanceSheet.availableBalanceOf(POOL_A, SC_1, erc20, 0);
        assertEq(balance, expectedBalance);
    }

    function testAvailableBalanceOfERC6909() public {
        uint128 expectedBalance = 500;

        vm.mockCall(
            escrow,
            abi.encodeWithSelector(IPoolEscrow.availableBalanceOf.selector, SC_1, erc6909, TOKEN_ID),
            abi.encode(expectedBalance)
        );

        uint128 balance = balanceSheet.availableBalanceOf(POOL_A, SC_1, erc6909, TOKEN_ID);
        assertEq(balance, expectedBalance);
    }
}
