// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonInput} from "./CommonDeployer.s.sol";
import {VaultsDeployer} from "./VaultsDeployer.s.sol";
import {SpokeReport, SpokeActionBatcher} from "./SpokeDeployer.s.sol";

import {FreezeOnly} from "../src/hooks/FreezeOnly.sol";
import {FullRestrictions} from "../src/hooks/FullRestrictions.sol";
import {FreelyTransferable} from "../src/hooks/FreelyTransferable.sol";
import {RedemptionRestrictions} from "../src/hooks/RedemptionRestrictions.sol";

struct HooksReport {
    SpokeReport spoke;
    FreezeOnly freezeOnlyHook;
    FullRestrictions fullRestrictionsHook;
    FreelyTransferable freelyTransferableHook;
    RedemptionRestrictions redemptionRestrictionsHook;
}

contract HooksActionBatcher is SpokeActionBatcher {
    function engageHooks(HooksReport memory report) public onlyDeployer {
        // Rely Spoke
        report.freezeOnlyHook.rely(address(report.spoke.spoke));
        report.fullRestrictionsHook.rely(address(report.spoke.spoke));
        report.freelyTransferableHook.rely(address(report.spoke.spoke));
        report.redemptionRestrictionsHook.rely(address(report.spoke.spoke));

        // Rely Root
        report.freezeOnlyHook.rely(address(report.spoke.common.root));
        report.fullRestrictionsHook.rely(address(report.spoke.common.root));
        report.freelyTransferableHook.rely(address(report.spoke.common.root));
        report.redemptionRestrictionsHook.rely(address(report.spoke.common.root));
    }

    function revokeHooks(HooksReport memory report) public onlyDeployer {
        report.freezeOnlyHook.deny(address(this));
        report.fullRestrictionsHook.deny(address(this));
        report.freelyTransferableHook.deny(address(this));
        report.redemptionRestrictionsHook.deny(address(this));
    }
}

/// @dev These hook deployments assume `src/vaults` is used as the vaults logic for the pools.
///      It sets `vaults.GlobalEscrow` as the deposit target, `vaults.AsyncRequestManager` as the redeem source,
///      and `spoke.Spoke` as the cross-chain transfer source.
contract HooksDeployer is VaultsDeployer {
    FreezeOnly public freezeOnlyHook;
    FullRestrictions public fullRestrictionsHook;
    FreelyTransferable public freelyTransferableHook;
    RedemptionRestrictions public redemptionRestrictionsHook;

    function deployHooks(CommonInput memory input, HooksActionBatcher batcher) public {
        _preDeployHooks(input, batcher);
        _postDeployHooks(batcher);
    }

    function _preDeployHooks(CommonInput memory input, HooksActionBatcher batcher) internal {
        _preDeploySpoke(input, batcher);

        freezeOnlyHook = FreezeOnly(
            create3(
                generateSalt("freezeOnlyHook-2"),
                abi.encodePacked(
                    type(FreezeOnly).creationCode,
                    abi.encode(
                        address(root), address(asyncRequestManager), address(globalEscrow), address(spoke), batcher
                    )
                )
            )
        );

        fullRestrictionsHook = FullRestrictions(
            create3(
                generateSalt("fullRestrictionsHook-2"),
                abi.encodePacked(
                    type(FullRestrictions).creationCode,
                    abi.encode(
                        address(root), address(asyncRequestManager), address(globalEscrow), address(spoke), batcher
                    )
                )
            )
        );

        freelyTransferableHook = FreelyTransferable(
            create3(
                generateSalt("freelyTransferableHook-2"),
                abi.encodePacked(
                    type(FreelyTransferable).creationCode,
                    abi.encode(
                        address(root), address(asyncRequestManager), address(globalEscrow), address(spoke), batcher
                    )
                )
            )
        );

        redemptionRestrictionsHook = RedemptionRestrictions(
            create3(
                generateSalt("redemptionRestrictionsHook-2"),
                abi.encodePacked(
                    type(RedemptionRestrictions).creationCode,
                    abi.encode(
                        address(root), address(asyncRequestManager), address(globalEscrow), address(spoke), batcher
                    )
                )
            )
        );

        batcher.engageHooks(_hooksReport());

        register("freezeOnlyHook", address(freezeOnlyHook));
        register("fullRestrictionsHook", address(fullRestrictionsHook));
        register("freelyTransferableHook", address(freelyTransferableHook));
        register("redemptionRestrictionsHook", address(redemptionRestrictionsHook));
    }

    function _postDeployHooks(HooksActionBatcher batcher) internal {
        _postDeploySpoke(batcher);
    }

    function removeHooksDeployerAccess(HooksActionBatcher batcher) public {
        removeSpokeDeployerAccess(batcher);

        batcher.revokeHooks(_hooksReport());
    }

    function _hooksReport() internal view returns (HooksReport memory) {
        return HooksReport(
            _spokeReport(), freezeOnlyHook, fullRestrictionsHook, freelyTransferableHook, redemptionRestrictionsHook
        );
    }
}
