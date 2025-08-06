// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {D18, d18} from "../../../src/misc/types/D18.sol";

import {AccountId} from "../../../src/common/types/AccountId.sol";
import {MAX_MESSAGE_COST} from "../../../src/common/interfaces/IGasService.sol";

/// @title IntegrationConstants
/// @notice Centralized constants for integration tests
library IntegrationConstants {
    // ======== Network IDs ========
    uint16 constant CENTRIFUGE_ID_A = 5;
    uint16 constant CENTRIFUGE_ID_B = 6;
    uint16 constant CENTRIFUGE_ID_C = 7;
    uint16 constant LOCAL_CENTRIFUGE_ID = 1;

    // ======== Amounts ========
    uint128 constant DEFAULT_USDC_AMOUNT = 1e12; // 1M USDC

    // ======== Account IDs ========
    AccountId constant ASSET_ACCOUNT = AccountId.wrap(0x01);
    AccountId constant EQUITY_ACCOUNT = AccountId.wrap(0x02);
    AccountId constant LOSS_ACCOUNT = AccountId.wrap(0x03);
    AccountId constant GAIN_ACCOUNT = AccountId.wrap(0x04);

    // ======== Decimals ========
    uint8 constant USDC_DECIMALS = 6;
    uint8 constant POOL_DECIMALS = 18;

    // ======== Gas Values ========
    uint128 constant GAS = MAX_MESSAGE_COST;
    uint256 constant DEFAULT_SUBSIDY = 0.1 ether;
    uint256 constant INTEGRATION_DEFAULT_SUBSIDY = 1 ether;
    uint128 constant SHARE_HOOK_GAS = 0 ether;
    uint128 constant EXTRA_GAS = 0;

    // ======== Protocol Addresses ========
    // Core system contracts
    address constant ROOT = 0x7Ed48C31f2fdC40d37407cBaBf0870B2b688368f;
    address constant GUARDIAN = 0xFEE13c017693a4706391D516ACAbF6789D5c3157;
    address constant GATEWAY = 0x51eA340B3fe9059B48f935D5A80e127d587B6f89;
    address constant GAS_SERVICE = 0x295262f96186505Ce67c67B9d29e36ad1f9EAe88;
    address constant TOKEN_RECOVERER = 0x94269dBaBA605b63321221679df1356be0c00E63;
    address constant HUB_REGISTRY = 0x12044ef361Cc3446Cb7d36541C8411EE4e6f52cb;
    address constant ACCOUNTING = 0xE999a426D92c30fEE4f074B3a53071A6e935419F;
    address constant HOLDINGS = 0x0261FA29b3F2784AF17874428b58d971b6652C47;
    address constant SHARE_CLASS_MANAGER = 0xe88e712d60bfd23048Dbc677FEb44E2145F2cDf4;
    address constant HUB = 0x9c8454A506263549f07c80698E276e3622077098;
    address constant HUB_HELPERS = 0xA30D9E76a80675A719d835a74d09683AD2CB71EE;
    address constant IDENTITY_VALUATION = 0x3b8FaE903a6511f9707A2f45747a0de3B747711f;
    address constant TOKEN_FACTORY = 0xC8eDca090b772C48BcE5Ae14Eb7dd517cd70A32C;
    address constant BALANCE_SHEET = 0xBcC8D02d409e439D98453C0b1ffa398dFFb31fda;
    address constant SPOKE = 0xd30Da1d7F964E5f6C2D9fE2AAA97517F6B23FA2B;
    address constant CONTRACT_UPDATER = 0x8dD5a3d4e9ec54388dAd23B8a1f3B2159B2f2D85;
    address constant ROUTER = 0xdbCcee499563D4AC2D3788DeD3acb14FB92B175D;
    address constant ROUTER_ESCROW = 0xB86B6AE94E6d05AAc086665534A73fee557EE9F6;
    address constant GLOBAL_ESCROW = 0x43d51be0B6dE2199A2396bA604114d24383F91E9;
    address constant ASYNC_VAULT_FACTORY = 0xed9D489BB79c7CB58c522f36Fc6944eAA95Ce385;
    address constant SYNC_DEPOSIT_VAULT_FACTORY = 0x21BF2544b5A0B03c8566a16592ba1b3B192B50Bc;
    address constant ASYNC_REQUEST_MANAGER = 0xf06f89A1b6C601235729A689595571B7455Dd433;
    address constant SYNC_MANAGER = 0x0D82d9fa76CFCd6F4cc59F053b2458665C6CE773;
    address constant FREEZE_ONLY_HOOK = 0xBb7ABFB0E62dfb36e02CeeCDA59ADFD71f50c88e;
    address constant FULL_RESTRICTIONS_HOOK = 0xa2C98F0F76Da0C97039688CA6280d082942d0b48;
    address constant FREELY_TRANSFERABLE_HOOK = 0xbce8C1f411484C28a64f7A6e3fA63C56b6f3dDDE;
    address constant REDEMPTION_RESTRICTIONS_HOOK = 0xf0C36EFD5F6465D18B9679ee1407a3FC9A2955dD;
    address constant WORMHOLE_ADAPTER = 0x6b98679eEC5b5DE3A803Dc801B2f12aDdDCD39Ec;
    address constant AXELAR_ADAPTER = 0x52271c9A29D0f97c350BBE32b3377CdD26026d0a;
    address constant MESSAGE_PROCESSOR = 0xE994149c6D00Fe8708f843dc73973D1E7205530d;
    address constant MESSAGE_DISPATCHER = 0x21AF0C29611CFAaFf9271C8a3F84F2bC31d59132;
    address constant MULTI_ADAPTER = 0x457C91384C984b1659157160e8543adb12BC5317;
    address constant POOL_ESCROW_FACTORY = 0xD166B3210edBeEdEa73c7b2e8aB64BDd30c980E9;
    address constant ETH_ADMIN_SAFE = 0xD9D30ab47c0f096b0AA67e9B8B1624504a63e7FD;
    address constant AVAX_ADMIN_SAFE = 0xb6642fEd2221e177dD29581BB6d1959Bd1c54185;

    // Token addresses
    address constant ETH_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant AVA_USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address constant PLUME_PUSD = 0xdddD73F5Df1F0DC31373357beAC77545dC5A6f3F;

    // Pool admins
    address constant ETH_DEFAULT_POOL_ADMIN = 0x742d100011fFbC6e509E39DbcB0334159e86be1e;
    address constant PLUME_POOL_ADMIN = 0xB3B442BFee81F9c2bE2c146A823cB54a2625DF98;

    // Pool Escrows
    address constant JTRSY_POOL_ESCROW = 0xB19Cdd566E5ee580E068ED099136d52906e2ca09;
    address constant JAAA_POOL_ESCROW = 0xcf5C83A12E0bd55a8c02fc7802203BC23e3efB30;

    // Vault addresses
    address constant ETH_JAAA_VAULT = 0x4880799eE5200fC58DA299e965df644fBf46780B;
    address constant ETH_JTRSY_VAULT = 0xFE6920eB6C421f1179cA8c8d4170530CDBdfd77A;
    address constant ETH_DEJAA_USDC_VAULT = 0x1121F4e21eD8B9BC1BB9A2952cDD8639aC897784;
    address constant ETH_DEJAA_JAAA_VAULT = 0x2D38c58Cc7d4DdD6B4DaF7b3539902a7667F4519;
    address constant ETH_DEJTRSY_USDC_VAULT = 0xCF4C60066aAB54b3f750F94c2a06046d5466Ccf9;
    address constant ETH_DEJTRSY_JTRSY_VAULT = 0x04157759a9fe406d82a16BdEB20F9BeB9bBEb958;
    address constant PLUME_SYNC_DEPOSIT_VAULT = 0x374Bc3D556fBc9feC0b9537c259DCB7935f7E5bf;
    address constant AVAX_JAAA_USDC_VAULT = 0x1121F4e21eD8B9BC1BB9A2952cDD8639aC897784;

    // Share token addresses
    address constant ETH_JAAA_SHARE_TOKEN = 0x5a0F93D040De44e78F251b03c43be9CF317Dcf64;
    address constant ETH_JTRSY_SHARE_TOKEN = 0x8c213ee79581Ff4984583C6a801e5263418C4b86;
    address constant ETH_DEJTRSY_SHARE_TOKEN = 0xA6233014B9b7aaa74f38fa1977ffC7A89642dC72;
    address constant ETH_DEJAAA_SHARE_TOKEN = 0xAAA0008C8CF3A7Dca931adaF04336A5D808C82Cc;
    address constant AVAX_JTRSY_SHARE_TOKEN = 0xa5d465251fBCc907f5Dd6bB2145488DFC6a2627b;
    address constant AVAX_JAAA_SHARE_TOKEN = 0x58F93d6b1EF2F44eC379Cb975657C132CBeD3B6b;

    // ======== V2 Constants (Legacy) ========
    address constant V2_ROOT = 0x0C1fDfd6a1331a875EA013F3897fc8a76ada5DfC;
    address constant V2_GUARDIAN = 0x09ab10a9c3E6Eac1d18270a2322B6113F4C7f5E8;
    address constant V2_INVESTOR = 0x491EDFB0B8b608044e227225C715981a30F3A44E;
    address constant V2_INVESTMENT_MANAGER = 0x427A1ce127b1775e4Cbd4F58ad468B9F832eA7e9;
    address constant V2_RESTRICTION_MANAGER = 0x4737C3f62Cc265e786b280153fC666cEA2fBc0c0;
    address constant V2_JTRSY_VAULT = 0x36036fFd9B1C6966ab23209E073c68Eb9A992f50;
    address constant V2_JAAA_VAULT = 0xE9d1f733F406D4bbbDFac6D4CfCD2e13A6ee1d01;
    uint256 constant V2_REQUEST_ID = 0;
    uint128 constant V2_USDC_ASSET_ID = 242333941209166991950178742833476896417;

    // ======== Cross-Chain Adapter IDs ========

    // Centrifuge Chain IDs
    uint16 constant ETH_CENTRIFUGE_ID = 1;
    uint16 constant BASE_CENTRIFUGE_ID = 2;
    uint16 constant ARBITRUM_CENTRIFUGE_ID = 3;
    uint16 constant PLUME_CENTRIFUGE_ID = 4;
    uint16 constant AVAX_CENTRIFUGE_ID = 5;
    uint16 constant BNB_CENTRIFUGE_ID = 6;

    // Wormhole Chain IDs
    uint16 constant ETH_WORMHOLE_ID = 2;
    uint16 constant BASE_WORMHOLE_ID = 30;
    uint16 constant ARBITRUM_WORMHOLE_ID = 23;
    uint16 constant PLUME_WORMHOLE_ID = 55;
    uint16 constant AVAX_WORMHOLE_ID = 6;
    uint16 constant BNB_WORMHOLE_ID = 4;

    // Axelar Chain IDs (strings)
    string constant ETH_AXELAR_ID = "Ethereum";
    string constant BASE_AXELAR_ID = "base";
    string constant ARBITRUM_AXELAR_ID = "arbitrum";
    string constant AVAX_AXELAR_ID = "Avalanche";
    string constant BNB_AXELAR_ID = "binance";

    // ======== RPC Endpoints ========
    string constant RPC_ETHEREUM = "https://ethereum-rpc.publicnode.com";
    string constant RPC_AVALANCHE = "https://avalanche-c-chain-rpc.publicnode.com";
    string constant RPC_PLUME = "https://rpc.plume.org";

    // ======== Misc Constants ========
    uint256 constant PLACEHOLDER_REQUEST_ID = 0;

    // ======== Price Retrieval Functions ========
    function zeroPrice() internal pure returns (D18) {
        return d18(0);
    }

    function identityPrice() internal pure returns (D18) {
        return d18(1, 1);
    }

    function assetPrice() internal pure returns (D18) {
        return d18(1, 2);
    }

    function sharePrice() internal pure returns (D18) {
        return d18(4, 1);
    }
}
