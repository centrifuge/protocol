// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IWormholeAdapter, IAdapter, IWormholeRelayer} from "src/common/interfaces/IWormholeAdapter.sol";

struct Source {
    uint32 centrifugeId;
    address addr;
}

struct Destination {
    uint16 wormholeId;
    address addr;
}

/// @title  Wormhole Adapter
/// @notice Routing contract that integrates with the Wormhole Relayer service
contract WormholeAdapter is Auth, IWormholeAdapter {
    using CastLib for bytes32;

    uint16 public immutable refundChain;
    IMessageHandler public immutable gateway;
    IWormholeRelayer public immutable relayer;

    mapping(uint16 wormholeId => Source) public sources;
    mapping(uint32 centrifugeId => Destination) public destinations;

    uint256 public /* transient */ gasPaid;
    address public /* transient */ refund;

    constructor(IMessageHandler gateway_, address relayer_, uint16 refundChain_) Auth(msg.sender) {
        gateway = gateway_;
        relayer = IWormholeRelayer(relayer_);
        refundChain = refundChain_;
    }

    // --- Administrative ---
    /// @inheritdoc IWormholeAdapter
    function file(bytes32 what, uint16 wormholeId, uint32 centrifugeId, address source) external auth {
        if (what == "sources") sources[wormholeId] = Source(centrifugeId, source);
        else revert FileUnrecognizedParam();
        emit File(what, wormholeId, centrifugeId, source);
    }

    /// @inheritdoc IWormholeAdapter
    function file(bytes32 what, uint32 centrifugeId, uint16 wormholeId, address destination) external auth {
        if (what == "destinations") destinations[centrifugeId] = Destination(wormholeId, destination);
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
        Source memory source = sources[sourceWormholeId];
        require(source.addr == sourceAddr.toAddress(), InvalidSource());
        require(msg.sender == address(relayer), NotWormholeRelayer());

        gateway.handle(source.centrifugeId, payload);
    }

    // --- Outgoing ---
    function send(uint32 chainId, bytes calldata payload) public {
        require(msg.sender == address(gateway), NotGateway());
        Destination memory target = destinations[chainId];
        require(target.wormholeId != 0, UnknownChainId());

        uint256 gasLimit = 1; // TODO

        relayer.sendPayloadToEvm{value: address(this).balance}(
            target.wormholeId, target.addr, payload, 0, gasLimit, refundChain, address(gateway)
        );
    }

    /// @inheritdoc IAdapter
    function estimate(uint32 chainId, bytes calldata, uint256 baseCost)
        public
        view
        returns (uint256 nativePriceQuote)
    {
        /// TODO: Wormhole assumes passing gasLimit and estimating based on this
        (nativePriceQuote,) = relayer.quoteEVMDeliveryPrice(destinations[chainId].wormholeId, 0, baseCost);
    }

    /// @inheritdoc IAdapter
    function pay(uint32, /*chainId*/ bytes calldata, /* payload */ address refund_) public payable {
        gasPaid += msg.value;
        refund = refund_;
    }
}
