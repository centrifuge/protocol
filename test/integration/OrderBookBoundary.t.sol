// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {EndToEndFlows} from "./EndToEnd.t.sol";
import {IntegrationConstants} from "./utils/IntegrationConstants.sol";

import {CastLib} from "../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {AssetId} from "../../src/core/types/AssetId.sol";
import {IHub} from "../../src/core/hub/interfaces/IHub.sol";
import {RequestId} from "../../src/core/types/RequestId.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {IMultiAdapter} from "../../src/core/messaging/interfaces/IMultiAdapter.sol";
import {IShareClassManager} from "../../src/core/hub/interfaces/IShareClassManager.sol";

import {IAsyncVault} from "../../src/vaults/interfaces/IAsyncVault.sol";
import {OrderBookAction} from "../../src/vaults/hub/interfaces/IOrderBook.sol";

import {StdHubPolicy} from "../../src/policies/hub/StdHubPolicy.sol";
import {IStdHubPolicy} from "../../src/policies/hub/interfaces/IStdHubPolicy.sol";

/// @dev Records the gas it is handed.
contract GasProbeObserver {
    uint256 public gasAtEntry;

    function onRequest(PoolId, ShareClassId, AssetId, RequestId, bool, uint128) external {
        gasAtEntry = gasleft();
    }
}

/// @dev Where the OrderBook meets the rest of the hub: the pool policy seen through the
///      FeeRequestManager, and the gas its request observer runs under.
contract OrderBookBoundaryTest is EndToEndFlows {
    using CastLib for *;

    address immutable KEEPER = makeAddr("KEEPER");

    function _setUpPool(bool sameChain) internal returns (IAsyncVault vault) {
        _configurePool(sameChain);
        _configurePrices(IntegrationConstants.assetPrice(), IntegrationConstants.sharePrice());
        vault = _deployVault();
    }

    /// @dev A keeper the pool's allowlist confines to `notifySharePrice` can no longer fulfil or cancel
    ///      by going through the FeeRequestManager, which the Hub sees as the caller: the policy is asked
    ///      about the keeper too.
    /// forge-config: default.isolate = true
    function testConfinedKeeperCannotFulfilOrCancelThroughTheFeeRequestManagerSameChain() public {
        _confinedKeeper(true);
    }

    /// forge-config: default.isolate = true
    function testConfinedKeeperCannotFulfilOrCancelThroughTheFeeRequestManagerCrossChain() public {
        _confinedKeeper(false);
    }

    function _confinedKeeper(bool sameChain) internal {
        IAsyncVault vault = _setUpPool(sameChain);

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IHub.notifySharePrice.selector;
        IStdHubPolicy.Entry[] memory allowlist = new IStdHubPolicy.Entry[](1);
        allowlist[0] = IStdHubPolicy.Entry({poolId: POOL_A, caller: KEEPER, selectors: selectors});

        IStdHubPolicy.Config memory c;
        c.delay = 2 days;
        c.expiry = 1 days;
        c.escalation = 7 days;
        c.allowlist = allowlist;
        c.orderBook = address(h.orderBook);
        c.maxFeeBps = type(uint128).max;
        StdHubPolicy policy = new StdHubPolicy(
            IHub(address(h.hub)),
            IMultiAdapter(address(h.multiAdapter)),
            IShareClassManager(address(h.shareClassManager)),
            c
        );

        vm.startPrank(FM);
        h.hub.updateHubManager(POOL_A, KEEPER, true);
        vm.stopPrank();
        vm.prank(address(h.root));
        h.hub.setPolicy(POOL_A, policy);
        vm.deal(KEEPER, 1 ether);

        RequestId requestId = _requestDeposit(vault, USDC_AMOUNT_1);

        vm.startPrank(KEEPER);
        vm.expectRevert(IStdHubPolicy.CallerNotAllowed.selector);
        h.feeRequestManager.fulfill{value: GAS}(
            POOL_A, SC_1, s.usdcId, requestId, true, USDC_AMOUNT_1 / 2, EXTRA_GAS, REFUND
        );
        vm.expectRevert(IStdHubPolicy.CallerNotAllowed.selector);
        h.feeRequestManager.cancel{value: GAS}(
            POOL_A, SC_1, s.usdcId, requestId, true, USDC_AMOUNT_1 / 2, EXTRA_GAS, REFUND
        );
        vm.stopPrank();

        assertEq(h.orderBook.depositOrders(POOL_A, SC_1, s.usdcId, requestId), USDC_AMOUNT_1, "order untouched");

        // An unconfined manager still goes through.
        _fulfill(true, requestId, USDC_AMOUNT_1);
        assertEq(h.orderBook.depositOrders(POOL_A, SC_1, s.usdcId, requestId), 0, "order fulfilled");
    }

    /// @dev Cross-chain, the request message is priced for the OrderBook alone, so a pool with a heavy
    ///      observer funds it through the router's per-pool extra gas, and the observer receives it.
    /// forge-config: default.isolate = true
    function testRequestObserverReceivesThePoolsExtraGasCrossChain() public {
        IAsyncVault vault = _setUpPool(false);

        GasProbeObserver obs = new GasProbeObserver();
        vm.prank(h.orderBook.envoy());
        h.orderBook.fromHub(POOL_A, abi.encode(uint8(OrderBookAction.SetObserver), address(obs)));
        vm.prank(s.vaultRequestRouter.envoy());
        s.vaultRequestRouter.fromHub(POOL_A, abi.encode(uint128(200_000)));

        _requestDeposit(vault, USDC_AMOUNT_1);

        assertGt(obs.gasAtEntry(), 199_000, "observer starved below the pool's extra gas");
    }
}
