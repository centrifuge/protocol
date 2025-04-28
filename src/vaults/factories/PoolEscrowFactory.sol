// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";

import {PoolId} from "src/common/types/PoolId.sol";

import {IPoolEscrowProvider, IPoolEscrowFactory} from "src/vaults/interfaces/factories/IPoolEscrowFactory.sol";
import {IPoolEscrow} from "src/vaults/interfaces/IEscrow.sol";
import {PoolEscrow} from "src/vaults/Escrow.sol";

contract PoolEscrowFactory is IPoolEscrowFactory, Auth {
    address public immutable root;

    address public poolManager;
    address public gateway;
    address public balanceSheet;
    address public asyncRequestManager;

    mapping(PoolId poolId => IPoolEscrow) public escrows;

    constructor(address root_, address deployer) Auth(deployer) {
        root = root_;
    }

    /// @inheritdoc IPoolEscrowFactory
    function file(bytes32 what, address data) external auth {
        if (what == "poolManager") poolManager = data;
        else if (what == "gateway") gateway = data;
        else if (what == "balanceSheet") balanceSheet = data;
        else if (what == "asyncRequestManager") asyncRequestManager = data;
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    /// @inheritdoc IPoolEscrowFactory
    function newEscrow(PoolId poolId) public auth returns (IPoolEscrow) {
        require(address(escrows[poolId]) == address(0), EscrowAlreadyDeployed());
        PoolEscrow escrow_ = new PoolEscrow{salt: bytes32(uint256(poolId.raw()))}(poolId, address(this));

        escrow_.rely(root);
        escrow_.rely(gateway);
        escrow_.rely(poolManager);
        escrow_.rely(balanceSheet);
        escrow_.rely(asyncRequestManager);

        escrow_.deny(address(this));

        escrows[poolId] = escrow_;

        emit DeployPoolEscrow(poolId, address(escrow_));
        return IPoolEscrow(escrow_);
    }

    // --- View methods ---
    /// @inheritdoc IPoolEscrowProvider
    function escrow(PoolId poolId) external view returns (IPoolEscrow) {
        bytes32 salt = bytes32(uint256(poolId.raw()));
        bytes memory bytecode = abi.encodePacked(type(PoolEscrow).creationCode, abi.encode(poolId, address(this)));

        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(bytecode)));

        return IPoolEscrow(address(uint160(uint256(hash))));
    }

    /// @inheritdoc IPoolEscrowProvider
    function deployedEscrow(PoolId poolId) external view returns (IPoolEscrow) {
        return escrows[poolId];
    }
}
