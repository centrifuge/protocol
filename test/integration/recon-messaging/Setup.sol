// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {ManagerActor} from "./mocks/ManagerActor.sol";
import {SimpleAdapter} from "./mocks/SimpleAdapter.sol";
import {CountingProcessor} from "./mocks/CountingProcessor.sol";
import {MockProtocolPauser} from "./mocks/MockProtocolPauser.sol";
import {MockMessageProperties} from "./mocks/MockMessageProperties.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {Gateway} from "../../../src/core/messaging/Gateway.sol";
import {MultiAdapter} from "../../../src/core/messaging/MultiAdapter.sol";
import {IAdapter} from "../../../src/core/messaging/interfaces/IAdapter.sol";

import {BaseSetup} from "@chimera/BaseSetup.sol";

abstract contract Setup is BaseSetup {
    uint16 internal constant LOCAL_CENTRIFUGE_ID = 1;
    uint16 internal constant REMOTE_CENTRIFUGE_ID = 2;

    uint8 internal constant ADAPTER_COUNT = 3;
    uint8 internal constant THRESHOLD = 2;

    // Payload keyspace bound: collapse fuzzed payloads into this many canonical single-byte
    // representatives so independent handler calls collide on the same (cId, hash) key.
    uint8 internal constant PAYLOAD_BUCKETS = 16;

    PoolId internal constant GLOBAL_POOL = PoolId.wrap(0);

    Gateway internal gateway;
    MultiAdapter internal multiAdapter;

    CountingProcessor internal countingProcessor;
    MockMessageProperties internal mockMessageProperties;
    MockProtocolPauser internal mockProtocolPauser;

    // Adapters: deliver() is the inbound entrypoint for the fuzzer
    SimpleAdapter internal adapter0;
    SimpleAdapter internal adapter1;
    SimpleAdapter internal adapter2;

    // Non-ward second actor for the pool-manager path (role granted/revoked via updateManager)
    ManagerActor internal managerActor;

    function setup() internal virtual override {
        mockMessageProperties = new MockMessageProperties();
        mockProtocolPauser = new MockProtocolPauser();
        countingProcessor = new CountingProcessor();

        gateway = new Gateway(LOCAL_CENTRIFUGE_ID, mockProtocolPauser, address(this));
        multiAdapter = new MultiAdapter(LOCAL_CENTRIFUGE_ID, gateway, address(this));

        adapter0 = new SimpleAdapter(REMOTE_CENTRIFUGE_ID, multiAdapter);
        adapter1 = new SimpleAdapter(REMOTE_CENTRIFUGE_ID, multiAdapter);
        adapter2 = new SimpleAdapter(REMOTE_CENTRIFUGE_ID, multiAdapter);

        managerActor = new ManagerActor(multiAdapter); // starts WITHOUT the manager role

        gateway.file("processor", address(countingProcessor));
        gateway.file("messageProperties", address(mockMessageProperties));
        gateway.file("adapter", address(multiAdapter));

        multiAdapter.file("messageProperties", address(mockMessageProperties));

        IAdapter[] memory addrs = new IAdapter[](ADAPTER_COUNT);
        addrs[0] = IAdapter(address(adapter0));
        addrs[1] = IAdapter(address(adapter1));
        addrs[2] = IAdapter(address(adapter2));
        // Session 1: this pool has never been configured, so the next session id is always 1.
        multiAdapter.setAdapters(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, addrs, THRESHOLD, 1);

        // Auth: multiAdapter must be a ward of gateway so it can call gateway.handle()
        gateway.rely(address(multiAdapter));

        // Auth: gateway must be a ward of multiAdapter so it can call multiAdapter.send() on outbound
        multiAdapter.rely(address(gateway));
    }

    /// @dev Collapse a fuzzed payload into one of PAYLOAD_BUCKETS canonical single-byte payloads so independent
    ///      handler calls collide on one (cId, hash); without it the fail -> retry/clear cycle is unreachable.
    ///      Idempotent, so Foundry tests can bucket once and keep hashing the raw payload.
    function _bucket(bytes memory payload) internal pure returns (bytes memory) {
        if (payload.length == 1 && uint8(payload[0]) < PAYLOAD_BUCKETS) return payload;
        return abi.encodePacked(uint8(uint256(keccak256(payload)) % PAYLOAD_BUCKETS));
    }

    /// @dev Prefix a payload with the 2-byte active session id, mirroring MultiAdapter.send(). Inbound
    ///      handle/vote/execute resolve the adapter set from `payload[0:2]`: unwrapped reverts InvalidAdapter.
    function _wrap(bytes memory payload) internal view returns (bytes memory) {
        return abi.encodePacked(multiAdapter.activeSessionId(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL), payload);
    }

    /// @dev `MultiAdapter._votes` is keyed by `keccak256(routedPoolId ++ wrappedPayload)`, not by the bare wrapped
    ///      hash. The width is load-bearing: `PoolId.raw()` is a `uint64`, so the prefix is 8 bytes; a 32-byte
    ///      prefix addresses an empty slot and silently makes every vote-reading property vacuous.
    function _voteKey(bytes memory wrappedPayload) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(GLOBAL_POOL.raw(), wrappedPayload));
    }

    /// @dev Live active adapter set, never mirrored in a ghost: reconfigure can install non-prefix sets.
    function _activeList() internal view returns (IAdapter[] memory) {
        return multiAdapter.activeAdapters(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL).list;
    }

    function _isActive(address adapter) internal view returns (bool) {
        IAdapter[] memory list = _activeList();
        for (uint256 i; i < list.length; i++) {
            if (address(list[i]) == adapter) return true;
        }
        return false;
    }
}
