// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import {IAdapter} from "src/common/interfaces/IAdapter.sol";

// From https://github.com/wormhole-foundation/wormhole-solidity-sdk/blob/main/src/interfaces/IWormholeRelayer.sol#L75
interface IWormholeRelayer {
    /**
     * @notice Publishes an instruction for the default delivery provider
     * to relay a payload to the address `targetAddress` on chain `targetChain`
     * with gas limit `gasLimit` and `msg.value` equal to `receiverValue`
     *
     * Any refunds (from leftover gas) will be sent to `refundAddress` on chain `refundChain`
     * `targetAddress` must implement the IWormholeReceiver interface
     *
     * This function must be called with `msg.value` equal to `quoteEVMDeliveryPrice(targetChain, receiverValue,
     * gasLimit)`
     *
     * @param targetChain in Wormhole Chain ID format
     * @param targetAddress address to call on targetChain (that implements IWormholeReceiver)
     * @param payload arbitrary bytes to pass in as parameter in call to `targetAddress`
     * @param receiverValue msg.value that delivery provider should pass in for call to `targetAddress` (in targetChain
     * currency units)
     * @param gasLimit gas limit with which to call `targetAddress`. Any units of gas unused will be refunded according
     * to the
     *        `targetChainRefundPerGasUnused` rate quoted by the delivery provider
     * @param refundChain The chain to deliver any refund to, in Wormhole Chain ID format
     * @param refundAddress The address on `refundChain` to deliver any refund to
     * @return sequence sequence number of published VAA containing delivery instructions
     */
    function sendPayloadToEvm(
        uint16 targetChain,
        address targetAddress,
        bytes memory payload,
        uint256 receiverValue,
        uint256 gasLimit,
        uint16 refundChain,
        address refundAddress
    ) external payable returns (uint64 sequence);

    /**
     * @notice Returns the price to request a relay to chain `targetChain`, using the default delivery provider
     *
     * @param targetChain in Wormhole Chain ID format
     * @param receiverValue msg.value that delivery provider should pass in for call to `targetAddress` (in targetChain
     * currency units)
     * @param gasLimit gas limit with which to call `targetAddress`.
     * @return nativePriceQuote Price, in units of current chain currency, that the delivery provider charges to perform
     * the relay
     * @return targetChainRefundPerGasUnused amount of target chain currency that will be refunded per unit of gas
     * unused,
     *         if a refundAddress is specified.
     *         Note: This value can be overridden by the delivery provider on the target chain. The returned value here
     * should be considered to be a
     *         promise by the delivery provider of the amount of refund per gas unused that will be returned to the
     * refundAddress at the target chain.
     *         If a delivery provider decides to override, this will be visible as part of the emitted Delivery event on
     * the target chain.
     */
    function quoteEVMDeliveryPrice(uint16 targetChain, uint256 receiverValue, uint256 gasLimit)
        external
        view
        returns (uint256 nativePriceQuote, uint256 targetChainRefundPerGasUnused);

    /**
     * @notice Returns the address of the current default delivery provider
     * @return deliveryProvider The address of (the default delivery provider)'s contract on this source
     *   chain. This must be a contract that implements IDeliveryProvider.
     */
    function getDefaultDeliveryProvider() external view returns (address deliveryProvider);
}

interface IWormholeDeliveryProvider {
    /// @notice Returns the chain ID.
    function chainId() external view returns (uint16);
}

// From
// https://github.com/wormhole-foundation/wormhole/blob/main/relayer/ethereum/contracts/interfaces/relayer/IWormholeReceiver.sol
interface IWormholeReceiver {
    /**
     * @notice When a `send` is performed with this contract as the target, this function will be
     *     invoked by the WormholeRelayer contract
     *
     * NOTE: This function should be restricted such that only the Wormhole Relayer contract can call it.
     *
     * We also recommend that this function checks that `sourceChain` and `sourceAddress` are indeed who
     *       you expect to have requested the calling of `send` on the source chain
     *
     * The invocation of this function corresponding to the `send` request will have msg.value equal
     *   to the receiverValue specified in the send request.
     *
     * If the invocation of this function reverts or exceeds the gas limit
     *   specified by the send requester, this delivery will result in a `ReceiverFailure`.
     *
     * @param payload - an arbitrary message which was included in the delivery by the
     *     requester. This message's signature will already have been verified (as long as msg.sender is the Wormhole
     * Relayer contract)
     * @param additionalMessages - Additional messages which were requested to be included in this delivery.
     *      Note: There are no contract-level guarantees that the messages in this array are what was requested
     *      so **you should verify any sensitive information given here!**
     *
     *      For example, if a 'VaaKey' was specified on the source chain, then MAKE SURE the corresponding message here
     *      has valid signatures (by calling `parseAndVerifyVM(message)` on the Wormhole core contract)
     *
     *      This field can be used to perform and relay TokenBridge or CCTP transfers, and there are example
     *      usages of this at
     *         https://github.com/wormhole-foundation/hello-token
     *         https://github.com/wormhole-foundation/hello-cctp
     *
     * @param sourceAddress - the (wormhole format) address on the sending chain which requested
     *     this delivery.
     * @param sourceChain - the wormhole chain ID where this delivery was requested.
     * @param deliveryHash - the VAA hash of the deliveryVAA.
     *
     */
    function receiveWormholeMessages(
        bytes memory payload,
        bytes[] memory additionalMessages,
        bytes32 sourceAddress,
        uint16 sourceChain,
        bytes32 deliveryHash
    ) external payable;
}

struct WormholeSource {
    uint16 centrifugeId;
    address addr;
}

struct WormholeDestination {
    uint16 wormholeId;
    address addr;
}

interface IWormholeAdapter is IAdapter, IWormholeReceiver {
    /// @dev see file() method
    event File(bytes32 indexed what, uint16 fromChainId, uint16 toChainId, address addr);

    error FileUnrecognizedParam();
    error NotWormholeRelayer();
    error InvalidSource();

    /// @dev Configures the adapter
    /// @param what Can be "sources" or "destinations".
    /// @param addr if what == "sources", it represents the source
    /// @param addr if what == "destinations", it represents the destination
    function file(bytes32 what, uint16 centrifugeId, uint16 wormholeId, address addr) external;
}
