// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IAuth} from "../../../../src/misc/interfaces/IAuth.sol";

import {Env, EnvConfig, ContractsConfig as C} from "../../../../script/utils/EnvConfig.s.sol";

import {BaseValidator, ValidationContext} from "../../spell/utils/validation/BaseValidator.sol";

/// @title Validate_ContractWards
/// @notice Validates all contract-to-contract ward relationships are correctly set.
contract Validate_ContractWards is BaseValidator("ContractWards") {
    function validate(ValidationContext memory ctx) public override {
        C memory c = ctx.contracts.live;

        // Load protocolSafe from env config
        EnvConfig memory config = Env.load(ctx.networkName);
        address protocolSafe = config.network.protocolAdmin;

        // ==================== ROOT WARDS ====================

        _checkWard(c.root, c.messageProcessor, "root <- messageProcessor");
        _checkWard(c.root, c.messageDispatcher, "root <- messageDispatcher");

        // ==================== CORE MESSAGING ====================

        _checkWard(c.multiAdapter, c.gateway, "multiAdapter <- gateway");
        _checkWard(c.gateway, c.multiAdapter, "gateway <- multiAdapter");
        _checkWard(c.gateway, c.messageDispatcher, "gateway <- messageDispatcher");
        _checkWard(c.gateway, c.messageProcessor, "gateway <- messageProcessor");
        _checkWard(c.gateway, c.spoke, "gateway <- spoke");

        _checkWard(c.messageProcessor, c.gateway, "messageProcessor <- gateway");
        _checkWard(c.multiAdapter, c.messageProcessor, "multiAdapter <- messageProcessor");
        _checkWard(c.multiAdapter, c.hub, "multiAdapter <- hub");

        _checkWard(c.spoke, c.messageDispatcher, "spoke <- messageDispatcher");
        _checkWard(c.balanceSheet, c.messageDispatcher, "balanceSheet <- messageDispatcher");
        _checkWard(c.contractUpdater, c.messageDispatcher, "contractUpdater <- messageDispatcher");
        if (c.vaultRegistry != address(0)) {
            _checkWard(c.vaultRegistry, c.messageDispatcher, "vaultRegistry <- messageDispatcher");
        }
        if (c.hubHandler != address(0)) {
            _checkWard(c.hubHandler, c.messageDispatcher, "hubHandler <- messageDispatcher");
        }

        _checkWard(c.messageDispatcher, c.spoke, "messageDispatcher <- spoke");
        _checkWard(c.messageDispatcher, c.balanceSheet, "messageDispatcher <- balanceSheet");
        _checkWard(c.messageDispatcher, c.hub, "messageDispatcher <- hub");
        if (c.hubHandler != address(0)) {
            _checkWard(c.messageDispatcher, c.hubHandler, "messageDispatcher <- hubHandler");
        }

        _checkWard(c.spoke, c.messageProcessor, "spoke <- messageProcessor");
        _checkWard(c.balanceSheet, c.messageProcessor, "balanceSheet <- messageProcessor");
        _checkWard(c.contractUpdater, c.messageProcessor, "contractUpdater <- messageProcessor");
        if (c.vaultRegistry != address(0)) {
            _checkWard(c.vaultRegistry, c.messageProcessor, "vaultRegistry <- messageProcessor");
        }
        if (c.hubHandler != address(0)) {
            _checkWard(c.hubHandler, c.messageProcessor, "hubHandler <- messageProcessor");
        }

        // ==================== SPOKE SIDE ====================

        _checkWard(c.tokenFactory, c.spoke, "tokenFactory <- spoke");
        _checkWard(c.poolEscrowFactory, c.spoke, "poolEscrowFactory <- spoke");
        if (c.vaultRegistry != address(0)) {
            _checkWard(c.spoke, c.vaultRegistry, "spoke <- vaultRegistry");
        }

        // ==================== HUB SIDE ====================

        _checkWard(c.accounting, c.hub, "accounting <- hub");
        _checkWard(c.holdings, c.hub, "holdings <- hub");
        _checkWard(c.hubRegistry, c.hub, "hubRegistry <- hub");
        _checkWard(c.shareClassManager, c.hub, "shareClassManager <- hub");

        if (c.hubHandler != address(0)) {
            _checkWard(c.hub, c.hubHandler, "hub <- hubHandler");
            _checkWard(c.hubRegistry, c.hubHandler, "hubRegistry <- hubHandler");
            _checkWard(c.holdings, c.hubHandler, "holdings <- hubHandler");
            _checkWard(c.shareClassManager, c.hubHandler, "shareClassManager <- hubHandler");
        }

        // ==================== VAULT SIDE ====================

        _checkWard(c.asyncRequestManager, c.spoke, "asyncRequestManager <- spoke");
        _checkWard(c.asyncRequestManager, c.contractUpdater, "asyncRequestManager <- contractUpdater");
        _checkWard(c.asyncRequestManager, c.asyncVaultFactory, "asyncRequestManager <- asyncVaultFactory");
        _checkWard(c.asyncRequestManager, c.syncDepositVaultFactory, "asyncRequestManager <- syncDepositVaultFactory");

        _checkWard(c.syncManager, c.contractUpdater, "syncManager <- contractUpdater");
        _checkWard(c.syncManager, c.syncDepositVaultFactory, "syncManager <- syncDepositVaultFactory");

        if (c.vaultRegistry != address(0)) {
            _checkWard(c.asyncVaultFactory, c.vaultRegistry, "asyncVaultFactory <- vaultRegistry");
            _checkWard(c.syncDepositVaultFactory, c.vaultRegistry, "syncDepositVaultFactory <- vaultRegistry");
        }

        // ==================== HOOKS ====================

        _checkWard(c.freezeOnlyHook, c.spoke, "freezeOnlyHook <- spoke");
        _checkWard(c.fullRestrictionsHook, c.spoke, "fullRestrictionsHook <- spoke");
        _checkWard(c.freelyTransferableHook, c.spoke, "freelyTransferableHook <- spoke");
        _checkWard(c.redemptionRestrictionsHook, c.spoke, "redemptionRestrictionsHook <- spoke");

        // ==================== BATCH REQUEST MANAGER ====================

        if (c.batchRequestManager != address(0)) {
            _checkWard(c.batchRequestManager, c.hub, "batchRequestManager <- hub");
            if (c.hubHandler != address(0)) {
                _checkWard(c.batchRequestManager, c.hubHandler, "batchRequestManager <- hubHandler");
            }
        }

        // ==================== GUARDIANS ====================

        if (c.protocolGuardian != address(0)) {
            _checkWard(c.gateway, c.protocolGuardian, "gateway <- protocolGuardian");
            _checkWard(c.multiAdapter, c.protocolGuardian, "multiAdapter <- protocolGuardian");
            _checkWard(c.messageDispatcher, c.protocolGuardian, "messageDispatcher <- protocolGuardian");
            _checkWard(c.root, c.protocolGuardian, "root <- protocolGuardian");
            _checkWard(c.tokenRecoverer, c.protocolGuardian, "tokenRecoverer <- protocolGuardian");
            if (c.wormholeAdapter != address(0)) {
                _checkWard(c.wormholeAdapter, c.protocolGuardian, "wormholeAdapter <- protocolGuardian");
            }
            if (c.axelarAdapter != address(0)) {
                _checkWard(c.axelarAdapter, c.protocolGuardian, "axelarAdapter <- protocolGuardian");
            }
            if (c.layerZeroAdapter != address(0)) {
                _checkWard(c.layerZeroAdapter, c.protocolGuardian, "layerZeroAdapter <- protocolGuardian");
            }
            if (c.chainlinkAdapter != address(0)) {
                _checkWard(c.chainlinkAdapter, c.protocolGuardian, "chainlinkAdapter <- protocolGuardian");
            }
        }

        if (c.opsGuardian != address(0)) {
            _checkWard(c.multiAdapter, c.opsGuardian, "multiAdapter <- opsGuardian");
            _checkWard(c.hub, c.opsGuardian, "hub <- opsGuardian");
            if (c.wormholeAdapter != address(0)) {
                _checkWard(c.wormholeAdapter, c.opsGuardian, "wormholeAdapter <- opsGuardian");
            }
            if (c.axelarAdapter != address(0)) {
                _checkWard(c.axelarAdapter, c.opsGuardian, "axelarAdapter <- opsGuardian");
            }
            if (c.layerZeroAdapter != address(0)) {
                _checkWard(c.layerZeroAdapter, c.opsGuardian, "layerZeroAdapter <- opsGuardian");
            }
            if (c.chainlinkAdapter != address(0)) {
                _checkWard(c.chainlinkAdapter, c.opsGuardian, "chainlinkAdapter <- opsGuardian");
            }
        }

        if (c.layerZeroAdapter != address(0) && protocolSafe != address(0)) {
            _checkWard(c.layerZeroAdapter, protocolSafe, "layerZeroAdapter <- protocolSafe");
        }

        // ==================== TOKEN RECOVERER ====================

        _checkWard(c.root, c.tokenRecoverer, "root <- tokenRecoverer");
        _checkWard(c.tokenRecoverer, c.messageDispatcher, "tokenRecoverer <- messageDispatcher");
        _checkWard(c.tokenRecoverer, c.messageProcessor, "tokenRecoverer <- messageProcessor");
    }

    function _checkWard(address wardedContract, address wardHolder, string memory label) internal {
        if (wardedContract == address(0) || wardHolder == address(0)) return;
        if (wardedContract.code.length == 0) return;

        try IAuth(wardedContract).wards(wardHolder) returns (uint256 val) {
            if (val != 1) {
                _errors.push(_buildError("ward", label, "1", vm.toString(val), string.concat("Ward missing: ", label)));
            }
        } catch {
            _errors.push(_buildError("ward", label, "callable", "reverted", string.concat("wards() reverted: ", label)));
        }
    }
}
