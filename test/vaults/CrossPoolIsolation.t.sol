// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IsContract, MockShareToken} from "./Vault.t.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {newAssetId} from "../../src/core/types/AssetId.sol";
import {ISpoke} from "../../src/core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {VaultDetails, ISpokeRegistry} from "../../src/core/spoke/interfaces/ISpokeRegistry.sol";

import {IAccountingToken} from "../../src/managers/spoke/interfaces/IAccountingToken.sol";

import {BasinLiquidityRoute} from "../../src/vaults/liquidity/BasinLiquidityRoute.sol";
import {ReserveInstantPolicy} from "../../src/vaults/policies/ReserveInstantPolicy.sol";
import {IReserveInstantPolicy} from "../../src/vaults/policies/interfaces/IVaultPlugins.sol";
import {IBasinLiquidityRoute, IGroveBasinLike} from "../../src/vaults/liquidity/interfaces/IBasinLiquidityRoute.sol";

import "forge-std/Test.sol";

/// @dev A contract that satisfies the vault surface these policies touch, and answers `poolId()`
///      differently depending on when it is asked: the pool whose manager deployed it while the
///      Envoy validates, the victim pool once the policy is acting on its answers.
contract LyingVault {
    PoolId public declaredPool;
    PoolId public targetPool;
    ShareClassId public targetShareClass;
    address public share;
    address public asset;
    bool public lying;

    constructor(PoolId declared, PoolId target, ShareClassId targetSc, address share_) {
        declaredPool = declared;
        targetPool = target;
        targetShareClass = targetSc;
        share = share_;
        asset = share_;
    }

    function startLying() external {
        lying = true;
    }

    function poolId() external view returns (PoolId) {
        return lying ? targetPool : declaredPool;
    }

    function scId() external view returns (ShareClassId) {
        return targetShareClass;
    }

    function isOperator(address, address) external pure returns (bool) {
        return true;
    }

    function convertToShares(uint256 assets) external pure returns (uint256) {
        return assets;
    }

    function drawFrom(BasinLiquidityRoute source, uint128 assets) external {
        source.provide(address(this), assets);
    }
}

/// @dev The threat model: a manager of pool A, using only what their own pool grants them, reaching
///      state that belongs to pool B.
///
///      These policies are shared per-network singletons — every mapping is keyed by vault — and they
///      hold balance-sheet manager rights on each pool that uses them. That makes the question of
///      *which pool a vault belongs to* a security boundary, and the vault is the one party that must
///      not answer it: the address is chosen by whoever configures the policy, and a contract can
///      answer one way while the Envoy validates and another once it is being acted on. Every one of
///      these reads goes to the SpokeRegistry, which is the sole authority on the association and
///      does not know a fabricated vault at all.
contract CrossPoolIsolationTest is Test {
    PoolId constant POOL_A = PoolId.wrap(1);
    PoolId constant POOL_B = PoolId.wrap(2);
    ShareClassId constant SC_B = ShareClassId.wrap(bytes16("scB"));

    address spoke = address(new IsContract());
    address spokeRegistry = address(new IsContract());
    address envoy = makeAddr("envoy");
    address attacker = makeAddr("attackerOfPoolA");

    MockShareToken share = new MockShareToken(18);
    LyingVault fake;

    function setUp() public {
        fake = new LyingVault(POOL_A, POOL_B, SC_B, address(share));

        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.spokeRegistry.selector), abi.encode(spokeRegistry));
        // The registry has never heard of this address, so it reports the zero pool.
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.vaultDetails.selector, address(fake)),
            abi.encode(
                VaultDetails(
                    PoolId.wrap(0), ShareClassId.wrap(bytes16(0)), newAssetId(0, 0), address(0), uint256(0), false
                )
            )
        );
    }

    /// @dev The liquidity route names both the escrow that receives a draw and the asset drawn, so a
    ///      fabricated vault would otherwise move a venue's funds into a pool of its choosing.
    function testLiquidityRouteRejectsAVaultThePoolDoesNotOwn() public {
        BasinLiquidityRoute source = new BasinLiquidityRoute(
            IGroveBasinLike(makeAddr("basin")),
            ISpoke(spoke),
            envoy,
            IAccountingToken(makeAddr("accountingToken")),
            makeAddr("root")
        );

        vm.prank(envoy);
        vm.expectRevert(IBasinLiquidityRoute.WrongPool.selector);
        source.fromHub(POOL_A, abi.encode(address(fake), uint128(1_000e6)));

        fake.startLying();
        vm.expectRevert(IBasinLiquidityRoute.ExceedsLimit.selector);
        fake.drawFrom(source, 1_000e6);
    }

    function testInstantPolicyRejectsAVaultThePoolDoesNotOwn() public {
        ReserveInstantPolicy policy = new ReserveInstantPolicy(ISpoke(spoke), envoy);

        vm.prank(envoy);
        vm.expectRevert(IReserveInstantPolicy.WrongPool.selector);
        policy.fromHub(
            POOL_A,
            abi.encode(
                IReserveInstantPolicy.ConfigKind.Terms,
                address(fake),
                abi.encode(makeAddr("recipient"), uint16(0), uint16(0), true, false, false, uint128(1))
            )
        );
    }

    /// @dev The registry answer is what the check now rests on, and it disagrees with the vault: this
    ///      is the discrepancy the whole family of attacks lived in.
    function testTheVaultAndTheRegistryDisagree() public view {
        assertEq(PoolId.unwrap(fake.poolId()), PoolId.unwrap(POOL_A), "the vault answers whatever it likes");
        assertEq(
            PoolId.unwrap(ISpokeRegistry(spokeRegistry).vaultDetails(address(fake)).poolId),
            0,
            "the registry does not know it"
        );
    }
}
