// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BytesLib} from "../../../src/misc/libraries/BytesLib.sol";

import {MessageLib, MessageType, VaultUpdateKind} from "../../../src/core/messaging/libraries/MessageLib.sol";

import {GasService} from "../../../src/admin/GasService.sol";

import "forge-std/Test.sol";

import {MAX_MESSAGE_COST} from "../../utils/GasConstants.sol";

contract GasServiceTest is Test {
    using MessageLib for *;
    using BytesLib for *;

    uint16 constant CENTRIFUGE_ID = 1;
    GasService service;

    function setUp() public {
        uint8[32] memory txLimits;
        txLimits[0] = 30; // Millions
        txLimits[1] = 150; // Millions
        txLimits[10] = 64; // Millions

        service = new GasService(txLimits, CENTRIFUGE_ID);
    }

    function testDefaultChainUsesDefaultFailureGasReserve() public view {
        assertEq(service.messageFailureGasReserve(), service.DEFAULT_FAILURE_GAS_RESERVE());
    }

    function testMonadChainUsesMonadFailureGasReserve() public {
        uint8[32] memory txLimits;
        txLimits[0] = 30;

        GasService monadService = new GasService(txLimits, service.MONAD_CENTRIFUGE_ID());
        assertEq(monadService.messageFailureGasReserve(), monadService.MONAD_FAILURE_GAS_RESERVE());
        assertTrue(monadService.MONAD_FAILURE_GAS_RESERVE() != monadService.DEFAULT_FAILURE_GAS_RESERVE());
    }

    function testDefaultChainHasNoColdAccessSurcharge() public view {
        bytes memory message = new bytes(266);
        message[0] = bytes1(uint8(MessageType.NotifyPool));

        assertEq(
            service.messageProcessingGasLimit(CENTRIFUGE_ID, message),
            service.notifyPool() + service.DEFAULT_FAILURE_GAS_RESERVE()
        );
    }

    /// @dev End-to-end check that the surcharge a message actually receives matches the counts benchmarked
    ///      for it by name, covering every benchmarked entry rather than every message type, so the three
    ///      VaultUpdateKind variants are checked apart. Catches a wrong count, a wrong index and a wrong shift.
    function testMonadSurchargeMatchesBenchmarkSnapshot() public view {
        string memory json = vm.readFile("snapshots/MessageColdAccesses.json");
        string[25] memory names = [
            "",
            "scheduleUpgrade",
            "cancelUpgrade",
            "registerAsset",
            "setPoolAdapters",
            "notifyPool",
            "notifyShareClass",
            "notifyPricePoolPerShare",
            "notifyPricePoolPerAsset",
            "notifyShareMetadata",
            "initiateTransferShares",
            "executeTransferShares",
            "updateRestriction",
            "", // UpdateVault: three sub-kinds share this index, resolved below
            "updateAssets",
            "updateShares",
            "request",
            "requestCallback",
            "setRequestManager",
            "managerCallFromSpoke",
            "managerCallFromHub",
            "updateManager",
            "setPolicy",
            "authorizeSpokeCall",
            "unauthorizeSpokeCall"
        ];

        bytes memory message = new bytes(266);

        for (uint256 i = 1; i < names.length; i++) {
            message[0] = bytes1(uint8(i));

            if (i == uint256(uint8(MessageType.UpdateVault))) {
                // Each VaultUpdateKind is benchmarked separately and must get its own surcharge
                string[3] memory kinds = ["updateVaultDeployAndLink", "updateVaultLink", "updateVaultUnlink"];
                for (uint256 k; k < kinds.length; k++) {
                    message[73] = bytes1(uint8(k)); // VaultUpdateKind is encoded at offset 73
                    _assertSurchargeMatchesSnapshot(json, message, kinds[k]);
                }
                message[73] = 0;
            } else {
                _assertSurchargeMatchesSnapshot(json, message, names[i]);
            }
        }
    }

    function _assertSurchargeMatchesSnapshot(string memory json, bytes memory message, string memory name)
        internal
        view
    {
        uint256 slots = vm.parseJsonUint(json, string.concat("$.", name, "Slots"));
        uint256 accounts = vm.parseJsonUint(json, string.concat("$.", name, "Accounts"));
        uint128 expected = uint128(slots) * service.MONAD_COLD_SLOT_SURCHARGE() + uint128(accounts)
            * service.MONAD_COLD_ACCOUNT_SURCHARGE();
        uint128 reserveDelta = service.MONAD_FAILURE_GAS_RESERVE() - service.DEFAULT_FAILURE_GAS_RESERVE();

        assertGt(expected, 0, string.concat(name, ": no cold-access counts recorded"));
        assertEq(
            service.messageProcessingGasLimit(service.MONAD_CENTRIFUGE_ID(), message)
                - service.messageProcessingGasLimit(CENTRIFUGE_ID, message),
            reserveDelta + expected,
            string.concat(name, ": surcharge does not match benchmarked counts")
        );
    }

    function testGasLimit(uint256 len, bytes calldata seed) public view {
        len = bound(len, 266, 4096); // ensuring we can deserialize extraGasLimit from any message (NotifyShareClass reads at offset 250)

        bytes memory message = new bytes(len);
        for (uint256 i; i < len && i < seed.length; ++i) {
            message[i] = seed[i];
        }

        vm.assume(message.messageExtraGasLimit() < 100_000);
        vm.assume(message.messageCode() > 0);
        vm.assume(message.messageCode() <= uint8(type(MessageType).max));

        if (message.messageCode() == uint8(MessageType.UpdateVault)) {
            vm.assume(message.length > 73);
            uint8 vaultKind = message.toUint8(73);
            vm.assume(vaultKind >= 0);
            vm.assume(vaultKind <= uint8(type(VaultUpdateKind).max));
        }

        if (message.messageCode() == uint8(MessageType.ManagerCallFromSpoke)) {
            vm.assume(message.length >= 91); // Minimum length without payload
        }

        uint256 messageGasLimit = service.messageOverallGasLimit(CENTRIFUGE_ID, message);
        assert(messageGasLimit > service.BASE_ADAPTER_COST());
        assertLt(messageGasLimit, MAX_MESSAGE_COST, "Higher than MAX_MESSAGE_COST");
    }

    /// @dev Covers Monad as a destination, which testGasLimit does not, so the chain carrying the largest
    ///      cold-access surcharge is checked against the reference ceiling too.
    function testOverallGasLimitStaysUnderMaxMessageCost() public view {
        bytes memory message = new bytes(266);

        for (uint8 i = 1; i <= uint8(type(MessageType).max); i++) {
            message[0] = bytes1(i);

            if (MessageType(i) == MessageType.UpdateVault) {
                for (uint8 k = 0; k <= uint8(type(VaultUpdateKind).max); k++) {
                    message[73] = bytes1(k); // VaultUpdateKind is encoded at offset 73
                    _assertUnderMaxMessageCost(message, i);
                }
                message[73] = 0;
            } else {
                _assertUnderMaxMessageCost(message, i);
            }
        }
    }

    function _assertUnderMaxMessageCost(bytes memory message, uint8 kind) internal view {
        assertLt(
            service.messageOverallGasLimit(CENTRIFUGE_ID, message),
            MAX_MESSAGE_COST,
            string.concat("type ", vm.toString(kind), ": default chain over MAX_MESSAGE_COST")
        );
        assertLt(
            service.messageOverallGasLimit(service.MONAD_CENTRIFUGE_ID(), message),
            MAX_MESSAGE_COST,
            string.concat("type ", vm.toString(kind), ": Monad over MAX_MESSAGE_COST")
        );
    }

    function testAllMessageTypesHaveSufficientGasReserve() public view {
        // 266 bytes covers the deepest offset read by messageExtraGasLimit across all types (NotifyShareClass
        // reads its extraGasLimit at offset 250 + 16 bytes). Extra-gas fields are zero-filled, giving the floor
        // for messageProcessingGasLimit — if the floor satisfies the invariant, any message with non-zero
        // extra gas also satisfies it.
        bytes memory message = new bytes(266);
        uint8 maxType = uint8(type(MessageType).max);

        for (uint8 i = 1; i <= maxType; i++) {
            message[0] = bytes1(i);

            if (MessageType(i) == MessageType.UpdateVault) {
                // UpdateVault dispatches on VaultUpdateKind, producing different base gas values per sub-kind
                for (uint8 k = 0; k <= uint8(type(VaultUpdateKind).max); k++) {
                    message[73] = bytes1(k); // VaultUpdateKind is encoded at offset 73
                    assertGe(
                        service.messageProcessingGasLimit(CENTRIFUGE_ID, message),
                        service.messageFailureGasReserve(),
                        string.concat(
                            "UpdateVault kind ",
                            vm.toString(k),
                            ": messageProcessingGasLimit does not cover messageFailureGasReserve"
                        )
                    );
                }
                message[73] = 0;
            } else {
                assertGe(
                    service.messageProcessingGasLimit(CENTRIFUGE_ID, message),
                    service.messageFailureGasReserve(),
                    string.concat(
                        "type ", vm.toString(i), ": messageProcessingGasLimit does not cover messageFailureGasReserve"
                    )
                );
            }
        }
    }

    function testMessageLength() public view {
        bytes memory message = MessageLib.NotifyPool({poolId: 1}).serialize();
        assertEq(service.messageLength(message), message.messageLength());
    }

    function testMessagePoolId() public view {
        bytes memory message = MessageLib.NotifyPool({poolId: 1}).serialize();
        assertEq(service.messagePoolId(message).raw(), message.messagePoolId().raw());
    }

    function testRoutePoolId() public view {
        bytes memory message = MessageLib.SetPoolAdapters({
                poolId: 1, threshold: 1, targetSessionId: 1, adapterList: new bytes32[](0)
            }).serialize();

        assertEq(service.routePoolId(message, true).raw(), message.messagePoolId().raw());
        assertEq(service.routePoolId(message, false).raw(), 0);
    }

    function testMessageSourceCentrifugeId() public view {
        bytes memory message = MessageLib.NotifyPool({poolId: uint64(CENTRIFUGE_ID) << 48}).serialize();
        assertEq(service.messageSourceCentrifugeId(message), message.messageSourceCentrifugeId());
    }

    function _updateVault(VaultUpdateKind kind, bytes memory payload) internal pure returns (bytes memory) {
        return MessageLib.UpdateVault({
                poolId: 1,
                scId: bytes16(uint128(2)),
                assetId: 3,
                vaultOrFactory: bytes32(uint256(4)),
                kind: uint8(kind),
                extraGasLimit: 0,
                payload: payload
            }).serialize();
    }

    function testMessageProcessingGasLimitIgnoresPayloadForLinkAndUnlink() public view {
        VaultUpdateKind[2] memory kinds = [VaultUpdateKind.Link, VaultUpdateKind.Unlink];

        for (uint256 i; i < kinds.length; i++) {
            assertEq(
                service.messageProcessingGasLimit(CENTRIFUGE_ID, _updateVault(kinds[i], "")),
                service.messageProcessingGasLimit(CENTRIFUGE_ID, _updateVault(kinds[i], new bytes(900))),
                string.concat("kind ", vm.toString(uint8(kinds[i])), ": limit depends on an unread payload")
            );
        }
    }

    /// @dev The gas estimator fully deserializes UpdateVault to read the kind byte.
    function testMessageProcessingGasLimitRevertsOnOverlongDeclaredPayload() public {
        bytes memory message = _updateVault(VaultUpdateKind.Link, "");
        assertEq(message.length, 92);

        uint16 declared = 300;
        message[90] = bytes1(uint8(declared >> 8));
        message[91] = bytes1(uint8(declared));

        vm.expectRevert(BytesLib.SliceOutOfBounds.selector);
        service.messageProcessingGasLimit(CENTRIFUGE_ID, message);
    }

    function testMaxBatchGasLimit(uint16 centrifugeId) public view {
        uint256 expectedGasLimit = service.DEFAULT_SUPPORTED_TX_LIMIT();
        if (centrifugeId == 0) expectedGasLimit = 30;
        if (centrifugeId == 1) expectedGasLimit = 150;
        if (centrifugeId == 10) expectedGasLimit = 64;
        expectedGasLimit = expectedGasLimit * 1_000_000;

        uint256 maxBatchGasLimit = service.maxBatchGasLimit(centrifugeId);
        assertEq(maxBatchGasLimit, expectedGasLimit);
    }
}
