// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {JsonUtils} from "./utils/JsonUtils.s.sol";
import {EnvConfig, Env} from "./utils/EnvConfig.s.sol";
import {GraphQLQuery} from "./utils/GraphQLQuery.s.sol";

import {IERC20Metadata} from "../src/misc/interfaces/IERC20.sol";

import {PoolEscrow} from "../src/core/spoke/PoolEscrow.sol";

import {OnOffRamp} from "../src/managers/spoke/OnOffRamp.sol";

import {AsyncVault} from "../src/vaults/AsyncVault.sol";
import {SyncDepositVault} from "../src/vaults/SyncDepositVault.sol";

import "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

struct AddressesToVerify {
    address asyncVault;
    address syncDepositVault;
    address shareToken;
    address poolEscrow;
    address refundEscrow;
    address onOfframpManager;
}

enum VerificationStatus {
    NotDeployed,
    NotVerified,
    AlreadyVerified,
    NewlyVerified
}

struct VerificationResult {
    string name;
    VerificationStatus status;
}

contract VerifyFactoryContracts is Script {
    using stdJson for string;
    using JsonUtils for *;

    error VerificationFailed(uint256 notVerified);

    EnvConfig config;
    GraphQLQuery indexer;

    constructor() {
        config = Env.load(vm.envString("NETWORK"));
    }

    function run() public {
        vm.createSelectFork(config.network.rpcUrl());
        indexer = new GraphQLQuery(config.network.graphQLApi());

        AddressesToVerify memory addr = _fetchAddresses();

        // Collect verification results
        VerificationResult[] memory results = new VerificationResult[](6);
        results[0] = _verifyContract(addr.asyncVault, "AsyncVault");
        results[1] = _verifyContract(addr.syncDepositVault, "SyncDepositVault");
        results[2] = _verifyContract(addr.shareToken, "ShareToken");
        results[3] = _verifyContract(addr.poolEscrow, "PoolEscrow");
        results[4] = _verifyContract(addr.refundEscrow, "RefundEscrow");
        results[5] = _verifyContract(addr.onOfframpManager, "OnOffRamp");

        // Log summary and revert if any contract failed verification
        _logSummary(results);
    }

    function _urlQuerySeparator(string memory url) internal pure returns (string memory) {
        bytes memory urlBytes = bytes(url);
        for (uint256 i = 0; i < urlBytes.length; i++) {
            if (urlBytes[i] == "?") return "&";
        }
        return "?";
    }

    function _fetchAddresses() internal returns (AddressesToVerify memory addr) {
        string memory orderBy =
            string.concat("orderBy: ", "createdAt".asJsonString(), ", orderDirection: ", "desc".asJsonString());

        string memory centrifugeIdValue = vm.toString(config.network.centrifugeId).asJsonString();

        // forgefmt: disable-next-item
        string memory json = indexer.queryGraphQL(string.concat(
            "onOffRampManagers(limit: 1, ", orderBy, ", where: {",
            "  centrifugeId: ", centrifugeIdValue,
            "}) { items { address } }",
            "escrows(limit: 1, ", orderBy, ", where: {",
            "  centrifugeId: ", centrifugeIdValue,
            "}) { items { address } }",
            "tokenInstances(limit: 1, ", orderBy, ", where: {",
            "  centrifugeId: ", centrifugeIdValue,
            "}) { items { address } }",
            "asyncVaults: vaults(limit: 1, ", orderBy, ", where: {",
            "  centrifugeId: ", centrifugeIdValue, ",",
            "  kind: Async",
            "}) { items { id } }",
            "syncDepositVaults: vaults(limit: 1, ", orderBy, ", where: {",
            "  centrifugeId: ", centrifugeIdValue, ",",
            "  kind: SyncDepositAsyncRedeem",
            "}) { items { id } }"
        ));

        addr.onOfframpManager = json.readAddressOr(".data.onOffRampManagers.items[0].address", address(0));
        addr.poolEscrow = json.readAddressOr(".data.escrows.items[0].address", address(0));
        addr.shareToken = json.readAddressOr(".data.tokenInstances.items[0].address", address(0));
        addr.asyncVault = json.readAddressOr(".data.asyncVaults.items[0].id", address(0));
        addr.syncDepositVault = json.readAddressOr(".data.syncDepositVaults.items[0].id", address(0));
    }

    function _verifyContract(address contractAddress, string memory contractName)
        internal
        returns (VerificationResult memory result)
    {
        result.name = contractName;

        if (contractAddress == address(0)) {
            result.status = VerificationStatus.NotDeployed;
            return result;
        }

        VerificationStatus status = _verificationStatus(contractAddress);
        if (status == VerificationStatus.AlreadyVerified) {
            result.status = VerificationStatus.AlreadyVerified;
            return result;
        }

        bytes memory constructorArgs = _getConstructorArgs(contractAddress, contractName);

        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = "-c";
        cmd[2] = string.concat(
            "forge verify-contract ",
            vm.toString(contractAddress),
            " ",
            contractName,
            (bytes(config.network.verifier).length > 0)
                ? string.concat(" --verifier ", config.network.verifier, " --verifier-url ", config.network.verifierUrl)
                : string.concat(
                    " --chain ", vm.toString(block.chainid), " --etherscan-api-key ", config.etherscanApiKey()
                ),
            " --constructor-args ",
            vm.toString(constructorArgs),
            " --watch",
            " 2>&1 | tail -c 4096; true" // Truncate to last 4KB (status msgs at end); exit 0
        );

        // Wait before hitting the Etherscan API again via forge verify-contract
        vm.sleep(400);

        bytes memory output = vm.ffi(cmd);
        if (_containsSubstring(output, "successfully verified")) {
            result.status = VerificationStatus.NewlyVerified;
        } else if (
            _containsSubstring(output, "already verified") || _containsSubstring(output, "This contract is verified")
        ) {
            result.status = VerificationStatus.AlreadyVerified;
        } else {
            result.status = VerificationStatus.NotVerified;
        }
    }

    function _verificationStatus(address contractAddress) internal returns (VerificationStatus) {
        if (contractAddress == address(0)) {
            return VerificationStatus.NotDeployed;
        }

        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = "-c";
        cmd[2] = string.concat(
            "curl -s --max-time 30 '",
            config.network.verifierUrl,
            _urlQuerySeparator(config.network.verifierUrl),
            "module=contract&action=getsourcecode&address=",
            vm.toString(contractAddress),
            "&apikey=",
            config.etherscanApiKey(),
            "'"
        );

        // Retry on transient API errors (rate limits, server errors, timeouts).
        // Only treat status="1" responses as definitive — status="0" means an API-level
        // error, not that the contract is unverified.
        for (uint256 i = 0; i < 3; i++) {
            vm.sleep(i == 0 ? 400 : 2000); // base delay, then backoff on retry

            string memory response = string(vm.ffi(cmd));

            // Skip malformed or error responses (rate limit, 503, empty, etc.)
            if (!vm.keyExists(response, ".status")) continue;
            if (keccak256(bytes(response.readString(".status"))) != keccak256(bytes("1"))) continue;

            // status=1: definitive answer from the API
            if (!vm.keyExists(response, ".result[0].SourceCode")) {
                return VerificationStatus.NotVerified;
            }

            string memory sourceCode = response.readString(".result[0].SourceCode");
            return bytes(sourceCode).length > 0 ? VerificationStatus.AlreadyVerified : VerificationStatus.NotVerified;
        }

        // All retries exhausted — let forge verify-contract make the final determination
        return VerificationStatus.NotVerified;
    }

    /// @notice Get constructor args by reading from contract storage
    function _getConstructorArgs(address contractAddress, string memory contractName)
        internal
        view
        returns (bytes memory)
    {
        bytes32 nameHash = keccak256(bytes(contractName));

        if (nameHash == keccak256("AsyncVault")) {
            return _getAsyncVaultArgs(contractAddress);
        } else if (nameHash == keccak256("SyncDepositVault")) {
            return _getSyncDepositVaultArgs(contractAddress);
        } else if (nameHash == keccak256("ShareToken")) {
            return _getShareTokenArgs(contractAddress);
        } else if (nameHash == keccak256("PoolEscrow")) {
            return _getPoolEscrowArgs(contractAddress);
        } else if (nameHash == keccak256("RefundEscrow")) {
            return _getRefundEscrowArgs();
        } else if (nameHash == keccak256("OnOffRamp")) {
            return _getOnOffRampArgs(contractAddress);
        }

        revert(string.concat("Unknown contract: ", contractName));
    }

    function _getAsyncVaultArgs(address vault) internal view returns (bytes memory) {
        AsyncVault v = AsyncVault(vault);
        return abi.encode(v.poolId(), v.scId(), v.asset(), v.share(), address(v.root()), address(v.baseManager()));
    }

    function _getSyncDepositVaultArgs(address vault) internal view returns (bytes memory) {
        SyncDepositVault v = SyncDepositVault(vault);
        return abi.encode(
            v.poolId(),
            v.scId(),
            v.asset(),
            v.share(),
            address(v.root()),
            address(v.syncDepositManager()),
            address(v.asyncRedeemManager())
        );
    }

    function _getShareTokenArgs(address token) internal view returns (bytes memory) {
        return abi.encode(IERC20Metadata(token).decimals());
    }

    function _getPoolEscrowArgs(address escrow) internal view returns (bytes memory) {
        return abi.encode(PoolEscrow(escrow).poolId(), config.contracts.poolEscrowFactory);
    }

    function _getRefundEscrowArgs() internal pure returns (bytes memory) {
        // RefundEscrow has no constructor parameters
        return "";
    }

    function _getOnOffRampArgs(address manager) internal view returns (bytes memory) {
        OnOffRamp m = OnOffRamp(manager);
        return abi.encode(m.poolId(), m.scId(), m.contractUpdater(), address(m.balanceSheet()));
    }

    function _containsSubstring(bytes memory data, bytes memory needle) internal pure returns (bool) {
        if (data.length < needle.length) return false;
        for (uint256 i = 0; i <= data.length - needle.length; i++) {
            bool found = true;
            for (uint256 j = 0; j < needle.length; j++) {
                if (data[i + j] != needle[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return true;
        }
        return false;
    }

    // ANSI color codes
    string constant GREEN = "\x1b[32m";
    string constant RED = "\x1b[31m";
    string constant YELLOW = "\x1b[33m";
    string constant RESET = "\x1b[0m";

    function _logSummary(VerificationResult[] memory results) internal pure {
        console.log("");
        console.log("----------------------------------------");
        console.log("       VERIFICATION SUMMARY");
        console.log("----------------------------------------");
        console.log("");

        uint256 verified;
        uint256 notVerified;
        uint256 notDeployed;

        for (uint256 i = 0; i < results.length; i++) {
            string memory statusStr;
            if (results[i].status == VerificationStatus.NewlyVerified) {
                statusStr = string.concat(GREEN, "[OK]", RESET, " Verified (new)");
                verified++;
            } else if (results[i].status == VerificationStatus.AlreadyVerified) {
                statusStr = string.concat(GREEN, "[OK]", RESET, " Verified");
                verified++;
            } else if (results[i].status == VerificationStatus.NotVerified) {
                statusStr = string.concat(RED, "[FAIL]", RESET, " Not Verified");
                notVerified++;
            } else {
                statusStr = string.concat(YELLOW, "[SKIP]", RESET, " Not Deployed");
                notDeployed++;
            }

            console.log(string.concat(results[i].name, ": ", statusStr));
        }

        console.log("");
        console.log("----------------------------------------");
        console.log(string.concat("Verified:     ", vm.toString(verified)));
        console.log(string.concat("Not Verified: ", vm.toString(notVerified)));
        console.log(string.concat("Not Deployed: ", vm.toString(notDeployed)));
        console.log("----------------------------------------");
        console.log("");

        if (notVerified > 0) {
            revert VerificationFailed(notVerified);
        }
    }
}
