// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAccounting} from "src/pools/interfaces/IAccounting.sol";
import {AccountId} from "src/pools/types/AccountId.sol";
import {PoolId} from "src/pools/types/PoolId.sol";
import {Auth} from "src/misc/Auth.sol";
import {ITransactionId} from "src/pools/interfaces/ITransactionId.sol";

contract TransactionId is Auth, ITransactionId {
    mapping(PoolId => uint256) internal _poolCounter;

    /// @inheritdoc ITransactionId
    bytes32 public transient transactionId;

    constructor(address deployer) Auth(deployer) {}

    /// @inheritdoc ITransactionId
    function generateTransactionId(PoolId poolId) external auth returns (bytes32) {
        transactionId = bytes32(++_poolCounter[poolId]);
        return transactionId;
    }
}
