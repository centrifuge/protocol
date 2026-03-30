// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IAdapter} from "../../../src/core/messaging/interfaces/IAdapter.sol";
import {Gateway} from "../../../src/core/messaging/Gateway.sol";
import {MultiAdapter} from "../../../src/core/messaging/MultiAdapter.sol";
import {PoolId} from "../../../src/core/types/PoolId.sol";

import {SimpleAdapter} from "./mocks/SimpleAdapter.sol";
import {CountingProcessor} from "./mocks/CountingProcessor.sol";
import {MockMessageProperties} from "./mocks/MockMessageProperties.sol";
import {MockProtocolPauser} from "./mocks/MockProtocolPauser.sol";

import {BaseSetup} from "@chimera/BaseSetup.sol";

abstract contract Setup is BaseSetup {
    // Chain IDs
    uint16 internal constant LOCAL_CENTRIFUGE_ID = 1;
    uint16 internal constant REMOTE_CENTRIFUGE_ID = 2;

    // Adapter configuration: 3 adapters, threshold=2, no recovery adapters
    uint8 internal constant ADAPTER_COUNT = 3;
    uint8 internal constant THRESHOLD = 2;
    uint8 internal constant RECOVERY_INDEX = 3; // past end → no recovery adapters

    PoolId internal constant GLOBAL_POOL = PoolId.wrap(0);

    // Contracts under test
    Gateway internal gateway;
    MultiAdapter internal multiAdapter;

    // Mocks
    CountingProcessor internal countingProcessor;
    MockMessageProperties internal mockMessageProperties;
    MockProtocolPauser internal mockProtocolPauser;

    // Adapters: deliver() is the inbound entrypoint for the fuzzer
    SimpleAdapter internal adapter0;
    SimpleAdapter internal adapter1;
    SimpleAdapter internal adapter2;

    function setup() internal virtual override {
        mockMessageProperties = new MockMessageProperties();
        mockProtocolPauser = new MockProtocolPauser();
        countingProcessor = new CountingProcessor();

        gateway = new Gateway(LOCAL_CENTRIFUGE_ID, mockProtocolPauser, address(this));
        multiAdapter = new MultiAdapter(LOCAL_CENTRIFUGE_ID, gateway, address(this));

        adapter0 = new SimpleAdapter(REMOTE_CENTRIFUGE_ID, multiAdapter);
        adapter1 = new SimpleAdapter(REMOTE_CENTRIFUGE_ID, multiAdapter);
        adapter2 = new SimpleAdapter(REMOTE_CENTRIFUGE_ID, multiAdapter);

        // Wire dependencies
        gateway.file("processor", address(countingProcessor));
        gateway.file("messageProperties", address(mockMessageProperties));
        gateway.file("adapter", address(multiAdapter));

        multiAdapter.file("messageProperties", address(mockMessageProperties));

        // Configure adapter set on MultiAdapter for the remote chain
        IAdapter[] memory addrs = new IAdapter[](ADAPTER_COUNT);
        addrs[0] = IAdapter(address(adapter0));
        addrs[1] = IAdapter(address(adapter1));
        addrs[2] = IAdapter(address(adapter2));
        multiAdapter.setAdapters(REMOTE_CENTRIFUGE_ID, GLOBAL_POOL, addrs, THRESHOLD, RECOVERY_INDEX);

        // Auth: multiAdapter must be a ward of gateway so it can call gateway.handle()
        gateway.rely(address(multiAdapter));

        // Auth: gateway must be a ward of multiAdapter so it can call multiAdapter.send() on outbound
        multiAdapter.rely(address(gateway));
    }
}
