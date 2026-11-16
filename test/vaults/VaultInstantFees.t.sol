// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IsContract, MockERC20, MockShareToken} from "./Vault.t.sol";

import {D18} from "../../src/misc/types/D18.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {ISpoke} from "../../src/core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../src/core/types/AssetId.sol";
import {VaultDetails, ISpokeRegistry} from "../../src/core/spoke/interfaces/ISpokeRegistry.sol";

import {Vault} from "../../src/vaults/Vault.sol";
import {IVault} from "../../src/vaults/interfaces/IVault.sol";
import {IVaultOracle} from "../../src/vaults/oracles/interfaces/IVaultOracle.sol";
import {ReserveInstantPolicy} from "../../src/vaults/policies/ReserveInstantPolicy.sol";
import {IAsyncVault, IVaultEvents, VaultConfig, VaultPlugins} from "../../src/vaults/interfaces/IAsyncVault.sol";
import {
    IInstantPolicy,
    IRequestPolicy,
    ILiquidityRoute,
    IReserveInstantPolicy,
    ISettlementObserver
} from "../../src/vaults/policies/interfaces/IVaultPlugins.sol";

import "forge-std/Test.sol";

import {IShareToken} from "../../src/token/interfaces/IShareToken.sol";

/// @dev The instant spread through the shipped policy: the exact-in entrypoints (`deposit`,
///      `redeem`) and the exact-out ones (`mint`, `withdraw`) charge it on the same base, the gross,
///      so routing through either costs the same.
contract VaultInstantFeesTest is Test {
    PoolId constant POOL = PoolId.wrap(1);
    ShareClassId constant SC = ShareClassId.wrap(bytes16("sc1"));
    AssetId immutable ASSET_ID = newAssetId(0, 1);
    D18 constant ONE = D18.wrap(1e18);

    address spoke = address(new IsContract());
    address spokeRegistry = address(new IsContract());
    address oracle = address(new IsContract());
    address envoy = makeAddr("envoy");
    address investor = makeAddr("investor");
    address feeRecipient = makeAddr("feeRecipient");

    MockERC20 asset = new MockERC20(6);
    ReserveInstantPolicy policy;
    MockShareToken share = new MockShareToken(18);
    IAsyncVault v;

    function setUp() public {
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.spokeRegistry.selector), abi.encode(spokeRegistry));
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.escrow.selector), abi.encode(address(new IsContract())));
        policy = new ReserveInstantPolicy(ISpoke(spoke), envoy);

        Vault vault = new Vault(
            POOL,
            SC,
            address(asset),
            ASSET_ID,
            IShareToken(address(share)),
            VaultConfig({
                foldHorizon: 0,
                spoke: ISpoke(spoke),
                spokeRegistry: ISpokeRegistry(spokeRegistry),
                plugins: VaultPlugins({
                    oracle: IVaultOracle(oracle),
                    instantPolicy: IInstantPolicy(address(policy)),
                    requestPolicy: IRequestPolicy(address(0)),
                    liquidityRoute: ILiquidityRoute(address(0)),
                    settlementObserver: ISettlementObserver(address(0))
                })
            })
        );
        v = IAsyncVault(address(vault));

        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.vaultDetails.selector, address(v)),
            abi.encode(VaultDetails(POOL, SC, ASSET_ID, address(asset), uint256(0), true))
        );
        vm.mockCall(address(v), abi.encodeWithSelector(IVault.poolId.selector), abi.encode(POOL));
        vm.mockCall(address(v), abi.encodeWithSelector(IVault.scId.selector), abi.encode(SC));
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.vaultDetails.selector),
            abi.encode(VaultDetails(POOL, SC, ASSET_ID, address(asset), uint256(0), true))
        );
        vm.mockCall(oracle, abi.encodeWithSelector(IVaultOracle.prices.selector), abi.encode(ONE, ONE, true));

        bytes4[5] memory voids = [
            ISpoke.noteDeposit.selector,
            ISpoke.issue.selector,
            ISpoke.revoke.selector,
            ISpoke.withdraw.selector,
            ISpoke.transferSharesFrom.selector
        ];
        for (uint256 i; i < voids.length; i++) {
            vm.mockCall(spoke, abi.encodeWithSelector(voids[i]), "");
        }
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.availableBalanceOf.selector), abi.encode(uint128(1_000_000e6)));
    }

    /// @dev A fee with no recipient is retained in the escrow instead of paid out.
    function _configure(uint16 feeBps, bool retained) internal {
        IReserveInstantPolicy.Config memory config_ = IReserveInstantPolicy.Config({
            feeRecipient: retained ? address(0) : feeRecipient,
            depositFeeBps: feeBps,
            redeemFeeBps: feeBps,
            redeemEnabled: true,
            gatedDeposit: false,
            gatedRedeem: false,
            maxReserve: 10_000_000e6
        });
        vm.prank(envoy);
        policy.fromHub(POOL, abi.encode(IReserveInstantPolicy.ConfigKind.Terms, address(v), abi.encode(config_)));
    }

    /// @dev A 10% fee is 10% of the gross on every entrypoint, not 10% of the net on the exact-out
    ///      ones, which would make them cost f/(1+f). Paid out or retained, the investor sees the same price.
    function testExactOutPaysTheSameRateAsExactIn(bool retained) public {
        _configure(1_000, retained);
        vm.startPrank(investor);

        assertEq(v.redeem(100e18, investor), 90e6, "redeem 100 pays 90");
        assertEq(v.withdraw(90e6, investor), 100e18, "withdrawing 90 burns 100");
        assertEq(v.deposit(100e6, investor), 90e18, "depositing 100 mints 90");
        assertEq(v.mint(90e18, investor), 100e6, "minting 90 costs 100");

        vm.stopPrank();
    }

    /// @dev Every instant entrypoint reports its pricing beside the ERC-4626 event: the fee and its
    ///      recipient, or the retained fee when there is none, and no route draw where there is no route.
    ///      The exact-out ones report the same as the exact-in ones for the same gross.
    function testEveryInstantEntrypointEmitsItsFees(bool retained) public {
        _configure(1_000, retained);
        address receiver = makeAddr("receiver");
        int128 paid = retained ? int128(0) : int128(10e6);
        address recipient = retained ? address(0) : feeRecipient;
        uint128 kept = retained ? 10e6 : 0;
        vm.startPrank(investor);

        vm.expectEmit(true, true, false, true, address(v));
        emit IVaultEvents.InstantFees(investor, receiver, true, 90e18, paid, recipient, kept, 0, ONE, ONE);
        v.deposit(100e6, receiver);

        vm.expectEmit(true, true, false, true, address(v));
        emit IVaultEvents.InstantFees(investor, receiver, true, 90e18, paid, recipient, kept, 0, ONE, ONE);
        v.mint(90e18, receiver);

        vm.expectEmit(true, true, false, true, address(v));
        emit IVaultEvents.InstantFees(investor, receiver, false, 100e18, paid, recipient, kept, 0, ONE, ONE);
        v.redeem(100e18, receiver);

        vm.expectEmit(true, true, false, true, address(v));
        emit IVaultEvents.InstantFees(investor, receiver, false, 100e18, paid, recipient, kept, 0, ONE, ONE);
        v.withdraw(90e6, receiver);

        vm.stopPrank();
    }

    /// @dev The previews agree with the executes, so `withdraw(x)` and `redeem(previewWithdraw(x))`
    ///      burn the same shares, and the round trip through either side stays within rounding.
    function testPreviewsRoundTripAcrossTheBase(uint16 feeBps, bool retained, uint128 shares) public {
        feeBps = uint16(bound(feeBps, 0, 5_000));
        shares = uint128(bound(shares, 1e18, 100_000e18));
        _configure(feeBps, retained);

        uint256 payout = v.previewRedeem(shares);
        uint256 burnt = v.previewWithdraw(payout);
        assertLe(burnt, shares, "exact-out never costs more than exact-in");
        assertApproxEqAbs(burnt, shares, 6e12, "and at most a few asset units less");

        vm.prank(investor);
        assertEq(v.withdraw(payout, investor), burnt, "withdraw burns what previewWithdraw quoted");

        uint256 cost = v.previewMint(shares);
        assertGe(v.previewDeposit(cost), shares - 6e12, "depositing the mint cost mints the shares, within rounding");
        vm.prank(investor);
        assertEq(v.mint(shares, investor), cost, "mint costs what previewMint quoted");
    }

    /// @dev ERC-4626: `withdraw(maxWithdraw)` must not need more shares than the owner holds when its
    ///      balance, not the capacity, bounds the exit. The view quotes the fee exact-in on the gross
    ///      while the withdraw re-grosses the net exact-out, and the two round differently.
    function testFuzzWithdrawingMaxWithdrawStaysWithinTheBalance(
        uint16 feeBps,
        bool retained,
        uint128 held,
        uint128 pps
    ) public {
        feeBps = uint16(bound(feeBps, 0, 6_000));
        held = uint128(bound(held, 1, 1_000e18));
        pps = uint128(bound(pps, 1e15, 1e21));
        vm.mockCall(oracle, abi.encodeWithSelector(IVaultOracle.prices.selector), abi.encode(ONE, D18.wrap(pps), true));
        _configure(feeBps, retained);
        share.setBalance(investor, held);

        uint256 maxWithdraw = v.maxWithdraw(investor);
        if (maxWithdraw == 0) return;
        vm.prank(investor);
        assertLe(v.withdraw(maxWithdraw, investor), held, "withdraw(maxWithdraw) burnt more than the balance");
    }

    /// @dev The capacity views stay exact with a spread on the gross: the full `maxMint` and
    ///      `maxWithdraw` execute.
    function testTheMaxViewsExecuteWithASpread(bool retained) public {
        _configure(1_500, retained);

        uint256 maxWithdraw = v.maxWithdraw(investor);
        vm.prank(investor);
        v.withdraw(maxWithdraw, investor);

        uint256 maxMint = v.maxMint(investor);
        vm.prank(investor);
        v.mint(maxMint, investor);
    }
}
