// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AmpleEscrow, IsContract, MockERC20, MockShareToken} from "./Vault.t.sol";

import {D18} from "../../src/misc/types/D18.sol";
import {MathLib} from "../../src/misc/libraries/MathLib.sol";

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
import {IVaultOracle} from "../../src/vaults/oracles/interfaces/IVaultOracle.sol";
import {PerPeriodPolicy, PerRequestPolicy} from "../../src/vaults/policies/RequestPolicies.sol";
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

interface ICoolCheatcode {
    function cool(address target) external;
}

/// @title  Fold horizon gas
/// @notice What claims, views and the eager-fold hub callback cost now that nothing walks a controller's
///         open positions: they read the pending totals and fold only the auto-fold horizon. Measured
///         cold: every vault and policy slot is cooled before the call. Everything outside the vault is
///         mocked, so the figures are the vault's own cost; a live claim adds the spoke's share transfer
///         and the token hook. Run with `-vv` to print the tables.
contract FoldHorizonGasTest is Test {
    PoolId constant POOL = PoolId.wrap(1);
    ShareClassId constant SC = ShareClassId.wrap(bytes16("sc1"));
    AssetId immutable ASSET_ID = newAssetId(0, 1);
    D18 constant ONE = D18.wrap(1e18);
    uint64 constant WINDOW = 1 days;

    /// @dev The largest horizon the test budgets allow.
    uint256 constant MAX_HORIZON = 16;
    /// @dev A claim folding a full horizon of settled shared windows on both sides, and a view over it.
    uint256 constant CLAIM_BUDGET = 2_000_000;
    uint256 constant VIEW_BUDGET = 1_000_000;
    /// @dev What `GasService` adds over the heaviest benchmarked message, settled at the non-batching default horizon of 1.
    uint256 constant GAS_SERVICE_MARGIN = 25_000;
    /// @dev The largest unbatched horizon whose settlement fold fits that margin without the fill's `extraGasLimit`.
    uint256 constant UNFUNDED_HORIZON = 8;
    /// @dev How much a claim or view may vary with the number of open positions outside the horizon.
    uint256 constant FLAT_TOLERANCE = 2_000;

    address spoke = address(new IsContract());
    address spokeRegistry = address(new IsContract());
    address actionHook = address(new IsContract());
    address router = address(new IsContract());
    address oracle = address(new IsContract());
    address instantPolicy = address(new IsContract());
    address escrow = address(new AmpleEscrow());

    MockERC20 asset = new MockERC20(6);
    MockShareToken share = new MockShareToken(18);

    Vault vault;
    address policy;
    bool batching;

    address controller = makeAddr("controller");
    address other = makeAddr("other");

    struct Row {
        uint256 claim;
        uint256 maxDeposit;
        uint256 pending;
        uint256 claimable;
    }

    function setUp() public {
        vm.warp(1_000_000);
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.escrow.selector), abi.encode(escrow));
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.vaultDetails.selector),
            abi.encode(VaultDetails(POOL, SC, ASSET_ID, address(asset), uint256(0), true))
        );
        vm.mockCall(spokeRegistry, abi.encodeWithSelector(ISpokeRegistry.requestManager.selector), abi.encode(router));
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
        vm.mockCall(router, abi.encodeWithSelector(IVaultRequestManager.sendDepositRequest.selector), "");
        vm.mockCall(oracle, abi.encodeWithSelector(IVaultOracle.prices.selector), abi.encode(ONE, ONE, true));
        vm.mockCall(router, abi.encodeWithSelector(IVaultRequestManager.sendRedeemRequest.selector), "");
        bytes4[7] memory voids = [
            ISpoke.noteDeposit.selector,
            ISpoke.reserve.selector,
            ISpoke.unreserve.selector,
            ISpoke.issue.selector,
            ISpoke.withdrawShares.selector,
            ISpoke.transferSharesFrom.selector,
            ISpoke.revoke.selector
        ];
        for (uint256 i; i < voids.length; i++) {
            vm.mockCall(spoke, abi.encodeWithSelector(voids[i]), "");
        }
    }

    //----------------------------------------------------------------------------------------------
    // Independence from the number of open positions
    //----------------------------------------------------------------------------------------------

    /// @dev Default horizon, N open positions: per-request ones the hub has not answered except the
    ///      latest, per-period windows shared with a second contributor, all settled and unfolded but
    ///      the latest. The claim folds one entry whatever N is.
    function testClaimsAndViewsDoNotGrowWithOpenPositions() public {
        _flatTable("per-request", false);
        _flatTable("per-period", true);
    }

    function _flatTable(string memory label, bool batching_) internal {
        uint256[4] memory counts = [uint256(1), 16, 64, 256];
        console.log(label);
        console.log("    N      claim  maxDeposit  pending(0)  claimableMint");
        Row memory first;
        for (uint256 i; i < counts.length; i++) {
            uint256 state = vm.snapshotState();
            _deploy(batching_, 1);
            _open(counts[i]);
            _settleAll(counts[i]);
            Row memory r = _measure();
            _print(counts[i], r);
            if (i == 0) first = r;
            else _assertFlat(first, r);
            vm.revertToState(state);
        }
    }

    function _assertFlat(Row memory a, Row memory b) internal pure {
        assertApproxEqAbs(b.claim, a.claim, FLAT_TOLERANCE, "claim grew with open positions");
        assertApproxEqAbs(b.maxDeposit, a.maxDeposit, FLAT_TOLERANCE, "maxDeposit grew with open positions");
        assertApproxEqAbs(b.pending, a.pending, FLAT_TOLERANCE, "pending grew with open positions");
        assertApproxEqAbs(b.claimable, a.claimable, FLAT_TOLERANCE, "claimableMint grew with open positions");
    }

    //----------------------------------------------------------------------------------------------
    // Cost of the horizon
    //----------------------------------------------------------------------------------------------

    /// @dev Per-period, a horizon of H windows on each side, every one settled and unfolded: the most work
    ///      a claim can find, since a claim folds both sides. Held to the budgets at the largest horizon.
    function testClaimAndViewsScaleWithTheHorizon() public {
        uint256[4] memory horizons = [uint256(1), 4, 8, MAX_HORIZON];
        console.log("per-period, full horizon of settled windows");
        console.log("    H      claim  maxDeposit  pending(0)  claimableMint");
        for (uint256 i; i < horizons.length; i++) {
            uint256 state = vm.snapshotState();
            _deploy(true, horizons[i]);
            _openBothSides(horizons[i]);
            Row memory r = _measure();
            _print(horizons[i], r);
            if (horizons[i] == MAX_HORIZON) {
                assertLt(r.claim, CLAIM_BUDGET, "claim at the largest horizon");
                assertLt(_maxView(r), VIEW_BUDGET, "view at the largest horizon");
            }
            vm.revertToState(state);
        }
    }

    //----------------------------------------------------------------------------------------------
    // Hub callback
    //----------------------------------------------------------------------------------------------

    /// @dev The per-request eager fold is one bucket's fold, whatever else the controller holds open.
    function testEagerFoldCallbackIsFlat() public {
        uint256[4] memory counts = [uint256(1), 16, 64, 256];
        console.log("per-request eager-fold callback (fulfillDepositRequest)");
        console.log("    N       used");
        uint256 first;
        for (uint256 i; i < counts.length; i++) {
            uint256 state = vm.snapshotState();
            _deploy(false, 1);
            _open(counts[i] + 1);
            _fulfill(1, 1e6);
            uint256 used = _fulfillCold(2);
            console.log(string.concat(_pad(counts[i], 5), _pad(used, 11)));
            if (i == 0) first = used;
            else assertApproxEqAbs(used, first, FLAT_TOLERANCE, "callback grew with open positions");
            vm.revertToState(state);
        }
    }

    /// @dev Settling an own position completes its fold, which loads and rewrites the owner's whole horizon, so the
    ///      callback grows by about two thousand gas an entry, and a stranger's gifts can fill the slots the owner
    ///      leaves free. Past horizon 1 the growth only has the `GasService` margin, and beyond `UNFUNDED_HORIZON` the
    ///      manager funds it with `extraGasLimit`.
    function testEagerFoldCallbackAtAFullHorizon() public {
        uint256[4] memory horizons = [uint256(1), UNFUNDED_HORIZON, MAX_HORIZON, 64];
        console.log("per-request eager-fold callback, latest of H own positions");
        console.log("    H       used     growth");
        uint256 base;
        for (uint256 i; i < horizons.length; i++) {
            uint256 state = vm.snapshotState();
            _deploy(false, horizons[i]);
            _open(horizons[i]);
            uint256 used = _fulfillCold(uint96(horizons[i]));
            if (i == 0) base = used;
            console.log(string.concat(_pad(horizons[i], 5), _pad(used, 11), _pad(used - base, 11)));
            if (horizons[i] <= UNFUNDED_HORIZON) assertLt(used - base, GAS_SERVICE_MARGIN, "fold past the margin");
            vm.revertToState(state);
        }
    }

    function _fulfillCold(uint96 localId) internal returns (uint256 used) {
        vm.startPrank(router);
        IVaultDepositCallbacks(address(vault)).approveDeposits(localId, 1e6);
        IVaultDepositCallbacks(address(vault)).issueShares(localId, 1e18);
        _cool();
        uint256 g = gasleft();
        IVaultDepositCallbacks(address(vault)).fulfillDepositRequest(localId, 1e6, 1e18);
        used = g - gasleft();
        vm.stopPrank();
    }

    //----------------------------------------------------------------------------------------------
    // Fixture
    //----------------------------------------------------------------------------------------------

    function _deploy(bool batching_, uint256 horizon) internal {
        batching = batching_;
        policy = batching_ ? address(new PerPeriodPolicy(WINDOW, 0, 0, 0)) : address(new PerRequestPolicy(true));
        VaultConfig memory config = VaultConfig({
            foldHorizon: horizon,
            spoke: ISpoke(spoke),
            spokeRegistry: ISpokeRegistry(spokeRegistry),
            plugins: VaultPlugins({
                oracle: IVaultOracle(oracle),
                instantPolicy: IInstantPolicy(instantPolicy),
                requestPolicy: IRequestPolicy(policy),
                liquidityRoute: ILiquidityRoute(address(0)),
                settlementObserver: ISettlementObserver(address(0))
            })
        });
        vault = new Vault(POOL, SC, address(asset), ASSET_ID, IShareToken(address(share)), config);
    }

    /// @dev Opens `n` own positions for the controller, local ids 1..n in order, all flushed.
    ///      Per-period takes one window each, shared with `other`.
    function _open(uint256 n) internal {
        for (uint256 i; i < n; i++) {
            if (batching) vm.warp(block.timestamp + WINDOW);
            _request(controller);
            if (batching) _request(other);
        }
        if (batching) {
            vm.warp(block.timestamp + WINDOW);
            IAsyncVault(address(vault)).flushRequest(uint96(n));
        }
    }

    /// @dev `n` windows, each with a deposit and a redemption from the controller and `other`, all
    ///      settled and none folded: deposit buckets get odd local ids, redeem buckets even ones.
    function _openBothSides(uint256 n) internal {
        for (uint256 i; i < n; i++) {
            vm.warp(block.timestamp + WINDOW);
            _request(controller);
            _request(other);
            _requestRedeem(controller);
            _requestRedeem(other);
        }
        vm.warp(block.timestamp + WINDOW);
        IAsyncVault(address(vault)).flushRequest(uint96(2 * n - 1));
        IAsyncVault(address(vault)).flushRequest(uint96(2 * n));
        for (uint96 id = 1; id <= 2 * n; id += 2) {
            _fulfill(id, 2e6);
            vm.startPrank(router);
            IVaultRedeemCallbacks(address(vault)).revokeShares(id + 1, 2e6, 2e18);
            IVaultRedeemCallbacks(address(vault)).fulfillRedeemRequest(id + 1, 2e6, 2e18);
            vm.stopPrank();
        }
    }

    function _requestRedeem(address who) internal {
        vm.prank(who);
        IAsyncVault(address(vault)).requestRedeem(1e18, who, who);
    }

    function _request(address who) internal {
        vm.prank(who);
        IAsyncVault(address(vault)).requestDeposit(1e6, who, who);
    }

    /// @dev Per-period: every window fully settled. Per-request: only the latest, the rest unanswered.
    function _settleAll(uint256 n) internal {
        if (!batching) return _fulfill(uint96(n), 1e6);
        for (uint96 id = 1; id <= n; id++) {
            _fulfill(id, 2e6);
        }
    }

    function _fulfill(uint96 localId, uint128 assets) internal {
        vm.startPrank(router);
        IVaultDepositCallbacks(address(vault)).approveDeposits(localId, assets);
        IVaultDepositCallbacks(address(vault)).issueShares(localId, uint128(assets) * 1e12);
        IVaultDepositCallbacks(address(vault)).fulfillDepositRequest(localId, assets, uint128(assets) * 1e12);
        vm.stopPrank();
    }

    function _measure() internal returns (Row memory r) {
        _cool();
        uint256 g = gasleft();
        IAsyncVault(address(vault)).maxDeposit(controller);
        r.maxDeposit = g - gasleft();

        _cool();
        g = gasleft();
        IAsyncVault(address(vault)).pendingDepositRequest(0, controller);
        r.pending = g - gasleft();

        _cool();
        g = gasleft();
        IAsyncVault(address(vault)).claimableMint(controller);
        r.claimable = g - gasleft();

        _cool();
        vm.prank(controller);
        g = gasleft();
        IAsyncVault(address(vault)).deposit(1e3, controller, controller);
        r.claim = g - gasleft();
    }

    function _print(uint256 n, Row memory r) internal pure {
        console.log(
            string.concat(
                _pad(n, 5), _pad(r.claim, 11), _pad(r.maxDeposit, 12), _pad(r.pending, 12), _pad(r.claimable, 13)
            )
        );
    }

    function _cool() internal {
        ICoolCheatcode(address(vm)).cool(address(vault));
        ICoolCheatcode(address(vm)).cool(policy);
    }

    function _maxView(Row memory r) internal pure returns (uint256) {
        return MathLib.max(MathLib.max(r.maxDeposit, r.pending), r.claimable);
    }

    function _pad(uint256 value, uint256 width) internal pure returns (string memory s) {
        s = vm.toString(value);
        while (bytes(s).length < width) {
            s = string.concat(" ", s);
        }
    }
}
