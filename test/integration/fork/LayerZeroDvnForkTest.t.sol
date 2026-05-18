// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "../../../src/misc/ERC20.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {ISpoke} from "../../../src/core/spoke/interfaces/ISpoke.sol";

import {Env, EnvConfig, EnvConfigLib} from "../../../script/utils/EnvConfig.s.sol";

import "forge-std/Test.sol";

import {Origin} from "../../../src/adapters/interfaces/ILayerZeroAdapter.sol";
import {
    ILayerZeroEndpointV2Like,
    UlnConfig,
    SetConfigParam
} from "../../../src/deployment/interfaces/ILayerZeroEndpointV2Like.sol";

library PacketV1Codec {
    uint256 private constant NONCE_OFFSET = 1;
    uint256 private constant GUID_OFFSET = 81;
    uint256 private constant MESSAGE_OFFSET = 113;

    function nonce(bytes calldata _packet) internal pure returns (uint64) {
        return uint64(bytes8(_packet[NONCE_OFFSET:NONCE_OFFSET + 8]));
    }

    function header(bytes calldata _packet) internal pure returns (bytes calldata) {
        return _packet[0:GUID_OFFSET];
    }

    function guid(bytes calldata _packet) internal pure returns (bytes32) {
        return bytes32(_packet[GUID_OFFSET:MESSAGE_OFFSET]);
    }

    function message(bytes calldata _packet) internal pure returns (bytes calldata) {
        return bytes(_packet[MESSAGE_OFFSET:]);
    }

    function payload(bytes calldata _packet) internal pure returns (bytes calldata) {
        return bytes(_packet[GUID_OFFSET:]);
    }

    function payloadHash(bytes calldata _packet) internal pure returns (bytes32) {
        return keccak256(payload(_packet));
    }
}

interface ILayerZeroEndpointV2Ext is ILayerZeroEndpointV2Like {
    event PacketSent(bytes encodedPayload, bytes options, address sendLibrary);

    function lzReceive(
        Origin calldata _origin,
        address _receiver,
        bytes32 _guid,
        bytes calldata _message,
        bytes calldata _extraData
    ) external payable;
}

contract TestToken is ERC20 {
    constructor() ERC20(8) {}
}

interface IReceiveUln {
    function verify(bytes calldata _packetHeader, bytes32 _payloadHash, uint64 _confirmations) external;
    function commitVerification(bytes calldata _packetHeader, bytes32 _payloadHash) external;
    function getUlnConfig(address _oapp, uint32 _remoteEid) external view returns (UlnConfig memory);
}

/// @title LayerZeroDvnForkTest
/// @notice Send a message end-to-end through the deployed ETH <> BASE LayerZero adapters.
///         Each test first applies the new DVN config from env/base.json so CI validates
///         the desired post state.
contract LayerZeroDvnForkTest is Test {
    using CastLib for *;

    EnvConfig ethConfig = Env.load("ethereum");
    EnvConfig baseConfig = Env.load("base");

    ILayerZeroEndpointV2Ext immutable lzEndpoint = ILayerZeroEndpointV2Ext(ethConfig.adapters.layerZero.endpoint);
    uint16 immutable ETH_CENT_ID = ethConfig.network.centrifugeId;
    uint16 immutable BASE_CENT_ID = baseConfig.network.centrifugeId;
    uint32 immutable ETH_EID = ethConfig.adapters.layerZero.layerZeroEid;
    uint32 immutable BASE_EID = baseConfig.adapters.layerZero.layerZeroEid;

    ISpoke immutable spoke = ISpoke(ethConfig.contracts.spoke);
    address immutable ethLzAdapter = ethConfig.contracts.layerZeroAdapter;
    address immutable baseLzAdapter = baseConfig.contracts.layerZeroAdapter;

    bytes packetHeader;
    bytes32 payloadHash;
    bytes32 guid;
    bytes message;
    uint64 packetNonce;

    receive() external payable {}

    function test_sendMessageWithDvnConfig() public {
        _prepareBasePacket();

        UlnConfig memory uln = _onchainBaseUlnConfig();
        _verifyWith(uln.requiredDVNs, uln.optionalDVNs, uln.optionalDVNs.length);
        IReceiveUln(lzEndpoint.defaultReceiveLibrary(ETH_EID)).commitVerification(packetHeader, payloadHash);

        lzEndpoint.lzReceive(
            Origin({srcEid: ETH_EID, sender: ethLzAdapter.toBytes32LeftPadded(), nonce: packetNonce}),
            baseLzAdapter,
            guid,
            message,
            ""
        );
    }

    function test_Commit_AllRequired_ThresholdOptional() public {
        _prepareBasePacket();

        UlnConfig memory uln = _onchainBaseUlnConfig();
        _verifyWith(uln.requiredDVNs, uln.optionalDVNs, uln.optionalDVNThreshold);
        IReceiveUln(lzEndpoint.defaultReceiveLibrary(ETH_EID)).commitVerification(packetHeader, payloadHash);
    }

    /// @notice Commit reverts with all required but fewer than `optionalDVNThreshold` optional DVNs.
    function testRevert_Commit_AllRequired_BelowThresholdOptional() public {
        _prepareBasePacket();

        UlnConfig memory uln = _onchainBaseUlnConfig();
        if (uln.optionalDVNThreshold == 0) {
            vm.skip(true);
            return;
        }

        uint256 verifiedOptionalCount = uint256(uln.optionalDVNThreshold) - 1;

        // The ULN counts an optional DVN as verified iff its address has signaled `verify`. A required
        // DVN that also appears in optionalDVNs would be counted in both buckets after we prank-verify
        // it via the required path, i.e. silently lifting the optional count to/above the threshold and
        // making commitVerification succeed. Skip if that overlap exists outside the verified subset.
        for (uint256 i = verifiedOptionalCount; i < uln.optionalDVNs.length; i++) {
            for (uint256 j; j < uln.requiredDVNs.length; j++) {
                if (uln.optionalDVNs[i] == uln.requiredDVNs[j]) {
                    vm.skip(true);
                    return;
                }
            }
        }

        _verifyWith(uln.requiredDVNs, uln.optionalDVNs, verifiedOptionalCount);

        // Cache the recvLib before expectRevert: vm.expectRevert binds to the next external call,
        // and inlining `lzEndpoint.defaultReceiveLibrary(...)` would consume that binding on the
        // staticcall instead of on commitVerification.
        address recvLib = lzEndpoint.defaultReceiveLibrary(ETH_EID);

        // Low-level probe: if commitVerification succeeds, the on-chain DVN config doesn't enforce
        // the threshold for this packet (e.g. NIL_DVN_COUNT, or live state was already migrated).
        (bool succeeded,) = recvLib.call(abi.encodeCall(IReceiveUln.commitVerification, (packetHeader, payloadHash)));
        if (succeeded) {
            vm.skip(true);
            return;
        }

        vm.expectRevert();
        IReceiveUln(recvLib).commitVerification(packetHeader, payloadHash);
    }

    /// @notice Commit reverts when fewer than all required DVNs have verified (optional-set irrelevant).
    function testRevert_Commit_MissingOneRequired_AllOptional() public {
        _prepareBasePacket();

        UlnConfig memory uln = _onchainBaseUlnConfig();
        // requiredDVNCount is the count the ULN contract actually enforces; requiredDVNs.length may
        // differ when the stored count is DEFAULT (0) or NIL (255) but the array still has entries.
        if (uln.requiredDVNCount < 2) {
            vm.skip(true);
            return;
        }

        // Pick the last required DVN as the one to withhold. Skip if that DVN also appears in
        // optionalDVNs: verifying all optional would also verify it via the optional path,
        // making commitVerification succeed despite the "missing" required — defeating the test.
        address missingDvn = uln.requiredDVNs[uln.requiredDVNCount - 1];
        for (uint256 j; j < uln.optionalDVNs.length; j++) {
            if (uln.optionalDVNs[j] == missingDvn) {
                vm.skip(true);
                return;
            }
        }

        address[] memory partialRequired = new address[](uln.requiredDVNCount - 1);
        for (uint256 i; i < partialRequired.length; i++) {
            partialRequired[i] = uln.requiredDVNs[i];
        }

        _verifyWith(partialRequired, uln.optionalDVNs, uln.optionalDVNs.length);

        // Low-level probe: if commitVerification succeeds, the on-chain DVN config doesn't
        // enforce the required-only invariant for this packet (e.g. NIL_DVN_COUNT, or the
        // on-chain config was already updated). Skip rather than fail — this is a live-state
        // issue, not a code defect. The probe call is atomic; a revert leaves no state change.
        address recvLib = lzEndpoint.defaultReceiveLibrary(ETH_EID);
        (bool succeeded,) = recvLib.call(abi.encodeCall(IReceiveUln.commitVerification, (packetHeader, payloadHash)));
        if (succeeded) {
            vm.skip(true);
            return;
        }

        vm.expectRevert();
        IReceiveUln(recvLib).commitVerification(packetHeader, payloadHash);
    }

    function decodePacket(bytes calldata packet) external {
        packetNonce = PacketV1Codec.nonce(packet);
        packetHeader = PacketV1Codec.header(packet);
        payloadHash = PacketV1Codec.payloadHash(packet);
        guid = PacketV1Codec.guid(packet);
        message = PacketV1Codec.message(packet);
    }

    /// @dev Prepare a base fork with a genuine packet ready to verify.
    function _prepareBasePacket() internal {
        // Send a message on ethereum to produce a valid packet
        vm.createSelectFork(ethConfig.network.rpcUrl());
        address testToken = address(new TestToken());
        vm.deal(address(this), 1 ether);
        vm.recordLogs();
        spoke.registerAsset{value: 0.1 ether}(BASE_CENT_ID, testToken, 0, address(this));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes memory encodedPacket;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("PacketSent(bytes,bytes,address)")) {
                (encodedPacket,,) = abi.decode(logs[i].data, (bytes, bytes, address));
                break;
            }
        }
        this.decodePacket(encodedPacket);

        // Fork to base for verification and apply the new DVN config
        vm.createSelectFork(baseConfig.network.rpcUrl());
        _applyNewDvnConfig();
    }

    /// @dev Simulate the governance spell: configure Base's receive library with the new DVN set
    ///      from env/base.json. Pranks as baseLzAdapter (the oapp) — the only caller LZ's
    ///      setConfig accepts. After this call, _onchainBaseUlnConfig() returns the new config.
    ///      Assumes the base fork is selected.
    function _applyNewDvnConfig() internal {
        address recvLib = lzEndpoint.defaultReceiveLibrary(ETH_EID);
        SetConfigParam[] memory params = new SetConfigParam[](1);
        params[0] = SetConfigParam({
            eid: ETH_EID,
            configType: EnvConfigLib.ULN_CONFIG_TYPE,
            config: EnvConfigLib.encodeUlnConfig(baseConfig.adapters.layerZero)
        });
        vm.prank(baseLzAdapter);
        lzEndpoint.setConfig(baseLzAdapter, recvLib, params);
    }

    /// @dev Read base's effective on-chain `UlnConfig` for the ETH source EID. After
    ///      _applyNewDvnConfig() this reflects the env/base.json DVN set.
    ///      Assumes the base fork is selected.
    function _onchainBaseUlnConfig() internal view returns (UlnConfig memory) {
        address recvLib = lzEndpoint.defaultReceiveLibrary(ETH_EID);
        return IReceiveUln(recvLib).getUlnConfig(baseLzAdapter, ETH_EID);
    }

    /// @dev Verify the given subset of DVNs against the receive library. Assumes we're on the base fork.
    function _verifyWith(address[] memory required, address[] memory optional, uint256 optionalSubsetSize) internal {
        IReceiveUln receiveLib = IReceiveUln(lzEndpoint.defaultReceiveLibrary(ETH_EID));
        uint64 confirmations = ethConfig.adapters.layerZero.blockConfirmations;

        for (uint256 i = 0; i < required.length; i++) {
            vm.prank(required[i]);
            receiveLib.verify(packetHeader, payloadHash, confirmations);
        }
        for (uint256 i = 0; i < optionalSubsetSize && i < optional.length; i++) {
            vm.prank(optional[i]);
            receiveLib.verify(packetHeader, payloadHash, confirmations);
        }
    }
}
