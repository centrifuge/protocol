// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Hub} from "../../../../src/core/hub/Hub.sol";
import {Spoke} from "../../../../src/core/spoke/Spoke.sol";
import {Gateway} from "../../../../src/core/messaging/Gateway.sol";
import {HubHandler} from "../../../../src/core/hub/HubHandler.sol";
import {BalanceSheet} from "../../../../src/core/spoke/BalanceSheet.sol";
import {VaultRegistry} from "../../../../src/core/spoke/VaultRegistry.sol";
import {MultiAdapter} from "../../../../src/core/messaging/MultiAdapter.sol";
import {MessageProcessor} from "../../../../src/core/messaging/MessageProcessor.sol";
import {MessageDispatcher} from "../../../../src/core/messaging/MessageDispatcher.sol";

import {OpsGuardian} from "../../../../src/admin/OpsGuardian.sol";
import {ProtocolGuardian} from "../../../../src/admin/ProtocolGuardian.sol";

import {SyncManager} from "../../../../src/vaults/SyncManager.sol";
import {AsyncRequestManager} from "../../../../src/vaults/AsyncRequestManager.sol";
import {BatchRequestManager} from "../../../../src/vaults/BatchRequestManager.sol";

import {Env, EnvConfig, ContractsConfig as C} from "../../../../script/utils/EnvConfig.s.sol";

import {RefundEscrowFactory} from "../../../../src/utils/RefundEscrowFactory.sol";
import {BaseValidator, ValidationContext} from "../../spell/utils/validation/BaseValidator.sol";

/// @title Validate_FileConfigurations
/// @notice Validates all file() pointer configurations are correctly set.
contract Validate_FileConfigurations is BaseValidator("FileConfigurations") {
    function validate(ValidationContext memory ctx) public override {
        C memory c = ctx.contracts.live;

        EnvConfig memory config = Env.load(ctx.networkName);
        address protocolSafe = config.network.protocolAdmin;

        // Guard: core contracts must have code to avoid full revert on getter calls
        if (
            c.gateway.code.length == 0 || c.multiAdapter.code.length == 0 || c.messageDispatcher.code.length == 0
                || c.messageProcessor.code.length == 0 || c.spoke.code.length == 0 || c.balanceSheet.code.length == 0
                || c.hub.code.length == 0 || c.asyncRequestManager.code.length == 0 || c.syncManager.code.length == 0
        ) {
            _errors.push(
                _buildError("code", "core contracts", "> 0", "0", "One or more core contracts have no deployed code")
            );
            return;
        }

        // ==================== GATEWAY ====================

        _checkConfig(address(Gateway(payable(c.gateway)).adapter()), c.multiAdapter, "Gateway.adapter");
        _checkConfig(
            address(Gateway(payable(c.gateway)).messageProperties()), c.gasService, "Gateway.messageProperties"
        );
        _checkConfig(address(Gateway(payable(c.gateway)).processor()), c.messageProcessor, "Gateway.processor");

        // ==================== MULTI ADAPTER ====================

        _checkConfig(
            address(MultiAdapter(c.multiAdapter).messageProperties()), c.gasService, "MultiAdapter.messageProperties"
        );

        // ==================== MESSAGE DISPATCHER ====================

        _checkConfig(address(MessageDispatcher(c.messageDispatcher).spoke()), c.spoke, "MessageDispatcher.spoke");
        _checkConfig(
            address(MessageDispatcher(c.messageDispatcher).balanceSheet()),
            c.balanceSheet,
            "MessageDispatcher.balanceSheet"
        );
        _checkConfig(
            address(MessageDispatcher(c.messageDispatcher).contractUpdater()),
            c.contractUpdater,
            "MessageDispatcher.contractUpdater"
        );
        _checkConfig(
            address(MessageDispatcher(c.messageDispatcher).tokenRecoverer()),
            c.tokenRecoverer,
            "MessageDispatcher.tokenRecoverer"
        );
        if (c.vaultRegistry != address(0)) {
            _checkConfig(
                address(MessageDispatcher(c.messageDispatcher).vaultRegistry()),
                c.vaultRegistry,
                "MessageDispatcher.vaultRegistry"
            );
        }
        if (c.hubHandler != address(0)) {
            _checkConfig(
                address(MessageDispatcher(c.messageDispatcher).hubHandler()),
                c.hubHandler,
                "MessageDispatcher.hubHandler"
            );
        }

        // ==================== MESSAGE PROCESSOR ====================

        _checkConfig(
            address(MessageProcessor(c.messageProcessor).multiAdapter()),
            c.multiAdapter,
            "MessageProcessor.multiAdapter"
        );
        _checkConfig(address(MessageProcessor(c.messageProcessor).gateway()), c.gateway, "MessageProcessor.gateway");
        _checkConfig(address(MessageProcessor(c.messageProcessor).spoke()), c.spoke, "MessageProcessor.spoke");
        _checkConfig(
            address(MessageProcessor(c.messageProcessor).balanceSheet()),
            c.balanceSheet,
            "MessageProcessor.balanceSheet"
        );
        _checkConfig(
            address(MessageProcessor(c.messageProcessor).contractUpdater()),
            c.contractUpdater,
            "MessageProcessor.contractUpdater"
        );
        _checkConfig(
            address(MessageProcessor(c.messageProcessor).tokenRecoverer()),
            c.tokenRecoverer,
            "MessageProcessor.tokenRecoverer"
        );
        if (c.vaultRegistry != address(0)) {
            _checkConfig(
                address(MessageProcessor(c.messageProcessor).vaultRegistry()),
                c.vaultRegistry,
                "MessageProcessor.vaultRegistry"
            );
        }
        if (c.hubHandler != address(0)) {
            _checkConfig(
                address(MessageProcessor(c.messageProcessor).hubHandler()), c.hubHandler, "MessageProcessor.hubHandler"
            );
        }

        // ==================== SPOKE ====================

        _checkConfig(address(Spoke(c.spoke).gateway()), c.gateway, "Spoke.gateway");
        _checkConfig(address(Spoke(c.spoke).poolEscrowFactory()), c.poolEscrowFactory, "Spoke.poolEscrowFactory");
        _checkConfig(address(Spoke(c.spoke).sender()), c.messageDispatcher, "Spoke.sender");

        // ==================== BALANCE SHEET ====================

        _checkConfig(address(BalanceSheet(c.balanceSheet).spoke()), c.spoke, "BalanceSheet.spoke");
        _checkConfig(address(BalanceSheet(c.balanceSheet).gateway()), c.gateway, "BalanceSheet.gateway");
        _checkConfig(
            address(BalanceSheet(c.balanceSheet).poolEscrowProvider()),
            c.poolEscrowFactory,
            "BalanceSheet.poolEscrowProvider"
        );
        _checkConfig(address(BalanceSheet(c.balanceSheet).sender()), c.messageDispatcher, "BalanceSheet.sender");

        // ==================== VAULT REGISTRY ====================

        if (c.vaultRegistry != address(0)) {
            _checkConfig(address(VaultRegistry(c.vaultRegistry).spoke()), c.spoke, "VaultRegistry.spoke");
        }

        // ==================== HUB ====================

        _checkConfig(address(Hub(c.hub).sender()), c.messageDispatcher, "Hub.sender");

        if (c.hubHandler != address(0)) {
            _checkConfig(address(HubHandler(c.hubHandler).sender()), c.messageDispatcher, "HubHandler.sender");
        }

        // ==================== VAULT SIDE ====================

        if (c.refundEscrowFactory != address(0) && c.subsidyManager != address(0)) {
            _checkConfig(
                address(RefundEscrowFactory(c.refundEscrowFactory).controller()),
                c.subsidyManager,
                "RefundEscrowFactory.controller"
            );
        }

        _checkConfig(
            address(AsyncRequestManager(payable(c.asyncRequestManager)).spoke()), c.spoke, "AsyncRequestManager.spoke"
        );
        _checkConfig(
            address(AsyncRequestManager(payable(c.asyncRequestManager)).balanceSheet()),
            c.balanceSheet,
            "AsyncRequestManager.balanceSheet"
        );
        if (c.vaultRegistry != address(0)) {
            _checkConfig(
                address(AsyncRequestManager(payable(c.asyncRequestManager)).vaultRegistry()),
                c.vaultRegistry,
                "AsyncRequestManager.vaultRegistry"
            );
        }

        _checkConfig(address(SyncManager(c.syncManager).spoke()), c.spoke, "SyncManager.spoke");
        _checkConfig(address(SyncManager(c.syncManager).balanceSheet()), c.balanceSheet, "SyncManager.balanceSheet");
        if (c.vaultRegistry != address(0)) {
            _checkConfig(
                address(SyncManager(c.syncManager).vaultRegistry()), c.vaultRegistry, "SyncManager.vaultRegistry"
            );
        }

        if (c.batchRequestManager != address(0)) {
            _checkConfig(address(BatchRequestManager(c.batchRequestManager).hub()), c.hub, "BatchRequestManager.hub");
        }

        // ==================== GUARDIANS ====================

        if (c.opsGuardian != address(0)) {
            address opsSafe = address(OpsGuardian(c.opsGuardian).opsSafe());
            if (opsSafe == address(0)) {
                _errors.push(
                    _buildError("opsSafe", "OpsGuardian", "!= address(0)", "address(0)", "OpsGuardian opsSafe not set")
                );
            }
        }

        if (c.protocolGuardian != address(0) && protocolSafe != address(0)) {
            _checkConfig(address(ProtocolGuardian(c.protocolGuardian).safe()), protocolSafe, "ProtocolGuardian.safe");
        }
    }

    function _checkConfig(address actual, address expected, string memory label) internal {
        if (actual != expected) {
            _errors.push(
                _buildError(
                    "config", label, vm.toString(expected), vm.toString(actual), string.concat(label, " mismatch")
                )
            );
        }
    }
}
