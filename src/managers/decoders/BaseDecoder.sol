// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

contract BaseDecoder {
    error FunctionNotImplemented(bytes _calldata);

    // @desc The spender address to approve
    // @tag spender:address
    function approve(address spender, uint256) external pure returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(spender);
    }

    // @desc deposit into the balance sheet
    function deposit(PoolId poolId, ShareClassId scId, address asset, uint256, uint128)
        external
        view
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(poolId, scId, asset);
    }

    // @desc withdraw from the balance sheet
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
