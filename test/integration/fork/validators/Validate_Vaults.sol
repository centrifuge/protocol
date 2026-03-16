// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IAuth} from "../../../../src/misc/interfaces/IAuth.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {ISpoke} from "../../../../src/core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {IShareToken} from "../../../../src/core/spoke/interfaces/IShareToken.sol";
import {IRequestManager} from "../../../../src/core/interfaces/IRequestManager.sol";
import {IBalanceSheet} from "../../../../src/core/spoke/interfaces/IBalanceSheet.sol";

import {IRoot} from "../../../../src/admin/interfaces/IRoot.sol";

import {BaseVault} from "../../../../src/vaults/BaseVaults.sol";
import {IBaseVault} from "../../../../src/vaults/interfaces/IBaseVault.sol";
import {IBaseRequestManager} from "../../../../src/vaults/interfaces/IBaseRequestManager.sol";

import {JsonUtils} from "../../../../script/utils/JsonUtils.s.sol";
import {ContractsConfig as C} from "../../../../script/utils/EnvConfig.s.sol";

import {stdJson} from "forge-std/StdJson.sol";

import {BaseValidator, ValidationContext} from "../../spell/utils/validation/BaseValidator.sol";

/// @title Validate_Vaults
/// @notice Validates all deployed vaults: Root ward, baseManager, root reference, share token wiring,
///         asset validity, spoke linkage, pool active, balanceSheet manager, and requestManager.
///         Queries the indexer for all vault addresses — zero hardcoded addresses.
contract Validate_Vaults is BaseValidator("Vaults") {
    using stdJson for string;
    using JsonUtils for *;

    function validate(ValidationContext memory ctx) public override {
        C memory c = ctx.contracts.live;

        string memory centrifugeIdStr = vm.toString(ctx.localCentrifugeId).asJsonString();
        string memory json = ctx.indexer
            .queryGraphQL(
                string.concat(
                    "vaults(limit: 1000, where: { centrifugeId: ", centrifugeIdStr, " }) { totalCount items { id } }"
                )
            );
        uint256 totalCount = json.readUint(".data.vaults.totalCount");

        if (totalCount == 0) return;
        require(totalCount <= 1000, "Vault count exceeds query limit; implement pagination");

        for (uint256 i; i < totalCount; i++) {
            address vaultAddr = json.readAddress(".data.vaults.items".asJsonPath(i, "id"));
            _validateVault(vaultAddr, c);
        }
    }

    function _validateVault(address vaultAddr, C memory c) internal {
        string memory vaultLabel = vm.toString(vaultAddr);

        if (vaultAddr.code.length == 0) {
            _errors.push(_buildError("code", vaultLabel, "> 0", "0", "Vault has no code"));
            return;
        }

        _checkWard(vaultAddr, c.root, vaultLabel, "vault Root ward");
        _checkBaseManager(vaultAddr, c.asyncRequestManager, vaultLabel);
        _checkVaultRoot(vaultAddr, c.root, vaultLabel);

        IBaseVault vault = IBaseVault(vaultAddr);
        address share;
        PoolId poolId;
        ShareClassId scId;

        try vault.share() returns (address s) {
            share = s;
        } catch {
            _errors.push(_buildError("share", vaultLabel, "callable", "reverted", "vault.share() reverted"));
            return;
        }
        try vault.poolId() returns (PoolId p) {
            poolId = p;
        } catch {
            _errors.push(_buildError("poolId", vaultLabel, "callable", "reverted", "vault.poolId() reverted"));
            return;
        }
        try vault.scId() returns (ShareClassId s) {
            scId = s;
        } catch {
            _errors.push(_buildError("scId", vaultLabel, "callable", "reverted", "vault.scId() reverted"));
            return;
        }

        if (share == address(0)) {
            _errors.push(_buildError("share", vaultLabel, "!= address(0)", "address(0)", "Vault share is zero"));
            return;
        }

        _validateVaultWiring(vaultAddr, vault, share, poolId, scId, c, vaultLabel);
    }

    function _validateVaultWiring(
        address vaultAddr,
        IBaseVault vault,
        address share,
        PoolId poolId,
        ShareClassId scId,
        C memory c,
        string memory vaultLabel
    ) internal {
        _checkWard(share, c.root, vaultLabel, "shareToken Root ward");
        _checkWard(share, c.balanceSheet, vaultLabel, "shareToken BalanceSheet ward");
        _checkWard(share, c.spoke, vaultLabel, "shareToken Spoke ward");

        address asset = vault.asset();
        if (asset.code.length == 0) {
            _errors.push(_buildError("asset", vaultLabel, "> 0", "0", "vault.asset() has no deployed code"));
        }

        _checkShareTokenVaultMapping(share, asset, vaultAddr, vaultLabel);
        _checkSpokeShareToken(c.spoke, poolId, scId, share, vaultLabel);
        _checkPoolActive(c.spoke, poolId, vaultLabel);
        _checkBalanceSheetManager(c.balanceSheet, c.asyncRequestManager, poolId, vaultLabel);
        _checkRequestManager(c.spoke, c.asyncRequestManager, poolId, vaultLabel);
    }

    // ==================== CHECK HELPERS ====================

    function _checkBaseManager(address vaultAddr, address expectedArm, string memory vaultLabel) internal {
        try BaseVault(vaultAddr).baseManager() returns (IBaseRequestManager mgr) {
            if (address(mgr) == address(0)) {
                _errors.push(
                    _buildError("baseManager", vaultLabel, "!= address(0)", "address(0)", "baseManager is zero")
                );
            } else if (address(mgr) != expectedArm) {
                _errors.push(
                    _buildError(
                        "baseManager",
                        vaultLabel,
                        vm.toString(expectedArm),
                        vm.toString(address(mgr)),
                        "baseManager does not match AsyncRequestManager"
                    )
                );
            }
        } catch {
            _errors.push(_buildError("baseManager", vaultLabel, "callable", "reverted", "baseManager() reverted"));
        }
    }

    function _checkVaultRoot(address vaultAddr, address expectedRoot, string memory vaultLabel) internal {
        try BaseVault(vaultAddr).root() returns (IRoot vaultRoot) {
            if (address(vaultRoot) != expectedRoot) {
                _errors.push(
                    _buildError(
                        "root",
                        vaultLabel,
                        vm.toString(expectedRoot),
                        vm.toString(address(vaultRoot)),
                        "vault.root() mismatch"
                    )
                );
            }
        } catch {
            _errors.push(_buildError("root", vaultLabel, "callable", "reverted", "vault.root() reverted"));
        }
    }

    function _checkShareTokenVaultMapping(address share, address asset, address vaultAddr, string memory vaultLabel)
        internal
    {
        try IShareToken(share).vault(asset) returns (address mappedVault) {
            if (mappedVault == address(0)) {
                _errors.push(
                    _buildError(
                        "shareToken.vault",
                        vaultLabel,
                        vm.toString(vaultAddr),
                        "address(0)",
                        "shareToken vault mapping not set"
                    )
                );
            }
        } catch {
            _errors.push(
                _buildError("shareToken.vault", vaultLabel, "callable", "reverted", "shareToken.vault() reverted")
            );
        }
    }

    function _checkSpokeShareToken(
        address spoke,
        PoolId poolId,
        ShareClassId scId,
        address share,
        string memory vaultLabel
    ) internal {
        try ISpoke(spoke).shareToken(poolId, scId) returns (IShareToken linkedToken) {
            if (address(linkedToken) != share) {
                _errors.push(
                    _buildError(
                        "spoke.shareToken",
                        vaultLabel,
                        vm.toString(share),
                        vm.toString(address(linkedToken)),
                        "Spoke shareToken mismatch"
                    )
                );
            }
        } catch {
            _errors.push(
                _buildError("spoke.shareToken", vaultLabel, "callable", "reverted", "spoke.shareToken() reverted")
            );
        }
    }

    function _checkPoolActive(address spoke, PoolId poolId, string memory vaultLabel) internal {
        try ISpoke(spoke).isPoolActive(poolId) returns (bool active) {
            if (!active) {
                _errors.push(_buildError("isPoolActive", vaultLabel, "true", "false", "Pool not active on Spoke"));
            }
        } catch {
            _errors.push(
                _buildError("isPoolActive", vaultLabel, "callable", "reverted", "spoke.isPoolActive() reverted")
            );
        }
    }

    function _checkBalanceSheetManager(
        address balanceSheet,
        address asyncRequestManager,
        PoolId poolId,
        string memory vaultLabel
    ) internal {
        if (asyncRequestManager == address(0)) return;
        try IBalanceSheet(balanceSheet).manager(poolId, asyncRequestManager) returns (bool isManager) {
            if (!isManager) {
                _errors.push(
                    _buildError(
                        "balanceSheet.manager",
                        vaultLabel,
                        "true",
                        "false",
                        "AsyncRequestManager not set as manager in BalanceSheet"
                    )
                );
            }
        } catch {
            _errors.push(
                _buildError(
                    "balanceSheet.manager", vaultLabel, "callable", "reverted", "balanceSheet.manager() reverted"
                )
            );
        }
    }

    function _checkRequestManager(address spoke, address asyncRequestManager, PoolId poolId, string memory vaultLabel)
        internal
    {
        try ISpoke(spoke).requestManager(poolId) returns (IRequestManager rm) {
            if (address(rm) != asyncRequestManager) {
                _errors.push(
                    _buildError(
                        "spoke.requestManager",
                        vaultLabel,
                        vm.toString(asyncRequestManager),
                        vm.toString(address(rm)),
                        "Spoke requestManager mismatch for pool"
                    )
                );
            }
        } catch {
            _errors.push(
                _buildError(
                    "spoke.requestManager", vaultLabel, "callable", "reverted", "spoke.requestManager() reverted"
                )
            );
        }
    }

    function _checkWard(address target, address wardHolder, string memory vaultLabel, string memory wardLabel)
        internal
    {
        if (target == address(0) || wardHolder == address(0)) return;
        if (target.code.length == 0) return;

        try IAuth(target).wards(wardHolder) returns (uint256 val) {
            if (val != 1) {
                _errors.push(
                    _buildError(wardLabel, vaultLabel, "1", vm.toString(val), string.concat(wardLabel, " missing"))
                );
            }
        } catch {
            _errors.push(
                _buildError(wardLabel, vaultLabel, "callable", "reverted", string.concat(wardLabel, " reverted"))
            );
        }
    }
}
