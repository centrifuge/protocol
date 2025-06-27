// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IdentityValuation} from "src/misc/IdentityValuation.sol";

import {ISafe} from "src/common/Guardian.sol";
import {AssetId, newAssetId} from "src/common/types/AssetId.sol";

import {Hub} from "src/hub/Hub.sol";
import {Holdings} from "src/hub/Holdings.sol";
import {Accounting} from "src/hub/Accounting.sol";
import {HubHelpers} from "src/hub/HubHelpers.sol";
import {HubRegistry} from "src/hub/HubRegistry.sol";
import {ShareClassManager} from "src/hub/ShareClassManager.sol";

import {CommonDeployer, CommonInput} from "script/CommonDeployer.s.sol";

import "forge-std/Script.sol";

contract HubDeployer is CommonDeployer {
    // Main contracts
    HubRegistry public hubRegistry;
    Accounting public accounting;
    Holdings public holdings;
    ShareClassManager public shareClassManager;
    HubHelpers public hubHelpers;
    Hub public hub;

    // Utilities
    IdentityValuation public identityValuation;

    // Data
    uint8 constant ISO4217_DECIMALS = 18;
    AssetId public immutable USD_ID = newAssetId(840);
    AssetId public immutable EUR_ID = newAssetId(978);

    function deployHub(CommonInput memory input, address deployer) public {
        deployCommon(input, deployer);

        // HubRegistry
        bytes32 hubRegistrySalt = generateSalt("hubRegistry");
        bytes memory hubRegistryBytecode = abi.encodePacked(type(HubRegistry).creationCode, abi.encode(deployer));
        hubRegistry = HubRegistry(create3(hubRegistrySalt, hubRegistryBytecode));

        // IdentityValuation
        bytes32 identityValuationSalt = generateSalt("identityValuation");
        bytes memory identityValuationBytecode =
            abi.encodePacked(type(IdentityValuation).creationCode, abi.encode(hubRegistry, deployer));
        identityValuation = IdentityValuation(create3(identityValuationSalt, identityValuationBytecode));

        // Accounting
        bytes32 accountingSalt = generateSalt("accounting");
        bytes memory accountingBytecode = abi.encodePacked(type(Accounting).creationCode, abi.encode(deployer));
        accounting = Accounting(create3(accountingSalt, accountingBytecode));

        // Holdings
        bytes32 holdingsSalt = generateSalt("holdings");
        bytes memory holdingsBytecode = abi.encodePacked(type(Holdings).creationCode, abi.encode(hubRegistry, deployer));
        holdings = Holdings(create3(holdingsSalt, holdingsBytecode));

        // ShareClassManager
        bytes32 shareClassManagerSalt = generateSalt("shareClassManager");
        bytes memory shareClassManagerBytecode =
            abi.encodePacked(type(ShareClassManager).creationCode, abi.encode(hubRegistry, deployer));
        shareClassManager = ShareClassManager(create3(shareClassManagerSalt, shareClassManagerBytecode));

        // Note: HubHelpers and Hub deployments were moved to separate helper functions
        // to avoid "stack too deep" compilation errors caused by too many local variables
        // in the constructor argument encoding.

        // HubHelpers
        hubHelpers = _deployHubHelpers(deployer);

        // Deploy Hub contract in a separate scope to avoid stack too deep errors
        hub = _deployHubContract(deployer);

        _poolsRegister();
        _poolsRely();
        _poolsFile();
        _poolsInitialConfig();
    }

    function _poolsRegister() private {
        register("hubRegistry", address(hubRegistry));
        register("accounting", address(accounting));
        register("holdings", address(holdings));
        register("shareClassManager", address(shareClassManager));
        register("hub", address(hub));
        register("identityValuation", address(identityValuation));
    }

    function _poolsRely() private {
        // Rely hub
        hubRegistry.rely(address(hub));
        holdings.rely(address(hub));
        accounting.rely(address(hub));
        shareClassManager.rely(address(hub));
        gateway.rely(address(hub));
        messageDispatcher.rely(address(hub));
        hubHelpers.rely(address(hub));
        poolEscrowFactory.rely(address(hub));

        // Rely hub helpers
        accounting.rely(address(hubHelpers));
        shareClassManager.rely(address(hubHelpers));
        messageDispatcher.rely(address(hubHelpers));

        // Rely others on hub
        hub.rely(address(messageProcessor));
        hub.rely(address(messageDispatcher));
        hub.rely(address(guardian));

        // Rely root
        hubRegistry.rely(address(root));
        accounting.rely(address(root));
        holdings.rely(address(root));
        shareClassManager.rely(address(root));
        hub.rely(address(root));
        identityValuation.rely(address(root));
        hubHelpers.rely(address(root));
    }

    function _poolsFile() private {
        messageProcessor.file("hub", address(hub));
        messageDispatcher.file("hub", address(hub));

        hub.file("sender", address(messageDispatcher));
        hub.file("poolEscrowFactory", address(poolEscrowFactory));

        guardian.file("hub", address(hub));

        hubHelpers.file("hub", address(hub));
    }

    function _poolsInitialConfig() private {
        hubRegistry.registerAsset(USD_ID, ISO4217_DECIMALS);
        hubRegistry.registerAsset(EUR_ID, ISO4217_DECIMALS);
    }

    function removeHubDeployerAccess(address deployer) public {
        removeCommonDeployerAccess(deployer);

        hubRegistry.deny(deployer);
        accounting.deny(deployer);
        holdings.deny(deployer);
        shareClassManager.deny(deployer);
        hub.deny(deployer);
        hubHelpers.deny(deployer);
        identityValuation.deny(deployer);
    }

    // Helper function to deploy HubHelpers in a separate scope to avoid stack too deep errors
    // The HubHelpers constructor requires 6 parameters which was causing compilation issues
    function _deployHubHelpers(address deployer) private returns (HubHelpers) {
        bytes32 hubHelpersSalt = generateSalt("hubHelpers");
        bytes memory hubHelpersBytecode = abi.encodePacked(
            type(HubHelpers).creationCode,
            abi.encode(
                address(holdings),
                address(accounting),
                address(hubRegistry),
                address(messageDispatcher),
                address(shareClassManager),
                deployer
            )
        );
        return HubHelpers(create3(hubHelpersSalt, hubHelpersBytecode));
    }

    // Helper function to deploy Hub contract in a separate scope to avoid stack too deep errors
    // The Hub constructor requires 7 parameters which was causing compilation issues
    function _deployHubContract(address deployer) private returns (Hub) {
        bytes32 hubSalt = generateSalt("hub");

        // Store variables to reduce stack pressure
        address gatewayAddr = address(gateway);
        address hubHelpersAddr = address(hubHelpers);

        bytes memory hubBytecode = abi.encodePacked(
            type(Hub).creationCode,
            abi.encode(
                gatewayAddr,
                address(holdings),
                hubHelpersAddr,
                address(accounting),
                address(hubRegistry),
                address(shareClassManager),
                deployer
            )
        );
        return Hub(create3(hubSalt, hubBytecode));
    }
}
