// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {PoolId} from "../../../core/types/PoolId.sol";
import {ShareClassId} from "../../../core/types/ShareClassId.sol";

contract BaseDecoder {
    error FunctionNotImplemented(bytes _calldata);

    /// @notice Approve ERC20 assets for transfer
    /// @param  spender the spender address to approve
    function approve(
        address spender,
        uint256 /* amount */
    )
        external
        pure
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(spender);
    }

    /// @notice Approve ERC6909 assets for transfer
    /// @param  spender the spender address to approve
    /// @param  tokenId ID of the token being approved
    function approve(
        address spender,
        uint256 tokenId,
        uint256 /* amount */
    )
        external
        pure
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(spender, tokenId);
    }

    /// @notice Deposit into the balance sheet
    /// @param  poolId ID of the pool
    /// @param  scId ID of the share class
    /// @param  asset ERC20/ERC6909 asset that is deposited
    /// @param  tokenId ID of the token being deposited (for ERC6909)
    function deposit(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        uint128 /* amount */
    )
        external
        view
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(poolId, scId, asset, tokenId);
    }

    /// @notice Withdraw from the balance sheet
    /// @param  poolId ID of the pool
    /// @param  scId ID of the share class
    /// @param  asset ERC20/ERC6909 asset that is deposited
    /// @param  tokenId ID of the token being withdrawn (for ERC6909)
    /// @param  receiver account of the withdrawn assets
    function withdraw(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        address receiver,
        uint128 /* amount */
    )
        external
        view
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(poolId, scId, asset, tokenId, receiver);
    }

    fallback() external {
        revert FunctionNotImplemented(msg.data);
    }
}
