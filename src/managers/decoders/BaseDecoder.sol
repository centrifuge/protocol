// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {PoolId} from "../../common/types/PoolId.sol";
import {ShareClassId} from "../../common/types/ShareClassId.sol";

contract BaseDecoder {
    error FunctionNotImplemented(bytes _calldata);

    /// @notice Approve ERC20 assets for transfer
    /// @param  spender the spender address to approve
    function approve(address spender, uint256) external pure returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(spender);
    }

    /// @notice Deposit into the balance sheet
    /// @param  poolId ID of the pool
    /// @param  scId ID of the share class
    /// @param  asset ERC20 asset that is deposited
    function deposit(PoolId poolId, ShareClassId scId, address asset, uint256, uint128)
        external
        view
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(poolId, scId, asset);
    }

    /// @notice Withdraw from the balance sheet
    /// @param  poolId ID of the pool
    /// @param  scId ID of the share class
    /// @param  asset ERC20 asset that is deposited
    /// @param  asset receiver account of the withdrawn assets
    function withdraw(PoolId poolId, ShareClassId scId, address asset, uint256, address receiver, uint128)
        external
        view
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(poolId, scId, asset, receiver);
    }

    fallback() external {
        revert FunctionNotImplemented(msg.data);
    }
}
