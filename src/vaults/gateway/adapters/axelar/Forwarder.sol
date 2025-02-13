// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Auth} from "src/Auth.sol";
import {IAxelarGateway} from "src/gateway/adapters/axelar/Adapter.sol";
import {IPrecompile} from "src/interfaces/misc/IPrecompile.sol";

// A contract to be deployed on Centrifuge-EVM in order to forward axelar tx to
// the precompile.
contract AxelarForwarder is Auth {
    // Represents the precompile address on Centrifuge. Precompile is located at `address(2048)` which is
    // 0x0000000000000000000000000000000000000800 in hex.
    address internal constant PRECOMPILE = 0x0000000000000000000000000000000000000800;

    IAxelarGateway public axelarGateway;

    // --- Events ---
    event File(bytes32 indexed what, address data);
    event Forwarded(bytes32 commandId, string sourceChain, string sourceAddress, bytes payload);

    constructor(address axelarGateway_) Auth(msg.sender) {
        axelarGateway = IAxelarGateway(axelarGateway_);
    }

    // --- Administration ---
    function file(bytes32 what, address data) external auth {
        if (what == "axelarGateway") {
            axelarGateway = IAxelarGateway(data);
        } else {
            revert("AxelarForwarder/file-unrecognized-param");
        }

        emit File(what, data);
    }

    // --- Incoming ---
    function execute(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) public {
        require(
            axelarGateway.validateContractCall(commandId, sourceChain, sourceAddress, keccak256(payload)),
            "AxelarForwarder/not-approved-by-gateway"
        );

        IPrecompile precompile = IPrecompile(PRECOMPILE);
        precompile.execute(commandId, sourceChain, sourceAddress, payload);

        emit Forwarded(commandId, sourceChain, sourceAddress, payload);
    }

    function executeWithToken(
        bytes32, //commandId,
        string calldata, //sourceChain,
        string calldata, //sourceAddress,
        bytes calldata, //payload,
        string calldata, //tokenSymbol,
        uint256 //amount
    ) external pure {
        revert("AxelarForwarder/execute-with-token-not-supported");
    }
}
