// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {
    IWormholeAdapter,
    IAdapter,
    IWormholeRelayer,
    WormholeSource,
    WormholeDestination
} from "src/common/interfaces/IWormholeAdapter.sol";

/// @title  Wormhole Adapter
/// @notice Routing contract that integrates with the Wormhole Relayer service
contract WormholeAdapter is Auth, IWormholeAdapter {
    using CastLib for bytes32;

    uint16 public immutable refundChain;
    IMessageHandler public immutable gateway;
    IWormholeRelayer public immutable relayer;

    mapping(uint16 wormholeId => WormholeSource) public sources;
    mapping(uint32 centrifugeId => WormholeDestination) public destinations;

    address public /* transient */ refund;
    uint256 public /* transient */ gasPaid;

    constructor(IMessageHandler gateway_, address relayer_, uint16 refundChain_) Auth(msg.sender) {
        gateway = gateway_;
        relayer = IWormholeRelayer(relayer_);
        refundChain = refundChain_;
    }

    // --- Administrative ---
    /// @inheritdoc IWormholeAdapter
    function file(bytes32 what, uint16 wormholeId, uint32 centrifugeId, address source) external auth {
        if (what == "sources") sources[wormholeId] = WormholeSource(centrifugeId, source);
        else revert FileUnrecognizedParam();
        emit File(what, wormholeId, centrifugeId, source);
    }

    /// @inheritdoc IWormholeAdapter
    function file(bytes32 what, uint32 centrifugeId, uint16 wormholeId, address destination) external auth {
        if (what == "destinations") destinations[centrifugeId] = WormholeDestination(wormholeId, destination);
        else revert FileUnrecognizedParam();
        emit File(what, centrifugeId, wormholeId, destination);
    }

    // --- Incoming ---
    /// @inheritdoc IWormholeAdapter
    function receiveWormholeMessages(
        bytes memory payload,
        bytes[] memory, /* additionalVaas */
        bytes32 sourceAddr,
        uint16 sourceWormholeId,
        bytes32 /* deliveryHash */
    ) external {
        WormholeSource memory source = sources[sourceWormholeId];
        require(source.addr == sourceAddr.toAddress(), InvalidSource());
        require(msg.sender == address(relayer), NotWormholeRelayer());

        gateway.handle(source.centrifugeId, payload);
    }

    // --- Outgoing ---
    /// @inheritdoc IAdapter
    function send(uint32 chainId, bytes calldata payload, uint256 gasLimit) public {
        require(msg.sender == address(gateway), NotGateway());
        WormholeDestination memory destination = destinations[chainId];
        require(destination.wormholeId != 0, UnknownChainId());

        relayer.sendPayloadToEvm{value: address(this).balance}(
            destination.wormholeId, destination.addr, payload, 0, gasLimit, refundChain, address(gateway)
        );

        gasPaid = 0;
    }

    /// @inheritdoc IAdapter
    function estimate(uint32 chainId, bytes calldata, uint256 gasLimit)
        public
        view
        returns (uint256 nativePriceQuote)
    {
        (nativePriceQuote,) = relayer.quoteEVMDeliveryPrice(destinations[chainId].wormholeId, 0, gasLimit);
    }

    /// @inheritdoc IAdapter
    /// @dev If called multiple times within the same transaction, the last refund address will be used
    function pay(uint32, /*chainId*/ bytes calldata, /* payload */ address refund_) public payable {
        gasPaid += msg.value;
        refund = refund_;
    }
}
