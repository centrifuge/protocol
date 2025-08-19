// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC7540Valuation} from "./interfaces/IERC7540Valuation.sol";

import {MathLib} from "../misc/libraries/MathLib.sol";

import {AssetId} from "../common/types/AssetId.sol";
import {PricingLib} from "../common/libraries/PricingLib.sol";
import {IValuation} from "../common/interfaces/IValuation.sol";

import {ISpoke} from "../spoke/interfaces/ISpoke.sol";

import {IAsyncVault} from "../vaults/interfaces/IAsyncVault.sol";

/// @notice Quotes the total value for an ERC7540 vault holdings by a specific controller
contract ERC7540Valuation is IERC7540Valuation {
    using MathLib for uint256;

    error InvalidBase();
    error InvalidQuote();

    uint256 internal constant REQUEST_ID = 0;

    AssetId public immutable shareId;
    AssetId public immutable assetId;
    IAsyncVault public immutable vault;
    address public immutable controller;

    constructor(address controller_, IAsyncVault vault_, ISpoke spoke) {
        vault = vault_;
        controller = controller_;
        shareId = spoke.assetToId(vault.share(), 0);
        assetId = spoke.assetToId(vault.asset(), 0);

        // TODO: check if ERC-7887
    }

    /// @inheritdoc IValuation
    function getQuote(uint128 baseAmount, AssetId base, AssetId quote) external view returns (uint128 quoteAmount) {
        require(base == shareId, InvalidBase());
        require(quote == assetId, InvalidQuote());

        uint256 assets = vault.pendingDepositRequest(REQUEST_ID, controller)
            + vault.claimableDepositRequest(REQUEST_ID, controller)
            + vault.claimableCancelDepositRequest(REQUEST_ID, controller);
        uint256 shares = vault.pendingRedeemRequest(REQUEST_ID, controller)
            + vault.claimableRedeemRequest(REQUEST_ID, controller)
            + vault.claimableCancelRedeemRequest(REQUEST_ID, controller);
        return (assets + vault.convertToAssets(shares)).toUint128();
    }
}

// TODO: add factory
