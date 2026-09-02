// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth, IAuth} from "../../misc/Auth.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {IVaultFactory} from "../../core/spoke/factories/interfaces/IVaultFactory.sol";

import {AsyncVault} from "../AsyncVault.sol";
import {IShareToken} from "../../token/interfaces/IShareToken.sol";
import {IAsyncRequestManager} from "../interfaces/IVaultManagers.sol";

/// @title  ERC7540 Vault Factory
/// @dev    Utility for deploying new vault contracts
contract AsyncVaultFactory is Auth, IVaultFactory {
    address public immutable root;
    IAsyncRequestManager public immutable asyncRequestManager;

    constructor(address root_, IAsyncRequestManager asyncRequestManager_, address deployer) Auth(deployer) {
        root = root_;
        asyncRequestManager = asyncRequestManager_;
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
        AsyncVault vault =
            new AsyncVault{salt: salt}(poolId, scId, asset, IShareToken(token), root, asyncRequestManager);

        vault.rely(root);
        vault.rely(address(asyncRequestManager));

        IAuth(address(asyncRequestManager)).rely(address(vault));

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
                type(AsyncVault).creationCode,
                abi.encode(poolId, scId, asset, IShareToken(token), root, asyncRequestManager)
            )
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }
}
