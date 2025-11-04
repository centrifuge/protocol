// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "../../misc/libraries/CastLib.sol";
import {ETH_ADDRESS, IRecoverable} from "../../misc/interfaces/IRecoverable.sol";

import {Spoke} from "../../core/spoke/Spoke.sol";
import {PoolId} from "../../core/types/PoolId.sol";
import {AssetId} from "../../core/types/AssetId.sol";
import {HubRegistry} from "../../core/hub/HubRegistry.sol";
import {VaultKind} from "../../core/spoke/interfaces/IVault.sol";
import {MessageDispatcher} from "../../core/messaging/MessageDispatcher.sol";

import {Root} from "../../admin/Root.sol";

import {BaseVault} from "../../vaults/BaseVaults.sol";
import {SyncManager} from "../../vaults/SyncManager.sol";
import {AsyncRequestManager} from "../../vaults/AsyncRequestManager.sol";

PoolId constant GLOBAL_POOL = PoolId.wrap(0);

contract MessageDispatcherInfallibleMock {
    MessageDispatcher original;

    constructor(MessageDispatcher original_) {
        original = original_;
    }

    function localCentrifugeId() external view returns (uint16) {
        return original.localCentrifugeId();
    }
    function sendRegisterAsset(uint16 centrifugeId, AssetId assetId, uint8 decimals, address refund) external payable {}
}

interface GatewayV3Like {
    function subsidy(PoolId) external view returns (uint96 value, IRecoverable refund);
    function recoverTokens(address token, address receiver, uint256 amount) external;
}

struct OldContracts {
    address gateway;
    address spoke;
    address hubRegistry;
    address asyncRequestManager;
    address syncManager;
}

struct GeneralParamsInput {
    OldContracts v3;
    Root root;
    Spoke spoke;
    HubRegistry hubRegistry;
    MessageDispatcher messageDispatcher;
    AsyncRequestManager asyncRequestManager;
    SyncManager syncManager;

    AssetId[] spokeAssetIds;
    AssetId[] hubAssetIds;
    address[] vaults;
}

contract GeneralMigrationSpell {
    using CastLib for *;

    address public owner;
    string public constant description = "General migration from v3.0.1 to v3.1";

    constructor(address owner_) {
        owner = owner_;
    }

    function cast(GeneralParamsInput memory input) external {
        require(owner == msg.sender, "not authorized");
        owner = address(0);

        address[] memory contracts = _authorizedContracts(input);
        for (uint256 i; i < contracts.length; i++) {
            input.root.relyContract(address(contracts[i]), address(this));
        }

        MessageDispatcherInfallibleMock messageDispatcherMock =
            new MessageDispatcherInfallibleMock(input.messageDispatcher);
        input.spoke.file("sender", address(messageDispatcherMock));

        _migrateGeneral(input);

        input.spoke.file("sender", address(input.messageDispatcher));

        for (uint256 i; i < contracts.length; i++) {
            input.root.denyContract(address(contracts[i]), address(this));
        }
    }

    function _authorizedContracts(GeneralParamsInput memory input) internal pure returns (address[] memory) {
        address[] memory contracts = new address[](3);
        contracts[0] = address(input.spoke);
        contracts[1] = address(input.hubRegistry);
        contracts[2] = address(input.v3.gateway);
        return contracts;
    }

    function _migrateGeneral(GeneralParamsInput memory input) internal {
        // ----- ASSETS -----
        for (uint256 i; i < input.spokeAssetIds.length; i++) {
            AssetId assetId = input.spokeAssetIds[i];
            (address erc20,) = Spoke(input.v3.spoke).idToAsset(assetId);
            input.spoke.registerAsset(assetId.centrifugeId(), erc20, 0, address(0));
        }

        for (uint256 i; i < input.hubAssetIds.length; i++) {
            AssetId assetId = input.hubAssetIds[i];
            if (assetId.centrifugeId() != 0) {
                uint8 decimals = HubRegistry(input.v3.hubRegistry).decimals(assetId);
                input.hubRegistry.registerAsset(assetId, decimals);
            }
        }

        // ----- GATEWAY -----
        // Transfer global pool funds from the gateway to msg.sender
        (uint96 subsidizedFunds,) = GatewayV3Like(input.v3.gateway).subsidy(GLOBAL_POOL);
        GatewayV3Like(input.v3.gateway).recoverTokens(ETH_ADDRESS, msg.sender, subsidizedFunds);

        // ----- VAULS -----
        for (uint256 i; i < input.vaults.length; i++) {
            BaseVault vault = BaseVault(input.vaults[i]);
            input.root.relyContract(address(vault), address(this));

            input.root.relyContract(address(vault), address(input.asyncRequestManager));
            input.root.relyContract(address(input.asyncRequestManager), address(vault));

            input.root.denyContract(address(vault), address(input.v3.asyncRequestManager));
            input.root.denyContract(address(input.v3.asyncRequestManager), address(vault));

            vault.file("manager", address(input.asyncRequestManager));
            vault.file("asyncRedeemManager", address(input.asyncRequestManager));

            if (vault.vaultKind() == VaultKind.SyncDepositAsyncRedeem) {
                input.root.relyContract(address(vault), address(input.syncManager));
                input.root.relyContract(address(input.syncManager), address(vault));

                input.root.denyContract(address(vault), input.v3.syncManager);
                input.root.denyContract(address(input.v3.syncManager), address(vault));

                vault.file("syncDepositManager", address(input.syncManager));
            }

            input.root.denyContract(address(vault), address(this));
        }
    }
}
