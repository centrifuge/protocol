// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";

import {
    IPoolEscrowProvider,
    IEscrowProvider,
    IPoolEscrowFactory
} from "src/vaults/interfaces/factories/IPoolEscrowFactory.sol";
import {IPoolEscrow} from "src/vaults/interfaces/IEscrow.sol";
import {PoolEscrow} from "src/vaults/Escrow.sol";

contract PoolEscrowFactory is IPoolEscrowFactory, Auth {
    uint64 public constant V2_POOL_ID = 4139607887;
    address public constant V2_GLOBAL_ESCROW = address(0x0000000005F458Fd6ba9EEb5f365D83b7dA913dD);

    address public immutable root;
    address public poolManager;
    address public balanceSheet;
    address public asyncRequests;

    mapping(uint64 poolId => address) public escrows;

    constructor(address root_, address deployer) Auth(deployer) {
        root = root_;
    }

    /// @inheritdoc IPoolEscrowFactory
    function file(bytes32 what, address data) external auth {
        if (what == "poolManager") poolManager = data;
        else if (what == "balanceSheet") balanceSheet = data;
        else if (what == "asyncRequests") asyncRequests = data;
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    /// @inheritdoc IPoolEscrowFactory
    function newEscrow(uint64 poolId) public auth returns (address) {
        require(escrows[poolId] == address(0), EscrowAlreadyDeployed());
        PoolEscrow escrow_ = new PoolEscrow{salt: bytes32(uint256(poolId))}(poolId, address(this));

        escrow_.rely(root);
        escrow_.rely(poolManager);
        escrow_.rely(balanceSheet);
        escrow_.rely(asyncRequests);

        escrow_.deny(address(this));

        escrows[poolId] = address(escrow_);

        emit DeployPoolEscrow(poolId, address(escrow_));
        return address(escrow_);
    }

    // --- View methods ---
    /// @inheritdoc IEscrowProvider
    function escrow(uint64 poolId) external view returns (address) {
        if (poolId == V2_POOL_ID) {
            return V2_GLOBAL_ESCROW;
        } else {
            return _deterministicAddress(poolId);
        }
    }

    /// @inheritdoc IPoolEscrowProvider
    function poolEscrow(uint64 poolId) external view returns (IPoolEscrow) {
        return IPoolEscrow(_deterministicAddress(poolId));
    }

    /// @inheritdoc IPoolEscrowProvider
    function deployedPoolEscrow(uint64 poolId) external view returns (address) {
        return escrows[poolId];
    }

    // --- Internal methods ---
    function _deterministicAddress(uint64 poolId) internal view returns (address) {
        bytes32 salt = bytes32(uint256(poolId));
        bytes memory bytecode = abi.encodePacked(type(PoolEscrow).creationCode, abi.encode(poolId, address(this)));

        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(bytecode)));

        return address(uint160(uint256(hash)));
    }
}
