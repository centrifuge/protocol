// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../types/PoolId.sol";
import {AssetId} from "../../types/AssetId.sol";
import {ShareClassId} from "../../types/ShareClassId.sol";

interface ISpoke {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event File(bytes32 indexed what, address data);
    event RegisterAsset(
        uint16 centrifugeId,
        AssetId indexed assetId,
        address indexed asset,
        uint256 indexed tokenId,
        string name,
        string symbol,
        uint8 decimals,
        bool isInitialization
    );
    event InitiateTransferShares(
        uint16 centrifugeId,
        PoolId indexed poolId,
        ShareClassId indexed scId,
        address indexed sender,
        bytes32 destinationAddress,
        uint128 amount
    );
    event UntrustedContractUpdate(
        uint16 indexed centrifugeId,
        PoolId indexed poolId,
        ShareClassId scId,
        bytes32 target,
        bytes payload,
        address indexed sender
    );

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    error FileUnrecognizedParam();
    error TooFewDecimals();
    error TooManyDecimals();
    error AssetMissingDecimals();
    error LocalTransferNotAllowed();
    error CrossChainTransferNotAllowed();
    error InvalidRequestManager();

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @notice Updates a contract parameter
    /// @param what Accepts "spokeRegistry", "sender"
    /// @param data The new address
    function file(bytes32 what, address data) external;

    //----------------------------------------------------------------------------------------------
    // Outgoing methods
    //----------------------------------------------------------------------------------------------

    /// @notice Transfers share class tokens to a cross-chain recipient address
    /// @dev To transfer to evm chains, pad a 20 byte evm address with 12 bytes of 0
    /// @param centrifugeId The destination chain id
    /// @param poolId The centrifuge pool id
    /// @param scId The share class id
    /// @param receiver A bytes32 representation of the receiver address
    /// @param amount The amount of tokens to transfer
    /// @param extraGasLimit Extra gas limit used for computation on the intermediary hub
    /// @param remoteExtraGasLimit Extra gas limit used for computation in the destination chain
    /// @param refund Address to refund the excess of the payment
    function crosschainTransferShares(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 receiver,
        uint128 amount,
        uint128 extraGasLimit,
        uint128 remoteExtraGasLimit,
        address refund
    ) external payable;

    /// @notice Transfers share class tokens to a cross-chain recipient address (legacy)
    /// @dev Maintained for retrocompatibility. New implementers should use the above
    /// @param centrifugeId The centrifuge id of chain to where the shares are transferred
    /// @param poolId The centrifuge pool id
    /// @param scId The share class id
    /// @param receiver A bytes32 representation of the receiver address
    /// @param amount The amount of tokens to transfer
    /// @param remoteExtraGasLimit Extra gas limit used for computation in the destination chain
    function crosschainTransferShares(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 receiver,
        uint128 amount,
        uint128 remoteExtraGasLimit
    ) external payable;

    /// @notice Registers an ERC-20 or ERC-6909 asset in another chain.
    /// @dev `decimals()` MUST return a `uint8` value between 2 and 18.
    /// @dev `name()` and `symbol()` MAY return no values.
    ///
    /// @param centrifugeId The centrifuge id of chain to where the shares are transferred
    /// @param asset The address of the asset to be registered
    /// @param tokenId The token id corresponding to the asset, i.e. zero if ERC20 or non-zero if ERC6909.
    /// @param refund Address to refund the excess of the payment
    /// @return assetId The underlying internal uint128 assetId.
    function registerAsset(uint16 centrifugeId, address asset, uint256 tokenId, address refund)
        external
        payable
        returns (AssetId assetId);

    /// @notice Initiates an update to a hub-side contract from spoke
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param target The hub-side target contract (as bytes32 for cross-chain compatibility)
    /// @param payload The update payload
    /// @param extraGasLimit Additional gas for cross-chain execution
    /// @param refund Address to refund excess payment
    /// @dev Permissionless by choice, forwards caller's address to recipient for permission validation
    function updateContract(
        PoolId poolId,
        ShareClassId scId,
        bytes32 target,
        bytes calldata payload,
        uint128 extraGasLimit,
        address refund
    ) external payable;

    /// @notice Handles a request originating from the Spoke side
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @param assetId The asset id
    /// @param payload The request payload to be processed
    /// @param extraGasLimit Additional gas stipend for cross-chain execution
    /// @param unpaid Whether to allow unpaid mode
    /// @param refund Address to refund excess payment
    function request(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes memory payload,
        uint128 extraGasLimit,
        bool unpaid,
        address refund
    ) external payable;
}
