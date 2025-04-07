// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {IAdapter} from "src/common/interfaces/IAdapter.sol";

import "forge-std/console2.sol";


contract MockGateway {
    bool public isBatching;


    receive() external payable {
    }

    //----------------------------------------------------------------------------------------------
    // Administration methods
    //----------------------------------------------------------------------------------------------

    function file(bytes32 what, IAdapter[] calldata addresses) external  {
        
    }

    function file(bytes32 what, address instance) external  {
        
    }

    function recoverTokens(address token, address receiver, uint256 amount) external  {
       
    }

    //----------------------------------------------------------------------------------------------
    // Incomming methods
    //----------------------------------------------------------------------------------------------

    /// @dev Handle a batch of messages
    function handle(uint32 chainId, bytes memory message) external  {
       
    }

    /// @dev Handle an isolated message
    function _handle(uint32 chainId, bytes memory payload, IAdapter adapter_, bool isRecovery) internal {
          
    }

    function _handleRecovery(bytes memory message) internal {
    }

    function disputeMessageRecovery(IAdapter adapter, bytes32 messageHash) external  {
    }

    function executeMessageRecovery(IAdapter adapter, bytes calldata message) external {
      
    }

    //----------------------------------------------------------------------------------------------
    // Outgoing methods
    //----------------------------------------------------------------------------------------------

    function send(uint32 chainId, bytes calldata message) external   {
    
    }

    function topUp() external payable {
        
    }

    function startBatching() external {
    }

    function endBatching() external {
    }

    function payTransaction() external payable {
    }


    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    function estimate(uint32 chainId, bytes calldata payload)
        external
        view
        returns (uint256[] memory perAdapter, uint256 total)
    {
        
    }
}
