// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IdentityValuation} from "src/misc/IdentityValuation.sol";

import {ISafe} from "src/common/Guardian.sol";
import {Gateway} from "src/common/Gateway.sol";
import {Root} from "src/common/Root.sol";
import {Create3Factory} from "src/common/Create3Factory.sol";

import {AssetId, newAssetId} from "src/common/types/AssetId.sol";
import {HubRegistry} from "src/hub/HubRegistry.sol";
import {ShareClassManager} from "src/hub/ShareClassManager.sol";
import {Holdings} from "src/hub/Holdings.sol";
import {Accounting} from "src/hub/Accounting.sol";
import {Hub} from "src/hub/Hub.sol";

import "forge-std/Script.sol";
import {CommonDeployer} from "script/CommonDeployer.s.sol";

contract HubDeployer is CommonDeployer {
    // Main contracts
    HubRegistry public hubRegistry;
    Accounting public accounting;
    Holdings public holdings;
    ShareClassManager public shareClassManager;
    Hub public hub;

    // Utilities
    IdentityValuation public identityValuation;

    // Data
    AssetId public immutable USD = newAssetId(840);

    function deployHub(
        uint16 centrifugeId,
        ISafe adminSafe_,
        address deployer,
        bool isTests
    ) public {
        deployCommon(centrifugeId, adminSafe_, deployer, isTests);
        _deployHubRegistry(deployer);
        _deployAccounting(deployer);
        _deployHub(centrifugeId, adminSafe_, deployer, isTests);
    }

    function _deployHubRegistry(address deployer) internal {
        Create3Factory create3Factory = Create3Factory(
            0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf
        );

        hubRegistry = HubRegistry(
            payable(
                create3Factory.deploy(
                    keccak256(abi.encodePacked("hub-registry")),
                    abi.encodePacked(
                        type(HubRegistry).creationCode,
                        abi.encode(deployer)
                    )
                )
            )
        );

        identityValuation = IdentityValuation(
            payable(
                create3Factory.deploy(
                    keccak256(abi.encodePacked("identity-valuation")),
                    abi.encodePacked(
                        type(IdentityValuation).creationCode,
                        abi.encode(hubRegistry, deployer)
                    )
                )
            )
        );
    }

    function _deployAccounting(address deployer) internal {
        Create3Factory create3Factory = Create3Factory(
            0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf
        );

        accounting = Accounting(
            payable(
                create3Factory.deploy(
                    keccak256(abi.encodePacked("accounting")),
                    abi.encodePacked(
                        type(Accounting).creationCode,
                        abi.encode(deployer)
                    )
                )
            )
        );

        holdings = Holdings(
            payable(
                create3Factory.deploy(
                    keccak256(abi.encodePacked("holdings")),
                    abi.encodePacked(
                        type(Holdings).creationCode,
                        abi.encode(hubRegistry, deployer)
                    )
                )
            )
        );

        shareClassManager = ShareClassManager(
            payable(
                create3Factory.deploy(
                    keccak256(abi.encodePacked("share-class-manager")),
                    abi.encodePacked(
                        type(ShareClassManager).creationCode,
                        abi.encode(hubRegistry, deployer)
                    )
                )
            )
        );
    }

    function _deployHub(
        uint16 centrifugeId,
        ISafe adminSafe_,
        address deployer,
        bool isTests
    ) internal {
        Create3Factory create3Factory = Create3Factory(
            0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf
        );

        hub = Hub(
            payable(
                create3Factory.deploy(
                    keccak256(abi.encodePacked("hub")),
                    abi.encodePacked(
                        type(Hub).creationCode,
                        abi.encode(
                            shareClassManager,
                            hubRegistry,
                            accounting,
                            holdings,
                            gateway,
                            deployer
                        )
                    )
                )
            )
        );

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
    }

    function _poolsFile() private {
        messageProcessor.file("hub", address(hub));
        messageDispatcher.file("hub", address(hub));

        hub.file("sender", address(messageDispatcher));

        guardian.file("hub", address(hub));
    }

    function _poolsInitialConfig() private {
        hubRegistry.registerAsset(USD, 18);
    }

    function removeHubDeployerAccess(address deployer) public {
        removeCommonDeployerAccess(deployer);

        hubRegistry.deny(deployer);
        accounting.deny(deployer);
        holdings.deny(deployer);
        shareClassManager.deny(deployer);
        hub.deny(deployer);

        identityValuation.deny(deployer);
    }
}
