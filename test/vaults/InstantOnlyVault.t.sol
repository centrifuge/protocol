// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AmpleEscrow, IsContract, MockERC20, MockShareToken} from "./Vault.t.sol";

import {D18} from "../../src/misc/types/D18.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {ISpoke} from "../../src/core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../src/core/types/AssetId.sol";
import {ISpokeRegistry, VaultDetails} from "../../src/core/spoke/interfaces/ISpokeRegistry.sol";

import {Vault} from "../../src/vaults/Vault.sol";
import {IVaultOracle} from "../../src/vaults/oracles/interfaces/IVaultOracle.sol";
import {IAsyncVault, VaultConfig, VaultPlugins} from "../../src/vaults/interfaces/IAsyncVault.sol";
import {
    IInstantPolicy,
    IRequestPolicy,
    ILiquidityRoute,
    ISettlementObserver
} from "../../src/vaults/policies/interfaces/IVaultPlugins.sol";

import "forge-std/Test.sol";

import {IRoleHook} from "../../src/token/interfaces/IRoleHook.sol";
import {IShareToken} from "../../src/token/interfaces/IShareToken.sol";

/// @dev A vault configured with an instant policy but no request policy is a valid, instant-only
///      vault: the sync ERC-4626 lane works end to end, and the async ERC-7540 entrypoints — the only
///      code that reaches `requestPolicy` — revert. Nothing else on the vault touches it, so leaving
///      it unset does not disable anything the instant lane needs.
contract InstantOnlyVaultTest is Test {
    PoolId constant POOL = PoolId.wrap(1);
    ShareClassId constant SC = ShareClassId.wrap(bytes16("sc1"));
    AssetId immutable ASSET_ID = newAssetId(0, 1);

    D18 constant ONE = D18.wrap(1e18);

    address spoke = address(new IsContract());
    address spokeRegistry = address(new IsContract());
    address actionHook = address(new IsContract());
    address oracle = address(new IsContract());
    address instantPolicy = address(new IsContract());
    address escrow = address(new AmpleEscrow());

    MockERC20 asset = new MockERC20(6);
    MockShareToken share = new MockShareToken(18);

    Vault vault;
    IAsyncVault v;

    address controller = makeAddr("controller");
    address receiver = makeAddr("receiver");

    function setUp() public {
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.escrow.selector), abi.encode(escrow));

        vault = new Vault(
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
                    instantPolicy: IInstantPolicy(instantPolicy),
                    // No request policy: this is an instant-only vault.
                    requestPolicy: IRequestPolicy(address(0)),
                    liquidityRoute: ILiquidityRoute(address(0)),
                    settlementObserver: ISettlementObserver(address(0))
                })
            })
        );
        v = IAsyncVault(address(vault));

        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.vaultDetails.selector),
            abi.encode(VaultDetails(POOL, SC, ASSET_ID, address(asset), uint256(0), true))
        );
        vm.mockCall(oracle, abi.encodeWithSelector(IVaultOracle.prices.selector), abi.encode(ONE, ONE, true));
        share.setHook(actionHook);
        vm.mockCall(
            actionHook, abi.encodeWithSelector(IRoleHook.onRoles.selector), abi.encode(IRoleHook.onRoles.selector)
        );
        vm.mockCall(actionHook, abi.encodeWithSelector(IRoleHook.checkRoles.selector), abi.encode(true));
        vm.mockCall(
            actionHook,
            abi.encodeWithSelector(IRoleHook.maxAllowed.selector),
            abi.encode(type(uint256).max, type(uint256).max)
        );

        bytes4[6] memory voids = [
            ISpoke.noteDeposit.selector,
            ISpoke.issue.selector,
            ISpoke.revoke.selector,
            ISpoke.withdraw.selector,
            ISpoke.withdrawShares.selector,
            ISpoke.transferSharesFrom.selector
        ];
        for (uint256 i; i < voids.length; i++) {
            vm.mockCall(spoke, abi.encodeWithSelector(voids[i]), "");
        }
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.availableBalanceOf.selector), abi.encode(uint128(1_000_000e6)));

        vm.mockCall(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.maxInstantDeposit.selector),
            abi.encode(uint128(type(uint128).max))
        );
        vm.mockCall(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.maxInstantRedeem.selector),
            abi.encode(uint128(type(uint128).max))
        );
        vm.mockCall(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantDeposit.selector),
            abi.encode(int128(0), address(0))
        );
        vm.mockCall(instantPolicy, abi.encodeWithSelector(IInstantPolicy.onInstantDeposit.selector), "");
        vm.mockCall(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantRedeem.selector),
            abi.encode(int128(0), address(0))
        );
        vm.mockCall(instantPolicy, abi.encodeWithSelector(IInstantPolicy.onInstantRedeem.selector), "");
        vm.mockCall(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantDeposit.selector),
            abi.encode(int128(0), address(0))
        );
        vm.mockCall(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantRedeem.selector),
            abi.encode(int128(0), address(0))
        );
    }

    /// @dev The instant deposit lane works with no request policy set.
    function testInstantDepositWorksWithoutARequestPolicy() public {
        vm.prank(controller);
        uint256 shares = v.deposit(1_000e6, receiver);
        assertEq(shares, 1_000e18, "instant deposit priced and issued");
    }

    /// @dev And the instant redeem lane.
    function testInstantRedeemWorksWithoutARequestPolicy() public {
        vm.prank(controller);
        uint256 assets = v.redeem(1_000e18, receiver);
        assertEq(assets, 1_000e6, "instant redeem priced and paid");
    }

    /// @dev The async entrypoints are the only code that reaches the request policy, so they — and
    ///      only they — revert when it is unset.
    function testAsyncEntrypointsRevertWithoutARequestPolicy() public {
        vm.prank(controller);
        vm.expectRevert();
        v.requestDeposit(1_000e6, controller, controller);

        vm.prank(controller);
        vm.expectRevert();
        v.requestRedeem(1_000e18, controller, controller);
    }
}
