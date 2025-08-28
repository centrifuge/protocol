// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonDeployer, CommonInput, CommonReport, CommonActionBatcher} from "./CommonDeployer.s.sol";

import "forge-std/Script.sol";

import {WormholeAdapter} from "../src/adapters/WormholeAdapter.sol";
import {LayerZeroAdapter} from "../src/adapters/LayerZeroAdapter.sol";

struct WormholeInput {
    bool shouldDeploy;
    address relayer;
}

struct LayerZeroInput {
    bool shouldDeploy;
    address endpoint;
    address delegate;
}

struct AdaptersInput {
    WormholeInput wormhole;
    LayerZeroInput layerZero;
}

struct AdaptersReport {
    CommonReport common;
    WormholeAdapter wormholeAdapter;
    LayerZeroAdapter layerZeroAdapter;
}

contract AdaptersActionBatcher is CommonActionBatcher {
    function engageAdapters(AdaptersReport memory report) public onlyDeployer {
        if (address(report.wormholeAdapter) != address(0)) {
            report.wormholeAdapter.rely(address(report.common.root));
            report.wormholeAdapter.rely(address(report.common.guardian));
            report.wormholeAdapter.rely(address(report.common.adminSafe));
        }
        if (address(report.layerZeroAdapter) != address(0)) {
            report.layerZeroAdapter.rely(address(report.common.root));
            report.layerZeroAdapter.rely(address(report.common.guardian));
            report.layerZeroAdapter.rely(address(report.common.adminSafe));
        }
    }

    function revokeAdapters(AdaptersReport memory report) public onlyDeployer {
        if (address(report.wormholeAdapter) != address(0)) report.wormholeAdapter.deny(address(this));
        if (address(report.layerZeroAdapter) != address(0)) report.layerZeroAdapter.deny(address(this));
    }
}

contract AdaptersDeployer is CommonDeployer {
    WormholeAdapter wormholeAdapter;
    LayerZeroAdapter layerZeroAdapter;

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
            require(adaptersInput.wormhole.relayer != address(0), "Wormhole relayer address cannot be zero");
            require(adaptersInput.wormhole.relayer.code.length > 0, "Wormhole relayer must be a deployed contract");

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

        if (adaptersInput.layerZero.shouldDeploy) {
            require(adaptersInput.layerZero.endpoint != address(0), "LayerZero endpoint address cannot be zero");
            require(adaptersInput.layerZero.endpoint.code.length > 0, "LayerZero endpoint must be a deployed contract");
            require(adaptersInput.layerZero.delegate != address(0), "LayerZero delegate address cannot be zero");

            layerZeroAdapter = LayerZeroAdapter(
                create3(
                    generateSalt("layerZeroAdapter"),
                    abi.encodePacked(
                        type(LayerZeroAdapter).creationCode,
                        abi.encode(
                            multiAdapter, adaptersInput.layerZero.endpoint, adaptersInput.layerZero.delegate, batcher
                        )
                    )
                )
            );
        }

        batcher.engageAdapters(_adaptersReport());

        if (adaptersInput.wormhole.shouldDeploy) register("wormholeAdapter", address(wormholeAdapter));
        if (adaptersInput.layerZero.shouldDeploy) register("layerZeroAdapter", address(layerZeroAdapter));
    }

    function _postDeployAdapters(AdaptersActionBatcher batcher) internal {
        _postDeployCommon(batcher);
    }

    function removeAdaptersDeployerAccess(AdaptersActionBatcher batcher) public {
        removeCommonDeployerAccess(batcher);

        batcher.revokeAdapters(_adaptersReport());
    }

    function _adaptersReport() internal view returns (AdaptersReport memory) {
        return AdaptersReport(_commonReport(), wormholeAdapter, layerZeroAdapter);
    }

    function noAdaptersInput() public pure returns (AdaptersInput memory) {
        return AdaptersInput({
            wormhole: WormholeInput({shouldDeploy: false, relayer: address(0)}),
            layerZero: LayerZeroInput({shouldDeploy: false, endpoint: address(0), delegate: address(0)})
        });
    }
}
