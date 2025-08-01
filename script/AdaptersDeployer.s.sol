// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonDeployer, CommonInput, CommonReport, CommonActionBatcher} from "./CommonDeployer.s.sol";

import "forge-std/Script.sol";

import {AxelarAdapter} from "../src/adapters/AxelarAdapter.sol";
import {WormholeAdapter} from "../src/adapters/WormholeAdapter.sol";

struct WormholeInput {
    bool shouldDeploy;
    address relayer;
}

struct AxelarInput {
    bool shouldDeploy;
    address gateway;
    address gasService;
}

struct AdaptersInput {
    WormholeInput wormhole;
    AxelarInput axelar;
}

struct AdaptersReport {
    CommonReport common;
    WormholeAdapter wormholeAdapter;
    AxelarAdapter axelarAdapter;
}

contract AdaptersActionBatcher is CommonActionBatcher {
    function engageAdapters(AdaptersReport memory report) public onlyDeployer {
        if (address(report.wormholeAdapter) != address(0)) {
            report.wormholeAdapter.rely(address(report.common.root));
            report.wormholeAdapter.rely(address(report.common.guardian));
        }
        if (address(report.axelarAdapter) != address(0)) {
            report.axelarAdapter.rely(address(report.common.root));
            report.axelarAdapter.rely(address(report.common.guardian));
        }
    }

    function revokeAdapters(AdaptersReport memory report) public onlyDeployer {
        if (address(report.wormholeAdapter) != address(0)) report.wormholeAdapter.deny(address(this));
        if (address(report.axelarAdapter) != address(0)) report.axelarAdapter.deny(address(this));
    }
}

contract AdaptersDeployer is CommonDeployer {
    WormholeAdapter wormholeAdapter;
    AxelarAdapter axelarAdapter;

    function deployAdapters(CommonInput memory input, AdaptersInput memory adaptersInput, AdaptersActionBatcher batcher)
        public
    {
        _preDeployAdapters(input, adaptersInput, batcher);
        _postDeployAdapters(batcher);
    }

    function _preDeployAdapters(
        CommonInput memory input,
        AdaptersInput memory adaptersInput,
        AdaptersActionBatcher batcher
    ) internal {
        _preDeployCommon(input, batcher);

        if (adaptersInput.wormhole.shouldDeploy) {
            wormholeAdapter = WormholeAdapter(
                create3(
                    generateSalt("wormholeAdapter"),
                    abi.encodePacked(
                        type(WormholeAdapter).creationCode,
                        abi.encode(multiAdapter, adaptersInput.wormhole.relayer, batcher)
                    )
                )
            );
        }

        if (adaptersInput.axelar.shouldDeploy) {
            axelarAdapter = AxelarAdapter(
                create3(
                    generateSalt("axelarAdapter"),
                    abi.encodePacked(
                        type(AxelarAdapter).creationCode,
                        abi.encode(multiAdapter, adaptersInput.axelar.gateway, adaptersInput.axelar.gasService, batcher)
                    )
                )
            );
        }

        batcher.engageAdapters(_adaptersReport());

        if (adaptersInput.wormhole.shouldDeploy) register("wormholeAdapter", address(wormholeAdapter));
        if (adaptersInput.axelar.shouldDeploy) register("axelarAdapter", address(axelarAdapter));
    }

    function _postDeployAdapters(AdaptersActionBatcher batcher) internal {
        _postDeployCommon(batcher);
    }

    function removeAdaptersDeployerAccess(AdaptersActionBatcher batcher) public {
        removeCommonDeployerAccess(batcher);

        batcher.revokeAdapters(_adaptersReport());
    }

    function _adaptersReport() internal view returns (AdaptersReport memory) {
        return AdaptersReport(_commonReport(), wormholeAdapter, axelarAdapter);
    }

    function noAdaptersInput() public pure returns (AdaptersInput memory) {
        return AdaptersInput({
            wormhole: WormholeInput({shouldDeploy: false, relayer: address(0)}),
            axelar: AxelarInput({shouldDeploy: false, gateway: address(0), gasService: address(0)})
        });
    }
}
