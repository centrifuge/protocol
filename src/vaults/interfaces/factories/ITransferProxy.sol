// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.5.0;

import {IRecoverable} from "src/interfaces/IRoot.sol";

interface ITransferProxy is IRecoverable {
    event File(bytes32 indexed what, address data);

    /// @notice Updates a contract parameter
    /// @param what Accepts a bytes32 representation of 'poolManager'
    function file(bytes32 what, address data) external;

    /// @notice Anyone can transfer tokens.
    function transfer(address asset) external;
}

interface ITransferProxyFactory {
    event File(bytes32 indexed what, address data);
    event DeployTransferProxy(bytes32 indexed destination, address proxy);

    /// @notice Updates a contract parameter
    /// @param what Accepts a bytes32 representation of 'poolManager'
    function file(bytes32 what, address data) external;

    /// @notice Returns the address of the linked pool manager
    function poolManager() external view returns (address);

    /// @notice Lookup proxy by destination address
    function proxies(bytes32 destination) external view returns (address proxy);

    /// @notice Deploy new transfer proxy
    function newTransferProxy(bytes32 destination) external returns (address);

    /// @notice Returns the predicted address (using CREATE2)
    function getAddress(bytes32 destination) external view returns (address);
}
