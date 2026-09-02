// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";

import {AsyncVaultFactory} from "../../../src/vaults/factories/AsyncVaultFactory.sol";
import {SyncDepositVaultFactory} from "../../../src/vaults/factories/SyncDepositVaultFactory.sol";
import {
    IAsyncRequestManager,
    ISyncDepositManager,
    IAsyncRedeemManager
} from "../../../src/vaults/interfaces/IVaultManagers.sol";

import "forge-std/Test.sol";

/// @dev Minimal share token: the vault constructor only reads `decimals()`.
contract Token {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}

/// @dev Empty contract so `vm.mockCall` (for manager `rely`) has code to target.
contract Stub {}

contract VaultFactoryTest is Test {
    PoolId poolId = PoolId.wrap(1);
    ShareClassId scId = ShareClassId.wrap(bytes16("sc1"));
    address asset = makeAddr("asset");
    address root = makeAddr("root");
    address token = address(new Token());

    function testAsyncFactoryGetVaultMatchesDeploy() public {
        address manager = address(new Stub());
        vm.mockCall(manager, abi.encodeWithSelector(IAuth.rely.selector), "");
        AsyncVaultFactory factory = new AsyncVaultFactory(root, IAsyncRequestManager(manager), address(this));

        address predicted = factory.getVault(poolId, scId, asset, 0, token, "");

        address deployed = factory.newVault(poolId, scId, asset, 0, token, "");

        assertEq(deployed, predicted, "prediction must match deployment");
    }

    function testSyncFactoryGetVaultMatchesDeploy() public {
        address syncManager = address(new Stub());
        address asyncRedeem = address(new Stub());
        vm.mockCall(syncManager, abi.encodeWithSelector(IAuth.rely.selector), "");
        vm.mockCall(asyncRedeem, abi.encodeWithSelector(IAuth.rely.selector), "");
        SyncDepositVaultFactory factory = new SyncDepositVaultFactory(
            root, ISyncDepositManager(syncManager), IAsyncRedeemManager(asyncRedeem), address(this)
        );

        address predicted = factory.getVault(poolId, scId, asset, 0, token, "");

        address deployed = factory.newVault(poolId, scId, asset, 0, token, "");

        assertEq(deployed, predicted, "prediction must match deployment");
    }
}
