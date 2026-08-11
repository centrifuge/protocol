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

import {OracleValuation} from "../src/valuations/OracleValuation.sol";

import "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

contract DeployOnchainPMV2 is BaseDeployer {
    AccountingToken public accountingToken;
    ScriptHelpers public scriptHelpers;
    FlashLoanHelper public flashLoanHelper;
    address public onchainPMFactory;
    OnOffRampFactory public onOffRampFactory;
    ApprovalGuard public approvalGuard;
    CircuitBreakerGuard public circuitBreakerGuard;
    SlippageGuard public slippageGuard;
    OracleValuation public oracleValuation;

    function run() public {
        string memory network = prettyEnvString("NETWORK");
        EnvConfig memory config = Env.load(network);
        string memory suffix = config.network.isMainnet() ? "" : vm.envOr("SUFFIX", string(""));

        vm.startBroadcast();
        startDeploymentOutput();

        _init(suffix);

        _deploy(
            config.contracts.contractUpdater,
            config.contracts.gateway,
            config.contracts.spoke,
            config.contracts.hub,
            config.contracts.hubRegistry
        );

        saveDeploymentOutput();

        vm.stopBroadcast();
    }

    function _deploy(address contractUpdater_, address gateway_, address spoke_, address hub_, address hubRegistry_)
        internal
    {
        require(contractUpdater_ != address(0), "contractUpdater not set in env");
        require(gateway_ != address(0), "gateway not set in env");
        require(spoke_ != address(0), "spoke not set in env");
        require(hub_ != address(0), "hub not set in env");
        require(hubRegistry_ != address(0), "hubRegistry not set in env");

        accountingToken = AccountingToken(
            create3(
                "accountingToken",
                V3_3,
                abi.encodePacked(type(AccountingToken).creationCode, abi.encode(contractUpdater_))
            )
        );

        scriptHelpers =
            ScriptHelpers(create3("scriptHelpers", V3_2, abi.encodePacked(type(ScriptHelpers).creationCode)));

        onchainPMFactory = create3(
            "onchainPMFactory",
            V3_3,
            abi.encodePacked(
                vm.getCode("out-ir/OnchainPM.sol/OnchainPMFactory.json"), abi.encode(contractUpdater_, spoke_, gateway_)
            )
        );

        flashLoanHelper = FlashLoanHelper(
            create3(
                "flashLoanHelper",
                V3_3,
                abi.encodePacked(type(FlashLoanHelper).creationCode, abi.encode(onchainPMFactory))
            )
        );

        onOffRampFactory = OnOffRampFactory(
            create3(
                "onOffRampFactory",
                V3_3,
                abi.encodePacked(
                    type(OnOffRampFactory).creationCode, abi.encode(contractUpdater_, spoke_, accountingToken)
                )
            )
        );

        approvalGuard =
            ApprovalGuard(create3("approvalGuard", V3_2, abi.encodePacked(type(ApprovalGuard).creationCode)));

        circuitBreakerGuard = CircuitBreakerGuard(
            create3("circuitBreakerGuard", V3_3, abi.encodePacked(type(CircuitBreakerGuard).creationCode))
        );

        slippageGuard = SlippageGuard(
            create3(
                "slippageGuard",
                V3_3,
                abi.encodePacked(
                    type(SlippageGuard).creationCode, abi.encode(spoke_, contractUpdater_, onchainPMFactory)
                )
            )
        );

        oracleValuation = OracleValuation(
            create3(
                "oracleValuation",
                V3_3,
                abi.encodePacked(type(OracleValuation).creationCode, abi.encode(hub_, hubRegistry_, contractUpdater_))
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
        console.log("oracleValuation:    %s", address(oracleValuation));
    }
}
