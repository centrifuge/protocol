// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {AssetId} from "../../../src/common/types/AssetId.sol";
import {IAdapter} from "../../../src/common/interfaces/IAdapter.sol";
import {IGuardian} from "../../../src/common/interfaces/IGuardian.sol";
import {IHubGuardianActions} from "../../../src/common/interfaces/IGuardianActions.sol";
import {Guardian, ISafe, IMultiAdapter, IRoot, IRootMessageSender} from "../../../src/common/Guardian.sol";

import "forge-std/Test.sol";

import {AxelarAddressToString} from "../../adapters/unit/AxelarAdapter.t.sol";
import {IAxelarAdapter} from "../../../src/adapters/interfaces/IAxelarAdapter.sol";
import {IWormholeAdapter} from "../../../src/adapters/interfaces/IWormholeAdapter.sol";

// Need it to overpass a mockCall issue: https://github.com/foundry-rs/foundry/issues/10703
contract IsContract {}

contract GuardianTest is Test {
    IRoot immutable root = IRoot(address(new IsContract()));
    IHubGuardianActions immutable hub = IHubGuardianActions(address(new IsContract()));
    IRootMessageSender sender = IRootMessageSender(address(new IsContract()));
    IMultiAdapter immutable multiAdapter = IMultiAdapter(makeAddr("multiAdapter"));

    ISafe immutable SAFE = ISafe(makeAddr("adminSafe"));
    address immutable OWNER = makeAddr("owner");
    address immutable UNAUTHORIZED = makeAddr("unauthorized");

    uint16 constant CENTRIFUGE_ID = 1;
    PoolId constant POOL_A = PoolId.wrap(1);
    AssetId constant ASSET_ID_A = AssetId.wrap(1);
    address immutable TARGET = makeAddr("target");
    IAdapter immutable ADAPTER = IAdapter(makeAddr("adapter"));
    bytes32 immutable HASH = bytes32("hash");

    Guardian guardian = new Guardian(SAFE, multiAdapter, root, sender);

    function testGuardian() public view {
        assertEq(address(guardian.safe()), address(SAFE));
        assertEq(address(guardian.multiAdapter()), address(multiAdapter));
        assertEq(address(guardian.root()), address(root));
        assertEq(address(guardian.sender()), address(sender));
    }
}

contract GuardianTestFile is GuardianTest {
    function testFile() public {
        vm.startPrank(address(SAFE));

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
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IGuardian.NotTheAuthorizedSafe.selector);
        guardian.file("safe", makeAddr("newSafe"));
    }
}

contract GuardianTestCreatePool is GuardianTest {
    address immutable POOL_ADMIN = makeAddr("poolAdmin");

    function testCreatePool() public {
        vm.prank(address(SAFE));
        guardian.file("hub", address(hub));

        vm.mockCall(
            address(hub), abi.encodeWithSelector(hub.createPool.selector, POOL_A, POOL_ADMIN, ASSET_ID_A), abi.encode()
        );

        vm.prank(address(SAFE));
        guardian.createPool(POOL_A, POOL_ADMIN, ASSET_ID_A);
    }

    function testCreatePoolOnlySafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IGuardian.NotTheAuthorizedSafe.selector);
        guardian.createPool(POOL_A, POOL_ADMIN, ASSET_ID_A);
    }
}

contract GuardianTestPause is GuardianTest {
    function testPause() public {
        vm.mockCall(address(root), abi.encodeWithSelector(root.pause.selector), abi.encode());

        vm.prank(address(SAFE));
        guardian.pause();
    }

    function testPauseWithOwner() public {
        vm.mockCall(address(root), abi.encodeWithSelector(root.pause.selector), abi.encode());
        vm.mockCall(address(SAFE), abi.encodeWithSelector(ISafe.isOwner.selector, OWNER), abi.encode(true));

        vm.prank(address(OWNER));
        guardian.pause();
    }

    function testPauseOnlySafe() public {
        vm.mockCall(address(SAFE), abi.encodeWithSelector(ISafe.isOwner.selector, UNAUTHORIZED), abi.encode(false));

        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IGuardian.NotTheAuthorizedSafeOrItsOwner.selector);
        guardian.pause();
    }
}

contract GuardianTestUnpause is GuardianTest {
    function testUnpause() public {
        vm.mockCall(address(root), abi.encodeWithSelector(root.unpause.selector), abi.encode());

        vm.prank(address(SAFE));
        guardian.unpause();
    }

    function testUnpauseOnlySafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IGuardian.NotTheAuthorizedSafe.selector);
        guardian.unpause();
    }
}

contract GuardianTestScheduleRely is GuardianTest {
    function testScheduleRely() public {
        vm.mockCall(address(root), abi.encodeWithSelector(root.scheduleRely.selector, TARGET), abi.encode());

        vm.prank(address(SAFE));
        guardian.scheduleRely(TARGET);
    }

    function testScheduleRelyOnlySafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IGuardian.NotTheAuthorizedSafe.selector);
        guardian.scheduleRely(TARGET);
    }
}

contract GuardianTestCancelRely is GuardianTest {
    function testCancelRely() public {
        vm.mockCall(address(root), abi.encodeWithSelector(root.cancelRely.selector, TARGET), abi.encode());

        vm.prank(address(SAFE));
        guardian.cancelRely(TARGET);
    }

    function testCancelRelyOnlySafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IGuardian.NotTheAuthorizedSafe.selector);
        guardian.cancelRely(TARGET);
    }
}

contract GuardianTestScheduleUpgrade is GuardianTest {
    using CastLib for *;

    function testScheduleUpgrade() public {
        vm.mockCall(
            address(sender),
            abi.encodeWithSelector(sender.sendScheduleUpgrade.selector, CENTRIFUGE_ID, TARGET.toBytes32()),
            abi.encode()
        );

        vm.prank(address(SAFE));
        guardian.scheduleUpgrade(CENTRIFUGE_ID, TARGET);
    }

    function testScheduleUpgradeOnlySafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IGuardian.NotTheAuthorizedSafe.selector);
        guardian.scheduleUpgrade(CENTRIFUGE_ID, TARGET);
    }
}

contract GuardianTestCancelUpgrade is GuardianTest {
    using CastLib for *;

    function testCancelUpgrade() public {
        vm.mockCall(
            address(sender),
            abi.encodeWithSelector(sender.sendCancelUpgrade.selector, CENTRIFUGE_ID, TARGET.toBytes32()),
            abi.encode()
        );

        vm.prank(address(SAFE));
        guardian.cancelUpgrade(CENTRIFUGE_ID, TARGET);
    }

    function testCancelUpgradeOnlySafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IGuardian.NotTheAuthorizedSafe.selector);
        guardian.cancelUpgrade(CENTRIFUGE_ID, TARGET);
    }
}

contract GuardianTestRecoverTokens is GuardianTest {
    using CastLib for *;

    address immutable TOKEN = makeAddr("Token");
    uint256 constant TOKEN_ID = 1;
    address immutable TO = makeAddr("To");
    uint256 constant AMOUNT = 100;

    function testRecoverTokens() public {
        vm.mockCall(
            address(sender),
            abi.encodeWithSelector(
                sender.sendRecoverTokens.selector,
                CENTRIFUGE_ID,
                TARGET.toBytes32(),
                TOKEN.toBytes32(),
                TOKEN_ID,
                TO.toBytes32(),
                AMOUNT
            ),
            abi.encode()
        );

        vm.prank(address(SAFE));
        guardian.recoverTokens(CENTRIFUGE_ID, TARGET, TOKEN, TOKEN_ID, TO, AMOUNT);
    }

    function testRecoverTokensOnlySafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IGuardian.NotTheAuthorizedSafe.selector);
        guardian.recoverTokens(CENTRIFUGE_ID, TARGET, TOKEN, TOKEN_ID, TO, AMOUNT);
    }
}

contract GuardianTestInitiateRecovery is GuardianTest {
    function testInitiateRecovery() public {
        vm.mockCall(
            address(multiAdapter),
            abi.encodeWithSelector(multiAdapter.initiateRecovery.selector, CENTRIFUGE_ID, ADAPTER, HASH),
            abi.encode()
        );

        vm.prank(address(SAFE));
        guardian.initiateRecovery(CENTRIFUGE_ID, ADAPTER, HASH);
    }

    function testInitiateRecoveryOnlySafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IGuardian.NotTheAuthorizedSafe.selector);
        guardian.initiateRecovery(CENTRIFUGE_ID, ADAPTER, HASH);
    }
}

contract GuardianTestDisputeRecovery is GuardianTest {
    function testDisputeRecovery() public {
        vm.mockCall(
            address(multiAdapter),
            abi.encodeWithSelector(multiAdapter.disputeRecovery.selector, CENTRIFUGE_ID, ADAPTER, HASH),
            abi.encode()
        );

        vm.prank(address(SAFE));
        guardian.disputeRecovery(CENTRIFUGE_ID, ADAPTER, HASH);
    }

    function testDisputeRecoveryOnlySafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IGuardian.NotTheAuthorizedSafe.selector);
        guardian.disputeRecovery(CENTRIFUGE_ID, ADAPTER, HASH);
    }
}

contract GuardianTestWireAdapter is GuardianTest {
    function testWireAdapters() public {
        IAdapter[] memory adapters = new IAdapter[](1);
        adapters[0] = ADAPTER;

        vm.mockCall(
            address(multiAdapter),
            abi.encodeWithSignature("file(bytes32,uint16,IAdapter[])", bytes32("adapters"), CENTRIFUGE_ID, adapters),
            abi.encode()
        );

        vm.prank(address(SAFE));
        guardian.wireAdapters(CENTRIFUGE_ID, adapters);
    }

    function testWireAdaptersOnlySafe() public {
        IAdapter[] memory adapters = new IAdapter[](1);
        adapters[0] = ADAPTER;

        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IGuardian.NotTheAuthorizedSafe.selector);
        guardian.wireAdapters(CENTRIFUGE_ID, adapters);
    }
}

contract GuardianTestWireWormholeAdapter is GuardianTest {
    uint16 constant REMOTE_CENTRIFUGE_CHAIN_ID = 3;
    uint16 constant REMOTE_WORMHOLE_CHAIN_ID = 4;
    address constant REMOTE_ADAPTER_ADDRESS = address(0x123);

    IWormholeAdapter localAdapter = IWormholeAdapter(makeAddr("localAdapter"));

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

        vm.prank(address(SAFE));
        guardian.wireWormholeAdapter(
            localAdapter, REMOTE_CENTRIFUGE_CHAIN_ID, REMOTE_WORMHOLE_CHAIN_ID, REMOTE_ADAPTER_ADDRESS
        );
    }

    function testWireWormholeAdapterOnlySafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IGuardian.NotTheAuthorizedSafe.selector);
        guardian.wireWormholeAdapter(
            localAdapter, REMOTE_CENTRIFUGE_CHAIN_ID, REMOTE_WORMHOLE_CHAIN_ID, REMOTE_ADAPTER_ADDRESS
        );
    }

    function testWireWormholeAdapterWithDifferentChainIds() public {
        uint16 anotherCentrifugeId = 5;
        uint16 anotherWormholeId = 6;

        // First configuration
        _mockWormholeFileCalls(REMOTE_CENTRIFUGE_CHAIN_ID, REMOTE_WORMHOLE_CHAIN_ID, REMOTE_ADAPTER_ADDRESS);
        vm.prank(address(SAFE));
        guardian.wireWormholeAdapter(
            localAdapter, REMOTE_CENTRIFUGE_CHAIN_ID, REMOTE_WORMHOLE_CHAIN_ID, REMOTE_ADAPTER_ADDRESS
        );

        // Second configuration
        _mockWormholeFileCalls(anotherCentrifugeId, anotherWormholeId, REMOTE_ADAPTER_ADDRESS);
        vm.prank(address(SAFE));
        guardian.wireWormholeAdapter(localAdapter, anotherCentrifugeId, anotherWormholeId, REMOTE_ADAPTER_ADDRESS);
    }

    function testWireWormholeAdapterFuzz(uint16 centrifugeId, uint16 wormholeId, address adapterAddr) public {
        vm.assume(centrifugeId != 0);
        vm.assume(wormholeId != 0);
        vm.assume(adapterAddr != address(0));

        _mockWormholeFileCalls(centrifugeId, wormholeId, adapterAddr);

        vm.prank(address(SAFE));
        guardian.wireWormholeAdapter(localAdapter, centrifugeId, wormholeId, adapterAddr);
    }
}

contract GuardianTestWireAxelarAdapter is GuardianTest {
    using AxelarAddressToString for address;

    uint16 constant REMOTE_CENTRIFUGE_CHAIN_ID = 2;
    string constant REMOTE_AXELAR_CHAIN_ID = "base";
    address constant REMOTE_ADAPTER_ADDRESS = address(0x123);

    IAxelarAdapter localAdapter = IAxelarAdapter(makeAddr("localAdapter"));

    function _remoteAdapter() internal pure returns (string memory) {
        return REMOTE_ADAPTER_ADDRESS.toAxelarString();
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

        vm.prank(address(SAFE));
        guardian.wireAxelarAdapter(localAdapter, REMOTE_CENTRIFUGE_CHAIN_ID, REMOTE_AXELAR_CHAIN_ID, _remoteAdapter());
    }

    function testWireAxelarAdapterOnlySafe() public {
        vm.prank(UNAUTHORIZED);
        vm.expectRevert(IGuardian.NotTheAuthorizedSafe.selector);
        guardian.wireAxelarAdapter(localAdapter, REMOTE_CENTRIFUGE_CHAIN_ID, REMOTE_AXELAR_CHAIN_ID, _remoteAdapter());
    }

    function testWireAxelarAdapterWithDifferentChainIds() public {
        uint16 anotherCentrifugeId = 3;
        string memory anotherAxelarId = "otherEvmChain";

        _mockAxelarFileCalls(REMOTE_CENTRIFUGE_CHAIN_ID, REMOTE_AXELAR_CHAIN_ID, _remoteAdapter());
        vm.prank(address(SAFE));
        guardian.wireAxelarAdapter(localAdapter, REMOTE_CENTRIFUGE_CHAIN_ID, REMOTE_AXELAR_CHAIN_ID, _remoteAdapter());

        _mockAxelarFileCalls(anotherCentrifugeId, anotherAxelarId, _remoteAdapter());
        vm.prank(address(SAFE));
        guardian.wireAxelarAdapter(localAdapter, anotherCentrifugeId, anotherAxelarId, _remoteAdapter());
    }

    function testWireAxelarAdapterFuzzed(uint16 centrifugeId, string calldata axelarId, string calldata adapterStr)
        public
    {
        vm.assume(centrifugeId != 0);
        vm.assume(bytes(axelarId).length > 0);
        vm.assume(bytes(adapterStr).length > 0);

        _mockAxelarFileCalls(centrifugeId, axelarId, adapterStr);

        vm.prank(address(SAFE));
        guardian.wireAxelarAdapter(localAdapter, centrifugeId, axelarId, adapterStr);
    }
}
