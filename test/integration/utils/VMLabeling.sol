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
        vm.label(IntegrationConstants.BASE_ADMIN_SAFE, "BaseAdminSafe");
        vm.label(IntegrationConstants.ARBITRUM_ADMIN_SAFE, "ArbitrumAdminSafe");
        vm.label(IntegrationConstants.AVAX_ADMIN_SAFE, "AvaxAdminSafe");
        vm.label(IntegrationConstants.BNB_ADMIN_SAFE, "BnbAdminSafe");
        vm.label(IntegrationConstants.PLUME_ADMIN_SAFE, "PlumeAdminSafe");

        // Vault addresses
        vm.label(IntegrationConstants.ETH_JAAA_VAULT, "EthJAAAVault");
        vm.label(IntegrationConstants.ETH_JTRSY_VAULT, "EthJTRSYVault");
        vm.label(IntegrationConstants.AVAX_JAAA_VAULT, "AvaxJAAAVault");
        vm.label(IntegrationConstants.ETH_DEJAA_USDC_VAULT, "EthDeJAAAUsdcVault");
        vm.label(IntegrationConstants.ETH_DEJAA_JAAA_VAULT, "EthDeJAAAJAAAVault");
        vm.label(IntegrationConstants.ETH_DEJTRSY_USDC_VAULT, "EthDeJTRSYUsdcVault");
        vm.label(IntegrationConstants.ETH_DEJTRSY_JTRSY_VAULT, "EthDeJTRSYJTRSYVault");
        vm.label(IntegrationConstants.AVAX_DEJTRSY_USDC_VAULT, "AvaxDeJTRSYUsdcVault");
        vm.label(IntegrationConstants.BASE_DEJAAA_USDC_VAULT, "BaseDeJAAAUsdcVault");
        vm.label(IntegrationConstants.AVAX_DEJAAA_USDC_VAULT, "AvaxDeJAAAUsdcVault");
        vm.label(IntegrationConstants.AVAX_JAAA_USDC_VAULT, "AvaxJAAAUsdcVault");
        vm.label(IntegrationConstants.PLUME_SYNC_DEPOSIT_VAULT, "PlumeSyncDepositVault");

        // Share token addresses
        vm.label(IntegrationConstants.ETH_JAAA_SHARE_TOKEN, "EthJAAAShareToken");
        vm.label(IntegrationConstants.ETH_JTRSY_SHARE_TOKEN, "EthJTRSYShareToken");
        vm.label(IntegrationConstants.ETH_DEJTRSY_SHARE_TOKEN, "EthDeJTRSYShareToken");
        vm.label(IntegrationConstants.ETH_DEJAAA_SHARE_TOKEN, "EthDeJAAAShareToken");
        vm.label(IntegrationConstants.AVAX_JAAA_SHARE_TOKEN, "AvaxJAAAShareToken");
        vm.label(IntegrationConstants.AVAX_JTRSY_SHARE_TOKEN, "AvaxJTRSYShareToken");

        // Token addresses
        vm.label(IntegrationConstants.ETH_USDC, "EthUSDC");
        vm.label(IntegrationConstants.AVA_USDC, "AvaUSDC");
        vm.label(IntegrationConstants.PLUME_PUSD, "PlumePUSD");

        // Pool admin addresses
        vm.label(IntegrationConstants.ETH_DEFAULT_POOL_ADMIN, "EthDefaultPoolAdmin");
        vm.label(IntegrationConstants.PLUME_POOL_ADMIN, "PlumePoolAdmin");

        // Pool escrow addresses
        vm.label(IntegrationConstants.JTRSY_POOL_ESCROW, "JTRSYPoolEscrow");
        vm.label(IntegrationConstants.JAAA_POOL_ESCROW, "JAAAPoolEscrow");

        // V2 Legacy contracts
        vm.label(IntegrationConstants.V2_ROOT, "V2Root");
        vm.label(IntegrationConstants.V2_GUARDIAN, "V2Guardian");
        vm.label(IntegrationConstants.V2_INVESTOR, "V2Investor");
        vm.label(IntegrationConstants.V2_INVESTMENT_MANAGER, "V2InvestmentManager");
        vm.label(IntegrationConstants.V2_RESTRICTION_MANAGER, "V2RestrictionManager");
        vm.label(IntegrationConstants.V2_JTRSY_VAULT, "V2JTRSYVault");
        vm.label(IntegrationConstants.V2_JAAA_VAULT, "V2JAAAVault");
    }
}
