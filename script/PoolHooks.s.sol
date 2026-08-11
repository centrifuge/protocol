// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseDeployer} from "./BaseDeployer.s.sol";
import {JsonUtils} from "./utils/JsonUtils.s.sol";
import {Env, EnvConfig} from "./utils/EnvConfig.s.sol";
import {GraphQLQuery} from "./utils/GraphQLQuery.s.sol";

import {Spoke} from "../src/core/spoke/Spoke.sol";
import {PoolId} from "../src/core/types/PoolId.sol";
import {ShareClassId} from "../src/core/types/ShareClassId.sol";
import {IPoolEscrow} from "../src/core/spoke/interfaces/IPoolEscrow.sol";
import {IPoolEscrowProvider} from "../src/core/spoke/factories/interfaces/IPoolEscrowFactory.sol";

import {Root} from "../src/admin/Root.sol";

import {FullRestrictions} from "../src/token/hooks/FullRestrictions.sol";
import {FreelyTransferable} from "../src/token/hooks/FreelyTransferable.sol";

import {console} from "forge-std/console.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {IShareToken} from "../src/token/interfaces/IShareToken.sol";

struct TokenInstanceData {
    PoolId poolId;
    ShareClassId scId;
    address tokenAddress;
}

/// @title PoolHooks
/// @notice Script to deploy pool-specific hooks with pool escrow addresses
contract PoolHooks is BaseDeployer {
    using stdJson for string;
    using JsonUtils for *;

    uint16 public centrifugeId;

    address public envoy;
    address public spokeHandler;
    address public spokeRegistry;
    address public shareTokenRegistrar;
    address public fullRestrictionsHook;
    address public freelyTransferableHook;
    Root public root;
    Spoke public spoke;
    IPoolEscrowProvider public poolEscrowFactory;

    function run() external {
        EnvConfig memory config = Env.load(vm.envString("NETWORK"));

        centrifugeId = config.network.centrifugeId;

        root = Root(config.contracts.root);
        spoke = Spoke(config.contracts.spoke);
        envoy = config.contracts.envoy;
        spokeHandler = config.contracts.spokeHandler;
        spokeRegistry = config.contracts.spokeRegistry;
        poolEscrowFactory = IPoolEscrowProvider(config.contracts.poolEscrowFactory);
        freelyTransferableHook = config.contracts.freelyTransferableHook;
        fullRestrictionsHook = config.contracts.fullRestrictionsHook;
        shareTokenRegistrar = config.contracts.shareTokenRegistrar;

        GraphQLQuery graphQL = new GraphQLQuery(config.network.graphQLApi());

        console.log("Network:", config.network.name);
        console.log("CentrifugeId:", centrifugeId);
        console.log("Root:", address(root));
        console.log("Spoke:", address(spoke));
        console.log("FreelyTransferableHook:", freelyTransferableHook);
        console.log("FullRestrictionsHook:", fullRestrictionsHook);
        console.log("Deployer:", msg.sender);

        vm.startBroadcast();

        _init("");

        TokenInstanceData[] memory tokens = _tokenInstances(graphQL);

        console.log("Found %d token instances on chain %d", tokens.length, centrifugeId);

        for (uint256 i = 0; i < tokens.length; i++) {
            _processToken(tokens[i]);
        }

        vm.stopBroadcast();
    }

    function _tokenInstances(GraphQLQuery graphQL) internal returns (TokenInstanceData[] memory tokens) {
        // forgefmt: disable-next-item
        string memory params = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", vm.toString(centrifugeId).asJsonString(),
            "}"
        );

        // forgefmt: disable-next-item
        string memory json = graphQL.queryGraphQL(string.concat(
            "tokenInstances(", params, ") {",
            "  totalCount"
            "  items {"
            "    tokenId"
            "    address"
            "    token {"
            "      poolId"
            "    }"
            "  }"
            "}"
        ));

        uint256 totalCount = json.readUint(".data.tokenInstances.totalCount");

        tokens = new TokenInstanceData[](totalCount);
        for (uint256 i = 0; i < totalCount; i++) {
            tokens[i].poolId =
                PoolId.wrap(uint64(json.readUint(".data.tokenInstances.items".asJsonPath(i, "token.poolId"))));
            tokens[i].scId =
                ShareClassId.wrap(_parseBytes16(json, ".data.tokenInstances.items".asJsonPath(i, "tokenId")));
            tokens[i].tokenAddress = json.readAddress(".data.tokenInstances.items".asJsonPath(i, "address"));
        }
    }

    function _processToken(TokenInstanceData memory token) internal {
        IShareToken shareToken = IShareToken(token.tokenAddress);
        address currentHook = shareToken.hook();
        IPoolEscrow poolEscrow = poolEscrowFactory.escrow(token.poolId);
        address poolEscrowAddr = address(poolEscrow);

        console.log("===");
        console.log("Processing pool %d with hook %s", PoolId.unwrap(token.poolId), currentHook);
        console.log("Pool escrow: %s", poolEscrowAddr);

        if (currentHook == freelyTransferableHook) {
            _deployFreelyTransferable(token.poolId, token.scId, poolEscrowAddr);
        } else if (currentHook == fullRestrictionsHook) {
            _deployFullRestrictions(token.poolId, token.scId, poolEscrowAddr);
        } else {
            console.log("Hook is not freelyTransferable or fullRestrictions, skipping");
        }
    }

    function _deployFreelyTransferable(PoolId poolId, ShareClassId scId, address poolEscrow) internal {
        string memory saltName = string.concat("freelyTransferable-", vm.toString(PoolId.unwrap(poolId)));
        address expectedAddr = create3Address(saltName, V3_3, msg.sender);

        if (expectedAddr.code.length > 0) {
            console.log(
                "FreelyTransferable already deployed at %s for pool %d scId %s",
                expectedAddr,
                PoolId.unwrap(poolId),
                vm.toString(abi.encodePacked(ShareClassId.unwrap(scId)))
            );
            return;
        }

        FreelyTransferable hook = FreelyTransferable(
            create3(
                saltName,
                V3_3,
                abi.encodePacked(
                    type(FreelyTransferable).creationCode,
                    abi.encode(
                        address(root),
                        envoy,
                        spokeRegistry,
                        address(spoke),
                        spokeHandler,
                        msg.sender,
                        address(poolEscrowFactory),
                        poolEscrow
                    )
                )
            )
        );

        console.log(
            "Deployed FreelyTransferable at %s for pool %d scId %s",
            address(hook),
            PoolId.unwrap(poolId),
            vm.toString(abi.encodePacked(ShareClassId.unwrap(scId)))
        );

        hook.rely(address(root));
        hook.rely(shareTokenRegistrar);
        hook.deny(msg.sender);
    }

    function _deployFullRestrictions(PoolId poolId, ShareClassId scId, address poolEscrow) internal {
        string memory saltName = string.concat("fullRestrictions-", vm.toString(PoolId.unwrap(poolId)));
        address expectedAddr = create3Address(saltName, V3_3, msg.sender);

        if (expectedAddr.code.length > 0) {
            console.log(
                "FullRestrictions already deployed at %s for pool %d scId %s",
                expectedAddr,
                PoolId.unwrap(poolId),
                vm.toString(abi.encodePacked(ShareClassId.unwrap(scId)))
            );
            return;
        }

        FullRestrictions hook = FullRestrictions(
            create3(
                saltName,
                V3_3,
                abi.encodePacked(
                    type(FullRestrictions).creationCode,
                    abi.encode(
                        address(root),
                        envoy,
                        spokeRegistry,
                        address(spoke),
                        spokeHandler,
                        msg.sender,
                        address(poolEscrowFactory),
                        poolEscrow
                    )
                )
            )
        );

        console.log(
            "Deployed FullRestrictions at %s for pool %d scId %s",
            address(hook),
            PoolId.unwrap(poolId),
            vm.toString(abi.encodePacked(ShareClassId.unwrap(scId)))
        );

        hook.rely(address(root));
        hook.rely(shareTokenRegistrar);
        hook.deny(msg.sender);
    }

    function _parseBytes16(string memory json, string memory path) internal pure returns (bytes16 result) {
        bytes memory rawBytes = json.readBytes(path);
        require(rawBytes.length == 16, "Expected 16 bytes for tokenId");
        assembly {
            result := mload(add(rawBytes, 32))
        }
    }
}
