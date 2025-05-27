// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {IRecoverable} from "src/misc/Recoverable.sol";

import {Root} from "src/common/Root.sol";
import {GasService} from "src/common/GasService.sol";
import {Gateway} from "src/common/Gateway.sol";
import {MultiAdapter} from "src/common/adapters/MultiAdapter.sol";
import {Guardian, ISafe} from "src/common/Guardian.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";
import {MessageProcessor} from "src/common/MessageProcessor.sol";
import {MessageDispatcher} from "src/common/MessageDispatcher.sol";
import {TokenRecoverer} from "src/common/TokenRecoverer.sol";
import {Create3Factory} from "src/common/Create3Factory.sol";
import {PoolId} from "src/common/types/PoolId.sol";

import {JsonRegistry} from "script/utils/JsonRegistry.s.sol";

import "forge-std/Script.sol";

string constant MESSAGE_COST_ENV = "MESSAGE_COST";
string constant MAX_BATCH_SIZE_ENV = "MAX_BATCH_SIZE";

abstract contract CommonDeployer is Script, JsonRegistry {
    uint256 constant DELAY = 48 hours;
    uint128 constant FALLBACK_MSG_COST = uint128(0.02 ether); // in Weight
    uint128 constant FALLBACK_MAX_BATCH_SIZE = uint128(10_000_000 ether); // 10M in Weight
    address constant CREATE3_FACTORY =
        0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
    // CreateX contract:https://github.com/pcaversaccio/createx?tab=readme-ov-file#createx-deployments

    // Version constants for different components
    string constant CORE_VERSION = "1.0.0";
    string constant HUB_VERSION = "1.0.0";
    string constant SPOKE_VERSION = "1.0.0";

    IAdapter[] adapters;

    ISafe public adminSafe;
    Root public root;
    TokenRecoverer public tokenRecoverer;
    Guardian public guardian;
    GasService public gasService;
    Gateway public gateway;
    MultiAdapter public multiAdapter;
    MessageProcessor public messageProcessor;
    MessageDispatcher public messageDispatcher;

    /// @notice Computes a deterministic salt for contract deployment
    /// @param name The name of the contract to deploy
    /// @param deployer The address of the authorized deployer
    /// @param version The semantic version of the contract (e.g., "1.0.0")
    /// @return salt The computed salt for deterministic deployment
    function computeSalt(
        string memory name,
        address deployer,
        string memory version
    ) internal pure returns (bytes32 salt) {
        // First 20 bytes: permissioned deploy protection (msg.sender)
        // 21st byte: cross-chain redeploy protection (0x01)
        // Last 11 bytes: entropy from name and version
        bytes memory entropy = abi.encodePacked(
            "centrifuge-v3", // namespace to avoid collisions
            name,
            version
        );

        // Create salt with the pattern:
        // - First 20 bytes: deployer address
        // - 21st byte: 0x01 for cross-chain protection
        // - Last 11 bytes: keccak256 of entropy (truncated to 11 bytes)
        // Docs: https://github.com/pcaversaccio/createx?tab=readme-ov-file#permissioned-deploy-protection-and-cross-chain-redeploy-protection
        salt = bytes32(
            abi.encodePacked(
                deployer, // 20 bytes
                bytes1(0x00), // 1 byte for cross-chain protection
                bytes11(keccak256(entropy)) // 11 bytes of entropy
            )
        );
    }

    function deployCommon(
        uint16 centrifugeId,
        ISafe adminSafe_,
        address deployer,
        bool isTests
    ) public {
        if (address(root) != address(0)) {
            return; // Already deployed. Make this method idempotent.
        }

        startDeploymentOutput(isTests);

        uint128 messageGasLimit = uint128(
            vm.envOr(MESSAGE_COST_ENV, FALLBACK_MSG_COST)
        );
        uint128 maxBatchSize = uint128(
            vm.envOr(MAX_BATCH_SIZE_ENV, FALLBACK_MAX_BATCH_SIZE)
        );

        root = new Root(DELAY, deployer);
        tokenRecoverer = new TokenRecoverer(root, deployer);

        messageProcessor = new MessageProcessor(root, tokenRecoverer, deployer);

        gasService = new GasService(maxBatchSize, messageGasLimit);
        gateway = new Gateway(root, gasService, deployer);
        multiAdapter = new MultiAdapter(centrifugeId, gateway, deployer);

        messageDispatcher = new MessageDispatcher(
            centrifugeId,
            root,
            gateway,
            tokenRecoverer,
            deployer
        );

        adminSafe = adminSafe_;

        // deployer is not actually an implementation of ISafe but for deployment this is not an issue
        guardian = new Guardian(
            ISafe(deployer),
            multiAdapter,
            root,
            messageDispatcher
        );

        _commonRegister();
        _commonRely();
        _commonFile();
    }

    function _deployCore(address deployer) internal {
        Create3Factory create3Factory = Create3Factory(CREATE3_FACTORY);

        // Use special PROXY_SALT for root to prevent accidental redeployment
        // Replace the first 20 bytes with the deployer's address
        bytes32 proxySalt = bytes32(
            abi.encodePacked(
                deployer, // 20 bytes - deployer address
                bytes1(0x00), // 1 byte for cross-chain protection
                bytes11(keccak256(abi.encodePacked("PROXY", "1.0.0"))) // 11 bytes of entropy
            )
        );

        root = Root(
            payable(
                create3Factory.deploy(
                    proxySalt,
                    abi.encodePacked(
                        type(Root).creationCode,
                        abi.encode(DELAY, deployer)
                    )
                )
            )
        );

        tokenRecoverer = TokenRecoverer(
            payable(
                create3Factory.deploy(
                    computeSalt("token-recoverer", deployer, CORE_VERSION),
                    abi.encodePacked(
                        type(TokenRecoverer).creationCode,
                        abi.encode(address(root), deployer)
                    )
                )
            )
        );

        messageProcessor = MessageProcessor(
            payable(
                create3Factory.deploy(
                    computeSalt("message-processor", deployer, CORE_VERSION),
                    abi.encodePacked(
                        type(MessageProcessor).creationCode,
                        abi.encode(
                            address(root),
                            address(tokenRecoverer),
                            deployer
                        )
                    )
                )
            )
        );
    }

    function _deployServices(address deployer) internal {
        Create3Factory create3Factory = Create3Factory(CREATE3_FACTORY);

        uint128 messageGasLimit = uint128(
            vm.envOr(MESSAGE_COST_ENV, FALLBACK_MSG_COST)
        );
        uint128 maxBatchSize = uint128(
            vm.envOr(MAX_BATCH_SIZE_ENV, FALLBACK_MAX_BATCH_SIZE)
        );

        gasService = GasService(
            payable(
                create3Factory.deploy(
                    computeSalt("gas-service", deployer, CORE_VERSION),
                    abi.encodePacked(
                        type(GasService).creationCode,
                        abi.encode(maxBatchSize, messageGasLimit)
                    )
                )
            )
        );
    }

    function _deployGatewayAndDispatcher(
        uint16 centrifugeId,
        address deployer
    ) internal {
        Create3Factory create3Factory = Create3Factory(CREATE3_FACTORY);

        gateway = Gateway(
            payable(
                create3Factory.deploy(
                    computeSalt("gateway", deployer, CORE_VERSION),
                    abi.encodePacked(
                        type(Gateway).creationCode,
                        abi.encode(
                            centrifugeId,
                            address(root),
                            address(gasService),
                            deployer
                        )
                    )
                )
            )
        );

        messageDispatcher = MessageDispatcher(
            payable(
                create3Factory.deploy(
                    computeSalt("message-dispatcher", deployer, CORE_VERSION),
                    abi.encodePacked(
                        type(MessageDispatcher).creationCode,
                        abi.encode(
                            centrifugeId,
                            address(root),
                            address(gateway),
                            address(tokenRecoverer),
                            deployer
                        )
                    )
                )
            )
        );
    }

    function _deployGuardian(address deployer) internal {
        Create3Factory create3Factory = Create3Factory(CREATE3_FACTORY);

        guardian = Guardian(
            payable(
                create3Factory.deploy(
                    computeSalt("guardian", deployer, CORE_VERSION),
                    abi.encodePacked(
                        type(Guardian).creationCode,
                        abi.encode(
                            ISafe(deployer),
                            address(root),
                            address(messageDispatcher)
                        )
                    )
                )
            )
        );
    }

    function _commonRegister() private {
        register("root", address(root));
        register("adminSafe", address(adminSafe));
        register("guardian", address(guardian));
        register("gasService", address(gasService));
        register("gateway", address(gateway));
        register("multiAdapter", address(multiAdapter));
        register("messageProcessor", address(messageProcessor));
        register("messageDispatcher", address(messageDispatcher));
    }

    function _commonRely() private {
        root.rely(address(guardian));
        root.rely(address(messageProcessor));
        root.rely(address(messageDispatcher));
        gateway.rely(address(root));
        gateway.rely(address(messageDispatcher));
        gateway.rely(address(messageProcessor));
        gateway.rely(address(multiAdapter));
        multiAdapter.rely(address(guardian));
        multiAdapter.rely(address(gateway));
        messageDispatcher.rely(address(root));
        messageProcessor.rely(address(gateway));
        messageDispatcher.rely(address(guardian));
        tokenRecoverer.rely(address(messageDispatcher));
        tokenRecoverer.rely(address(messageProcessor));
    }

    function _commonFile() private {
        gateway.file("processor", address(messageProcessor));
        gateway.file("adapter", address(multiAdapter));
        gateway.setRefundAddress(
            PoolId.wrap(0),
            IRecoverable(address(gateway))
        );
    }

    function wire(
        uint16 centrifugeId,
        IAdapter adapter,
        address deployer
    ) public {
        adapters.push(adapter);
        multiAdapter.file("adapters", centrifugeId, adapters);
        IAuth(address(adapter)).rely(address(root));
        IAuth(address(adapter)).deny(deployer);
    }

    function removeCommonDeployerAccess(address deployer) public {
        if (root.wards(deployer) == 0) {
            return; // Already removed. Make this method idempotent.
        }

        guardian.file("safe", address(adminSafe));

        root.deny(deployer);
        gateway.deny(deployer);
        tokenRecoverer.deny(deployer);
        messageProcessor.deny(deployer);
        messageDispatcher.deny(deployer);
    }
}
