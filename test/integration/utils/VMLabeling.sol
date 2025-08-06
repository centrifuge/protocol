// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IntegrationConstants} from "./IntegrationConstants.sol";

import "forge-std/Test.sol";

/// @title VMLabeling
/// @notice Abstract contract that provides VM labeling for all integration test contracts
abstract contract VMLabeling is Test {
    /// @notice Sets up VM labels for all contracts to enable automatic name resolution in test outputs
    function _setupVMLabels() internal {
        // Core system contracts
        vm.label(IntegrationConstants.ROOT, "Root");
        vm.label(IntegrationConstants.GUARDIAN, "Guardian");
        vm.label(IntegrationConstants.GATEWAY, "Gateway");
        vm.label(IntegrationConstants.GAS_SERVICE, "GasService");
        vm.label(IntegrationConstants.TOKEN_RECOVERER, "TokenRecoverer");
        vm.label(IntegrationConstants.HUB_REGISTRY, "HubRegistry");
        vm.label(IntegrationConstants.ACCOUNTING, "Accounting");
        vm.label(IntegrationConstants.HOLDINGS, "Holdings");
        vm.label(IntegrationConstants.SHARE_CLASS_MANAGER, "ShareClassManager");
        vm.label(IntegrationConstants.HUB, "Hub");
        vm.label(IntegrationConstants.HUB_HELPERS, "HubHelpers");
        vm.label(IntegrationConstants.IDENTITY_VALUATION, "IdentityValuation");
        vm.label(IntegrationConstants.TOKEN_FACTORY, "TokenFactory");
        vm.label(IntegrationConstants.BALANCE_SHEET, "BalanceSheet");
        vm.label(IntegrationConstants.SPOKE, "Spoke");
        vm.label(IntegrationConstants.CONTRACT_UPDATER, "ContractUpdater");
        vm.label(IntegrationConstants.ROUTER, "Router");
        vm.label(IntegrationConstants.ROUTER_ESCROW, "RouterEscrow");
        vm.label(IntegrationConstants.GLOBAL_ESCROW, "GlobalEscrow");
        vm.label(IntegrationConstants.ASYNC_VAULT_FACTORY, "AsyncVaultFactory");
        vm.label(IntegrationConstants.SYNC_DEPOSIT_VAULT_FACTORY, "SyncDepositVaultFactory");
        vm.label(IntegrationConstants.ASYNC_REQUEST_MANAGER, "AsyncRequestManager");
        vm.label(IntegrationConstants.SYNC_MANAGER, "SyncManager");
        vm.label(IntegrationConstants.FREEZE_ONLY_HOOK, "FreezeOnlyHook");
        vm.label(IntegrationConstants.FULL_RESTRICTIONS_HOOK, "FullRestrictionsHook");
        vm.label(IntegrationConstants.FREELY_TRANSFERABLE_HOOK, "FreelyTransferableHook");
        vm.label(IntegrationConstants.REDEMPTION_RESTRICTIONS_HOOK, "RedemptionRestrictionsHook");
        vm.label(IntegrationConstants.WORMHOLE_ADAPTER, "WormholeAdapter");
        vm.label(IntegrationConstants.AXELAR_ADAPTER, "AxelarAdapter");
        vm.label(IntegrationConstants.MESSAGE_PROCESSOR, "MessageProcessor");
        vm.label(IntegrationConstants.MESSAGE_DISPATCHER, "MessageDispatcher");
        vm.label(IntegrationConstants.MULTI_ADAPTER, "MultiAdapter");
        vm.label(IntegrationConstants.POOL_ESCROW_FACTORY, "PoolEscrowFactory");
        vm.label(IntegrationConstants.ETH_ADMIN_SAFE, "EthAdminSafe");
        vm.label(IntegrationConstants.AVAX_ADMIN_SAFE, "AvaxAdminSafe");

        // Vault and share token addresses
        vm.label(IntegrationConstants.ETH_JAAA_VAULT, "EthJAAAVault");
        vm.label(IntegrationConstants.ETH_JTRSY_VAULT, "EthJTRSYVault");
        vm.label(IntegrationConstants.ETH_DEJAA_USDC_VAULT, "EthDeJAAAVault");
        vm.label(IntegrationConstants.ETH_DEJTRSY_USDC_VAULT, "EthDeJTRSYVault");

        vm.label(IntegrationConstants.AVAX_JAAA_USDC_VAULT, "AvaxJAAAVault");
        vm.label(IntegrationConstants.ETH_JTRSY_VAULT, "AvaxJTRSYVault");

        vm.label(IntegrationConstants.ETH_JAAA_SHARE_TOKEN, "EthJAAAShareToken");
        vm.label(IntegrationConstants.ETH_JTRSY_SHARE_TOKEN, "EthJTRSYShareToken");
        vm.label(IntegrationConstants.ETH_DEJTRSY_SHARE_TOKEN, "EthDeJTRSYShareToken");
        vm.label(IntegrationConstants.ETH_DEJAAA_SHARE_TOKEN, "EthDeJAAAShareToken");

        vm.label(IntegrationConstants.AVAX_JAAA_SHARE_TOKEN, "AvaxJAAAShareToken");
        vm.label(IntegrationConstants.AVAX_JTRSY_SHARE_TOKEN, "AvaxJTRSYShareToken");

        // Additional important addresses
        vm.label(IntegrationConstants.ETH_DEFAULT_POOL_ADMIN, "EthDefaultPoolAdmin");
        vm.label(IntegrationConstants.ETH_USDC, "EthUSDC");
        vm.label(IntegrationConstants.JTRSY_POOL_ESCROW, "PoolEscrow_JTRSY");

        // Old vault addresses (pre-migration)
        vm.label(IntegrationConstants.ETH_DEJAA_USDC_VAULT, "OldEthDeJAAAVault_USDC");
        vm.label(IntegrationConstants.ETH_DEJTRSY_USDC_VAULT, "OldEthDeJTRSYVault_USDC");
        vm.label(IntegrationConstants.ETH_DEJTRSY_JTRSY_VAULT, "OldEthDeJTRSYVault_JTRSY");
        vm.label(IntegrationConstants.ETH_DEJAA_JAAA_VAULT, "OldEthDeJAA_JAA");
    }
}
