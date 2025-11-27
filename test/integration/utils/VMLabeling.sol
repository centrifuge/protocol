// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {IntegrationConstants} from "./IntegrationConstants.sol";

import "forge-std/Test.sol";

/// @title VMLabeling
/// @notice Abstract contract that provides VM labeling for all integration test contracts
abstract contract VMLabeling is Test {
    /// @notice Sets up VM labels for all contracts to enable automatic name resolution in test outputs
    function _setupVMLabels() internal virtual {
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
        vm.label(IntegrationConstants.LAYER_ZERO_ADAPTER, "LayerZeroAdapter");
        vm.label(IntegrationConstants.MESSAGE_PROCESSOR, "MessageProcessor");
        vm.label(IntegrationConstants.MESSAGE_DISPATCHER, "MessageDispatcher");
        vm.label(IntegrationConstants.MULTI_ADAPTER, "MultiAdapter");
        vm.label(IntegrationConstants.POOL_ESCROW_FACTORY, "PoolEscrowFactory");

        // V3.1 new contracts
        vm.label(IntegrationConstants.HUB_HANDLER, "HubHandler");
        vm.label(IntegrationConstants.VAULT_REGISTRY, "VaultRegistry");
        vm.label(IntegrationConstants.BATCH_REQUEST_MANAGER, "BatchRequestManager");
        vm.label(IntegrationConstants.REFUND_ESCROW_FACTORY, "RefundEscrowFactory");
        vm.label(IntegrationConstants.PROTOCOL_GUARDIAN, "ProtocolGuardian");
        vm.label(IntegrationConstants.OPS_GUARDIAN, "OpsGuardian");
        vm.label(IntegrationConstants.QUEUE_MANAGER, "QueueManager");
        vm.label(IntegrationConstants.ORACLE_VALUATION, "OracleValuation");
        vm.label(IntegrationConstants.NAV_MANAGER, "NAVManager");
        vm.label(IntegrationConstants.SIMPLE_PRICE_MANAGER, "SimplePriceManager");
        vm.label(IntegrationConstants.ETH_ADMIN_SAFE, "EthAdminSafe");
        vm.label(IntegrationConstants.BASE_ADMIN_SAFE, "BaseAdminSafe");
        vm.label(IntegrationConstants.ARBITRUM_ADMIN_SAFE, "ArbitrumAdminSafe");
        vm.label(IntegrationConstants.AVAX_ADMIN_SAFE, "AvaxAdminSafe");
        vm.label(IntegrationConstants.BNB_ADMIN_SAFE, "BnbAdminSafe");
        vm.label(IntegrationConstants.PLUME_ADMIN_SAFE, "PlumeAdminSafe");

        // Vault addresses
        // Ethereum
        vm.label(IntegrationConstants.ETH_JAAA_VAULT, "EthJAAAVault");
        vm.label(IntegrationConstants.ETH_JTRSY_VAULT, "EthJTRSYVault");
        vm.label(IntegrationConstants.ETH_DEJAA_USDC_VAULT, "EthDeJAAAUsdcVault");
        vm.label(IntegrationConstants.ETH_DEJTRSY_USDC_VAULT, "EthDeJTRSYUsdcVault");
        vm.label(IntegrationConstants.ETH_DEJTRSY_JTRSY_VAULT_A, "EthDeJTRSYJTRSYVaultA");
        vm.label(IntegrationConstants.ETH_DEJTRSY_VAULT, "EthDeJTRSYVault");
        vm.label(IntegrationConstants.ETH_DEJAA_JAAA_VAULT_A, "EthDeJAAAJAAAVaultA");
        vm.label(IntegrationConstants.ETH_DISTRICT_USDC_VAULT, "EthDistrictUsdcVault");

        // Base
        vm.label(IntegrationConstants.BASE_JAAA_USDC_VAULT, "BaseJAAAUsdcVault");
        vm.label(IntegrationConstants.BASE_DEJAAA_USDC_VAULT, "BaseDeJAAAUsdcVault");
        vm.label(IntegrationConstants.BASE_DEJAAA_JAAA_VAULT, "BaseDeJAAAJAAAVault");
        vm.label(IntegrationConstants.BASE_SPXA_USDC_VAULT, "BaseSpxaUsdcVault");

        // Arbitrum
        vm.label(IntegrationConstants.ARBITRUM_JTRSY_USDC_VAULT, "ArbitrumJtrsyUsdcVault");
        vm.label(IntegrationConstants.ARBITRUM_DEJAAA_USDC_VAULT, "ArbitrumDeJAAAUsdcVault");

        // Avalanche
        vm.label(IntegrationConstants.AVAX_JAAA_USDC_VAULT, "AvaxJAAAUsdcVault");
        vm.label(IntegrationConstants.AVAX_DEJTRSY_USDC_VAULT, "AvaxDeJTRSYUsdcVault");
        vm.label(IntegrationConstants.AVAX_DEJTRSY_JTRSY_VAULT, "AvaxDeJTRSYJTRSYVault");
        vm.label(IntegrationConstants.AVAX_JTRSY_USDC_VAULT, "AvaxJTRSYUsdcVault");
        vm.label(IntegrationConstants.AVAX_DEJAAA_USDC_VAULT, "AvaxDeJAAAUsdcVault");
        vm.label(IntegrationConstants.AVAX_DEJAAA_VAULT, "AvaxDeJAAAVault");

        // BNB
        vm.label(IntegrationConstants.BNB_JTRSY_USDC_VAULT, "BnbJtrsyUsdcVault");
        vm.label(IntegrationConstants.BNB_JAAA_USDC_VAULT, "BnbJaaaUsdcVault");

        // Plume
        vm.label(IntegrationConstants.PLUME_SYNC_DEPOSIT_VAULT, "PlumeSyncDepositVault");
        vm.label(IntegrationConstants.PLUME_ACRDX_USDC_VAULT, "PlumeAcrdxUsdcVault");
        vm.label(IntegrationConstants.PLUME_JTRSY_USDC_VAULT, "PlumeJtrsyUsdcVault");

        // Share token addresses
        // JAAA
        vm.label(IntegrationConstants.ETH_JAAA_SHARE_TOKEN, "EthJAAAShareToken");
        vm.label(IntegrationConstants.BASE_JAAA_SHARE_TOKEN, "BaseJAAAShareToken");
        vm.label(IntegrationConstants.AVAX_JAAA_SHARE_TOKEN, "AvaxJAAAShareToken");
        vm.label(IntegrationConstants.BNB_JAAA_SHARE_TOKEN, "BnbJAAAShareToken");

        // JTRSY
        vm.label(IntegrationConstants.ETH_JTRSY_SHARE_TOKEN, "EthJTRSYShareToken");
        vm.label(IntegrationConstants.BASE_JTRSY_SHARE_TOKEN, "BaseJTRSYShareToken");
        vm.label(IntegrationConstants.ARBITRUM_JTRSY_SHARE_TOKEN, "ArbitrumJTRSYShareToken");
        vm.label(IntegrationConstants.AVAX_JTRSY_SHARE_TOKEN, "AvaxJTRSYShareToken");
        vm.label(IntegrationConstants.BNB_JTRSY_SHARE_TOKEN, "BnbJTRSYShareToken");
        vm.label(IntegrationConstants.PLUME_JTRSY_SHARE_TOKEN, "PlumeJTRSYShareToken");

        // deJAAA
        vm.label(IntegrationConstants.ETH_DEJAAA_SHARE_TOKEN, "EthDeJAAAShareToken");
        vm.label(IntegrationConstants.BASE_DEJAAA_SHARE_TOKEN, "BaseDeJAAAShareToken");
        vm.label(IntegrationConstants.ARBITRUM_DEJAAA_SHARE_TOKEN, "ArbitrumDeJAAAShareToken");
        vm.label(IntegrationConstants.AVAX_DEJAAA_SHARE_TOKEN, "AvaxDeJAAAShareToken");

        // deJTRSY
        vm.label(IntegrationConstants.ETH_DEJTRSY_SHARE_TOKEN, "EthDeJTRSYShareToken");
        vm.label(IntegrationConstants.BASE_DEJTRSY_SHARE_TOKEN, "BaseDeJTRSYShareToken");
        vm.label(IntegrationConstants.ARBITRUM_DEJTRSY_SHARE_TOKEN, "ArbitrumDeJTRSYShareToken");
        vm.label(IntegrationConstants.AVAX_DEJTRSY_SHARE_TOKEN, "AvaxDeJTRSYShareToken");

        // DISTRICT
        vm.label(IntegrationConstants.ETH_DISTRICT_SHARE_TOKEN, "EthDistrictShareToken");

        // ACRDX
        vm.label(IntegrationConstants.PLUME_ACRDX_SHARE_TOKEN, "PlumeAcrdxShareToken");

        // TEST (Plume)
        vm.label(IntegrationConstants.PLUME_TEST_SHARE_TOKEN, "PlumeTestShareToken");

        // SPXA
        vm.label(IntegrationConstants.BASE_SPXA_SHARE_TOKEN, "BaseSpxaShareToken");

        // Token addresses
        vm.label(IntegrationConstants.ETH_USDC, "EthUSDC");
        vm.label(IntegrationConstants.BASE_USDC, "BaseUSDC");
        vm.label(IntegrationConstants.ARBITRUM_USDC, "ArbitrumUSDC");
        vm.label(IntegrationConstants.AVAX_USDC, "AvaxUSDC");
        vm.label(IntegrationConstants.BNB_USDC, "BnbUSDC");
        vm.label(IntegrationConstants.PLUME_PUSD, "PlumePUSD");

        // Pool admin addresses
        vm.label(IntegrationConstants.ETH_DEFAULT_POOL_ADMIN, "EthDefaultPoolAdmin");
        vm.label(IntegrationConstants.PLUME_POOL_ADMIN, "PlumePoolAdmin");

        // Pool escrow addresses
        vm.label(IntegrationConstants.JTRSY_POOL_ESCROW, "JTRSYPoolEscrow");
        vm.label(IntegrationConstants.JAAA_POOL_ESCROW, "JAAAPoolEscrow");

        // CFG Governance contracts
        vm.label(IntegrationConstants.CFG, "CFG");
        vm.label(IntegrationConstants.WCFG, "WCFG");
        vm.label(IntegrationConstants.IOU_CFG, "IouCFG");
        vm.label(IntegrationConstants.WCFG_MULTISIG, "WCFGMultisig");
        vm.label(IntegrationConstants.CHAINBRIDGE_ERC20_HANDLER, "ChainbridgeERC20Handler");

        // V2 Legacy contracts
        vm.label(IntegrationConstants.V2_ROOT, "V2Root");
        vm.label(IntegrationConstants.V2_GUARDIAN, "V2Guardian");
        vm.label(IntegrationConstants.V2_INVESTOR, "V2Investor");
        vm.label(IntegrationConstants.V2_INVESTMENT_MANAGER, "V2InvestmentManager");
        vm.label(IntegrationConstants.V2_RESTRICTION_MANAGER, "V2RestrictionManager");
        vm.label(IntegrationConstants.V2_JTRSY_VAULT, "V2JTRSYVault");
        vm.label(IntegrationConstants.V2_JAAA_VAULT, "V2JAAAVault");
        vm.label(IntegrationConstants.ETH_V2_JTRSY_VAULT, "EthV2JTRSYVault");
        vm.label(IntegrationConstants.ETH_V2_JAAA_VAULT, "EthV2JAAAVault");
        vm.label(IntegrationConstants.ARB_V2_JTRSY_VAULT, "ArbV2JTRSYVault");
        vm.label(IntegrationConstants.BASE_V2_JTRSY_VAULT, "BaseV2JTRSYVault");
    }
}
