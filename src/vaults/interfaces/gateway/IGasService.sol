// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

interface IGasService {
    event File(bytes32 indexed what, uint64 value);
    event UpdateGasPrice(uint128 value, uint256 computedAt);
    event UpdateTokenPrice(uint256 value);

    /// @notice Using file patter to update state variables;
    /// @dev    Used to update the messageCost and proofCost;
    ///         It is used in occasions where update is done rarely.
    function file(bytes32 what, uint64 value) external;

    /// @notice The cost of 'message' execution on Centrifuge Chain.
    /// @dev    This is a getter method
    /// @return Amount in Weigth ( gas unit on Centrifuge Chain )
    function messageCost() external returns (uint64);

    /// @notice The cost of 'proof' execution on Centrifuge Chain.
    /// @dev    This is a getter method
    /// @return Amount in Weight ( gas unit on Centrifuge Chain )
    function proofCost() external returns (uint64);

    /// @notice Weigth Gas Price from Centrifuge Chain
    /// @dev    This is a getter method
    /// @return The current gas price on Centrifuge Chain
    function gasPrice() external returns (uint128);

    /// @notice Keeps track what was the last time when the gas price was updated
    /// @dev    This is a getter method
    /// @return Timestamp when the gas price was last updated
    function lastUpdatedAt() external returns (uint64);

    /// @notice CFG/ETH price
    /// @dev    This is a getter method
    /// @return The current price
    function tokenPrice() external returns (uint256);

    /// @notice Executes a message from the gateway
    /// @dev    The function can only be executed by the gateway contract.
    function handle(bytes calldata message) external;

    /// @notice Updates the gas price on Centrifuge Chain
    /// @dev    The update comes as a message from the Centrifuge Chain.
    /// @param  value New price in Centrifuge Chain base unit
    /// @param  computedAt Timestamp when the value was evaluated.
    function updateGasPrice(uint128 value, uint64 computedAt) external;

    /// @notice Called to update the  CFG/ETH price
    /// @param  value New price in wei
    function updateTokenPrice(uint256 value) external;

    /// @notice Estimate the total execution cost on Centrifuge Chain in ETH.
    /// @dev    Currently payload is disregarded and not included in the calculation.
    /// @param  payload Estimates the execution cost based on the payload
    /// @return Estimated cost in WEI units
    function estimate(bytes calldata payload) external view returns (uint256);

    /// @notice Used to verify if given user for a given message can take advantage of
    ///         transaction cost prepayment.
    /// @dev    This is used in the Gateway to check if the source of the transaction
    ///         is eligible for tx cost payment from Gateway's balance.
    /// @param  source Source that triggered the transaction
    /// @param  payload The message that is going to be send
    function shouldRefuel(address source, bytes calldata payload) external returns (bool);
}
