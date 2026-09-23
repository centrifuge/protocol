// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AssetId} from "../core/types/AssetId.sol";

/// @dev The precision every ISO 4217 currency is registered at, which is the pool denomination the hub
///      accounts in rather than the currency's own minor unit
uint8 constant ISO4217_DECIMALS = 18;

/// @dev `AssetId.wrap` rather than `newAssetId`, a free function being no constant expression

// Majors and the rest of the G10
AssetId constant USD_ID = AssetId.wrap(840);
AssetId constant EUR_ID = AssetId.wrap(978);
AssetId constant GBP_ID = AssetId.wrap(826);
AssetId constant JPY_ID = AssetId.wrap(392);
AssetId constant CHF_ID = AssetId.wrap(756);
AssetId constant CAD_ID = AssetId.wrap(124);
AssetId constant AUD_ID = AssetId.wrap(36);
AssetId constant NZD_ID = AssetId.wrap(554);
AssetId constant SEK_ID = AssetId.wrap(752);
AssetId constant NOK_ID = AssetId.wrap(578);

// Non-euro Europe
AssetId constant DKK_ID = AssetId.wrap(208);
AssetId constant PLN_ID = AssetId.wrap(985);
AssetId constant CZK_ID = AssetId.wrap(203);
AssetId constant HUF_ID = AssetId.wrap(348);
AssetId constant RON_ID = AssetId.wrap(946);
AssetId constant ISK_ID = AssetId.wrap(352);

// Asia-Pacific
AssetId constant CNY_ID = AssetId.wrap(156);
AssetId constant HKD_ID = AssetId.wrap(344);
AssetId constant SGD_ID = AssetId.wrap(702);
AssetId constant KRW_ID = AssetId.wrap(410);
AssetId constant INR_ID = AssetId.wrap(356);
AssetId constant TWD_ID = AssetId.wrap(901);
AssetId constant THB_ID = AssetId.wrap(764);
AssetId constant MYR_ID = AssetId.wrap(458);
AssetId constant IDR_ID = AssetId.wrap(360);
AssetId constant PHP_ID = AssetId.wrap(608);
AssetId constant VND_ID = AssetId.wrap(704);

// Middle East and Africa
AssetId constant AED_ID = AssetId.wrap(784);
AssetId constant SAR_ID = AssetId.wrap(682);
AssetId constant QAR_ID = AssetId.wrap(634);
AssetId constant KWD_ID = AssetId.wrap(414);
AssetId constant BHD_ID = AssetId.wrap(48);
AssetId constant OMR_ID = AssetId.wrap(512);
AssetId constant ILS_ID = AssetId.wrap(376);
AssetId constant TRY_ID = AssetId.wrap(949);
AssetId constant ZAR_ID = AssetId.wrap(710);
AssetId constant NGN_ID = AssetId.wrap(566);
AssetId constant KES_ID = AssetId.wrap(404);
AssetId constant EGP_ID = AssetId.wrap(818);
AssetId constant MAD_ID = AssetId.wrap(504);

// Latin America
AssetId constant BRL_ID = AssetId.wrap(986);
AssetId constant MXN_ID = AssetId.wrap(484);
AssetId constant ARS_ID = AssetId.wrap(32);
AssetId constant CLP_ID = AssetId.wrap(152);
AssetId constant COP_ID = AssetId.wrap(170);
AssetId constant PEN_ID = AssetId.wrap(604);

/// @notice The currencies a deployment registers, for pools to denominate themselves in.
/// @dev    Adding one afterwards costs a spell on every chain the protocol is live on, while an unused
///         registration costs a single deploy-time SSTORE, so the set is deliberately wide.
function iso4217Codes() pure returns (AssetId[] memory codes) {
    AssetId[46] memory list = [
        USD_ID,
        EUR_ID,
        GBP_ID,
        JPY_ID,
        CHF_ID,
        CAD_ID,
        AUD_ID,
        NZD_ID,
        SEK_ID,
        NOK_ID,
        DKK_ID,
        PLN_ID,
        CZK_ID,
        HUF_ID,
        RON_ID,
        ISK_ID,
        CNY_ID,
        HKD_ID,
        SGD_ID,
        KRW_ID,
        INR_ID,
        TWD_ID,
        THB_ID,
        MYR_ID,
        IDR_ID,
        PHP_ID,
        VND_ID,
        AED_ID,
        SAR_ID,
        QAR_ID,
        KWD_ID,
        BHD_ID,
        OMR_ID,
        ILS_ID,
        TRY_ID,
        ZAR_ID,
        NGN_ID,
        KES_ID,
        EGP_ID,
        MAD_ID,
        BRL_ID,
        MXN_ID,
        ARS_ID,
        CLP_ID,
        COP_ID,
        PEN_ID
    ];

    codes = new AssetId[](list.length);
    for (uint256 i; i < list.length; i++) {
        codes[i] = list[i];
    }
}
