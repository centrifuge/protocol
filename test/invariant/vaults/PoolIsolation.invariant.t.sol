// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "../../../src/misc/types/D18.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {AssetId} from "../../../src/core/types/AssetId.sol";
import {PoolId, newPoolId} from "../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";
import {SpokeHandler} from "../../../src/core/spoke/SpokeHandler.sol";
import {IPoolEscrow} from "../../../src/core/spoke/interfaces/IPoolEscrow.sol";
import {VaultUpdateKind} from "../../../src/core/messaging/libraries/MessageLib.sol";

import {VaultBaseTest} from "../../integration/vaults/VaultBaseTest.sol";

import {AsyncVault} from "../../../src/vaults/AsyncVault.sol";
import {IBaseVault} from "../../../src/vaults/interfaces/IBaseVault.sol";
import {IAsyncRequestManager} from "../../../src/vaults/interfaces/IVaultManagers.sol";
import {RequestCallbackMessageLib} from "../../../src/vaults/libraries/RequestCallbackMessageLib.sol";

import "forge-std/Test.sol";

import {IShareToken} from "../../../src/token/interfaces/IShareToken.sol";
import {IShareTokenRegistrar} from "../../../src/token/interfaces/IShareTokenRegistrar.sol";

/// @dev Everything the handler is allowed to do, and the addresses it acts on. Pool B appears here only as a
///      *target* the fuzzer may aim at; no pool-B authority is ever handed over.
struct HandlerEnv {
    SpokeHandler spokeHandler;
    PoolId poolA;
    ShareClassId scIdA;
    AssetId assetId;
    address asset;
    address shareTokenA;
}

/// @notice The only `targetContract`. Every call it can make is an action POOL A is legitimately authorised
///         to perform: moving its own share token's ERC-7575 pointer (it holds a ward on its own token, which
///         the hub can grant over `RegistrarCall.UpdateWard`), and driving fulfillment callbacks that the
///         message layer authenticated for POOL A.
/// @dev    Every action swallows reverts: `fail_on_revert = false` would keep the run alive, but a reverting
///         call still burns a step of the sequence, and the two-step attack needs both steps to land.
contract PoolAHandler is Test {
    using CastLib for *;
    using RequestCallbackMessageLib for *;

    HandlerEnv internal env;

    address[] public actors;
    address[] public vaultTargets;

    uint256 public pointed;
    uint256 public fulfilledDeposits;
    uint256 public fulfilledRedeems;
    uint256 public repriced;

    constructor(HandlerEnv memory env_, address[] memory actors_, address[] memory vaultTargets_) {
        env = env_;
        actors = actors_;
        vaultTargets = vaultTargets_;
    }

    /// @dev Aims pool A's share token at one of a small set of vaults. Legal for pool A: it is a ward on its
    ///      own token. `vaultTargets` deliberately includes a foreign pool's vault.
    function pointShareToken(uint8 vaultSel) public {
        address target = vaultTargets[vaultSel % vaultTargets.length];
        (bool ok,) = env.shareTokenA.call(abi.encodeWithSelector(IShareToken.updateVault.selector, env.asset, target));
        if (ok) pointed++;
    }

    /// @dev A deposit fulfillment authenticated for POOL A, over the same path production uses.
    function fulfillDeposit(uint128 assets, uint128 shares, uint8 who) public {
        bytes memory payload = RequestCallbackMessageLib.FulfilledDepositRequest({
                investor: actors[who % actors.length].toBytes32(),
                fulfilledAssetAmount: uint128(_bound(assets, 1, 1e12)),
                fulfilledShareAmount: uint128(_bound(shares, 1, 1e12)),
                cancelledAssetAmount: 0
            }).serialize();

        if (_callback(payload)) fulfilledDeposits++;
    }

    /// @dev A redeem fulfillment authenticated for POOL A.
    function fulfillRedeem(uint128 assets, uint128 shares, uint8 who) public {
        bytes memory payload = RequestCallbackMessageLib.FulfilledRedeemRequest({
                investor: actors[who % actors.length].toBytes32(),
                fulfilledAssetAmount: uint128(_bound(assets, 1, 1e12)),
                fulfilledShareAmount: uint128(_bound(shares, 1, 1e12)),
                cancelledShareAmount: 0
            }).serialize();

        if (_callback(payload)) fulfilledRedeems++;
    }

    /// @dev Pool A approving its own deposits.
    function approveDeposits(uint128 assets) public {
        _callback(
            RequestCallbackMessageLib.ApprovedDeposits({
                    assetAmount: uint128(_bound(assets, 1, 1e12)), pricePoolPerAsset: d18(1, 1).raw()
                }).serialize()
        );
    }

    /// @dev Pool A issuing its own shares.
    function issueShares(uint128 shares) public {
        _callback(
            RequestCallbackMessageLib.IssuedShares({
                    shareAmount: uint128(_bound(shares, 1, 1e12)), pricePoolPerShare: d18(1, 1).raw()
                }).serialize()
        );
    }

    /// @dev Pool A repricing its own share class.
    function updatePrice(uint128 price) public {
        (bool ok,) = address(env.spokeHandler)
            .call(
                abi.encodeWithSelector(
                    SpokeHandler.updatePricePoolPerShare.selector,
                    env.poolA,
                    env.scIdA,
                    D18.wrap(uint128(_bound(price, 1e16, 1e20))),
                    uint64(block.timestamp)
                )
            );
        if (ok) repriced++;
    }

    function _callback(bytes memory payload) internal returns (bool ok) {
        (ok,) = address(env.spokeHandler)
            .call(
                abi.encodeWithSelector(
                    SpokeHandler.requestCallback.selector, env.poolA, env.scIdA, env.assetId, payload
                )
            );
    }
}

/// @notice Pool isolation invariant: nothing POOL A is authorised to do may move POOL B's state.
/// @dev    Catches `AsyncRequestManager._requestVault` resolving a callback's vault through the share token's
///         ERC-7575 pointer without checking the resolved vault belongs to the callback's (pool, share class,
///         asset) tuple.
contract PoolIsolationInvariantTest is VaultBaseTest {
    using CastLib for *;

    /// @dev Pool B's observable footprint, kept field-by-field so a failure can be localised.
    struct Footprint {
        uint128 escrowHolding;
        uint128 escrowReserved;
        uint256 shareSupply;
        uint256 escrowShares;
        uint128[] maxMint;
        uint128[] maxWithdraw;
        uint128[] pendingDeposit;
        uint128[] pendingRedeem;
        uint128[] claimableCancelDeposit;
        uint128[] claimableCancelRedeem;
    }

    PoolId public POOL_B;
    ShareClassId public scIdA;
    ShareClassId public scIdB;
    AssetId public assetId;

    AsyncVault public vaultA;
    AsyncVault public vaultB;

    PoolAHandler public handler;

    address[] internal actors;
    bytes32 internal snapshotB;
    Footprint internal baselineB;

    address internal investorB1 = makeAddr("investorB1");
    address internal investorB2 = makeAddr("investorB2");
    address internal investorA1 = makeAddr("investorA1");

    function setUp() public override {
        super.setUp();

        scIdA = ShareClassId.wrap(defaultShareClassId);
        (, address vaultA_, uint128 assetId_) = deploySimpleVault(asyncVaultFactory);
        vaultA = AsyncVault(vaultA_);
        assetId = AssetId.wrap(assetId_);

        // --- Pool B: a second, unrelated pool on the same spoke, sharing the same asset ---
        POOL_B = newPoolId(OTHER_CHAIN_ID, 2);
        scIdB = ShareClassId.wrap(bytes16(bytes("2")));

        subsidyManager.deposit{value: 0.5 ether}(POOL_B);
        centrifugeChain.addPool(POOL_B.raw());
        spokeRegistry.updateManager(POOL_B, address(this), true);
        multiAdapter.setAdapters(OTHER_CHAIN_ID, POOL_B, testAdapters, uint8(testAdapters.length), 1);

        vaultB = AsyncVault(_deployVaultFor(POOL_B, scIdB.raw(), address(erc20)));

        // --- Real pool B state, so there is something to lose ---
        // A settled investor: funds the escrow and puts shares into circulation.
        deposit(address(vaultB), investorB1, 10e6, true);

        // A pending redeem, and a pending deposit that has not been fulfilled. The pending deposit is the
        // precondition the hijacked callback needs, and is ordinary pool B state.
        _requestRedeem(vaultB, investorB1, 4e6);
        _requestDeposit(vaultB, investorB2, 7e6);

        // Pool A gets a pending request too, so the honest callback path is reachable as well.
        _requestDeposit(vaultA, investorA1, 3e6);

        // --- Handler: pool A authority only ---
        actors.push(investorB1);
        actors.push(investorB2);
        actors.push(investorA1);

        address[] memory vaultTargets = new address[](3);
        vaultTargets[0] = address(0);
        vaultTargets[1] = address(vaultA);
        vaultTargets[2] = address(vaultB);

        address shareTokenA = address(spokeRegistry.shareToken(POOL_A, scIdA));
        handler = new PoolAHandler(
            HandlerEnv({
                spokeHandler: spokeHandler,
                poolA: POOL_A,
                scIdA: scIdA,
                assetId: assetId,
                asset: address(erc20),
                shareTokenA: shareTokenA
            }),
            actors,
            vaultTargets
        );

        // The message layer authenticates these callbacks as POOL A's; the handler stands in for that.
        spokeHandler.rely(address(handler));

        // Pool A grants a ward on its OWN share token, which the hub can do over `RegistrarCall.UpdateWard`.
        // Nothing here touches pool B.
        vm.prank(shareTokenRegistrar.envoy());
        shareTokenRegistrar.fromHub(
            POOL_A,
            abi.encode(uint8(IShareTokenRegistrar.RegistrarCall.UpdateWard), scIdA.raw(), address(handler), true)
        );

        baselineB = _footprintFields(POOL_B);
        snapshotB = _footprint(POOL_B);

        targetContract(address(handler));
    }

    //----------------------------------------------------------------------------------------------
    // Invariant
    //----------------------------------------------------------------------------------------------

    function invariant_poolB_untouched() public view {
        assertEq(_footprint(POOL_B), snapshotB, "a pool A action changed pool B state");
    }

    /// @dev Not an invariant: run it by hand (or from a failing sequence) to localise which field moved.
    function _debugDiff() internal view {
        Footprint memory f = _footprintFields(POOL_B);
        assertEq(f.escrowHolding, baselineB.escrowHolding, "pool B escrow holding");
        assertEq(f.escrowReserved, baselineB.escrowReserved, "pool B escrow reserved");
        assertEq(f.shareSupply, baselineB.shareSupply, "pool B share supply");
        assertEq(f.escrowShares, baselineB.escrowShares, "pool B escrow share balance");
        for (uint256 i; i < actors.length; i++) {
            assertEq(f.maxMint[i], baselineB.maxMint[i], "pool B maxMint");
            assertEq(f.maxWithdraw[i], baselineB.maxWithdraw[i], "pool B maxWithdraw");
            assertEq(f.pendingDeposit[i], baselineB.pendingDeposit[i], "pool B pendingDepositRequest");
            assertEq(f.pendingRedeem[i], baselineB.pendingRedeem[i], "pool B pendingRedeemRequest");
            assertEq(f.claimableCancelDeposit[i], baselineB.claimableCancelDeposit[i], "pool B claimableCancelDeposit");
            assertEq(f.claimableCancelRedeem[i], baselineB.claimableCancelRedeem[i], "pool B claimableCancelRedeem");
        }
    }

    function test_debugDiff() public view {
        _debugDiff();
    }

    //----------------------------------------------------------------------------------------------
    // Footprint
    //----------------------------------------------------------------------------------------------

    function _footprint(PoolId poolId) internal view returns (bytes32) {
        Footprint memory f = _footprintFields(poolId);
        return keccak256(abi.encode(f));
    }

    function _footprintFields(PoolId poolId) internal view returns (Footprint memory f) {
        IPoolEscrow escrow = spoke.escrow(poolId);
        (f.escrowHolding, f.escrowReserved) = escrow.holding(scIdB, address(erc20), 0);

        IShareToken shareToken = IShareToken(address(spokeRegistry.shareToken(poolId, scIdB)));
        f.shareSupply = shareToken.totalSupply();
        f.escrowShares = shareToken.balanceOf(address(escrow));

        uint256 n = actors.length;
        f.maxMint = new uint128[](n);
        f.maxWithdraw = new uint128[](n);
        f.pendingDeposit = new uint128[](n);
        f.pendingRedeem = new uint128[](n);
        f.claimableCancelDeposit = new uint128[](n);
        f.claimableCancelRedeem = new uint128[](n);

        for (uint256 i; i < n; i++) {
            (
                f.maxMint[i],
                f.maxWithdraw[i],,,
                f.pendingDeposit[i],
                f.pendingRedeem[i],
                f.claimableCancelDeposit[i],
                f.claimableCancelRedeem[i],,
            ) = IAsyncRequestManager(address(asyncRequestManager)).investments(IBaseVault(address(vaultB)), actors[i]);
        }
    }

    //----------------------------------------------------------------------------------------------
    // Setup helpers
    //----------------------------------------------------------------------------------------------

    /// @dev `deploySimpleVault` is hardcoded to POOL_A; this is the same walk, parameterised by pool.
    function _deployVaultFor(PoolId poolId, bytes16 scId, address asset) internal returns (address vaultAddress) {
        if (!spokeRegistry.hasShareClass(poolId, ShareClassId.wrap(scId))) {
            centrifugeChain.addShareClass(poolId.raw(), scId, "name", "symbol", 6, address(fullRestrictionsHook));
            centrifugeChain.updatePricePoolPerShare(poolId.raw(), scId, uint128(10 ** 18), uint64(block.timestamp));
        }

        uint128 assetId_ = spokeRegistry.assetToId(asset, 0).raw();
        centrifugeChain.updatePricePoolPerAsset(
            poolId.raw(), scId, assetId_, uint128(10 ** 18), uint64(block.timestamp)
        );

        if (address(spokeRegistry.requestManager(poolId)) == address(0)) {
            spokeRegistry.setRequestManager(poolId, asyncRequestManager);
        }
        spokeRegistry.updateManager(poolId, address(asyncRequestManager), true);
        spokeRegistry.updateManager(poolId, address(syncManager), true);

        syncManager.setMaxReserve(poolId, ShareClassId.wrap(scId), asset, 0, type(uint128).max);

        vm.recordLogs();
        spokeHandler.updateVault(
            poolId,
            ShareClassId.wrap(scId),
            AssetId.wrap(assetId_),
            address(asyncVaultFactory),
            VaultUpdateKind.DeployAndLink,
            bytes("")
        );
        vaultAddress = _deployedVaultFromLogs();

        vm.prank(shareTokenRegistrar.envoy());
        shareTokenRegistrar.fromHub(
            poolId, abi.encode(uint8(IShareTokenRegistrar.RegistrarCall.SetVault), scId, assetId_, vaultAddress)
        );
    }

    function _requestDeposit(AsyncVault vault, address user, uint256 amount) internal {
        erc20.mint(user, amount);
        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), user, type(uint64).max);
        vm.startPrank(user);
        erc20.approve(address(vault), amount);
        vault.requestDeposit(amount, user, user);
        vm.stopPrank();
    }

    function _requestRedeem(AsyncVault vault, address user, uint256 shares) internal {
        vm.startPrank(user);
        IShareToken(vault.share()).approve(address(vault), shares);
        vault.requestRedeem(shares, user, user);
        vm.stopPrank();
    }
}
