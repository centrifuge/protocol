// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseDeployer} from "./BaseDeployer.s.sol";
import {EnvConfig, Env, prettyEnvString} from "./utils/EnvConfig.s.sol";

import {AccountingToken} from "../src/managers/spoke/AccountingToken.sol";
import {FlashLoanHelper} from "../src/managers/spoke/FlashLoanHelper.sol";
import {IOnchainPMFactory} from "../src/managers/spoke/interfaces/IOnchainPMFactory.sol";
import {ScriptHelpers} from "../src/managers/spoke/ScriptHelpers.sol";

import "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

string constant ONCHAIN_PM_V2_VERSION = "v3.2";

contract DeployOnchainPMV2 is BaseDeployer {
    AccountingToken public accountingToken;
    ScriptHelpers public scriptHelpers;
    FlashLoanHelper public flashLoanHelper;
    address public onchainPMFactory;

    function run() public {
        string memory network = prettyEnvString("NETWORK");
        EnvConfig memory config = Env.load(network);
        string memory suffix = config.network.isMainnet() ? "" : vm.envOr("SUFFIX", string(""));

        vm.startBroadcast();
        startDeploymentOutput();

        _init(suffix, msg.sender);

        _deploy(config.contracts.contractUpdater, config.contracts.balanceSheet, config.contracts.gateway);

        saveDeploymentOutput();
        _updateEnvFile(network);

        vm.stopBroadcast();
    }

    function _deploy(address contractUpdater_, address balanceSheet_, address gateway_) internal {
        require(contractUpdater_ != address(0), "contractUpdater not set in env");
        require(balanceSheet_ != address(0), "balanceSheet not set in env");
        require(gateway_ != address(0), "gateway not set in env");

        accountingToken = AccountingToken(
            create3(
                createSalt("accountingToken", ONCHAIN_PM_V2_VERSION),
                abi.encodePacked(type(AccountingToken).creationCode, abi.encode(contractUpdater_))
            )
        );

        scriptHelpers = ScriptHelpers(
            create3(
                createSalt("scriptHelpers", ONCHAIN_PM_V2_VERSION),
                abi.encodePacked(type(ScriptHelpers).creationCode)
            )
        );

        onchainPMFactory = create3(
            createSalt("onchainPMFactory", ONCHAIN_PM_V2_VERSION),
            abi.encodePacked(
                vm.getCode("out-ir/OnchainPM.sol/OnchainPMFactory.json"),
                abi.encode(contractUpdater_, balanceSheet_, gateway_)
            )
        );

        flashLoanHelper = FlashLoanHelper(
            create3(
                createSalt("flashLoanHelper", ONCHAIN_PM_V2_VERSION),
                abi.encodePacked(type(FlashLoanHelper).creationCode, abi.encode(onchainPMFactory))
            )
        );

        console.log("accountingToken:   %s", address(accountingToken));
        console.log("scriptHelpers:  %s", address(scriptHelpers));
        console.log("onchainPMFactory:  %s", onchainPMFactory);
        console.log("flashLoanHelper:   %s", address(flashLoanHelper));
    }

    function _updateEnvFile(string memory network) internal {
        string memory path = string.concat("env/", network, ".json");

        vm.writeJson(_contractEntry(address(accountingToken)), path, ".contracts.accountingToken");
        vm.writeJson(_contractEntry(address(scriptHelpers)), path, ".contracts.scriptHelpers");
        vm.writeJson(_contractEntry(address(flashLoanHelper)), path, ".contracts.flashLoanHelper");
        vm.writeJson(_contractEntry(onchainPMFactory), path, ".contracts.onchainPMFactory");

        console.log("Env file updated: %s", path);
    }

    function _contractEntry(address addr) internal pure returns (string memory) {
        return string.concat('{"address":"', vm.toString(addr), '","version":"', ONCHAIN_PM_V2_VERSION, '"}');
    }
}
