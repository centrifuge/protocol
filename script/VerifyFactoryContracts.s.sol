// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {EnvConfig, Env} from "./utils/EnvConfig.s.sol";
import {GraphQLQuery} from "./utils/GraphQLQuery.s.sol";

import {IERC20Metadata} from "../src/misc/interfaces/IERC20.sol";

import {PoolEscrow} from "../src/core/spoke/PoolEscrow.sol";

import {OnOfframpManager} from "../src/managers/spoke/OnOfframpManager.sol";
import {MerkleProofManager} from "../src/managers/spoke/MerkleProofManager.sol";

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
    address merkleProofManager;
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

contract VerifyFactoryContracts is Script, GraphQLQuery {
    using stdJson for string;

    error VerificationFailed(uint256 notVerified);

    EnvConfig config;

    constructor() {
        config = Env.load(vm.envString("NETWORK"));
    }

    function _graphQLApi() internal view override returns (string memory) {
        return config.network.graphQLApi();
    }

    function run() public {
        vm.createSelectFork(config.network.rpcUrl());

        AddressesToVerify memory addr = _fetchAddresses();

        // Collect verification results
        VerificationResult[] memory results = new VerificationResult[](7);
        results[0] = _verifyContract(addr.asyncVault, "AsyncVault");
        results[1] = _verifyContract(addr.syncDepositVault, "SyncDepositVault");
        results[2] = _verifyContract(addr.shareToken, "ShareToken");
        results[3] = _verifyContract(addr.poolEscrow, "PoolEscrow");
        results[4] = _verifyContract(addr.refundEscrow, "RefundEscrow");
        results[5] = _verifyContract(addr.onOfframpManager, "OnOfframpManager");
        results[6] = _verifyContract(addr.merkleProofManager, "MerkleProofManager");

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
            string.concat("orderBy: ", _jsonString("createdAt"), ", orderDirection: ", _jsonString("desc"));

        string memory centrifugeIdValue = _jsonValue(config.network.centrifugeId);

        // forgefmt: disable-next-item
        string memory json = _queryGraphQL(string.concat(
            "onOffRampManagers(limit: 1, ", orderBy, ", where: {",
            "  centrifugeId: ", centrifugeIdValue,
            "}) { items { address } }",
            "merkleProofManagers(limit: 1, ", orderBy, ", where: {",
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
        addr.merkleProofManager = json.readAddressOr(".data.merkleProofManagers.items[0].address", address(0));
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
            " 2>&1 || true" // Capture output; exit 0 so ffi doesn't revert
        );

        // Wait before hitting the Etherscan API again via forge verify-contract
        vm.sleep(400);

        bytes memory output = vm.ffi(cmd);
        if (_containsSubstring(output, "successfully verified")) {
            result.status = VerificationStatus.NewlyVerified;
        } else if (_containsSubstring(output, "already verified")) {
            result.status = VerificationStatus.AlreadyVerified;
        } else {
            result.status = VerificationStatus.NotVerified;
        }
    }

    function _verificationStatus(address contractAddress) internal returns (VerificationStatus) {
        if (contractAddress == address(0)) {
            return VerificationStatus.NotDeployed;
        }

        // Rate-limit Etherscan API calls to avoid 3/sec limit
        vm.sleep(400);

        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = "-c";
        cmd[2] = string.concat(
            "curl -s '",
            config.network.verifierUrl,
            _urlQuerySeparator(config.network.verifierUrl),
            "module=contract&action=getsourcecode&address=",
            vm.toString(contractAddress),
            "&apikey=",
            config.etherscanApiKey(),
            "'"
        );

        string memory response = string(vm.ffi(cmd));

        // Check if SourceCode field exists and has content
        if (!vm.keyExists(response, ".result[0].SourceCode")) {
            return VerificationStatus.NotVerified;
        }

        string memory sourceCode = response.readString(".result[0].SourceCode");
        if (bytes(sourceCode).length == 0) {
            return VerificationStatus.NotVerified;
        }

        return VerificationStatus.AlreadyVerified;
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
        } else if (nameHash == keccak256("OnOfframpManager")) {
            return _getOnOfframpManagerArgs(contractAddress);
        } else if (nameHash == keccak256("MerkleProofManager")) {
            return _getMerkleProofManagerArgs(contractAddress);
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

    function _getOnOfframpManagerArgs(address manager) internal view returns (bytes memory) {
        OnOfframpManager m = OnOfframpManager(manager);
        return abi.encode(m.poolId(), m.scId(), m.contractUpdater(), address(m.balanceSheet()));
    }

    function _getMerkleProofManagerArgs(address manager) internal view returns (bytes memory) {
        MerkleProofManager m = MerkleProofManager(payable(manager));
        return abi.encode(m.poolId(), m.contractUpdater());
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
