// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IAdapter} from "../../../../src/core/messaging/interfaces/IAdapter.sol";
import {BeforeAfter} from "../BeforeAfter.sol";

abstract contract MultiAdapterTargets is BeforeAfter {
    /// @dev Deliver a payload via adapter[adapterIdx % adapterCount]. Simulates a GMP message
    ///      arriving from REMOTE_CENTRIFUGE_ID. Updates ghost delivery count so properties can
    ///      verify threshold enforcement.
    function multiAdapter_deliver(uint8 adapterIdx, bytes calldata payload) public {
        // Require non-empty payload so messageLength can't return 0 and confuse the Gateway loop
        require(payload.length > 0 && payload.length <= 200, "invalid payload");

        uint8 idx = adapterIdx % ghost_adapterCount;

        _recordDelivery(REMOTE_CENTRIFUGE_ID, payload);

        if (idx == 0) adapter0.deliver(payload);
        else if (idx == 1) adapter1.deliver(payload);
        else adapter2.deliver(payload);
    }

    /// @dev Deliver via all three adapters in one transaction — exercises the fast quorum path where
    ///      a single sender pushes a payload over threshold in consecutive calls.
    function multiAdapter_deliverAll(bytes calldata payload) public {
        require(payload.length > 0 && payload.length <= 200, "invalid payload");
        require(ghost_adapterCount == ADAPTER_COUNT, "adapters reconfigured");

        _recordDelivery(REMOTE_CENTRIFUGE_ID, payload);
        adapter0.deliver(payload);

        _recordDelivery(REMOTE_CENTRIFUGE_ID, payload);
        adapter1.deliver(payload);

        _recordDelivery(REMOTE_CENTRIFUGE_ID, payload);
        adapter2.deliver(payload);
    }

    /// @dev Deliver the same payload threshold times — guarantees at least one execution happens,
    ///      useful for coverage-directed fuzzing.
    function multiAdapter_deliverToThreshold(bytes calldata payload) public {
        require(payload.length > 0 && payload.length <= 200, "invalid payload");
        require(ghost_adapterCount >= 2, "need at least 2 adapters");

        _recordDelivery(REMOTE_CENTRIFUGE_ID, payload);
        adapter0.deliver(payload);

        _recordDelivery(REMOTE_CENTRIFUGE_ID, payload);
        adapter1.deliver(payload);
    }

    /// @dev Reconfigure the adapter set with a fuzzed threshold.  Exercises session invalidation:
    ///      pending votes from the old session should be discarded, and the new threshold/quorum
    ///      should take effect immediately.
    ///
    ///      Keeps the same 3 adapters but allows the fuzzer to vary the threshold (1-3) and the
    ///      number of active adapters (1-3).
    function multiAdapter_reconfigure(uint8 adapterCountSeed, uint8 thresholdSeed) public {
        uint8 count = (adapterCountSeed % ADAPTER_COUNT) + 1; // 1..3
        uint8 threshold_ = (thresholdSeed % count) + 1; // 1..count

        IAdapter[] memory addrs = new IAdapter[](count);
        addrs[0] = IAdapter(address(adapter0));
        if (count > 1) addrs[1] = IAdapter(address(adapter1));
        if (count > 2) addrs[2] = IAdapter(address(adapter2));

        // recoveryIndex = count → no recovery adapters (same as initial setup)
        multiAdapter.setAdapters(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, addrs, threshold_, count);
        ghost_adapterCount = count;
    }
}
