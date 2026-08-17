// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IPoolEscrowProvider, IPoolEscrowFactory} from "./interfaces/IPoolEscrowFactory.sol";

import {Auth} from "../../../misc/Auth.sol";

import {PoolEscrow} from "../PoolEscrow.sol";
import {PoolId} from "../../types/PoolId.sol";
import {IPoolEscrow} from "../interfaces/IPoolEscrow.sol";

contract PoolEscrowFactory is Auth, IPoolEscrowFactory {
    address public immutable root;

    address public spoke;

    mapping(address escrow => PoolId) public poolId;

    constructor(address root_, address deployer) Auth(deployer) {
        root = root_;
    }

    /// @inheritdoc IPoolEscrowFactory
    function file(bytes32 what, address data) external auth {
        if (what == "spoke") spoke = data;
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    /// @inheritdoc IPoolEscrowFactory
    function newEscrow(PoolId poolId_) public auth returns (IPoolEscrow) {
        PoolEscrow escrow_ = new PoolEscrow{salt: bytes32(uint256(poolId_.raw()))}(poolId_, address(this));

        poolId[address(escrow_)] = poolId_;

        escrow_.rely(root);
        escrow_.rely(spoke);

        escrow_.deny(address(this));

        emit DeployPoolEscrow(poolId_, address(escrow_));
        return IPoolEscrow(escrow_);
    }

    /// @inheritdoc IPoolEscrowProvider
    function escrow(PoolId poolId_) external view returns (IPoolEscrow) {
        bytes32 salt = bytes32(uint256(poolId_.raw()));
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(abi.encodePacked(type(PoolEscrow).creationCode, abi.encode(poolId_, address(this))))
            )
        );

        return IPoolEscrow(address(uint160(uint256(hash))));
    }
}
