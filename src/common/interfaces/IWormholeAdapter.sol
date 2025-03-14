// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

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
}

interface IWormholeAdapter is IAdapter {
    event File(bytes32 indexed what, uint32 centrifugeId, uint16 wormholeId, address addr);
    event File(bytes32 indexed what, uint16 wormholeID, bytes32 sourceAddress);

    error FileUnrecognizedParam();
    error NotWormholeRelayer();
    error InvalidSource(uint16 sourceChain, bytes32 sourceAddress);

    function file(bytes32 what, uint32 centrifugeId, uint16 wormholeId, address addr) external;
    function file(bytes32 what, uint16 wormholeId, bytes32 sourceAddress) external;

    // --- Incoming ---
    /// @notice Execute a message
    /// @dev    Relies on Wormhole to ensure messages cannot be executed more than once.
    function receiveWormholeMessages(
        bytes memory payload,
        bytes[] memory, /* additionalVaas */
        bytes32 sourceAddress,
        uint16 sourceChain,
        bytes32 /* deliveryHash */
    ) external;
}
