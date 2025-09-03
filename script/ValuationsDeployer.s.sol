// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonInput} from "./CommonDeployer.s.sol";
import {HubDeployer, HubReport, HubActionBatcher} from "./HubDeployer.s.sol";

import {OracleValuation} from "../src/valuations/OracleValuation.sol";
import {IdentityValuation} from "../src/valuations/IdentityValuation.sol";

import "forge-std/Script.sol";

struct ValuationsReport {
    HubReport hub;
    IdentityValuation identityValuation;
}

contract ValuationsActionBatcher is HubActionBatcher {
    function engageValuations(ValuationsReport memory report) public onlyDeployer {}

    function revokeValuations(ValuationsReport memory report) public onlyDeployer {}
}

contract ValuationsDeployer is HubDeployer {
    IdentityValuation public identityValuation;
    OracleValuation public oracleValuation;

    function deployValuations(CommonInput memory input, ValuationsActionBatcher batcher) public {
        _preDeployValuations(input, batcher);
        _postDeployValuations(batcher);
    }

    function _preDeployValuations(CommonInput memory input, ValuationsActionBatcher batcher) internal {
        _preDeployHub(input, batcher);

        identityValuation = IdentityValuation(
            create3(
                generateSalt("identityValuation"),
                abi.encodePacked(type(IdentityValuation).creationCode, abi.encode(hubRegistry))
            )
        );

        oracleValuation = OracleValuation(
            create3(
                generateSalt("oracleValuation"),
                abi.encodePacked(type(OracleValuation).creationCode, abi.encode(hubRegistry))
            )
        );

        batcher.engageValuations(_valuationsReport());

        register("identityValuation", address(identityValuation));
        register("oracleValuation", address(oracleValuation));
    }

    function _postDeployValuations(ValuationsActionBatcher batcher) internal {
        _postDeployHub(batcher);
    }

    function removeValuationsDeployerAccess(ValuationsActionBatcher batcher) public {
        removeHubDeployerAccess(batcher);

        batcher.revokeValuations(_valuationsReport());
    }

    function _valuationsReport() internal view returns (ValuationsReport memory) {
        return ValuationsReport(_hubReport(), identityValuation);
    }
}
