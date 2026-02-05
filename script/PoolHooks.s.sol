// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {makeSalt} from "./CoreDeployer.s.sol";
import {CreateXScript} from "./utils/CreateXScript.sol";
import {GraphQLQuery} from "./utils/GraphQLQuery.s.sol";
import {JsonRegistry} from "./utils/JsonRegistry.s.sol";
import {GraphQLConstants} from "./utils/GraphQLConstants.sol";

import {Spoke} from "../src/core/spoke/Spoke.sol";
import {PoolId} from "../src/core/types/PoolId.sol";
import {BalanceSheet} from "../src/core/spoke/BalanceSheet.sol";
import {ShareClassId} from "../src/core/types/ShareClassId.sol";
import {IPoolEscrow} from "../src/core/spoke/interfaces/IPoolEscrow.sol";
import {IShareToken} from "../src/core/spoke/interfaces/IShareToken.sol";
import {IPoolEscrowProvider} from "../src/core/spoke/factories/interfaces/IPoolEscrowFactory.sol";

import {Root} from "../src/admin/Root.sol";

import {FullRestrictions} from "../src/hooks/FullRestrictions.sol";
import {FreelyTransferable} from "../src/hooks/FreelyTransferable.sol";

import {console} from "forge-std/console.sol";
import {stdJson} from "forge-std/StdJson.sol";

struct TokenInstanceData {
    PoolId poolId;
    ShareClassId scId;
    address tokenAddress;
}

/// @title PoolHooks
/// @notice Script to deploy pool-specific hooks with pool escrow addresses
contract PoolHooks is JsonRegistry, GraphQLQuery, CreateXScript {
    using stdJson for string;

    bytes32 constant VERSION = "1";

    uint16 public centrifugeId;

    address public freelyTransferableHook;
    address public fullRestrictionsHook;
    Root public root;
    Spoke public spoke;
    BalanceSheet public balanceSheet;
    IPoolEscrowProvider public poolEscrowFactory;

    address public deployer;

    function _graphQLApi() internal pure override returns (string memory) {
        return GraphQLConstants.PRODUCTION_API;
    }

    function run() external {
        string memory network = vm.envString("NETWORK");
        string memory config = _loadConfig(network);

        deployer = msg.sender;

        setUpCreateXFactory();

        root = Root(_readContractAddress(config, "$.contracts.root"));
        spoke = Spoke(_readContractAddress(config, "$.contracts.spoke"));
        balanceSheet = BalanceSheet(_readContractAddress(config, "$.contracts.balanceSheet"));
        poolEscrowFactory = IPoolEscrowProvider(_readContractAddress(config, "$.contracts.poolEscrowFactory"));
        freelyTransferableHook = _readContractAddress(config, "$.contracts.freelyTransferableHook");
        fullRestrictionsHook = _readContractAddress(config, "$.contracts.fullRestrictionsHook");

        centrifugeId = uint16(vm.parseJsonUint(config, "$.network.centrifugeId"));

        console.log("Network:", network);
        console.log("CentrifugeId:", centrifugeId);
        console.log("Root:", address(root));
        console.log("Spoke:", address(spoke));
        console.log("BalanceSheet:", address(balanceSheet));
        console.log("FreelyTransferableHook:", freelyTransferableHook);
        console.log("FullRestrictionsHook:", fullRestrictionsHook);
        console.log("Deployer:", deployer);

        vm.startBroadcast();

        TokenInstanceData[] memory tokens = _tokenInstances();

        console.log("Found %d token instances on chain %d", tokens.length, centrifugeId);

        for (uint256 i = 0; i < tokens.length; i++) {
            _processToken(tokens[i]);
        }

        vm.stopBroadcast();
    }

    function _loadConfig(string memory network) internal view returns (string memory) {
        string memory configFile = string.concat("env/", network, ".json");
        return vm.readFile(configFile);
    }

    function _tokenInstances() internal returns (TokenInstanceData[] memory tokens) {
        // forgefmt: disable-next-item
        string memory params = string.concat(
            "limit: 1000,"
            "where: {"
            "  centrifugeId: ", _jsonValue(centrifugeId),
            "}"
        );

        // forgefmt: disable-next-item
        string memory json = _queryGraphQL(string.concat(
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
                PoolId.wrap(uint64(json.readUint(_buildJsonPath(".data.tokenInstances.items", i, "token.poolId"))));
            tokens[i].scId =
                ShareClassId.wrap(_parseBytes16(json, _buildJsonPath(".data.tokenInstances.items", i, "tokenId")));
            tokens[i].tokenAddress = json.readAddress(_buildJsonPath(".data.tokenInstances.items", i, "address"));
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

    function _deployFreelyTransferable(PoolId poolId, ShareClassId scId, address poolEscrow)
        internal
        returns (FreelyTransferable hook)
    {
        string memory saltName = string.concat("freelyTransferable-", vm.toString(PoolId.unwrap(poolId)));
        bytes32 salt = makeSalt(saltName, VERSION, deployer);

        hook = FreelyTransferable(
            create3(
                salt,
                abi.encodePacked(
                    type(FreelyTransferable).creationCode,
                    abi.encode(
                        address(root),
                        address(spoke),
                        address(balanceSheet),
                        address(spoke),
                        deployer,
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
        hook.rely(address(spoke));
        hook.deny(msg.sender);
    }

    function _deployFullRestrictions(PoolId poolId, ShareClassId scId, address poolEscrow)
        internal
        returns (FullRestrictions hook)
    {
        string memory saltName = string.concat("fullRestrictions-", vm.toString(PoolId.unwrap(poolId)));
        bytes32 salt = makeSalt(saltName, VERSION, deployer);

        hook = FullRestrictions(
            create3(
                salt,
                abi.encodePacked(
                    type(FullRestrictions).creationCode,
                    abi.encode(
                        address(root),
                        address(spoke),
                        address(balanceSheet),
                        address(spoke),
                        deployer,
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
        hook.rely(address(spoke));
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
