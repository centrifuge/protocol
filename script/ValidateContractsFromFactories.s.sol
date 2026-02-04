// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {RPCComposer} from "./utils/RPCComposer.s.sol";
import {GraphQLQuery} from "./utils/GraphQLQuery.s.sol";
import {GraphQLConstants} from "./utils/GraphQLConstants.sol";

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
    Verified
}

struct VerificationResult {
    string name;
    VerificationStatus status;
}

contract ValidateContractsFromFactories is Script, GraphQLQuery, RPCComposer {
    using stdJson for string;

    string internal _graphQLUrl;
    string internal _etherscanKey;
    string internal _verifier;
    string internal _verifierUrl;
    string internal _config;
    uint16 internal _centrifugeId;

    function _graphQLApi() internal view override returns (string memory) {
        return _graphQLUrl;
    }

    function run() public {
        _configure();

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

        // Log summary
        _logSummary(results);
    }

    function _configure() internal {
        string memory network = vm.envString("NETWORK");
        string memory configFile = string.concat("env/", network, ".json");
        _config = vm.readFile(configFile);

        string memory environment = _config.readString("$.network.environment");
        bool isTestnet = keccak256(bytes(environment)) == keccak256("testnet");
        _graphQLUrl = isTestnet ? GraphQLConstants.TESTNET_API : GraphQLConstants.PRODUCTION_API;

        // Create fork to read from deployed contracts
        vm.createSelectFork(_getRpcUrl(network));

        _centrifugeId = uint16(_config.readUint("$.network.centrifugeId"));
        _etherscanKey = vm.envOr("ETHERSCAN_API_KEY", string(""));

        string memory configVerifierUrl = _config.readStringOr("$.network.verifierUrl", "");
        _verifierUrl = bytes(configVerifierUrl).length > 0
            ? string.concat(configVerifierUrl, "?")
            : string.concat("https://api.etherscan.io/v2/api?chainid=", vm.toString(block.chainid), "&");
        _verifier = _config.readStringOr("$.network.verifier", "");
    }

    function _fetchAddresses() internal returns (AddressesToVerify memory addr) {
        string memory orderBy =
            string.concat("orderBy: ", _jsonString("createdAt"), ", orderDirection: ", _jsonString("desc"));

        // forgefmt: disable-next-item
        string memory json = _queryGraphQL(string.concat(
            "onOffRampManagers(limit: 1, ", orderBy, ", where: {",
            "  centrifugeId: ", _jsonValue(_centrifugeId),
            "}) { items { address } }",
            "merkleProofManagers(limit: 1, ", orderBy, ", where: {",
            "  centrifugeId: ", _jsonValue(_centrifugeId),
            "}) { items { address } }",
            "escrows(limit: 1, ", orderBy, ", where: {",
            "  centrifugeId: ", _jsonValue(_centrifugeId),
            "}) { items { address } }",
            "tokenInstances(limit: 1, ", orderBy, ", where: {",
            "  centrifugeId: ", _jsonValue(_centrifugeId),
            "}) { items { address } }",
            "asyncVaults: vaults(limit: 1, ", orderBy, ", where: {",
            "  centrifugeId: ", _jsonValue(_centrifugeId), ",",
            "  kind: Async",
            "}) { items { id } }",
            "syncDepositVaults: vaults(limit: 1, ", orderBy, ", where: {",
            "  centrifugeId: ", _jsonValue(_centrifugeId), ",",
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
        if (status == VerificationStatus.Verified) {
            result.status = VerificationStatus.Verified;
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
            (bytes(_verifier).length > 0)
                ? string.concat(" --verifier ", _verifier, " --verifier-url ", _verifierUrl)
                : string.concat(" --chain ", vm.toString(block.chainid), " --etherscan-api-key ", _etherscanKey),
            " --constructor-args ",
            vm.toString(constructorArgs),
            " --watch",
            " >/dev/tty 2>&1" //Redirect to terminal directly
        );

        try vm.ffi(cmd) returns (bytes memory) {
            result.status = VerificationStatus.Verified;
        } catch {
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
            "curl -s '",
            _verifierUrl,
            "module=contract&action=getsourcecode&address=",
            vm.toString(contractAddress),
            "&apikey=",
            _etherscanKey,
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

        return VerificationStatus.Verified;
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
        // deployer is the factory address (factory passes address(this) as deployer)
        address factory = _config.readAddress("$.contracts.poolEscrowFactory.address");
        return abi.encode(PoolEscrow(escrow).poolId(), factory);
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

    // ANSI color codes
    string constant GREEN = "\x1b[32m";
    string constant RED = "\x1b[31m";
    string constant YELLOW = "\x1b[33m";
    string constant RESET = "\x1b[0m";

    function _logSummary(VerificationResult[] memory results) internal pure {
        console.log("");
        console.log("========================================");
        console.log("       VERIFICATION SUMMARY");
        console.log("========================================");
        console.log("");

        uint256 verified;
        uint256 notVerified;
        uint256 notDeployed;

        for (uint256 i = 0; i < results.length; i++) {
            string memory statusStr;
            if (results[i].status == VerificationStatus.Verified) {
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
    }
}
