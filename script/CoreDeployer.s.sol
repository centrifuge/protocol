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
import {VaultRegistry} from "../src/core/spoke/VaultRegistry.sol";
import {MultiAdapter} from "../src/core/messaging/MultiAdapter.sol";
import {ContractUpdater} from "../src/core/utils/ContractUpdater.sol";
import {ShareClassManager} from "../src/core/hub/ShareClassManager.sol";
import {TokenFactory} from "../src/core/spoke/factories/TokenFactory.sol";
import {MessageProcessor} from "../src/core/messaging/MessageProcessor.sol";
import {MessageDispatcher} from "../src/core/messaging/MessageDispatcher.sol";
import {PoolEscrowFactory} from "../src/core/spoke/factories/PoolEscrowFactory.sol";

import {Root} from "../src/admin/Root.sol";
import {ISafe} from "../src/admin/interfaces/ISafe.sol";
import {OpsGuardian} from "../src/admin/OpsGuardian.sol";
import {TokenRecoverer} from "../src/admin/TokenRecoverer.sol";
import {ProtocolGuardian} from "../src/admin/ProtocolGuardian.sol";

import "forge-std/Script.sol";

import {Constants, CoreActionBatcher, CoreInput, CoreReport} from "../src/deployer/ActionBatchers.sol";

function makeSalt(string memory contractName, bytes32 version, address deployer) pure returns (bytes32) {
    bytes32 baseHash = keccak256(abi.encodePacked(contractName, version));

    // NOTE: To avoid CreateX InvalidSalt issues, 21st byte needs to be 0
    return bytes32(abi.encodePacked(bytes20(deployer), bytes1(0x0), bytes11(baseHash)));
}

abstract contract CoreDeployer is Script, JsonRegistry, CreateXScript, Constants {
    uint256 public constant DELAY = 48 hours;

    bytes32 public version;
    address public deployer;

    ISafe public protocolSafe;
    ISafe public opsSafe;

    Root public root;
    TokenRecoverer public tokenRecoverer;
    ProtocolGuardian public protocolGuardian;
    OpsGuardian public opsGuardian;

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

    function _init(bytes32 version_, address deployer_) internal {
        // NOTE: This implementation must be idempotent
        setUpCreateXFactory();

        version = version_;
        deployer = deployer_;
    }

    /// @dev Generates a deterministic salt based on contract name and optional VERSION
    function generateSalt(string memory contractName) internal view returns (bytes32) {
        return makeSalt(contractName, version, deployer);
    }

    function deployCore(CoreInput memory input, CoreActionBatcher batcher) public {
        _init(input.version, batcher.deployer());

        protocolSafe = input.protocolSafe;
        opsSafe = input.opsSafe;

        // Admin
        root =
            Root(create3(generateSalt("root"), abi.encodePacked(type(Root).creationCode, abi.encode(DELAY, batcher))));

        // Core
        gateway = Gateway(
            create3(
                generateSalt("gateway"),
                abi.encodePacked(type(Gateway).creationCode, abi.encode(input.centrifugeId, root, batcher))
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
            create3(
                generateSalt("gasService"), abi.encodePacked(type(GasService).creationCode, abi.encode(input.txLimits))
            )
        );

        messageProcessor = MessageProcessor(
            create3(
                generateSalt("messageProcessor"),
                abi.encodePacked(type(MessageProcessor).creationCode, abi.encode(root, batcher))
            )
        );

        messageDispatcher = MessageDispatcher(
            create3(
                generateSalt("messageDispatcher"),
                abi.encodePacked(
                    type(MessageDispatcher).creationCode, abi.encode(input.centrifugeId, root, gateway, batcher)
                )
            )
        );

        // Spoke
        tokenFactory = TokenFactory(
            create3(
                generateSalt("tokenFactory"),
                abi.encodePacked(type(TokenFactory).creationCode, abi.encode(root, batcher))
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
                abi.encodePacked(type(BalanceSheet).creationCode, abi.encode(root, batcher))
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
                abi.encodePacked(type(PoolEscrowFactory).creationCode, abi.encode(root, batcher))
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

        // Admin (depends on core contracts)
        tokenRecoverer = TokenRecoverer(
            create3(
                generateSalt("tokenRecoverer"),
                abi.encodePacked(type(TokenRecoverer).creationCode, abi.encode(root, batcher))
            )
        );

        protocolGuardian = ProtocolGuardian(
            create3(
                generateSalt("protocolGuardian"),
                abi.encodePacked(
                    type(ProtocolGuardian).creationCode,
                    abi.encode(ISafe(address(batcher)), root, gateway, messageDispatcher)
                )
            )
        );

        opsGuardian = OpsGuardian(
            create3(
                generateSalt("opsGuardian"),
                abi.encodePacked(type(OpsGuardian).creationCode, abi.encode(ISafe(address(batcher)), hub, multiAdapter))
            )
        );

        batcher.engageCore(coreReport(), input);

        // Admin
        register("root", address(root));
        register("tokenRecoverer", address(tokenRecoverer));
        register("protocolGuardian", address(protocolGuardian));
        register("opsGuardian", address(opsGuardian));

        // Messaging
        register("gateway", address(gateway));
        register("multiAdapter", address(multiAdapter));
        register("contractUpdater", address(contractUpdater));
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
        batcher.revokeCore(coreReport());
    }

    function coreReport() public view returns (CoreReport memory) {
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
            hub,
            root,
            tokenRecoverer,
            protocolGuardian,
            opsGuardian
        );
    }
}
