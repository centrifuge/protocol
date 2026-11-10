// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {TrackingSpoke} from "./VaultInvariants.t.sol";
import {IsContract, MockERC20, MockShareToken} from "./Vault.t.sol";

import {D18} from "../../src/misc/types/D18.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {ISpoke} from "../../src/core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../src/core/types/AssetId.sol";
import {ISpokeRegistry, VaultDetails} from "../../src/core/spoke/interfaces/ISpokeRegistry.sol";

import {
    IVaultRequestManager,
    IVaultDepositCallbacks,
    IVaultRedeemCallbacks
} from "../../src/vaults/messaging/interfaces/IVaultRequestManager.sol";

import {Vault} from "../../src/vaults/Vault.sol";
import {PerRequestPolicy} from "../../src/vaults/policies/RequestPolicies.sol";
import {IVaultOracle} from "../../src/vaults/oracles/interfaces/IVaultOracle.sol";
import {
    IAsyncVault,
    VaultConfig,
    VaultPlugins,
    REASON_DEPOSIT,
    REASON_REDEEM
} from "../../src/vaults/interfaces/IAsyncVault.sol";
import {
    IInstantPolicy,
    IRequestPolicy,
    ILiquidityRoute,
    ISettlementObserver
} from "../../src/vaults/policies/interfaces/IVaultPlugins.sol";

import "forge-std/Test.sol";

import {IShareToken} from "../../src/token/interfaces/IShareToken.sol";

/// @dev A spoke that is also its own escrow, so `reservedBy` answers from the same books the
///      reservations are made in. Every other test in the module mocks `reservedBy` to `uint128.max`,
///      which makes `_releaseDeposit` a no-op and leaves the clamp it exists for unexercised.
contract ReservationSpoke is TrackingSpoke {
    constructor(ISpokeRegistry registry) TrackingSpoke(address(this), registry) {}

    function reservedBy(ShareClassId, address, bytes32 reason, address, uint256) external view returns (uint128) {
        return reserved[reason];
    }

    /// @dev Unbounded, so payout reservations are never refused here: this suite is about the keys.
    function holding(ShareClassId, address, uint256) external pure returns (uint128, uint128) {
        return (type(uint128).max, 0);
    }

    /// @dev A balance-sheet manager unlocking part of a reservation for cash access, outside the
    ///      vault. Permissionless by design in core: the reason is an accounting key, not an
    ///      authenticated identity, which is exactly why the vault has to survive it.
    function unlockExternally(bytes32 reason, uint128 amount) external {
        reserved[reason] -= amount;
        noted += amount;
    }
}

/// @dev What the escrow is holding, and under which key. The deposit side reserves per request
///      and the redeem side reserves flat, and the difference is load-bearing: an early unlock or an
///      over-sized approval on one request must not be able to reach another's money.
contract VaultReservationsTest is Test {
    PoolId constant POOL = PoolId.wrap(1);
    ShareClassId constant SC = ShareClassId.wrap(bytes16("sc1"));
    AssetId immutable ASSET_ID = newAssetId(0, 1);

    D18 constant ONE = D18.wrap(1e18);

    address spokeRegistry = address(new IsContract());
    address oracle = address(new IsContract());
    address router = makeAddr("requestManager");

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    ReservationSpoke spoke;
    IAsyncVault v;

    function setUp() public {
        spoke = new ReservationSpoke(ISpokeRegistry(spokeRegistry));

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
                    instantPolicy: IInstantPolicy(address(0)),
                    requestPolicy: IRequestPolicy(address(new PerRequestPolicy(true))),
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
        vm.mockCall(spokeRegistry, abi.encodeWithSelector(ISpokeRegistry.requestManager.selector), abi.encode(router));
        vm.mockCall(oracle, abi.encodeWithSelector(IVaultOracle.prices.selector), abi.encode(ONE, ONE, true));
        vm.mockCall(router, abi.encodeWithSelector(IVaultRequestManager.sendDepositRequest.selector), "");
        vm.mockCall(router, abi.encodeWithSelector(IVaultRequestManager.sendRedeemRequest.selector), "");
    }

    function _depositReason(uint96 localId) internal pure returns (bytes32) {
        return keccak256(abi.encode(REASON_DEPOSIT, localId));
    }

    function _request(address who, uint128 assets) internal returns (uint96 localId) {
        vm.prank(who);
        return uint96(v.requestDeposit(assets, who, who));
    }

    //----------------------------------------------------------------------------------------------
    // Keying
    //----------------------------------------------------------------------------------------------

    /// @dev Each request's assets sit under their own key. This is what makes a manager's early unlock
    ///      for cash access safe alongside a later approval: it can only reach the request it names.
    function testEachRequestGetsItsOwnReservation() public {
        uint96 first = _request(alice, 1_000e6);
        uint96 second = _request(bob, 400e6);

        assertTrue(first != second, "two requests, two buckets");
        assertEq(spoke.reserved(_depositReason(first)), 1_000e6, "alice's assets under alice's key");
        assertEq(spoke.reserved(_depositReason(second)), 400e6, "bob's under bob's");
        assertEq(spoke.noted(), 0, "and none of it is in the free holding");
    }

    /// @dev Settling one request must leave the other's reservation exactly where it was.
    function testApprovingOneRequestLeavesTheOtherReservationAlone() public {
        uint96 first = _request(alice, 1_000e6);
        uint96 second = _request(bob, 400e6);

        vm.prank(router);
        IVaultDepositCallbacks(address(v)).approveDeposits(first, 1_000e6);

        assertEq(spoke.reserved(_depositReason(first)), 0, "alice's reservation was released");
        assertEq(spoke.reserved(_depositReason(second)), 400e6, "bob's is untouched");
        assertEq(spoke.noted(), 1_000e6, "and only alice's assets reached the holding");
    }

    //----------------------------------------------------------------------------------------------
    // The clamp
    //----------------------------------------------------------------------------------------------

    /// @dev `_releaseDeposit` clamps the release to what the vault still holds under that reason. Without
    ///      it, a manager who unlocked part of a request's reservation for cash access would make the
    ///      later approval revert on an underflow, wedging the request permanently.
    function testAnEarlyUnlockDoesNotWedgeTheApproval() public {
        uint96 localId = _request(alice, 1_000e6);
        bytes32 reason = _depositReason(localId);

        spoke.unlockExternally(reason, 600e6);
        assertEq(spoke.reserved(reason), 400e6, "the manager took most of it out early");

        vm.prank(router);
        IVaultDepositCallbacks(address(v)).approveDeposits(localId, 1_000e6);

        assertEq(spoke.reserved(reason), 0, "the approval released what was left, and did not revert");
    }

    /// @dev The same clamp on the cancellation path, which releases the gross amount. Releasing only
    ///      the net would strand the difference, and releasing more than is there would revert.
    function testACancellationClampsItsReleaseToo() public {
        uint96 localId = _request(alice, 1_000e6);
        bytes32 reason = _depositReason(localId);

        spoke.unlockExternally(reason, 900e6);

        vm.prank(router);
        IVaultDepositCallbacks(address(v)).cancelDeposit(localId, 1_000e6, 950e6);

        assertEq(spoke.reserved(reason), 0, "the request's own key is emptied");
        assertEq(spoke.reserved(REASON_REDEEM), 950e6, "and the refund is re-reserved for the claim");
    }

    /// @dev An approval larger than the request must not reach past its own key into another's.
    function testAnOverSizedApprovalCannotReachAnotherRequest() public {
        uint96 first = _request(alice, 1_000e6);
        uint96 second = _request(bob, 400e6);

        vm.prank(router);
        IVaultDepositCallbacks(address(v)).approveDeposits(first, 1_400e6);

        assertEq(spoke.reserved(_depositReason(second)), 400e6, "bob's reservation is still bob's");
        assertEq(spoke.noted(), 1_000e6, "and only alice's own assets were released");
    }

    //----------------------------------------------------------------------------------------------
    // The redeem side
    //----------------------------------------------------------------------------------------------

    /// @dev The redeem reservation is flat: one key for the whole vault, because a payout is claimed
    ///      per controller rather than per request, and a controller's claimable ledger blends every
    ///      fulfillment they have. Two redemptions therefore share one reservation.
    function testTheRedeemReservationIsFlat() public {
        // Fund the escrow so a payout has something to reserve against, and mint the supply the
        // revocation burns.
        uint96 funding = _request(alice, 10_000e6);
        vm.startPrank(router);
        IVaultDepositCallbacks(address(v)).approveDeposits(funding, 10_000e6);
        IVaultDepositCallbacks(address(v)).issueShares(funding, 10_000e18);
        vm.stopPrank();

        vm.prank(alice);
        uint96 firstRedeem = uint96(v.requestRedeem(1_000e18, alice, alice));
        vm.prank(bob);
        uint96 secondRedeem = uint96(v.requestRedeem(500e18, bob, bob));

        vm.startPrank(router);
        IVaultRedeemCallbacks(address(v)).revokeShares(firstRedeem, 1_000e6, 1_000e18);
        IVaultRedeemCallbacks(address(v)).revokeShares(secondRedeem, 500e6, 500e18);
        vm.stopPrank();

        assertEq(spoke.reserved(REASON_REDEEM), 1_500e6, "both payouts sit under the one redeem key");
        assertEq(spoke.reserved(_depositReason(firstRedeem)), 0, "and none under a per-request one");
    }

    /// @dev A claim draws from that reservation and not from the free holding, so a pool with cash
    ///      sitting idle cannot have it paid out to a redeemer who was never fulfilled.
    function testARedeemClaimPaysOutOfTheReservation() public {
        uint96 funding = _request(alice, 10_000e6);
        vm.startPrank(router);
        IVaultDepositCallbacks(address(v)).approveDeposits(funding, 10_000e6);
        IVaultDepositCallbacks(address(v)).issueShares(funding, 10_000e18);
        vm.stopPrank();

        vm.prank(alice);
        uint96 localId = uint96(v.requestRedeem(1_000e18, alice, alice));

        vm.startPrank(router);
        IVaultRedeemCallbacks(address(v)).revokeShares(localId, 1_000e6, 1_000e18);
        IVaultRedeemCallbacks(address(v)).fulfillRedeemRequest(localId, 1_000e6, 1_000e18);
        vm.stopPrank();

        uint128 heldBefore = spoke.noted();

        vm.prank(alice);
        v.withdraw(1_000e6, alice, alice);

        assertEq(spoke.reserved(REASON_REDEEM), 0, "the claim consumed the reservation");
        assertEq(spoke.noted(), heldBefore, "and left the free holding untouched");
    }
}
