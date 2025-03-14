// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IWormholeAdapter, IAdapter, IWormholeRelayer} from "src/common/interfaces/IWormholeAdapter.sol";
import {Auth} from "src/misc/Auth.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";

/// @title  Wormhole Adapter
/// @notice Routing contract that integrates with the Wormhole Gateway
contract WormholeAdapter is Auth, IWormholeAdapter {
    uint16 public immutable refundChain;
    IMessageHandler public immutable gateway;
    IWormholeRelayer public immutable relayer;

    mapping(uint32 centrifugeId => uint16 wormholeId) public chainIdLookup;
    mapping(uint16 wormholeId => bytes32 sourceAddress) public adapters;

    uint256 public gasLimit = 0;
    uint256 public /* transient */ gasPaid;
    address public /* transient */ refund;

    constructor(IMessageHandler gateway_, address relayer_, uint16 refundChain_) Auth(msg.sender) {
        gateway = gateway_;
        relayer = IWormholeRelayer(relayer_);
        refundChain = refundChain_;
    }

    // --- Administrative ---
    /// @inheritdoc IWormholeAdapter
    function file(bytes32 what, uint32 centrifugeId, uint16 wormholeId) external auth {
        if (what == "chainIdLookup") chainIdLookup[centrifugeId] = wormholeId;
        else revert FileUnrecognizedParam();
        emit File(what, centrifugeId, wormholeId);
    }

    /// @inheritdoc IWormholeAdapter
    function file(bytes32 what, uint16 wormholeId, bytes32 sourceAddress) external auth {
        if (what == "chainIdLookup") adapters[wormholeId] = sourceAddress;
        else revert FileUnrecognizedParam();
        emit File(what, wormholeId, sourceAddress);
    }

    // --- Incoming ---
    /// @inheritdoc IWormholeAdapter
    function receiveWormholeMessages(
        bytes memory payload,
        bytes[] memory, /* additionalVaas */
        bytes32 sourceAddress,
        uint16 sourceChain,
        bytes32 /* deliveryHash */
    ) external {
        require(msg.sender == address(relayer), NotWormholeRelayer());
        require(adapters[sourceChain] == sourceAddress, InvalidSource(sourceChain, sourceAddress));

        // TODO extract the Id from the storage of this contract
        gateway.handle(0, payload);
    }

    // --- Outgoing ---
    function send(uint32 chainId, bytes calldata payload) public {
        require(msg.sender == address(gateway), NotGateway());

        address targetAddress = address(0); // TODO

        relayer.sendPayloadToEvm{value: address(this).balance}(
            chainIdLookup[chainId], targetAddress, abi.encode(payload), 0, gasLimit, refundChain, address(gateway)
        );
    }

    /// @inheritdoc IAdapter
    function estimate(uint32 chainId, bytes calldata, uint256 /* baseCost */ )
        public
        view
        returns (uint256 nativePriceQuote)
    {
        (nativePriceQuote,) = relayer.quoteEVMDeliveryPrice(chainIdLookup[chainId], 0, gasLimit);
    }

    /// @inheritdoc IAdapter
    function pay(uint32, /*chainId*/ bytes calldata, /* payload */ address refund_) public payable {
        gasPaid = msg.value;
        refund = refund_;
    }
}
