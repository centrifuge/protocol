// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "../../misc/Auth.sol";
import {IAuth} from "../../misc/interfaces/IAuth.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {IVaultFactory} from "../../core/spoke/factories/interfaces/IVaultFactory.sol";

import {SyncDepositVault} from "../SyncDepositVault.sol";
import {IShareToken} from "../../token/interfaces/IShareToken.sol";
import {IAsyncRedeemManager, ISyncDepositManager} from "../interfaces/IVaultManagers.sol";

/// @title  Sync Vault Factory
/// @dev    Utility for deploying new vault contracts
contract SyncDepositVaultFactory is Auth, IVaultFactory {
    address public immutable root;
    ISyncDepositManager public immutable syncDepositManager;
    IAsyncRedeemManager public immutable asyncRedeemManager;

    constructor(
        address root_,
        ISyncDepositManager syncDepositManager_,
        IAsyncRedeemManager asyncRedeemManager_,
        address deployer
    ) Auth(deployer) {
        root = root_;
        syncDepositManager = syncDepositManager_;
        asyncRedeemManager = asyncRedeemManager_;
    }

    /// @inheritdoc IVaultFactory
    /// @dev The trailing payload is unused: this factory needs no extra deployment configuration.
    function newVault(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId, address token, bytes calldata)
        public
        auth
        returns (address)
    {
        require(tokenId == 0, UnsupportedTokenId());

        bytes32 salt = keccak256(abi.encode(poolId, scId, asset));
        SyncDepositVault vault = new SyncDepositVault{salt: salt}(
            poolId, scId, asset, IShareToken(token), root, syncDepositManager, asyncRedeemManager
        );

        vault.rely(root);
        vault.rely(address(syncDepositManager));
        vault.rely(address(asyncRedeemManager));

        IAuth(address(syncDepositManager)).rely(address(vault));
        IAuth(address(asyncRedeemManager)).rely(address(vault));

        vault.deny(address(this));
        return address(vault);
    }

    /// @inheritdoc IVaultFactory
    /// @dev The trailing payload is unused: the deployed address does not depend on it.
    function getVault(PoolId poolId, ShareClassId scId, address asset, uint256, address token, bytes calldata)
        external
        view
        returns (address)
    {
        bytes32 salt = keccak256(abi.encode(poolId, scId, asset));
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(SyncDepositVault).creationCode,
                abi.encode(poolId, scId, asset, IShareToken(token), root, syncDepositManager, asyncRedeemManager)
            )
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }
}
