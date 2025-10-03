// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CreateXScript} from "./utils/CreateXScript.sol";
import {JsonRegistry} from "./utils/JsonRegistry.s.sol";

import {Root} from "../src/core/Root.sol";
import {Gateway} from "../src/core/Gateway.sol";
import {MultiAdapter} from "../src/core/MultiAdapter.sol";
import {TokenRecoverer} from "../src/core/TokenRecoverer.sol";
import {PoolEscrowFactory} from "../src/core/spoke/factories/PoolEscrowFactory.sol";

import {GasService} from "../src/messaging/GasService.sol";
import {MessageProcessor} from "../src/messaging/MessageProcessor.sol";
import {MessageDispatcher} from "../src/messaging/MessageDispatcher.sol";

import {Guardian, ISafe} from "../src/admin/Guardian.sol";

import "forge-std/Script.sol";

struct CommonInput {
    uint16 centrifugeId;
    ISafe adminSafe;
    bytes32 version;
}

struct CommonReport {
    ISafe adminSafe;
    Root root;
    TokenRecoverer tokenRecoverer;
    Guardian guardian;
    GasService gasService;
    Gateway gateway;
    MultiAdapter multiAdapter;
    MessageProcessor messageProcessor;
    MessageDispatcher messageDispatcher;
    PoolEscrowFactory poolEscrowFactory;
}

contract CommonActionBatcher {
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

    function engageCommon(CommonReport memory report) public onlyDeployer {
        report.root.rely(address(report.guardian));
        report.root.rely(address(report.tokenRecoverer));
        report.root.rely(address(report.messageProcessor));
        report.root.rely(address(report.messageDispatcher));
        report.gateway.rely(address(report.root));
        report.gateway.rely(address(report.messageDispatcher));
        report.gateway.rely(address(report.messageProcessor));
        report.gateway.rely(address(report.guardian));
        report.gateway.rely(address(report.multiAdapter));
        report.multiAdapter.rely(address(report.root));
        report.multiAdapter.rely(address(report.guardian));
        report.multiAdapter.rely(address(report.gateway));
        report.multiAdapter.rely(address(report.messageProcessor));
        report.messageDispatcher.rely(address(report.root));
        report.messageDispatcher.rely(address(report.guardian));
        report.messageProcessor.rely(address(report.root));
        report.messageProcessor.rely(address(report.gateway));
        report.tokenRecoverer.rely(address(report.root));
        report.tokenRecoverer.rely(address(report.messageDispatcher));
        report.tokenRecoverer.rely(address(report.messageProcessor));
        report.poolEscrowFactory.rely(address(report.root));

        report.gateway.file("processor", address(report.messageProcessor));
        report.gateway.file("adapter", address(report.multiAdapter));
        report.poolEscrowFactory.file("gateway", address(report.gateway));
        report.messageProcessor.file("multiAdapter", address(report.multiAdapter));
        report.messageProcessor.file("gateway", address(report.gateway));
    }

    function postEngageCommon(CommonReport memory report) public onlyDeployer {
        // We override the deployer with the correct admin once everything is deployed
        report.guardian.file("safe", address(report.adminSafe));
    }

    function revokeCommon(CommonReport memory report) public onlyDeployer {
        report.root.deny(address(this));
        report.gateway.deny(address(this));
        report.multiAdapter.deny(address(this));
        report.tokenRecoverer.deny(address(this));
        report.messageProcessor.deny(address(this));
        report.messageDispatcher.deny(address(this));
        report.poolEscrowFactory.deny(address(this));
    }
}

abstract contract CommonDeployer is Script, JsonRegistry, CreateXScript {
    uint256 public constant DELAY = 48 hours;

    bytes32 version;
    ISafe public adminSafe;

    Root public root;
    TokenRecoverer public tokenRecoverer;
    Guardian public guardian;
    GasService public gasService;
    Gateway public gateway;
    MultiAdapter public multiAdapter;
    MessageProcessor public messageProcessor;
    MessageDispatcher public messageDispatcher;
    PoolEscrowFactory public poolEscrowFactory;

    /**
     * @dev Generates a salt for contract deployment
     * @param contractName The name of the contract
     * @return salt A deterministic salt based on contract name and optional VERSION
     */
    function generateSalt(string memory contractName) internal view returns (bytes32) {
        bytes32 baseHash;
        if (version != bytes32(0)) {
            bytes32 contractNameHash = keccak256(bytes(contractName));
            // Special handling for v3.0.1 contracts that were deployed with version "3" instead of keccak256("3")
            if (
                version == keccak256(abi.encodePacked("3"))
                    && (
                        contractNameHash == keccak256(bytes("asyncRequestManager-2"))
                            || contractNameHash == keccak256(bytes("syncDepositVaultFactory-2"))
                            || contractNameHash == keccak256(bytes("asyncVaultFactory-2"))
                    )
            ) {
                baseHash = keccak256(abi.encodePacked(contractName, bytes32(bytes("3"))));
            } else {
                baseHash = keccak256(abi.encodePacked(contractName, version));
            }
        } else {
            baseHash = keccak256(abi.encodePacked(contractName));
        }

        // NOTE: To avoid CreateX InvalidSalt issues, 21st byte needs to be 0
        return bytes32(abi.encodePacked(bytes20(msg.sender), bytes1(0x0), bytes11(baseHash)));
    }

    function deployCommon(CommonInput memory input, CommonActionBatcher batcher) public {
        _preDeployCommon(input, batcher);
        _postDeployCommon(batcher);
    }

    function _preDeployCommon(CommonInput memory input, CommonActionBatcher batcher) internal {
        if (address(gateway) != address(0)) {
            return; // Already deployed. Make this method idempotent.
        }

        setUpCreateXFactory();

        adminSafe = input.adminSafe;
        version = input.version;

        root =
            Root(create3(generateSalt("root"), abi.encodePacked(type(Root).creationCode, abi.encode(DELAY, batcher))));

        tokenRecoverer = TokenRecoverer(
            create3(
                generateSalt("tokenRecoverer"),
                abi.encodePacked(type(TokenRecoverer).creationCode, abi.encode(root, batcher))
            )
        );

        gasService = GasService(
            create3(generateSalt("gasService-2"), abi.encodePacked(type(GasService).creationCode, abi.encode()))
        );

        messageProcessor = MessageProcessor(
            create3(
                generateSalt("messageProcessor"),
                abi.encodePacked(
                    type(MessageProcessor).creationCode, abi.encode(root, tokenRecoverer, gasService, batcher)
                )
            )
        );

        gateway = Gateway(
            payable(
                create3(
                    generateSalt("gateway"),
                    abi.encodePacked(type(Gateway).creationCode, abi.encode(input.centrifugeId, root, batcher))
                )
            )
        );

        multiAdapter = MultiAdapter(
            create3(
                generateSalt("multiAdapter"),
                abi.encodePacked(
                    type(MultiAdapter).creationCode, abi.encode(input.centrifugeId, gateway, messageProcessor, batcher)
                )
            )
        );

        messageDispatcher = MessageDispatcher(
            create3(
                generateSalt("messageDispatcher"),
                abi.encodePacked(
                    type(MessageDispatcher).creationCode,
                    abi.encode(input.centrifugeId, root, gateway, tokenRecoverer, batcher)
                )
            )
        );

        guardian = Guardian(
            create3(
                generateSalt("guardian"),
                abi.encodePacked(
                    type(Guardian).creationCode,
                    abi.encode(ISafe(address(batcher)), root, gateway, multiAdapter, messageDispatcher)
                )
            )
        );

        poolEscrowFactory = PoolEscrowFactory(
            create3(
                generateSalt("poolEscrowFactory"),
                abi.encodePacked(type(PoolEscrowFactory).creationCode, abi.encode(root, batcher))
            )
        );

        batcher.engageCommon(_commonReport());

        register("root", address(root));
        register("guardian", address(guardian));
        register("gasService", address(gasService));
        register("gateway", address(gateway));
        register("multiAdapter", address(multiAdapter));
        register("messageProcessor", address(messageProcessor));
        register("messageDispatcher", address(messageDispatcher));
        register("poolEscrowFactory", address(poolEscrowFactory));
        register("tokenRecoverer", address(tokenRecoverer));
    }

    function _postDeployCommon(CommonActionBatcher batcher) internal {
        if (guardian.safe() == _commonReport().adminSafe) {
            return; // Already configured. Make this method idempotent.
        }

        batcher.postEngageCommon(_commonReport());
    }

    function removeCommonDeployerAccess(CommonActionBatcher batcher) public {
        if (gateway.wards(address(batcher)) == 0) {
            return; // Already removed. Make this method idempotent.
        }

        batcher.revokeCommon(_commonReport());
    }

    function _commonReport() internal view returns (CommonReport memory) {
        return CommonReport(
            adminSafe,
            root,
            tokenRecoverer,
            guardian,
            gasService,
            gateway,
            multiAdapter,
            messageProcessor,
            messageDispatcher,
            poolEscrowFactory
        );
    }
}
