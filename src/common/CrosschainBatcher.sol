// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IGateway} from "./interfaces/IGateway.sol";
import {ICrosschainBatcher} from "./interfaces/ICrosschainBatcher.sol";

import {Auth} from "../misc/Auth.sol";

/// @title  CrosschainBatcher
/// @dev    Helper contract that enables integrations to automatically batch multiple cross-chain tansactions.
///         Should be used like:
///         ```
///         contract Integration {
///             ICrosschainBatcher batcher;
///
///             function doSomething(PoolId poolId) external {
///                 batcher.execute(abi.encodeWithSelector(Integration.callback.selector, poolId));
///             }
///
///             function callback(PoolId poolId) external {
///                 require(batcher.sender() == address(this));
///                 // Call several hub, balance sheet, or spoke methods that trigger cross-chain transactions
///             }
///         }
///         ```
contract CrosschainBatcher is Auth, ICrosschainBatcher {
    IGateway public gateway;
    address public transient caller;

    constructor(IGateway gateway_, address deployer) Auth(deployer) {
        gateway = gateway_;
    }

    /// @inheritdoc ICrosschainBatcher
    function file(bytes32 what, address data) external auth {
        if (what == "gateway") gateway = IGateway(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    /// @inheritdoc ICrosschainBatcher
    function execute(bytes memory data) external payable returns (uint256 cost) {
        require(caller == address(0), AlreadyBatching());

        gateway.startBatching();
        caller = msg.sender;

        (bool success, bytes memory returnData) = msg.sender.call{value: msg.value}(data);
        if (!success) {
            uint256 length = returnData.length;
            require(length != 0, CallFailedWithEmptyRevert());

            assembly ("memory-safe") {
                revert(add(32, returnData), length)
            }
        }

        caller = address(0);
        return gateway.endBatching();
    }
}
