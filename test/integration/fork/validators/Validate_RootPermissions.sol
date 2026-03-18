// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {ContractsConfig as C} from "../../../../script/utils/EnvConfig.s.sol";

import {BaseValidator, ValidationContext} from "../../spell/utils/validation/BaseValidator.sol";

/// @title Validate_RootPermissions
/// @notice Validates that all core protocol contracts have Root as a ward.
///         Uses env config only. Vault/share token Root wards are checked by Validate_Vaults.
contract Validate_RootPermissions is BaseValidator("RootPermissions") {
    function validate(ValidationContext memory ctx) public override {
        address root = ctx.contracts.live.root;
        C memory c = ctx.contracts.live;

        // ==================== CORE CONTRACTS (from env config) ====================

        _checkRootWard(root, c.gateway, "gateway");
        _checkRootWard(root, c.multiAdapter, "multiAdapter");
        _checkRootWard(root, c.messageDispatcher, "messageDispatcher");
        _checkRootWard(root, c.messageProcessor, "messageProcessor");

        _checkRootWard(root, c.poolEscrowFactory, "poolEscrowFactory");
        _checkRootWard(root, c.tokenFactory, "tokenFactory");
        _checkRootWard(root, c.spoke, "spoke");
        _checkRootWard(root, c.balanceSheet, "balanceSheet");
        _checkRootWard(root, c.contractUpdater, "contractUpdater");
        _checkRootWard(root, c.vaultRegistry, "vaultRegistry");

        _checkRootWard(root, c.hubRegistry, "hubRegistry");
        _checkRootWard(root, c.accounting, "accounting");
        _checkRootWard(root, c.holdings, "holdings");
        _checkRootWard(root, c.shareClassManager, "shareClassManager");
        _checkRootWard(root, c.hub, "hub");
        _checkRootWard(root, c.hubHandler, "hubHandler");

        _checkRootWard(root, c.tokenRecoverer, "tokenRecoverer");
        _checkRootWard(root, c.refundEscrowFactory, "refundEscrowFactory");

        _checkRootWard(root, c.asyncVaultFactory, "asyncVaultFactory");
        _checkRootWard(root, c.asyncRequestManager, "asyncRequestManager");
        _checkRootWard(root, c.syncDepositVaultFactory, "syncDepositVaultFactory");
        _checkRootWard(root, c.syncManager, "syncManager");
        _checkRootWard(root, c.vaultRouter, "vaultRouter");
        _checkRootWard(root, c.batchRequestManager, "batchRequestManager");

        _checkRootWard(root, c.freezeOnlyHook, "freezeOnlyHook");
        _checkRootWard(root, c.fullRestrictionsHook, "fullRestrictionsHook");
        _checkRootWard(root, c.freelyTransferableHook, "freelyTransferableHook");
        _checkRootWard(root, c.redemptionRestrictionsHook, "redemptionRestrictionsHook");

        _checkRootWard(root, c.subsidyManager, "subsidyManager");

        _checkRootWard(root, c.wormholeAdapter, "wormholeAdapter");
        _checkRootWard(root, c.axelarAdapter, "axelarAdapter");
        _checkRootWard(root, c.layerZeroAdapter, "layerZeroAdapter");
        _checkRootWard(root, c.chainlinkAdapter, "chainlinkAdapter");
    }

    function _checkRootWard(address root, address target, string memory label) internal {
        _checkWard(target, root, string.concat("Root not ward of ", label));
    }
}
