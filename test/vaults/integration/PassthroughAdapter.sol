// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/vaults/Auth.sol";
import {IAdapter} from "src/vaults/interfaces/gateway/IAdapter.sol";

interface PrecompileLike {
    function execute(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) external;
}

interface GatewayLike {
    function handle(bytes memory message) external;
}

/// @title  PassthroughAdapter
/// @notice Routing contract that accepts any incomming messages and forwards them
///         to the gateway and solely emits an event for outgoing messages.
contract PassthroughAdapter is Auth, IAdapter {
    address internal constant PRECOMPILE = 0x0000000000000000000000000000000000000800;
    bytes32 internal constant FAKE_COMMAND_ID = keccak256("FAKE_COMMAND_ID");

    GatewayLike public gateway;
    string public sourceChain;
    string public sourceAddress;

    event Route(string destinationChain, string destinationContractAddress, bytes payload);
    event ExecuteOnDomain(string sourceChain, string sourceAddress, bytes payload);
    event ExecuteOnCentrifuge(string sourceChain, string sourceAddress, bytes payload);
    event File(bytes32 indexed what, address addr);
    event File(bytes32 indexed what, string data);

    constructor() Auth(msg.sender) {}

    // --- Administrative ---
    function file(bytes32 what, address addr) external auth {
        if (what == "gateway") {
            gateway = GatewayLike(addr);
        } else {
            revert("PassthroughAdapter/file-unrecognized-param");
        }

        emit File(what, addr);
    }

    function file(bytes32 what, string calldata data) external auth {
        if (what == "sourceChain") {
            sourceChain = data;
        } else if (what == "sourceAddress") {
            sourceAddress = data;
        } else {
            revert("PassthroughAdapter/file-unrecognized-param");
        }

        emit File(what, data);
    }

    /// --- Incoming ---
    /// @notice From Centrifuge to LP on other domain. Just emits an event.
    ///         Just used on Centrifuge.
    function callContract(
        string calldata destinationChain,
        string calldata destinationContractAddress,
        bytes calldata payload
    ) public {
        emit Route(destinationChain, destinationContractAddress, payload);
    }

    /// --- Outgoing ---
    /// @inheritdoc IAdapter
    /// @notice From other domain to Centrifuge. Just emits an event.
    ///         Just used on EVM domains.
    function send(bytes calldata message) public {
        emit Route(sourceChain, sourceAddress, message);
    }

    /// @notice Execute message on centrifuge
    function executeOnCentrifuge(string calldata _sourceChain, string calldata _sourceAddress, bytes calldata payload)
        external
    {
        PrecompileLike precompile = PrecompileLike(PRECOMPILE);
        precompile.execute(FAKE_COMMAND_ID, _sourceChain, _sourceAddress, payload);

        emit ExecuteOnCentrifuge(_sourceChain, _sourceAddress, payload);
    }

    /// @notice Execute message on other domain
    function executeOnDomain(string calldata _sourceChain, string calldata _sourceAddress, bytes calldata payload)
        external
    {
        gateway.handle(payload);
        emit ExecuteOnDomain(_sourceChain, _sourceAddress, payload);
    }

    /// @inheritdoc IAdapter
    function estimate(bytes calldata, uint256) external pure returns (uint256) {
        return 0;
    }

    /// @inheritdoc IAdapter
    function pay(bytes calldata, address) public payable {
        return;
    }

    // Added to be ignored in coverage report
    function test() public {}
}
