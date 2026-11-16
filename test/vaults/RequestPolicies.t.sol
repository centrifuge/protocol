// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IsContract} from "./Vault.t.sol";

import {CastLib} from "../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {newAssetId} from "../../src/core/types/AssetId.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {ISpokeRegistry, VaultDetails} from "../../src/core/spoke/interfaces/ISpokeRegistry.sol";

import {IVault} from "../../src/vaults/interfaces/IVault.sol";
import {PerInvestorPolicy, PerPeriodPolicy, PerRequestPolicy} from "../../src/vaults/policies/RequestPolicies.sol";
import {
    IPerInvestorPolicy,
    IPerRequestPolicy,
    IPerPeriodPolicy
} from "../../src/vaults/policies/interfaces/IRequestPolicies.sol";

import "forge-std/Test.sol";

/// @dev The request policies. `PerInvestorPolicy` is the default one every vault gets unless a pool asks for
///      something else.
contract RequestPoliciesTest is Test {
    address vault = address(new IsContract());
    address otherVault = address(new IsContract());
    address controller = makeAddr("controller");
    address other = makeAddr("other");
    address envoy = makeAddr("envoy");
    address spokeRegistry = address(new IsContract());
    PoolId constant POOL = PoolId.wrap(1);

    PerInvestorPolicy perInvestor = new PerInvestorPolicy();
    PerRequestPolicy perRequest = new PerRequestPolicy(true);
    PerPeriodPolicy perPeriod = new PerPeriodPolicy(1 days, 14 hours, 0, 0);

    function setUp() public {
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.vaultDetails.selector, vault),
            abi.encode(VaultDetails(POOL, ShareClassId.wrap(bytes16("sc")), newAssetId(0, 1), address(0), 0, true))
        );
        vm.mockCall(vault, abi.encodeWithSelector(IVault.poolId.selector), abi.encode(POOL));
        vm.mockCall(vault, abi.encodeWithSelector(IVault.scId.selector), abi.encode(ShareClassId.wrap(bytes16("sc"))));
    }

    //----------------------------------------------------------------------------------------------
    // PerInvestorPolicy
    //----------------------------------------------------------------------------------------------

    /// @dev Constructor-fixed config is announced, since an indexer cannot call the views.
    function testConstructorsAnnounceTheirConfig() public {
        vm.expectEmit(vm.computeCreateAddress(address(this), vm.getNonce(address(this))));
        emit IPerRequestPolicy.PerRequestConfigured(true);
        new PerRequestPolicy(true);

        vm.expectEmit(vm.computeCreateAddress(address(this), vm.getNonce(address(this))));
        emit IPerPeriodPolicy.PerPeriodConfigured(1 days, 14 hours, 0, 0);
        new PerPeriodPolicy(1 days, 14 hours, 0, 0);
    }

    /// @dev One bucket per controller per side, so repeat requests keep extending a single hub-side
    ///      position instead of opening a new one each time. That is the whole point of the default. The key is
    ///      the controller, the same on both sides, since the vault keys buckets per side.
    function testPerInvestorKeysTheBucketByTheController(address who) public view {
        bytes32 key = perInvestor.onRequest(vault, who, who, true, 1e6);
        bytes32 again = perInvestor.onRequest(otherVault, who, other, false, 5e6);
        bytes32 otherKey = perInvestor.onRequest(vault, other, other, true, 1e6);

        assertEq(key, CastLib.toBytes32(who), "the controller is the key");
        assertEq(again, key, "whatever the vault, side, payer or amount");
        if (who != other) assertNotEq(otherKey, key, "two controllers are two buckets");
        assertFalse(perInvestor.isBatched(), "non-batching: the request flushes in the same transaction");
    }

    /// @dev Whether a vault lets pending requests change hands, and advertises ERC-8161, follows the policy. A per-investor
    ///      bucket is the controller's own, so a transfer would have to move the bucket rather than a contribution.
    function testPoliciesSayWhetherTheyAllowTransfers() public {
        assertFalse(perInvestor.supportsTransfers());
        assertTrue(perPeriod.supportsTransfers());
        assertTrue(new PerRequestPolicy(true).supportsTransfers());
        assertFalse(new PerRequestPolicy(false).supportsTransfers());
    }

    function testPerInvestorAlwaysAllowsFlush(bytes32 key) public view {
        assertTrue(perInvestor.isClosed(vault, key));
    }

    //----------------------------------------------------------------------------------------------
    // PerRequestPolicy
    //----------------------------------------------------------------------------------------------

    /// @dev The zero key: the vault opens a fresh bucket for every request, so this policy keeps nothing.
    function testPerRequestAsksForAFreshBucketEveryTime() public view {
        assertEq(perRequest.onRequest(vault, controller, controller, true, 1e6), 0, "a fresh bucket");
        assertFalse(perRequest.isBatched());
    }

    /// @dev And the open shape still trades, so the flag picks a shape rather than removing one.
    function testPerRequestTransfersWhenEnabled() public view {
        assertTrue(perRequest.supportsTransfers());
    }

    //----------------------------------------------------------------------------------------------
    // PerPeriodPolicy
    //----------------------------------------------------------------------------------------------

    /// @dev A request is keyed by the window it lands in, whoever makes it, and the window reads closed once it has
    ///      elapsed. The policy keeps nothing: which batch to send is the vault's to track.
    function testPerPeriodKeysARequestByItsWindow() public {
        vm.warp(10 days);
        bytes32 first = perPeriod.onRequest(vault, controller, controller, true, 1e6);
        assertEq(perPeriod.onRequest(otherVault, other, other, false, 1e6), first, "any vault, side or controller");
        assertFalse(perPeriod.isClosed(vault, first), "the open window");

        vm.warp(11 days);
        bytes32 second = perPeriod.onRequest(vault, controller, controller, true, 1e6);
        assertEq(uint256(second), uint256(first) + 1, "the next window");
        assertTrue(perPeriod.isClosed(vault, first), "the elapsed window");
        assertFalse(perPeriod.isClosed(vault, 0), "zero names no window");
    }

    function testPerPeriodRejectsAnOffsetOutsideItsWindow() public {
        vm.expectRevert(IPerPeriodPolicy.InvalidOffset.selector);
        new PerPeriodPolicy(1 days, 1 days, 0, 0);
    }

    //----------------------------------------------------------------------------------------------
    // Open buckets
    //----------------------------------------------------------------------------------------------

    /// @dev A controller adds to one bucket at a time, except where a notice puts requests in windows ahead of the open
    ///      one: then it can hold the open window and every window the notice spans.
    function testMaxOpenBucketsCountsTheWindowsANoticeSpans() public {
        assertEq(perInvestor.maxOpenBuckets(), 1);
        assertEq(perRequest.maxOpenBuckets(), 1);
        assertEq(perPeriod.maxOpenBuckets(), 1);

        assertEq(new PerPeriodPolicy(1 days, 0, 1 hours, 0).maxOpenBuckets(), 2, "under a window spans one");
        assertEq(new PerPeriodPolicy(1 days, 0, 0, 1 days).maxOpenBuckets(), 2, "a whole window spans one");
        assertEq(new PerPeriodPolicy(1 days, 0, 0, 1 days + 1).maxOpenBuckets(), 3, "the longer side counts");
        assertEq(new PerPeriodPolicy(1 days, 0, 0, 31 days).maxOpenBuckets(), 32);
    }
}
