// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseDeployer} from "./BaseDeployer.s.sol";
import {EnvConfig, Env, prettyEnvString} from "./utils/EnvConfig.s.sol";

import {OnOffRampFactory} from "../src/managers/spoke/OnOffRamp.sol";
import {ScriptHelpers} from "../src/managers/spoke/ScriptHelpers.sol";
import {AccountingToken} from "../src/managers/spoke/AccountingToken.sol";
import {FlashLoanHelper} from "../src/managers/spoke/FlashLoanHelper.sol";
import {ApprovalGuard} from "../src/managers/spoke/guards/ApprovalGuard.sol";
import {SlippageGuard} from "../src/managers/spoke/guards/SlippageGuard.sol";
import {CircuitBreakerGuard} from "../src/managers/spoke/guards/CircuitBreakerGuard.sol";

import "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

string constant ONCHAIN_PM_V2_VERSION = "v3.2";

contract DeployOnchainPMV2 is BaseDeployer {
    AccountingToken public accountingToken;
    ScriptHelpers public scriptHelpers;
    FlashLoanHelper public flashLoanHelper;
    address public onchainPMFactory;
    OnOffRampFactory public onOffRampFactory;
    ApprovalGuard public approvalGuard;
    CircuitBreakerGuard public circuitBreakerGuard;
    SlippageGuard public slippageGuard;

    function run() public {
        string memory network = prettyEnvString("NETWORK");
        EnvConfig memory config = Env.load(network);
        string memory suffix = config.network.isMainnet() ? "" : vm.envOr("SUFFIX", string(""));

        vm.startBroadcast();
        startDeploymentOutput();

        _init(suffix, msg.sender);

        _deploy(
            config.contracts.contractUpdater,
            config.contracts.balanceSheet,
            config.contracts.gateway,
            config.contracts.spoke
        );

        saveDeploymentOutput();

        vm.stopBroadcast();
    }

    function _deploy(address contractUpdater_, address balanceSheet_, address gateway_, address spoke_) internal {
        require(contractUpdater_ != address(0), "contractUpdater not set in env");
        require(balanceSheet_ != address(0), "balanceSheet not set in env");
        require(gateway_ != address(0), "gateway not set in env");
        require(spoke_ != address(0), "spoke not set in env");

        accountingToken = AccountingToken(
            create3(
                createSalt("accountingToken", ONCHAIN_PM_V2_VERSION),
                abi.encodePacked(type(AccountingToken).creationCode, abi.encode(contractUpdater_))
            )
        );

        scriptHelpers = ScriptHelpers(
            create3(
                createSalt("scriptHelpers", ONCHAIN_PM_V2_VERSION), abi.encodePacked(type(ScriptHelpers).creationCode)
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

        onOffRampFactory = OnOffRampFactory(
            create3(
                createSalt("onOffRampFactory", ONCHAIN_PM_V2_VERSION),
                abi.encodePacked(
                    type(OnOffRampFactory).creationCode, abi.encode(contractUpdater_, balanceSheet_, accountingToken)
                )
            )
        );

        approvalGuard = ApprovalGuard(
            create3(
                createSalt("approvalGuard", ONCHAIN_PM_V2_VERSION), abi.encodePacked(type(ApprovalGuard).creationCode)
            )
        );

        circuitBreakerGuard = CircuitBreakerGuard(
            create3(
                createSalt("circuitBreakerGuard", ONCHAIN_PM_V2_VERSION),
                abi.encodePacked(type(CircuitBreakerGuard).creationCode)
            )
        );

        slippageGuard = SlippageGuard(
            create3(
                createSalt("slippageGuard", ONCHAIN_PM_V2_VERSION),
                abi.encodePacked(
                    type(SlippageGuard).creationCode,
                    abi.encode(spoke_, balanceSheet_, contractUpdater_, onchainPMFactory)
                )
            )
        );

        console.log("accountingToken:    %s", address(accountingToken));
        console.log("scriptHelpers:      %s", address(scriptHelpers));
        console.log("onchainPMFactory:   %s", onchainPMFactory);
        console.log("flashLoanHelper:    %s", address(flashLoanHelper));
        console.log("onOffRampFactory:   %s", address(onOffRampFactory));
        console.log("approvalGuard:      %s", address(approvalGuard));
        console.log("circuitBreakerGuard:%s", address(circuitBreakerGuard));
        console.log("slippageGuard:      %s", address(slippageGuard));
    }
}
