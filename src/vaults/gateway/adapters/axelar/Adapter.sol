// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {
    IAxelarAdapter,
    IAdapter,
    IAxelarGateway,
    IAxelarGasService
} from "src/interfaces/gateway/adapters/IAxelarAdapter.sol";
import {IGateway} from "src/interfaces/gateway/IGateway.sol";
import {Auth} from "src/Auth.sol";
import {IGateway} from "src/interfaces/gateway/IGateway.sol";

/// @title  Axelar Adapter
/// @notice Routing contract that integrates with an Axelar Gateway
contract AxelarAdapter is Auth, IAxelarAdapter {
    string public constant CENTRIFUGE_ID = "centrifuge";
    string public constant CENTRIFUGE_AXELAR_EXECUTABLE = "0xc1757c6A0563E37048869A342dF0651b9F267e41";

    IGateway public immutable gateway;
    bytes32 public immutable centrifugeIdHash;
    bytes32 public immutable centrifugeAddressHash;
    IAxelarGateway public immutable axelarGateway;
    IAxelarGasService public immutable axelarGasService;

    /// @inheritdoc IAxelarAdapter
    uint256 public axelarCost = 58_039_058_122_843;

    constructor(address gateway_, address axelarGateway_, address axelarGasService_) Auth(msg.sender) {
        gateway = IGateway(gateway_);
        axelarGateway = IAxelarGateway(axelarGateway_);
        axelarGasService = IAxelarGasService(axelarGasService_);

        centrifugeIdHash = keccak256(bytes(CENTRIFUGE_ID));
        centrifugeAddressHash = keccak256(bytes("0x7369626CEF070000000000000000000000000000"));
    }

    // --- Administrative ---
    /// @inheritdoc IAxelarAdapter
    function file(bytes32 what, uint256 value) external auth {
        if (what == "axelarCost") axelarCost = value;
        else revert("AxelarAdapterfile-unrecognized-param");
        emit File(what, value);
    }

    // --- Incoming ---
    /// @inheritdoc IAxelarAdapter
    function execute(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) public {
        require(keccak256(bytes(sourceChain)) == centrifugeIdHash, "AxelarAdapter/invalid-chain");
        require(keccak256(bytes(sourceAddress)) == centrifugeAddressHash, "AxelarAdapter/invalid-address");
        require(
            axelarGateway.validateContractCall(commandId, sourceChain, sourceAddress, keccak256(payload)),
            "AxelarAdapter/not-approved-by-axelar-gateway"
        );

        gateway.handle(payload);
    }

    // --- Outgoing ---
    function send(bytes calldata payload) public {
        require(msg.sender == address(gateway), "AxelarAdapter/not-gateway");
        axelarGateway.callContract(CENTRIFUGE_ID, CENTRIFUGE_AXELAR_EXECUTABLE, payload);
    }

    /// @inheritdoc IAdapter
    /// @dev Currently the payload (message) is not taken into consideration during cost estimation
    ///      A predefined `axelarCost` value is used.
    function estimate(bytes calldata, uint256 baseCost) public view returns (uint256) {
        return baseCost + axelarCost;
    }

    /// @inheritdoc IAdapter
    function pay(bytes calldata payload, address refund) public payable {
        axelarGasService.payNativeGasForContractCall{value: msg.value}(
            address(this), CENTRIFUGE_ID, CENTRIFUGE_AXELAR_EXECUTABLE, payload, refund
        );
    }
}
