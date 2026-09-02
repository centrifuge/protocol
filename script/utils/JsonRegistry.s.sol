// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";

// Passed to `startDeploymentOutput` by a run whose contracts are the whole of a chain's, so that everything
// the config held and the run does not mention is dropped. Named rather than a bare `true` because what it
// does is destructive and the call site is where that has to be visible.
bool constant REPLACE = true;

/// @notice Collects the contracts a deploy script produces and writes them into `env/<environment>/<network>.json`.
///
/// @dev    A script opens a run with `startDeploymentOutput()`, registers each contract as it goes — which
///         `BaseDeployer.reportedSalt()` already does for anything deployed through a reported salt — and
///         closes with `saveDeploymentOutput(network)`. Deploy-time only contracts take `unreportedSalt()`
///         instead and never reach this registry.
///
///         A deployment records itself completely: addresses, versions, block numbers and the chain's
///         `startBlock`. Nothing has to be filled in afterwards and nothing else reads the chain to do it.
///
///         Writing happens during forge's simulation pass, before the broadcast lands. For the addresses
///         that is exact — they are deterministic, CREATE3 from the gate, the salt and the deployment id, so what is
///         written is what will be deployed, including after a later `--resume`. For the block numbers it is
///         an underestimate: `block.number` here is the block the script *read*, and the transactions land a
///         few blocks later (measured: 1 on a local fork, up to ~183 on a fast chain). That is deliberate and
///         it is the safe direction — these feed indexers, which must not start *after* a contract exists.
///         Every contract in one run therefore shares a block number, since simulation does not advance.
///
///         Only an abandoned deployment leaves entries for contracts that never landed — a run whose
///         simulation reverts partway never reaches this, and one that stops during the broadcast is
///         finished with `--resume`. Nor is that window anything the `REPLACE` flag below widens: the merge
///         overwrites by name, and a run that registers a name claims it either way.
///
///         `env/` is read-only to forge (`fs_permissions`), so the merge goes through jq rather than a
///         cheatcode. That keeps the guard against a test or a stray script rewriting a config, and keeps
///         the diff to what actually changed.
contract JsonRegistry is Script {
    /// @dev The whole merge, in one jq program, so that what a run does to `env/<environment>/<network>.json` is read in
    ///      one place. It takes `$new` (this run's contracts), `$block`, and the three `deploymentInfo`
    ///      fields, and does three things:
    ///
    ///      1. A contract that landed on a new address gets this run's block number. One that was already
    ///         recorded at the same address keeps the block it had — a run that re-reports an address it did
    ///         not deploy this time is not evidence about when it was deployed, and overwriting would move
    ///         the chain's `startBlock` under an indexer. That holds under `$replace` too, which is what
    ///         lets `--resume` finish a run without redating what the first attempt landed.
    ///      1b. One the run does not mention is left alone, so a config can hold more than one script's
    ///         worth — unless `$replace`, where this run's contracts are the whole of the chain's and
    ///         whatever the config held belonged to a deployment this one supersedes.
    ///      2. Only a full protocol deployment claims the chain's `deploymentInfo`, which is what `$new`
    ///         holding `root` says, and the same run claims its `startBlock`: a script shipping one contract
    ///         records its address without redating the chain, so both live in one branch rather than two
    ///         conditions that can disagree. The info is merged into what is there rather than replacing it.
    ///      3. That `startBlock` is the earliest block *any* contract in the config carries, not this run's:
    ///         a redeployment that reuses contracts leaves older ones in place, and an indexer starting
    ///         after one of them misses its history. Computed over what the file ends up holding.
    string internal constant MERGE = ". as $root"
        " | .contracts = ((if $replace then {} else ($root.contracts // {}) end) + ($new | with_entries("
        "     ($root.contracts[.key] // {}) as $old" "     | .value = ({address: .value.address,"
        "        blockNumber: (if ($old.address // null) == .value.address and ($old.blockNumber // null) != null"
        "                      then $old.blockNumber else $block end),"
        "        version: (if .value.version != \"\" then .value.version else ($old.version // null) end)"
        "       } | if .version == null then del(.version) else . end))))" " | (if ($new | has(\"root\"))"
        "    then .deploymentInfo[\"deploy:protocol\"] = ((.deploymentInfo[\"deploy:protocol\"] // {})"
        "           + {gitCommit: $gitCommit, timestamp: $timestamp}"
        // The deployment a record belongs to is the environment the config declares, so recording it here
        // would be the same string twice. Older records named it `suffix`, which goes with the rest
        "           | del(.suffix))" "         | ([.contracts[] | .blockNumber | select(. != null)] | min) as $earliest"
        "         | if $earliest != null then .deploymentInfo[\"deploy:protocol\"].startBlock = $earliest else . end"
        "    else . end)";

    string[] private registeredNames;
    address[] private registeredAddrs;
    string[] private registeredVersions;

    function register(string memory name, address target, string memory version) public {
        registeredNames.push(name);
        registeredAddrs.push(target);
        registeredVersions.push(version);
    }

    function startDeploymentOutput() public {
        startDeploymentOutput(!REPLACE);
    }

    /// @notice Same, for a run that owns the whole of a chain's contracts. Pass `REPLACE` and everything the
    ///         config held that this run does not register is dropped: a script deploying a protocol from
    ///         nothing supersedes whatever was there, and leaving it would keep unreachable addresses beside
    ///         the live ones with nothing marking them dead. Every other script shares the file and merges.
    function startDeploymentOutput(bool replaces) public {
        replacesDeployment = replaces;

        delete registeredNames;
        delete registeredAddrs;
        delete registeredVersions;
    }

    /// @notice How many contracts this run has registered so far.
    /// @dev    Worth asserting on: the commit phase registers addresses as it walks, and the state
    ///         rollback that ends it discards them again — this contract's storage is rolled back with
    ///         everything else — so after a gated deployment this equals what the deploy phase deployed,
    ///         less the contracts submitted unreported.
    function registeredCount() public view returns (uint256) {
        return registeredNames.length;
    }

    /// @notice What this run would write under `.contracts`, as JSON.
    /// @dev    Public so that a test can hold the parser to the deployer: `EnvConfig` reads this object back,
    ///         and requiring a contract the deployer never registers is then a test failure rather than a
    ///         deployment that writes a config no script can load.
    function registeredContractsJson() public view returns (string memory contracts) {
        contracts = "{";
        for (uint256 i; i < registeredNames.length; i++) {
            contracts = string.concat(
                contracts,
                i == 0 ? "" : ",",
                "\"",
                registeredNames[i],
                "\":{\"address\":\"",
                vm.toString(registeredAddrs[i]),
                "\",\"version\":\"",
                registeredVersions[i],
                "\"}"
            );
        }
        contracts = string.concat(contracts, "}");
    }

    /// @param path Where to write, as `Chains.pathOf` resolves it. Passed in rather than worked out here, so
    ///        that this file stays free of the env-parsing stack — the deployer stack it belongs to is
    ///        mirrored publicly and `ChainConfig` is not.
    ///
    function saveDeploymentOutput(string memory path) public {
        _saveDeploymentOutput(path);
    }

    bool private replacesDeployment;

    function _saveDeploymentOutput(string memory path) internal {
        if (registeredNames.length == 0) return;

        // A deployment records itself under env/, never anywhere else. `Chains.pathOf` resolves by probing
        // and falls through to the checked-in fixtures under script/anvil/env/ when no run has copied them
        // into an env/ directory yet — a LaunchDeployer run started without anvil.sh would otherwise merge its addresses into a
        // tracked fixture, which describes two chains and never a deployment. The write goes through ffi,
        // which `fs_permissions` does not bind, so the guard has to live here.
        require(vm.indexOf(path, "env/") == 0, "a deployment records itself under env/");

        // A dry run walks the same deployment and computes the same addresses, but save nothing
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) && !vm.isContext(VmSafe.ForgeContext.ScriptResume)) {
            return;
        }

        string memory contracts = registeredContractsJson();

        // Handed over through the environment rather than pasted into the command: a value that reaches a
        // shell inside quotes it can close is a value that can run commands, and these are assembled from
        // whatever a deploy script chose to name its contracts and tag its salts. The git and date calls are
        // quoted for the same reason — jq's `--arg` then escapes each into JSON, so nothing here has to.
        vm.setEnv("REGISTRY_CONTRACTS", contracts);

        _sh(
            string.concat(
                "jq --argjson new \"$REGISTRY_CONTRACTS\" --argjson replace ",
                replacesDeployment ? "true" : "false",
                " --argjson block ",
                vm.toString(block.number),
                " --arg gitCommit \"$(git rev-parse --short HEAD)\"",
                " --arg timestamp \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"",
                " '",
                MERGE,
                "' '",
                path,
                "' > '",
                path,
                ".tmp' && mv '",
                path,
                ".tmp' '",
                path,
                "'"
            )
        );
        console.log("Wrote %s contracts into %s", registeredNames.length, path);
    }

    /// @notice Whether a name reached this registry, which is how a test tells a reported contract from one
    ///         deployed through `unreportedSalt`.
    function _registered(string memory name) internal view returns (bool) {
        for (uint256 i; i < registeredNames.length; i++) {
            if (keccak256(bytes(registeredNames[i])) == keccak256(bytes(name))) return true;
        }
        return false;
    }

    function _sh(string memory command) private returns (string memory) {
        string[] memory argv = new string[](5);
        argv[0] = "bash";
        argv[1] = "-euo";
        argv[2] = "pipefail";
        argv[3] = "-c";
        argv[4] = command;

        return string(vm.ffi(argv));
    }
}
