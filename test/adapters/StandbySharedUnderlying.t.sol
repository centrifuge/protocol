// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MockUnderlying} from "./StandbyAdapter.t.sol";

import {MockGateway, MockMessageParser, POOL_0} from "../core/unit/MultiAdapter.t.sol";

import {MultiAdapter} from "../../src/core/messaging/MultiAdapter.sol";
import {IAdapter} from "../../src/core/messaging/interfaces/IAdapter.sol";

import {GasService} from "../../src/admin/GasService.sol";

import "forge-std/Test.sol";

import {StandbyAdapter} from "../../src/adapters/StandbyAdapter.sol";

/// @dev Two StandbyAdapters in one set sharing a single underlying adapter instance.
contract StandbySharedUnderlyingTest is Test {
    uint16 constant LOCAL = 1;
    uint16 constant REMOTE = 2;
    uint256 constant GAS = 100_000;
    bytes constant PAYLOAD = hex"c0ffee";

    MockGateway gateway = new MockGateway();
    MockMessageParser props = new MockMessageParser();
    MultiAdapter multi;

    MockUnderlying activeA = new MockUnderlying();
    MockUnderlying shared = new MockUnderlying();
    StandbyAdapter s1;
    StandbyAdapter s2;

    function setUp() public {
        multi = new MultiAdapter(LOCAL, gateway, address(this));
        multi.file("parser", address(props));

        uint8[32] memory txLimits;
        multi.file("messageGas", address(new GasService(txLimits, LOCAL)));

        // Both standbys wrap the SAME underlying instance.
        s1 = new StandbyAdapter(multi, shared);
        s2 = new StandbyAdapter(multi, shared);

        IAdapter[] memory set = new IAdapter[](3);
        set[0] = activeA;
        set[1] = s1;
        set[2] = s2;
        multi.setAdapters(REMOTE, POOL_0, set, 3, 1); // 3-of-3, the supported configuration
    }

    function _wrapped() internal view returns (bytes memory) {
        return abi.encodePacked(multi.activeSessionId(REMOTE, POOL_0), PAYLOAD);
    }

    /// @dev setAdapters accepts it: MultiAdapter has no view of `underlying`.
    function testSetAdaptersAcceptsTwoStandbysOverOneUnderlying() public view {
        assertEq(address(s1.underlying()), address(s2.underlying()));
        assertEq(multi.quorum(REMOTE, POOL_0), 3);
    }

    function testBothStandbysRecordAndBothForward() public {
        multi.send(REMOTE, PAYLOAD, GAS, address(this));
        bytes32 id = keccak256(abi.encodePacked(REMOTE, GAS, _wrapped()));
        assertEq(s1.forwardable(id), 1);
        assertEq(s2.forwardable(id), 1);

        s1.forward(REMOTE, _wrapped(), GAS);
        s2.forward(REMOTE, _wrapped(), GAS);
        assertEq(shared.sendCount(), 2, "two identical cross-chain sends, one per standby");
    }

    /// @dev The far-side shared underlying has ONE entrypoint, so both deliveries land on the same
    ///      standby and vote in the same slot. The other standby's slot can never be filled.
    function testThresholdIsUnreachable() public {
        bytes memory wrapped = _wrapped();

        vm.prank(address(activeA));
        multi.handle(REMOTE, wrapped);

        // Both forwarded deliveries arrive through `shared`, whose entrypoint is s1.
        vm.prank(address(shared));
        s1.handle(REMOTE, wrapped);
        vm.prank(address(shared));
        s1.handle(REMOTE, wrapped);

        assertEq(gateway.count(REMOTE), 0, "3-of-3 never reached: s2's slot has no delivery path");

        int16[8] memory v = multi.votes(REMOTE, keccak256(abi.encodePacked(POOL_0.raw(), wrapped)));
        assertEq(v[0], 1, "activeA");
        assertEq(v[1], 2, "s1 voted twice");
        assertEq(v[2], 0, "s2 never votes");
    }
}
