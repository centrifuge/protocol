// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseDeployer} from "./BaseDeployer.s.sol";
import {EnvConfig, Env, prettyEnvString} from "./utils/EnvConfig.s.sol";

import {AccountingToken} from "../src/managers/spoke/AccountingToken.sol";
import {ExecutorHelpers} from "../src/managers/spoke/ExecutorHelpers.sol";
import {FlashLoanHelper} from "../src/managers/spoke/FlashLoanHelper.sol";

import {console} from "forge-std/console.sol";
import "forge-std/Script.sol";

string constant EXECUTOR_V2_VERSION = "v3.2";

contract DeployExecutorV2 is BaseDeployer {
    AccountingToken public accountingToken;
    ExecutorHelpers public executorHelpers;
    FlashLoanHelper public flashLoanHelper;
    address public executorFactory;

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
                createSalt("accountingToken", EXECUTOR_V2_VERSION),
                abi.encodePacked(type(AccountingToken).creationCode, abi.encode(contractUpdater_))
            )
        );

        executorHelpers = ExecutorHelpers(
            create3(createSalt("executorHelpers", EXECUTOR_V2_VERSION), abi.encodePacked(type(ExecutorHelpers).creationCode))
        );

        flashLoanHelper = FlashLoanHelper(
            create3(createSalt("flashLoanHelper", EXECUTOR_V2_VERSION), abi.encodePacked(type(FlashLoanHelper).creationCode))
        );

        executorFactory = create3(
            createSalt("executorFactory", EXECUTOR_V2_VERSION),
            abi.encodePacked(
                vm.getCode("out-ir/Executor.sol/ExecutorFactory.json"),
                abi.encode(contractUpdater_, balanceSheet_, gateway_)
            )
        );

        console.log("accountingToken:  %s", address(accountingToken));
        console.log("executorHelpers:  %s", address(executorHelpers));
        console.log("flashLoanHelper:  %s", address(flashLoanHelper));
        console.log("executorFactory:  %s", executorFactory);
    }

    function _updateEnvFile(string memory network) internal {
        string memory path = string.concat("env/", network, ".json");

        vm.writeJson(_contractEntry(address(accountingToken)), path, ".contracts.accountingToken");
        vm.writeJson(_contractEntry(address(executorHelpers)), path, ".contracts.executorHelpers");
        vm.writeJson(_contractEntry(address(flashLoanHelper)), path, ".contracts.flashLoanHelper");
        vm.writeJson(_contractEntry(executorFactory), path, ".contracts.executorFactory");

        console.log("Env file updated: %s", path);
    }

    function _contractEntry(address addr) internal pure returns (string memory) {
        return string.concat('{"address":"', vm.toString(addr), '","version":"', EXECUTOR_V2_VERSION, '"}');
    }
}
