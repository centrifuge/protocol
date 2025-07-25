// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";

import {RelinkV2Common} from "./RelinkV2Common.sol";

interface VaultLike {
    function poolId() external view returns (uint64);
    function trancheId() external view returns (bytes16);
}

interface InvestmentManagerLike {
    function fulfillDepositRequest(
        uint64 poolId,
        bytes16 trancheId,
        address user,
        uint128 assetId,
        uint128 assets,
        uint128 shares
    ) external;
    function mint(address vault, uint256 shares, address receiver, address controller)
        external
        returns (uint256 assets);
}

/// @notice Ethereum-specific spell that relinks V2 vaults to JTRSY and JAAA token
contract RelinkV2Eth is RelinkV2Common {
    IShareToken public constant JAAA_SHARE_TOKEN = IShareToken(0x5a0F93D040De44e78F251b03c43be9CF317Dcf64);

    address public constant USDC_TOKEN = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    uint128 public constant USDC_ASSET_ID = 242333941209166991950178742833476896417;

    address public constant JTRSY_VAULT_ADDRESS = address(0x1d01Ef1997d44206d839b78bA6813f60F1B3A970);
    address public constant JAAA_VAULT_ADDRESS = address(0xE9d1f733F406D4bbbDFac6D4CfCD2e13A6ee1d01);

    InvestmentManagerLike public constant V2_INVESTMENT_MANAGER =
        InvestmentManagerLike(0xE79f06573d6aF1B66166A926483ba00924285d20);

    function execute() internal override {
        // Relink JTRSY and JAAAA
        _relink(USDC_TOKEN, JTRSY_SHARE_TOKEN, JTRSY_VAULT_ADDRESS);
        _relink(USDC_TOKEN, JAAA_SHARE_TOKEN, JAAA_VAULT_ADDRESS);

        // Final cleanup - deny spell's root permissions
        _cleanupRootPermissions();
    }

    function _cleanupInvestment(InvestmentManagerLike manager, address vault, address user) internal {
        // Rely spell on investment manager
        V2_ROOT.relyContract(address(manager), address(this));

        // Cancel and then fulfill cancelation at price 0.0 the investment, since shares were already issued separately
        VaultLike vault_ = VaultLike(vault);
        manager.fulfillDepositRequest(vault_.poolId(), vault_.trancheId(), user, USDC_ASSET_ID, 50_000_000e6, 0);
        manager.mint(vault, 0, user, user);

        // Deny spell on share token
        V2_ROOT.denyContract(address(manager), address(this));
    }
}
