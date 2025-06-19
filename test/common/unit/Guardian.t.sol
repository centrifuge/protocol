// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "src/common/types/PoolId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";
import {IGuardian} from "src/common/interfaces/IGuardian.sol";
import {IAxelarAdapter} from "src/common/interfaces/adapters/IAxelarAdapter.sol";
import {IWormholeAdapter} from "src/common/interfaces/adapters/IWormholeAdapter.sol";
import {Guardian, ISafe, IMultiAdapter, IRoot, IRootMessageSender} from "src/common/Guardian.sol";

import {AxelarAddressToString} from "test/common/unit/AxelarAdapter.t.sol";

import "forge-std/Test.sol";

contract GuardianTest is Test {
    Guardian guardian;
    ISafe immutable adminSafe = ISafe(makeAddr("adminSafe"));
    IMultiAdapter immutable gateway = IMultiAdapter(makeAddr("gateway"));
    IRoot immutable root = IRoot(makeAddr("root"));
    IRootMessageSender messageDispatcher = IRootMessageSender(makeAddr("messageDispatcher"));

    address immutable unauthorized = makeAddr("unauthorized");

    function setUp() public virtual {
        guardian = new Guardian(adminSafe, gateway, root, messageDispatcher);
    }

    function testGuardian() public view {
        assertEq(address(guardian.safe()), address(adminSafe));
        assertEq(address(guardian.multiAdapter()), address(gateway));
        assertEq(address(guardian.root()), address(root));
        assertEq(address(guardian.sender()), address(messageDispatcher));
    }
}

contract GuardianTestFile is GuardianTest {
    function testFile() public {
        vm.startPrank(address(adminSafe));

        guardian.file("sender", makeAddr("newSender"));
        assertEq(address(guardian.sender()), makeAddr("newSender"));

        guardian.file("hub", makeAddr("newHub"));
        assertEq(address(guardian.hub()), makeAddr("newHub"));

        guardian.file("multiAdapter", makeAddr("newMultiAdapter"));
        assertEq(address(guardian.multiAdapter()), makeAddr("newMultiAdapter"));

        guardian.file("safe", makeAddr("newSafe"));
        assertEq(address(guardian.safe()), makeAddr("newSafe"));
    }

    function testFileOnlySafe() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IGuardian.NotTheAuthorizedSafe.selector));
        guardian.file("safe", makeAddr("newSafe"));
    }

    function testCreatePoolOnlySafe() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IGuardian.NotTheAuthorizedSafe.selector));
        guardian.createPool(PoolId.wrap(1), makeAddr("admin"), AssetId.wrap(1));
    }

    function testUnpauseOnlySafe() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IGuardian.NotTheAuthorizedSafe.selector));
        guardian.unpause();
    }

    function testScheduleRelyOnlySafe() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IGuardian.NotTheAuthorizedSafe.selector));
        guardian.scheduleRely(makeAddr("target"));
    }

    function testCancelRelyOnlySafe() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IGuardian.NotTheAuthorizedSafe.selector));
        guardian.cancelRely(makeAddr("target"));
    }

    function testScheduleUpgradeOnlySafe() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IGuardian.NotTheAuthorizedSafe.selector));
        guardian.scheduleUpgrade(1, makeAddr("target"));
    }

    function testCancelUpgradeOnlySafe() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IGuardian.NotTheAuthorizedSafe.selector));
        guardian.cancelUpgrade(1, makeAddr("target"));
    }

    function testRecoverTokensOnlySafe() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IGuardian.NotTheAuthorizedSafe.selector));
        guardian.recoverTokens(1, makeAddr("target"), makeAddr("token"), 0, makeAddr("to"), 100);
    }

    function testInitiateRecoveryOnlySafe() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IGuardian.NotTheAuthorizedSafe.selector));
        guardian.initiateRecovery(1, IAdapter(makeAddr("adapter")), bytes32(uint256(1)));
    }

    function testDisputeRecoveryOnlySafe() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IGuardian.NotTheAuthorizedSafe.selector));
        guardian.disputeRecovery(1, IAdapter(makeAddr("adapter")), bytes32(uint256(1)));
    }

    function testWireAdaptersOnlySafe() public {
        IAdapter[] memory adapters = new IAdapter[](1);
        adapters[0] = IAdapter(makeAddr("adapter"));

        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IGuardian.NotTheAuthorizedSafe.selector));
        guardian.wireAdapters(1, adapters);
    }

    function testWireWormholeAdapterOnlySafe() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IGuardian.NotTheAuthorizedSafe.selector));
        guardian.wireWormholeAdapter(IWormholeAdapter(makeAddr("localAdapter")), 1, 2, makeAddr("remoteAdapter"));
    }

    function testWireAxelarAdapterOnlySafe() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IGuardian.NotTheAuthorizedSafe.selector));
        guardian.wireAxelarAdapter(
            IAxelarAdapter(makeAddr("localAdapter")), 1, "remoteAxelarId", "remoteAdapterAddress"
        );
    }
}

contract GuardianWireWormholeAdapterTest is GuardianTest {
    IWormholeAdapter localAdapter;

    uint16 constant REMOTE_CENTRIFUGE_CHAIN_ID = 3;
    uint16 constant REMOTE_WORMHOLE_CHAIN_ID = 4;
    address constant REMOTE_ADAPTER_ADDRESS = address(0x123);

    function setUp() public override {
        super.setUp();
        localAdapter = IWormholeAdapter(makeAddr("localAdapter"));
    }

    function _mockWormholeFileCalls(uint16 centrifugeId, uint16 wormholeId, address adapter) internal {
        vm.mockCall(
            address(localAdapter),
            abi.encodeWithSelector(IWormholeAdapter.file.selector, "sources", centrifugeId, wormholeId, adapter),
            abi.encode()
        );
        vm.mockCall(
            address(localAdapter),
            abi.encodeWithSelector(IWormholeAdapter.file.selector, "destinations", centrifugeId, wormholeId, adapter),
            abi.encode()
        );
    }

    function testWireWormholeAdapter() public {
        _mockWormholeFileCalls(REMOTE_CENTRIFUGE_CHAIN_ID, REMOTE_WORMHOLE_CHAIN_ID, REMOTE_ADAPTER_ADDRESS);

        vm.prank(address(adminSafe));
        guardian.wireWormholeAdapter(
            localAdapter, REMOTE_CENTRIFUGE_CHAIN_ID, REMOTE_WORMHOLE_CHAIN_ID, REMOTE_ADAPTER_ADDRESS
        );
    }

    function testWireWormholeAdapterOnlySafe() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IGuardian.NotTheAuthorizedSafe.selector));
        guardian.wireWormholeAdapter(
            localAdapter, REMOTE_CENTRIFUGE_CHAIN_ID, REMOTE_WORMHOLE_CHAIN_ID, REMOTE_ADAPTER_ADDRESS
        );
    }

    function testWireWormholeAdapterWithDifferentChainIds() public {
        uint16 anotherCentrifugeId = 5;
        uint16 anotherWormholeId = 6;

        // First configuration
        _mockWormholeFileCalls(REMOTE_CENTRIFUGE_CHAIN_ID, REMOTE_WORMHOLE_CHAIN_ID, REMOTE_ADAPTER_ADDRESS);
        vm.prank(address(adminSafe));
        guardian.wireWormholeAdapter(
            localAdapter, REMOTE_CENTRIFUGE_CHAIN_ID, REMOTE_WORMHOLE_CHAIN_ID, REMOTE_ADAPTER_ADDRESS
        );

        // Second configuration
        _mockWormholeFileCalls(anotherCentrifugeId, anotherWormholeId, REMOTE_ADAPTER_ADDRESS);
        vm.prank(address(adminSafe));
        guardian.wireWormholeAdapter(localAdapter, anotherCentrifugeId, anotherWormholeId, REMOTE_ADAPTER_ADDRESS);
    }

    function testWireWormholeAdapterFuzz(uint16 centrifugeId, uint16 wormholeId, address adapterAddr) public {
        vm.assume(centrifugeId != 0);
        vm.assume(wormholeId != 0);
        vm.assume(adapterAddr != address(0));

        _mockWormholeFileCalls(centrifugeId, wormholeId, adapterAddr);

        vm.prank(address(adminSafe));
        guardian.wireWormholeAdapter(localAdapter, centrifugeId, wormholeId, adapterAddr);
    }
}

contract GuardianWireAxelarAdapterTest is GuardianTest {
    using AxelarAddressToString for address;

    IAxelarAdapter localAdapter;

    uint16 constant REMOTE_CENTRIFUGE_CHAIN_ID = 2;
    string constant REMOTE_AXELAR_CHAIN_ID = "base";
    address constant REMOTE_ADAPTER_ADDRESS = address(0x123);

    function _remoteAdapter() internal pure returns (string memory) {
        return REMOTE_ADAPTER_ADDRESS.toAxelarString();
    }

    function setUp() public override {
        super.setUp();
        localAdapter = IAxelarAdapter(makeAddr("localAdapter"));
    }

    function _mockAxelarFileCalls(uint16 centrifugeId, string memory axelarId, string memory adapter) internal {
        vm.mockCall(
            address(localAdapter),
            abi.encodeWithSignature("file(bytes32,string,uint16,string)", "sources", axelarId, centrifugeId, adapter),
            abi.encode()
        );
        vm.mockCall(
            address(localAdapter),
            abi.encodeWithSignature(
                "file(bytes32,uint16,string,string)", "destinations", centrifugeId, axelarId, adapter
            ),
            abi.encode()
        );
    }

    function testWireAxelarAdapter() public {
        _mockAxelarFileCalls(REMOTE_CENTRIFUGE_CHAIN_ID, REMOTE_AXELAR_CHAIN_ID, _remoteAdapter());

        vm.prank(address(adminSafe));
        guardian.wireAxelarAdapter(localAdapter, REMOTE_CENTRIFUGE_CHAIN_ID, REMOTE_AXELAR_CHAIN_ID, _remoteAdapter());
    }

    function testWireAxelarAdapterOnlySafe() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IGuardian.NotTheAuthorizedSafe.selector));
        guardian.wireAxelarAdapter(localAdapter, REMOTE_CENTRIFUGE_CHAIN_ID, REMOTE_AXELAR_CHAIN_ID, _remoteAdapter());
    }

    function testWireAxelarAdapterWithDifferentChainIds() public {
        uint16 anotherCentrifugeId = 3;
        string memory anotherAxelarId = "otherEvmChain";

        _mockAxelarFileCalls(REMOTE_CENTRIFUGE_CHAIN_ID, REMOTE_AXELAR_CHAIN_ID, _remoteAdapter());
        vm.prank(address(adminSafe));
        guardian.wireAxelarAdapter(localAdapter, REMOTE_CENTRIFUGE_CHAIN_ID, REMOTE_AXELAR_CHAIN_ID, _remoteAdapter());

        _mockAxelarFileCalls(anotherCentrifugeId, anotherAxelarId, _remoteAdapter());
        vm.prank(address(adminSafe));
        guardian.wireAxelarAdapter(localAdapter, anotherCentrifugeId, anotherAxelarId, _remoteAdapter());
    }

    function testWireAxelarAdapterFuzzed(uint16 centrifugeId, string calldata axelarId, string calldata adapterStr)
        public
    {
        vm.assume(centrifugeId != 0);
        vm.assume(bytes(axelarId).length > 0);
        vm.assume(bytes(adapterStr).length > 0);

        _mockAxelarFileCalls(centrifugeId, axelarId, adapterStr);

        vm.prank(address(adminSafe));
        guardian.wireAxelarAdapter(localAdapter, centrifugeId, axelarId, adapterStr);
    }
}
