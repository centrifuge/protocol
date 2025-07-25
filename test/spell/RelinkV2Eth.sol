// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {RelinkV2Common} from "./RelinkV2Common.sol";

import {IShareToken} from "../../src/spoke/interfaces/IShareToken.sol";

interface VaultLike {
    function poolId() external view returns (uint64);
    function trancheId() external view returns (bytes16);
    function pendingDepositRequest(uint256, address controller) external view returns (uint256 pendingAssets);
    function claimableDepositRequest(uint256, address controller) external view returns (uint256 claimableAssets);
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

interface RestrictionManagerLike {
    function updateMember(address token, address user, uint64 validUntil) external;
}

interface AxelarAdapterLike {
    function execute(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) external;
}

/// @notice Ethereum-specific spell that relinks V2 vaults to JTRSY and JAAA token
contract RelinkV2Eth is RelinkV2Common {
    IShareToken public constant JAAA_SHARE_TOKEN = IShareToken(0x5a0F93D040De44e78F251b03c43be9CF317Dcf64);

    address public constant USDC_TOKEN = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    uint128 public constant USDC_ASSET_ID = 242333941209166991950178742833476896417;

    address public constant JTRSY_VAULT_ADDRESS = address(0x1d01Ef1997d44206d839b78bA6813f60F1B3A970);
    address public constant JAAA_VAULT_ADDRESS = address(0xE9d1f733F406D4bbbDFac6D4CfCD2e13A6ee1d01);

    address public constant JAAA_INVESTOR = address(0x491EDFB0B8b608044e227225C715981a30F3A44E);

    InvestmentManagerLike public constant V2_INVESTMENT_MANAGER =
        InvestmentManagerLike(0x427A1ce127b1775e4Cbd4F58ad468B9F832eA7e9);
    RestrictionManagerLike public constant V2_RESTRICTION_MANAGER =
        RestrictionManagerLike(0x4737C3f62Cc265e786b280153fC666cEA2fBc0c0);
    AxelarAdapterLike public constant V2_AXELAR_ADAPTER = AxelarAdapterLike(0x85bAFcAdeA202258e3512FFBC3E2c9eE6Ad56365);

    bytes32 public constant COMMAND_ID = 0x373a36b10c3b4c2b0e6c1f7efe871cef762e96a72c68249094b05238b7a5efe0;
    string public constant SOURCE_CHAIN = "centrifuge";
    string public constant SOURCE_ADDR = "0x7369626CEF070000000000000000000000000000";
    bytes public constant PAYLOAD =
        hex"1600000000097583fd57e1b211a9ce6306b69a414f274f9998491edfb0b8b608044e227225c715981a30f3a44e000000000000000145564d00b64fd1c3a60c260188389850000186a1000000000000000000002d79883d2000000000000000000000002d79883d2000";

    function execute() internal override {
        // Relink JTRSY and JAAAA
        _relink(USDC_TOKEN, JTRSY_SHARE_TOKEN, JTRSY_VAULT_ADDRESS);
        _relink(USDC_TOKEN, JAAA_SHARE_TOKEN, JAAA_VAULT_ADDRESS);

        // Clean up already executed investment state
        _cleanupInvestment();

        // Final cleanup - deny spell's root permissions
        _cleanupRootPermissions();
    }

    function _cleanupInvestment() internal {
        // Rely spell on investment manager + restriction manager + JAAA token
        V2_ROOT.relyContract(address(V2_INVESTMENT_MANAGER), address(this));
        V2_ROOT.relyContract(address(V2_RESTRICTION_MANAGER), address(this));
        V2_ROOT.relyContract(address(JAAA_SHARE_TOKEN), address(this));

        // Give permissions on restriction manager to the spell
        V2_RESTRICTION_MANAGER.updateMember(address(JAAA_SHARE_TOKEN), address(this), type(uint64).max);

        // Fulfill and burn shares
        V2_AXELAR_ADAPTER.execute(COMMAND_ID, SOURCE_CHAIN, SOURCE_ADDR, PAYLOAD);
        V2_INVESTMENT_MANAGER.mint(JAAA_VAULT_ADDRESS, 50000000000000, address(this), JAAA_INVESTOR);
        JAAA_SHARE_TOKEN.burn(address(this), 50000000000000);

        // Remove permissions on restriction manager from the spell
        V2_RESTRICTION_MANAGER.updateMember(address(JAAA_SHARE_TOKEN), address(this), uint64(block.timestamp));

        // Deny spell on investment manager + restriction manager + JAAA token
        V2_ROOT.denyContract(address(V2_INVESTMENT_MANAGER), address(this));
        V2_ROOT.denyContract(address(V2_RESTRICTION_MANAGER), address(this));
        V2_ROOT.denyContract(address(JAAA_SHARE_TOKEN), address(this));
    }
}
