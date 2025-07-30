// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "../../src/misc/interfaces/IERC20.sol";

import {IShareToken} from "../../src/spoke/interfaces/IShareToken.sol";

import "forge-std/Test.sol";

interface InvestmentManagerLike {
    function fulfillDepositRequest(
        uint64 poolId,
        bytes16 trancheId,
        address user,
        uint128 assetId,
        uint128 assets,
        uint128 shares
    ) external;
    function fulfillRedeemRequest(
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
    function investments(address vault, address investor)
        external
        view
        returns (
            uint128 maxMint,
            uint128 maxWithdraw,
            uint256 depositPrice,
            uint256 redeemPrice,
            uint128 pendingDepositRequest,
            uint128 pendingRedeemRequest,
            uint128 claimableCancelDepositRequest,
            uint128 claimableCancelRedeemRequest,
            bool pendingCancelDepositRequest,
            bool pendingCancelRedeemRequest
        );
}

interface IERC7540Vault {
    function poolId() external view returns (uint64);
    function trancheId() external view returns (bytes16);
    function share() external view returns (address shareTokenAddress);
    function asset() external view returns (address assetTokenAddress);
    function requestDeposit(uint256 assets, address controller, address owner) external returns (uint256 requestId);
    function pendingDepositRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 pendingAssets);
    function maxMint(address receiver) external view returns (uint256 maxShares);
    function mint(uint256 shares, address receiver) external returns (uint256 assets);
    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256);
    function pendingRedeemRequest(uint256, address controller) external view returns (uint256 pendingShares);
    function maxWithdraw(address controller) external view returns (uint256 maxAssets);
    function withdraw(uint256 assets, address receiver, address controller) external returns (uint256 shares);
}

// Simple base class for V2 fork tests
contract ForkTestBase is Test {
    function setUp() public virtual {
        vm.createSelectFork("https://ethereum-rpc.publicnode.com");
    }
}

// Interface for V2 Root contract endorsement
interface IRoot {
    function rely(address user) external;
}

contract ForkTestAsyncInvestmentsV2 is ForkTestBase {
    address public constant V2_ROOT = address(0x0C1fDfd6a1331a875EA013F3897fc8a76ada5DfC);
    address public constant V2_INVESTOR = address(0x491EDFB0B8b608044e227225C715981a30F3A44E);
    address public constant V2_INVESTMENT_MANAGER = address(0x427A1ce127b1775e4Cbd4F58ad468B9F832eA7e9);

    uint256 public constant REQUEST_ID = 0;
    uint128 public constant USDC_ASSET_ID = 242333941209166991950178742833476896417;

    address public constant V2_JTRSY_VAULT_ADDRESS = 0x36036fFd9B1C6966ab23209E073c68Eb9A992f50;
    address public constant V2_JAAA_VAULT_ADDRESS = 0xE9d1f733F406D4bbbDFac6D4CfCD2e13A6ee1d01;

    function test_completeAsyncInvestmentFlow() public {
        // Use V2_INVESTOR which should already have sufficient permissions
        _completeAsyncDepositFlow(V2_JTRSY_VAULT_ADDRESS, V2_INVESTOR, 100_000e6);
        _completeAsyncRedeemFlow(V2_JTRSY_VAULT_ADDRESS, V2_INVESTOR, 50_000e6);

        _completeAsyncDepositFlow(V2_JAAA_VAULT_ADDRESS, V2_INVESTOR, 100_000e6);
        _completeAsyncRedeemFlow(V2_JAAA_VAULT_ADDRESS, V2_INVESTOR, 50_000e6);
    }

    function _completeAsyncDepositFlow(address vault_, address investor, uint128 amount) internal {
        IERC7540Vault vault = IERC7540Vault(vault_);
        uint64 poolId = vault.poolId();
        bytes16 trancheId = vault.trancheId();
        uint128 assetId = USDC_ASSET_ID;
        IShareToken shareToken = IShareToken(address(vault.share()));

        InvestmentManagerLike investmentManager = InvestmentManagerLike(V2_INVESTMENT_MANAGER);

        deal(vault.asset(), investor, amount);

        vm.startPrank(investor);
        IERC20(vault.asset()).approve(address(vault), amount);
        vault.requestDeposit(amount, investor, investor);
        vm.stopPrank();

        // Check that pending request increased by the expected amount
        // NOTE: V2_INVESTOR may have existing pending requests on mainnet
        uint256 pendingRequest = vault.pendingDepositRequest(REQUEST_ID, investor);
        assertGe(pendingRequest, amount, "Deposit request not recorded with vault");

        vm.startPrank(V2_ROOT);
        investmentManager.fulfillDepositRequest(poolId, trancheId, investor, assetId, amount, amount);
        vm.stopPrank();

        uint256 sharesBefore = shareToken.balanceOf(investor);

        vm.startPrank(investor);
        uint256 maxMintable = vault.maxMint(investor);
        assertGt(maxMintable, 0, "Max mintable shares should be greater than 0");
        vault.mint(maxMintable, investor);
        vm.stopPrank();

        uint256 sharesAfter = shareToken.balanceOf(investor);
        assertGt(sharesAfter, sharesBefore, "User should have received shares");
    }

    function _completeAsyncRedeemFlow(address vault_, address investor, uint128 amount) internal {
        IERC7540Vault vault = IERC7540Vault(vault_);
        uint64 poolId = vault.poolId();
        bytes16 trancheId = vault.trancheId();
        uint128 assetId = USDC_ASSET_ID;
        IShareToken shareToken = IShareToken(address(vault.share()));

        InvestmentManagerLike investmentManager = InvestmentManagerLike(V2_INVESTMENT_MANAGER);

        uint256 sharesBefore = shareToken.balanceOf(investor);

        vm.startPrank(investor);
        vault.requestRedeem(amount, investor, investor);
        vm.stopPrank();

        // Check that pending request exists (may not be exactly equal due to existing state)
        uint256 pendingRequest = vault.pendingRedeemRequest(REQUEST_ID, investor);
        assertGe(pendingRequest, amount, "Redeem request not recorded with vault");

        vm.startPrank(V2_ROOT);
        investmentManager.fulfillRedeemRequest(poolId, trancheId, investor, assetId, amount, amount);
        vm.stopPrank();

        vm.startPrank(investor);
        uint256 maxWithdrawable = vault.maxWithdraw(investor);
        assertGt(maxWithdrawable, 0, "Max withdrawable shares should be greater than 0");
        vault.withdraw(maxWithdrawable, investor, investor);
        vm.stopPrank();

        uint256 sharesAfter = shareToken.balanceOf(investor);
        assertLt(sharesAfter, sharesBefore, "User should have burned shares");
    }
}
