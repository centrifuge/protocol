// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IWormholeAdapter, IAdapter, IWormholeRelayer} from "src/common/interfaces/IWormholeAdapter.sol";

struct Target {
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

    mapping(uint32 centrifugeId => Target) public targets;
    mapping(uint16 wormholeId => address source) public adapters;

    uint256 public /* transient */ gasPaid;
    address public /* transient */ refund;

    constructor(IMessageHandler gateway_, address relayer_, uint16 refundChain_) Auth(msg.sender) {
        gateway = gateway_;
        relayer = IWormholeRelayer(relayer_);
        refundChain = refundChain_;
    }

    // --- Administrative ---
    /// @inheritdoc IWormholeAdapter
    function file(bytes32 what, uint32 centrifugeId, uint16 wormholeId, address addr) external auth {
        if (what == "targets") targets[centrifugeId] = Target(wormholeId, addr);
        else revert FileUnrecognizedParam();
        emit File(what, centrifugeId, wormholeId, addr);
    }

    /// @inheritdoc IWormholeAdapter
    function file(bytes32 what, uint16 wormholeId, address sourceAddress) external auth {
        if (what == "adapters") adapters[wormholeId] = sourceAddress;
        else revert FileUnrecognizedParam();
        emit File(what, wormholeId, sourceAddress);
    }

    /// @inheritdoc IWormholeAdapter
    function receiveWormholeMessages(
        bytes memory payload,
        bytes[] memory, /* additionalVaas */
        bytes32 sourceAddress,
        uint16 sourceChain,
        bytes32 /* deliveryHash */
    ) external {
        require(msg.sender == address(relayer), NotWormholeRelayer());
        address source = sourceAddress.toAddress();
        require(adapters[sourceChain] == source, InvalidSource());

        // TODO extract the Id from the storage of this contract
        gateway.handle(0, payload);
    }

    // --- Outgoing ---
    function send(uint32 chainId, bytes calldata payload) public {
        require(msg.sender == address(gateway), NotGateway());
        Target memory target = targets[chainId];
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
        (nativePriceQuote,) = relayer.quoteEVMDeliveryPrice(targets[chainId].wormholeId, 0, baseCost);
    }

    /// @inheritdoc IAdapter
    function pay(uint32, /*chainId*/ bytes calldata, /* payload */ address refund_) public payable {
        gasPaid += msg.value;
        refund = refund_;
    }
}
