// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CreateXScript} from "./utils/CreateXScript.sol";
import {JsonRegistry} from "./utils/JsonRegistry.s.sol";

import {Hub} from "../src/core/hub/Hub.sol";
import {Spoke} from "../src/core/spoke/Spoke.sol";
import {Holdings} from "../src/core/hub/Holdings.sol";
import {Accounting} from "../src/core/hub/Accounting.sol";
import {Gateway} from "../src/core/messaging/Gateway.sol";
import {HubHandler} from "../src/core/hub/HubHandler.sol";
import {HubRegistry} from "../src/core/hub/HubRegistry.sol";
import {BalanceSheet} from "../src/core/spoke/BalanceSheet.sol";
import {GasService} from "../src/core/messaging/GasService.sol";
import {AssetId, newAssetId} from "../src/core/types/AssetId.sol";
import {VaultRegistry} from "../src/core/spoke/VaultRegistry.sol";
import {MultiAdapter} from "../src/core/messaging/MultiAdapter.sol";
import {ContractUpdater} from "../src/core/utils/ContractUpdater.sol";
import {ShareClassManager} from "../src/core/hub/ShareClassManager.sol";
import {TokenFactory} from "../src/core/spoke/factories/TokenFactory.sol";
import {MessageProcessor} from "../src/core/messaging/MessageProcessor.sol";
import {MessageDispatcher} from "../src/core/messaging/MessageDispatcher.sol";
import {PoolEscrowFactory} from "../src/core/spoke/factories/PoolEscrowFactory.sol";

import "forge-std/Script.sol";

struct CoreInput {
    uint16 centrifugeId;
    bytes32 version;
    address root;
}

struct CoreReport {
    Gateway gateway;
    MultiAdapter multiAdapter;
    GasService gasService;
    MessageProcessor messageProcessor;
    MessageDispatcher messageDispatcher;
    PoolEscrowFactory poolEscrowFactory;
    Spoke spoke;
    BalanceSheet balanceSheet;
    TokenFactory tokenFactory;
    ContractUpdater contractUpdater;
    VaultRegistry vaultRegistry;
    HubRegistry hubRegistry;
    Accounting accounting;
    Holdings holdings;
    ShareClassManager shareClassManager;
    HubHandler hubHandler;
    Hub hub;
}

abstract contract Constants {
    uint8 public constant ISO4217_DECIMALS = 18;
    AssetId public immutable USD_ID = newAssetId(840);
    AssetId public immutable EUR_ID = newAssetId(978);
}

contract CoreActionBatcher is Constants {
    error NotDeployer();

    address deployer;

    constructor() {
        deployer = msg.sender;
    }

    modifier onlyDeployer() {
        require(msg.sender == deployer, NotDeployer());
        _;
    }

    function setDeployer(address newDeployer) public onlyDeployer {
        deployer = newDeployer;
    }

    function lock() public onlyDeployer {
        deployer = address(0);
    }

    function engageCore(CoreReport memory report, address root) public onlyDeployer {
        // Rely root
        report.gateway.rely(root);
        report.multiAdapter.rely(root);

        report.messageDispatcher.rely(root);
        report.messageProcessor.rely(root);

        report.poolEscrowFactory.rely(root);
        report.tokenFactory.rely(root);
        report.spoke.rely(root);
        report.balanceSheet.rely(root);
        report.contractUpdater.rely(root);
        report.vaultRegistry.rely(root);

        report.hubRegistry.rely(root);
        report.accounting.rely(root);
        report.holdings.rely(root);
        report.shareClassManager.rely(root);
        report.hub.rely(root);
        report.hubHandler.rely(root);

        // Rely gateway
        report.multiAdapter.rely(address(report.gateway));
        report.messageProcessor.rely(address(report.gateway));

        // Rely multiAdapter
        report.gateway.rely(address(report.multiAdapter));

        // Rely messageDispatcher
        report.gateway.rely(address(report.messageDispatcher));
        report.spoke.rely(address(report.messageDispatcher));
        report.balanceSheet.rely(address(report.messageDispatcher));
        report.contractUpdater.rely(address(report.messageDispatcher));
        report.vaultRegistry.rely(address(report.messageDispatcher));
        report.hubHandler.rely(address(report.messageDispatcher));

        // Rely messageProcessor
        report.gateway.rely(address(report.messageProcessor));
        report.multiAdapter.rely(address(report.messageProcessor));
        report.spoke.rely(address(report.messageProcessor));
        report.balanceSheet.rely(address(report.messageProcessor));
        report.contractUpdater.rely(address(report.messageProcessor));
        report.vaultRegistry.rely(address(report.messageProcessor));
        report.hubHandler.rely(address(report.messageProcessor));

        // Rely spoke
        report.gateway.rely(address(report.spoke));
        report.messageDispatcher.rely(address(report.spoke));
        report.tokenFactory.rely(address(report.spoke));
        report.poolEscrowFactory.rely(address(report.spoke));

        // Rely balanceSheet
        report.messageDispatcher.rely(address(report.balanceSheet));

        // Rely vaultRegistry
        report.spoke.rely(address(report.vaultRegistry));
        report.messageDispatcher.rely(address(report.vaultRegistry));

        // Rely hub
        report.multiAdapter.rely(address(report.hub));
        report.accounting.rely(address(report.hub));
        report.holdings.rely(address(report.hub));
        report.hubRegistry.rely(address(report.hub));
        report.shareClassManager.rely(address(report.hub));
        report.messageDispatcher.rely(address(report.hub));

        // Rely hubHandler
        report.hubRegistry.rely(address(report.hubHandler));
        report.holdings.rely(address(report.hubHandler));
        report.shareClassManager.rely(address(report.hubHandler));
        report.hub.rely(address(report.hubHandler));
        report.messageDispatcher.rely(address(report.hubHandler));

        // File
        report.gateway.file("adapter", address(report.multiAdapter));
        report.gateway.file("messageLimits", address(report.gasService));
        report.gateway.file("processor", address(report.messageProcessor));

        report.multiAdapter.file("messageProperties", address(report.messageProcessor));

        report.messageDispatcher.file("spoke", address(report.spoke));
        report.messageDispatcher.file("balanceSheet", address(report.balanceSheet));
        report.messageDispatcher.file("contractUpdater", address(report.contractUpdater));
        report.messageDispatcher.file("vaultRegistry", address(report.vaultRegistry));
        report.messageDispatcher.file("hubHandler", address(report.hubHandler));

        report.messageProcessor.file("multiAdapter", address(report.multiAdapter));
        report.messageProcessor.file("gateway", address(report.gateway));
        report.messageProcessor.file("spoke", address(report.spoke));
        report.messageProcessor.file("balanceSheet", address(report.balanceSheet));
        report.messageProcessor.file("contractUpdater", address(report.contractUpdater));
        report.messageProcessor.file("vaultRegistry", address(report.vaultRegistry));
        report.messageProcessor.file("hubHandler", address(report.hubHandler));

        report.poolEscrowFactory.file("gateway", address(report.gateway));
        report.poolEscrowFactory.file("balanceSheet", address(report.balanceSheet));

        report.spoke.file("gateway", address(report.gateway));
        report.spoke.file("poolEscrowFactory", address(report.poolEscrowFactory));
        report.spoke.file("sender", address(report.messageDispatcher));

        report.balanceSheet.file("spoke", address(report.spoke));
        report.balanceSheet.file("gateway", address(report.gateway));
        report.balanceSheet.file("poolEscrowProvider", address(report.poolEscrowFactory));
        report.balanceSheet.file("sender", address(report.messageDispatcher));

        report.vaultRegistry.file("spoke", address(report.spoke));

        report.hub.file("sender", address(report.messageDispatcher));

        report.hubHandler.file("sender", address(report.messageDispatcher));

        address[] memory tokenWards = new address[](2);
        tokenWards[0] = address(report.spoke);
        tokenWards[1] = address(report.balanceSheet);
        report.tokenFactory.file("wards", tokenWards);

        // Init configuration
        report.hubRegistry.registerAsset(USD_ID, ISO4217_DECIMALS);
        report.hubRegistry.registerAsset(EUR_ID, ISO4217_DECIMALS);
    }

    function revokeCore(CoreReport memory report) public onlyDeployer {
        report.gateway.deny(address(this));
        report.multiAdapter.deny(address(this));

        report.messageProcessor.deny(address(this));
        report.messageDispatcher.deny(address(this));

        report.spoke.deny(address(this));
        report.balanceSheet.deny(address(this));
        report.tokenFactory.deny(address(this));
        report.contractUpdater.deny(address(this));
        report.vaultRegistry.deny(address(this));
        report.poolEscrowFactory.deny(address(this));

        report.hubRegistry.deny(address(this));
        report.accounting.deny(address(this));
        report.holdings.deny(address(this));
        report.shareClassManager.deny(address(this));
        report.hub.deny(address(this));
        report.hubHandler.deny(address(this));
    }
}

abstract contract CoreDeployer is Script, JsonRegistry, CreateXScript, Constants {
    bytes32 public version;

    Gateway public gateway;
    MultiAdapter public multiAdapter;

    GasService public gasService;
    MessageProcessor public messageProcessor;
    MessageDispatcher public messageDispatcher;

    Spoke public spoke;
    BalanceSheet public balanceSheet;
    TokenFactory public tokenFactory;
    ContractUpdater public contractUpdater;
    VaultRegistry public vaultRegistry;
    PoolEscrowFactory public poolEscrowFactory;

    HubRegistry public hubRegistry;
    Accounting public accounting;
    Holdings public holdings;
    ShareClassManager public shareClassManager;
    HubHandler public hubHandler;
    Hub public hub;

    /// @dev Generates a deterministic salt based on contract name and optional VERSION
    function generateSalt(string memory contractName) internal view returns (bytes32) {
        bytes32 baseHash = keccak256(abi.encodePacked(contractName, version));

        // NOTE: To avoid CreateX InvalidSalt issues, 21st byte needs to be 0
        return bytes32(abi.encodePacked(bytes20(msg.sender), bytes1(0x0), bytes11(baseHash)));
    }

    function deployCore(CoreInput memory input, CoreActionBatcher batcher) public {
        setUpCreateXFactory();

        version = input.version;

        // Core
        gateway = Gateway(
            create3(
                generateSalt("gateway"),
                abi.encodePacked(type(Gateway).creationCode, abi.encode(input.centrifugeId, input.root, batcher))
            )
        );

        multiAdapter = MultiAdapter(
            create3(
                generateSalt("multiAdapter"),
                abi.encodePacked(type(MultiAdapter).creationCode, abi.encode(input.centrifugeId, gateway, batcher))
            )
        );

        contractUpdater = ContractUpdater(
            create3(
                generateSalt("contractUpdater"),
                abi.encodePacked(type(ContractUpdater).creationCode, abi.encode(batcher))
            )
        );

        // Messaging
        gasService = GasService(
            create3(generateSalt("gasService-2"), abi.encodePacked(type(GasService).creationCode, abi.encode()))
        );

        messageProcessor = MessageProcessor(
            create3(
                generateSalt("messageProcessor"),
                abi.encodePacked(type(MessageProcessor).creationCode, abi.encode(input.root, batcher))
            )
        );

        messageDispatcher = MessageDispatcher(
            create3(
                generateSalt("messageDispatcher"),
                abi.encodePacked(
                    type(MessageDispatcher).creationCode, abi.encode(input.centrifugeId, input.root, gateway, batcher)
                )
            )
        );

        // Spoke
        tokenFactory = TokenFactory(
            create3(
                generateSalt("tokenFactory"),
                abi.encodePacked(type(TokenFactory).creationCode, abi.encode(input.root, batcher))
            )
        );

        spoke = Spoke(
            create3(
                generateSalt("spoke"), abi.encodePacked(type(Spoke).creationCode, abi.encode(tokenFactory, batcher))
            )
        );

        balanceSheet = BalanceSheet(
            create3(
                generateSalt("balanceSheet"),
                abi.encodePacked(type(BalanceSheet).creationCode, abi.encode(input.root, batcher))
            )
        );

        vaultRegistry = VaultRegistry(
            create3(
                generateSalt("vaultRegistry"), abi.encodePacked(type(VaultRegistry).creationCode, abi.encode(batcher))
            )
        );

        poolEscrowFactory = PoolEscrowFactory(
            create3(
                generateSalt("poolEscrowFactory"),
                abi.encodePacked(type(PoolEscrowFactory).creationCode, abi.encode(input.root, batcher))
            )
        );

        // Hub
        hubRegistry = HubRegistry(
            create3(generateSalt("hubRegistry"), abi.encodePacked(type(HubRegistry).creationCode, abi.encode(batcher)))
        );

        accounting = Accounting(
            create3(generateSalt("accounting"), abi.encodePacked(type(Accounting).creationCode, abi.encode(batcher)))
        );

        holdings = Holdings(
            create3(
                generateSalt("holdings"),
                abi.encodePacked(type(Holdings).creationCode, abi.encode(hubRegistry, batcher))
            )
        );

        shareClassManager = ShareClassManager(
            create3(
                generateSalt("shareClassManager"),
                abi.encodePacked(type(ShareClassManager).creationCode, abi.encode(hubRegistry, batcher))
            )
        );

        hub = Hub(
            create3(
                generateSalt("hub"),
                abi.encodePacked(
                    type(Hub).creationCode,
                    abi.encode(gateway, holdings, accounting, hubRegistry, multiAdapter, shareClassManager, batcher)
                )
            )
        );

        hubHandler = HubHandler(
            create3(
                generateSalt("hubHandler"),
                abi.encodePacked(
                    type(HubHandler).creationCode, abi.encode(hub, holdings, hubRegistry, shareClassManager, batcher)
                )
            )
        );

        batcher.engageCore(_coreReport(), input.root);

        // Core
        register("gateway", address(gateway));
        register("multiAdapter", address(multiAdapter));
        register("contractUpdater", address(contractUpdater));

        // Messaging
        register("gasService", address(gasService));
        register("messageProcessor", address(messageProcessor));
        register("messageDispatcher", address(messageDispatcher));

        // Spoke
        register("tokenFactory", address(tokenFactory));
        register("spoke", address(spoke));
        register("balanceSheet", address(balanceSheet));
        register("vaultRegistry", address(vaultRegistry));
        register("poolEscrowFactory", address(poolEscrowFactory));

        // Hub
        register("hubRegistry", address(hubRegistry));
        register("accounting", address(accounting));
        register("holdings", address(holdings));
        register("shareClassManager", address(shareClassManager));
        register("hubHandler", address(hubHandler));
        register("hub", address(hub));
    }

    function removeCoreDeployerAccess(CoreActionBatcher batcher) public {
        batcher.revokeCore(_coreReport());
    }

    function _coreReport() internal view returns (CoreReport memory) {
        return CoreReport(
            gateway,
            multiAdapter,
            gasService,
            messageProcessor,
            messageDispatcher,
            poolEscrowFactory,
            spoke,
            balanceSheet,
            tokenFactory,
            contractUpdater,
            vaultRegistry,
            hubRegistry,
            accounting,
            holdings,
            shareClassManager,
            hubHandler,
            hub
        );
    }
}
