// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IsContract, MockERC20, MockShareToken} from "./Vault.t.sol";

import {D18} from "../../src/misc/types/D18.sol";
import {ReentrancyProtection} from "../../src/misc/ReentrancyProtection.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {ISpoke} from "../../src/core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../src/core/types/AssetId.sol";
import {ISpokeRegistry, VaultDetails} from "../../src/core/spoke/interfaces/ISpokeRegistry.sol";

import {
    IVaultDepositCallbacks,
    IVaultRedeemCallbacks
} from "../../src/vaults/messaging/interfaces/IVaultRequestManager.sol";

import {Vault} from "../../src/vaults/Vault.sol";
import {PerRequestPolicy} from "../../src/vaults/policies/RequestPolicies.sol";
import {IVaultOracle} from "../../src/vaults/oracles/interfaces/IVaultOracle.sol";
import {
    IInstantPolicy,
    IRequestPolicy,
    ILiquidityRoute,
    ISettlementObserver
} from "../../src/vaults/policies/interfaces/IVaultPlugins.sol";
import {
    IAsyncVault,
    IVaultBase,
    IVaultErrors,
    VaultConfig,
    VaultPlugins,
    REASON_DEPOSIT,
    REASON_REDEEM
} from "../../src/vaults/interfaces/IAsyncVault.sol";

import "forge-std/Test.sol";

import {IShareToken} from "../../src/token/interfaces/IShareToken.sol";

/// @dev Mirrors core's Spoke and Escrow books: `reserve` does not check the balance, as
///      `Escrow.reserve` does not, and every note, reserve and unreserve is queued to the hub as a
///      holding delta.
contract EscrowLikeSpoke {
    uint128 public total;
    uint128 public reservedTotal;
    mapping(bytes32 => uint128) public reserved;
    int256 public hubHolding;
    uint128 public shareSupply;

    function escrow(PoolId) external view returns (address) {
        return address(this);
    }

    function reservedBy(ShareClassId, address, bytes32 reason, address, uint256) external view returns (uint128) {
        return reserved[reason];
    }

    function noteDeposit(PoolId, ShareClassId, address, uint256, uint128 amount) external {
        total += amount;
        hubHolding += int256(uint256(amount));
    }

    function reserve(PoolId, ShareClassId, address, uint256, uint128 amount, address, bytes32 reason) external {
        reserved[reason] += amount;
        reservedTotal += amount;
        hubHolding -= int256(uint256(amount));
    }

    function unreserve(PoolId, ShareClassId, address, uint256, uint128 amount, address, bytes32 reason) external {
        reserved[reason] -= amount;
        reservedTotal -= amount;
        hubHolding += int256(uint256(amount));
    }

    function withdrawReserved(PoolId, ShareClassId, address, uint256, address, uint128 amount, address, bytes32 reason)
        external
    {
        reserved[reason] -= amount;
        reservedTotal -= amount;
        require(total >= amount, "InsufficientBalance");
        total -= amount;
    }

    function withdraw(PoolId, ShareClassId, address, uint256, address, uint128 amount) external {
        require(total >= reservedTotal + amount, "InsufficientBalance");
        total -= amount;
        hubHolding -= int256(uint256(amount));
    }

    function holding(ShareClassId, address, uint256) external view returns (uint128, uint128) {
        return (total, reservedTotal);
    }

    function availableBalanceOf(PoolId, ShareClassId, address, uint256) external view returns (uint128) {
        return total < reservedTotal ? 0 : total - reservedTotal;
    }

    function issue(PoolId, ShareClassId, address, uint128 shares) external {
        shareSupply += shares;
    }

    function revoke(PoolId, ShareClassId, uint128 shares) external {
        shareSupply -= shares;
    }

    function transferSharesFrom(PoolId, ShareClassId, address, address, address, uint256) external {}
    function withdrawShares(PoolId, ShareClassId, address, uint128) external {}
}

/// @dev A request manager that answers a deposit from inside the flush, the shape
///      `docs/vaults-policies.md` documents for a manager that fulfils locally. Prices 1:1 across 6/18 decimals.
contract SettlingRequestManager {
    bool public cancelInstead;
    bool public holdDeposits;

    function setCancelInstead(bool cancel) external {
        cancelInstead = cancel;
    }

    /// @dev Leaves a deposit pending, as a hub manager does until it settles the window.
    function setHoldDeposits(bool hold) external {
        holdDeposits = hold;
    }

    function sendDepositRequest(uint96 localId, uint128 amount) external {
        if (holdDeposits) return;
        if (cancelInstead) {
            IVaultDepositCallbacks(msg.sender).cancelDeposit(localId, amount, amount);
        } else {
            IVaultDepositCallbacks(msg.sender).approveDeposits(localId, amount);
            IVaultDepositCallbacks(msg.sender).issueShares(localId, amount * 1e12);
            IVaultDepositCallbacks(msg.sender).fulfillDepositRequest(localId, amount, amount * 1e12);
        }
    }

    function sendRedeemRequest(uint96, uint128) external {}
}

/// @dev The order a request's funds and its settlement reach the escrow in, against books that
///      behave like core's: a settlement inside the flush, and a redeem fill landing after the
///      instant lane has drawn on the cash it was priced against.
contract VaultSettlementOrderingTest is Test {
    PoolId constant POOL = PoolId.wrap(1);
    ShareClassId constant SC = ShareClassId.wrap(bytes16("sc1"));
    AssetId immutable ASSET_ID = newAssetId(0, 1);
    D18 constant ONE = D18.wrap(1e18);

    address spokeRegistry = address(new IsContract());
    address oracle = address(new IsContract());
    address instantPolicy = address(new IsContract());
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    EscrowLikeSpoke spoke = new EscrowLikeSpoke();
    SettlingRequestManager manager = new SettlingRequestManager();
    IAsyncVault v;

    function setUp() public {
        Vault vault = new Vault(
            POOL,
            SC,
            address(new MockERC20(6)),
            ASSET_ID,
            IShareToken(address(new MockShareToken(18))),
            VaultConfig({
                foldHorizon: 0,
                spoke: ISpoke(address(spoke)),
                spokeRegistry: ISpokeRegistry(spokeRegistry),
                plugins: VaultPlugins({
                    oracle: IVaultOracle(oracle),
                    instantPolicy: IInstantPolicy(instantPolicy),
                    requestPolicy: IRequestPolicy(address(new PerRequestPolicy(false))),
                    liquidityRoute: ILiquidityRoute(address(0)),
                    settlementObserver: ISettlementObserver(address(0))
                })
            })
        );
        v = IAsyncVault(address(vault));

        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.vaultDetails.selector),
            abi.encode(VaultDetails(POOL, SC, ASSET_ID, v.asset(), uint256(0), true))
        );
        vm.mockCall(
            spokeRegistry, abi.encodeWithSelector(ISpokeRegistry.requestManager.selector), abi.encode(address(manager))
        );
        vm.mockCall(oracle, abi.encodeWithSelector(IVaultOracle.prices.selector), abi.encode(ONE, ONE, true));
        vm.mockCall(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.maxInstantRedeem.selector),
            abi.encode(type(uint128).max)
        );
        vm.mockCall(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantRedeem.selector),
            abi.encode(int128(0), address(0))
        );
        vm.mockCall(instantPolicy, abi.encodeWithSelector(IInstantPolicy.onInstantRedeem.selector), "");
    }

    function _depositReason(uint96 localId) internal pure returns (bytes32) {
        return keccak256(abi.encode(REASON_DEPOSIT, localId));
    }

    /// @dev Settled inside the flush, the approval has to find the request's assets reserved, or it
    ///      releases nothing and the request then reserves them under a reason nothing will release:
    ///      shares issued against a holding the hub never sees grow.
    function testADepositSettledInsideTheFlushReleasesItsAssets() public {
        vm.prank(alice);
        uint96 localId = uint96(v.requestDeposit(1_000e6, alice, alice));

        assertEq(v.maxMint(alice), 1_000e18, "settled and claimable");
        assertEq(spoke.reserved(_depositReason(localId)), 0, "nothing left under the request's reason");
        assertEq(spoke.hubHolding(), 1_000e6, "the hub sees the assets backing the issued shares");
        assertEq(spoke.availableBalanceOf(POOL, SC, address(0), 0), 1_000e6);
    }

    /// @dev The cancellation variant: the refund is re-reserved out of the request's own released
    ///      assets, not reserved a second time on top of them.
    function testADepositCancelledInsideTheFlushIsRefundable() public {
        manager.setCancelInstead(true);

        vm.prank(alice);
        uint96 localId = uint96(v.requestDeposit(1_000e6, alice, alice));

        assertEq(spoke.reserved(_depositReason(localId)), 0, "the request's reservation released");
        assertEq(spoke.reserved(REASON_REDEEM), 1_000e6, "and the refund reserved once");
        assertEq(spoke.hubHolding(), 0, "the hub is told nothing changed");

        vm.prank(alice);
        v.withdraw(1_000e6, alice, alice);
        assertEq(spoke.total(), 0, "the refund paid out of the request's own assets");
    }

    /// @dev A cancellation with a retained fee refunds the net, not the gross: the retained part stays in the
    ///      holding, so only the net is reserved for the investor's refund.
    function testACancelledDepositReservesOnlyTheNet() public {
        manager.setHoldDeposits(true);

        vm.prank(alice);
        uint96 localId = uint96(v.requestDeposit(1_000e6, alice, alice));

        vm.prank(address(manager));
        IVaultDepositCallbacks(address(v)).cancelDeposit(localId, 1_000e6, 600e6);

        assertEq(spoke.reserved(REASON_REDEEM), 600e6, "only the net is reserved for the refund");
        assertEq(spoke.reserved(_depositReason(localId)), 0, "the request's own reservation is released");
    }

    /// @dev A payout is backed on top of what the vault already owes: 1,000 of cash covers one 600 payout, and a
    ///      second 600 would leave the first unbacked, so it reverts rather than reserving against the same cash.
    function testAPayoutIsBackedOnTopOfWhatIsAlreadyOwed() public {
        spoke.noteDeposit(POOL, SC, address(0), 0, 1_000e6);
        spoke.issue(POOL, SC, address(0), 2_000e18);

        vm.prank(alice);
        uint96 localId = uint96(v.requestRedeem(1_000e18, alice, alice));

        vm.startPrank(address(manager));
        IVaultRedeemCallbacks(address(v)).revokeShares(localId, 600e6, 600e18);
        assertEq(spoke.reserved(REASON_REDEEM), 600e6, "the first payout is reserved");

        vm.expectRevert(IVaultErrors.InsufficientLiquidity.selector);
        IVaultRedeemCallbacks(address(v)).revokeShares(localId, 600e6, 400e18);
        vm.stopPrank();
        assertEq(spoke.reserved(REASON_REDEEM), 600e6, "the second is not reserved against the same cash");
    }

    /// @dev The hub prices a redeem fill against escrow cash it saw; while the callback is in flight
    ///      an instant exit takes that cash. The callback must not reserve a payout the escrow cannot
    ///      cover: it reverts, which leaves it retryable, and applies once the pool refunds the escrow.
    function testARedeemFillTheEscrowCannotCoverWaitsForLiquidity() public {
        spoke.noteDeposit(POOL, SC, address(0), 0, 1_000e6);
        spoke.issue(POOL, SC, address(0), 2_000e18);

        vm.prank(alice);
        uint96 localId = uint96(v.requestRedeem(1_000e18, alice, alice));

        vm.prank(bob);
        v.redeem(1_000e18, bob);
        assertEq(spoke.total(), 0, "the instant lane drained the idle cash");

        vm.prank(address(manager));
        vm.expectRevert(IVaultErrors.InsufficientLiquidity.selector);
        IVaultRedeemCallbacks(address(v)).revokeShares(localId, 1_000e6, 1_000e18);
        assertEq(spoke.reserved(REASON_REDEEM), 0, "no unbacked reservation");
        assertEq(v.maxWithdraw(alice), 0, "and no unbacked claim");

        spoke.noteDeposit(POOL, SC, address(0), 0, 1_000e6);
        vm.startPrank(address(manager));
        IVaultRedeemCallbacks(address(v)).revokeShares(localId, 1_000e6, 1_000e18);
        IVaultRedeemCallbacks(address(v)).fulfillRedeemRequest(localId, 1_000e6, 1_000e18);
        vm.stopPrank();

        vm.prank(alice);
        v.withdraw(1_000e6, alice, alice);
        assertEq(spoke.hubHolding(), 0, "the holding never went into deficit");
    }

    /// @dev A pool that invests its subscription cash and nets the next window settles the redemption
    ///      before the deposit funding it. The escrow's cash is all reserved for that pending deposit,
    ///      so nothing is available, but it is there: the fill is not refused for it.
    function testARedeemFillFundedByAPendingDepositSettlesFirst() public {
        manager.setHoldDeposits(true);
        address carol = makeAddr("carol");
        spoke.issue(POOL, SC, address(0), 1_000e18);

        vm.prank(carol);
        uint96 depositId = uint96(v.requestDeposit(1_000e6, carol, carol));
        assertEq(spoke.availableBalanceOf(POOL, SC, address(0), 0), 0, "all of the cash is reserved");

        vm.prank(alice);
        uint96 redeemId = uint96(v.requestRedeem(1_000e18, alice, alice));
        vm.startPrank(address(manager));
        IVaultRedeemCallbacks(address(v)).revokeShares(redeemId, 1_000e6, 1_000e18);
        IVaultRedeemCallbacks(address(v)).fulfillRedeemRequest(redeemId, 1_000e6, 1_000e18);
        vm.stopPrank();
        assertEq(v.maxWithdraw(alice), 1_000e6, "the redemption settled first");

        vm.startPrank(address(manager));
        IVaultDepositCallbacks(address(v)).approveDeposits(depositId, 1_000e6);
        IVaultDepositCallbacks(address(v)).issueShares(depositId, 1_000e18);
        IVaultDepositCallbacks(address(v)).fulfillDepositRequest(depositId, 1_000e6, 1_000e18);
        vm.stopPrank();

        vm.prank(alice);
        v.withdraw(1_000e6, alice, alice);
        assertEq(spoke.total(), 0, "paid out of the deposit's cash");
        assertEq(spoke.hubHolding(), 0, "and the holding nets to zero");
    }

    /// @dev The cancellation credits a claim the same way a fill does, so it is refused on the same
    ///      condition: a manager unlocked the request early and spent the cash, and the refund then
    ///      waits for the pool to restore it rather than compete with backed claims.
    function testACancellationTheEscrowCannotCoverWaitsForLiquidity() public {
        manager.setHoldDeposits(true);
        vm.prank(alice);
        uint96 localId = uint96(v.requestDeposit(1_000e6, alice, alice));

        spoke.unreserve(POOL, SC, address(0), 0, 1_000e6, address(v), _depositReason(localId));
        spoke.withdraw(POOL, SC, address(0), 0, address(0), 1_000e6);

        vm.prank(address(manager));
        vm.expectRevert(IVaultErrors.InsufficientLiquidity.selector);
        IVaultDepositCallbacks(address(v)).cancelDeposit(localId, 1_000e6, 1_000e6);

        spoke.noteDeposit(POOL, SC, address(0), 0, 1_000e6);
        vm.prank(address(manager));
        IVaultDepositCallbacks(address(v)).cancelDeposit(localId, 1_000e6, 1_000e6);

        vm.prank(alice);
        v.withdraw(1_000e6, alice, alice);
        assertEq(spoke.total(), 0, "refunded once the pool restored the cash");
    }
}

/// @dev An asset whose `transferFrom` hands control to a third party, which tries one call into the
///      vault mid-request and keeps what it returned.
contract ReenteringAsset {
    uint8 public constant decimals = 6;
    address public target;
    bytes public data;
    bytes public result;

    function arm(address target_, bytes calldata data_) external {
        target = target_;
        data = data_;
    }

    function transferFrom(address, address, uint256) external returns (bool) {
        if (target == address(0)) return true;
        address target_ = target;
        target = address(0);
        (bool ok, bytes memory returned) = target_.call(data);
        result = ok ? bytes("") : returned;
        return true;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
}

/// @dev The permissionless maintenance entrypoints share the vault's lock, so a token callback cannot
///      flush or fold mid-request.
contract VaultMaintenanceReentrancyTest is Test {
    PoolId constant POOL = PoolId.wrap(1);
    ShareClassId constant SC = ShareClassId.wrap(bytes16("sc1"));
    D18 constant ONE = D18.wrap(1e18);

    address spokeRegistry = address(new IsContract());
    address oracle = address(new IsContract());
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    EscrowLikeSpoke spoke = new EscrowLikeSpoke();
    SettlingRequestManager manager = new SettlingRequestManager();
    ReenteringAsset asset = new ReenteringAsset();
    IAsyncVault v;

    function setUp() public {
        address policy = address(new PerRequestPolicy(false));
        Vault vault = new Vault(
            POOL,
            SC,
            address(asset),
            newAssetId(0, 1),
            IShareToken(address(new MockShareToken(18))),
            VaultConfig({
                foldHorizon: 0,
                spoke: ISpoke(address(spoke)),
                spokeRegistry: ISpokeRegistry(spokeRegistry),
                plugins: VaultPlugins({
                    oracle: IVaultOracle(oracle),
                    instantPolicy: IInstantPolicy(address(0)),
                    requestPolicy: IRequestPolicy(policy),
                    liquidityRoute: ILiquidityRoute(address(0)),
                    settlementObserver: ISettlementObserver(address(0))
                })
            })
        );
        v = IAsyncVault(address(vault));

        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.vaultDetails.selector),
            abi.encode(VaultDetails(POOL, SC, newAssetId(0, 1), v.asset(), uint256(0), true))
        );
        vm.mockCall(
            spokeRegistry, abi.encodeWithSelector(ISpokeRegistry.requestManager.selector), abi.encode(address(manager))
        );
        vm.mockCall(oracle, abi.encodeWithSelector(IVaultOracle.prices.selector), abi.encode(ONE, ONE, true));
    }

    function testATokenCallbackCannotFlushMidRequest() public {
        manager.setHoldDeposits(true);
        asset.arm(address(v), abi.encodeWithSelector(IVaultBase.flushRequest.selector, uint96(1)));

        vm.prank(alice);
        v.requestDeposit(1_000e6, alice, alice);

        assertEq(asset.result(), abi.encodeWithSelector(ReentrancyProtection.Reentrancy.selector));
    }

    function testATokenCallbackCannotFoldMidRequest() public {
        vm.prank(alice);
        uint96 settled = uint96(v.requestDeposit(1_000e6, alice, alice));
        manager.setHoldDeposits(true);
        asset.arm(address(v), abi.encodeCall(IAsyncVault.foldRequest, (settled, alice)));

        vm.prank(bob);
        v.requestDeposit(1_000e6, bob, bob);

        assertEq(asset.result(), abi.encodeWithSelector(ReentrancyProtection.Reentrancy.selector));
    }

    /// @dev A manager settling inside the flush has the vault fold the bucket under the lock.
    function testASettlementMadeInsideTheFlushIsFolded() public {
        vm.prank(alice);
        uint96 localId = uint96(v.requestDeposit(1_000e6, alice, alice));

        assertEq(v.contribution(localId, alice).amount, 0, "folded by the vault");
        assertEq(v.maxMint(alice), 1_000e18, "and claimable");
    }
}
