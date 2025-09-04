// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Recon Deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {vm} from "@chimera/Hevm.sol";
import {MockERC20} from "@recon/MockERC20.sol";
import {Panic} from "@recon/Panic.sol";
import {console2} from "forge-std/console2.sol";

// Dependencies
import {AsyncVault} from "src/vaults/AsyncVault.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {AccountId} from "src/common/types/AccountId.sol";
import {BaseVault} from "src/vaults/BaseVaults.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";

// Test Utils
import {Properties} from "../properties/Properties.sol";
import {OpType} from "../BeforeAfter.sol";

abstract contract DoomsdayTargets is BaseTargetFunctions, Properties {
    /// @dev Property: user pays pricePerShare + precision, the amount of shares user receives should be pricePerShare -
    /// precision
    /// @dev Property: user should always be able to deposit less than maxMint
    function doomsday_deposit(uint256 assets) public statelessTest {
        uint256 ppfsBefore = BaseVault(_getVault()).pricePerShare();
        (uint128 maxMint,,,,,,,,,) = asyncRequestManager.investments(IBaseVault(_getVault()), _getActor());
        uint256 maxMintAsAssets = IBaseVault(_getVault()).convertToAssets(maxMint);

        uint256 sharesReceived;
        vm.prank(_getActor());
        try IBaseVault(_getVault()).deposit(assets, _getActor()) returns (uint256 shares) {
            sharesReceived = shares;
        } catch {
            bool isFrozen = fullRestrictions.isFrozen(_getVault(), _getActor());
            (bool isMember,) = fullRestrictions.isMember(_getShareToken(), _getActor());
            if (assets < maxMintAsAssets && !isFrozen && isMember) {
                t(false, "cant deposit less than maxMint");
            }
        }
        uint256 sharesAsAssets = IBaseVault(_getVault()).convertToAssets(sharesReceived);

        uint256 expectedAssetsSpent = (sharesReceived * ppfsBefore) + (10 ** MockERC20(_getAsset()).decimals());
        uint256 expectedSharesReceived = (assets / ppfsBefore) - (10 ** IShareToken(_getShareToken()).decimals());

        // should always round in protocol's favor, requiring more assets to be spent than shares received
        gte(sharesAsAssets, expectedAssetsSpent, "sharesAsAssets < expectedAssetsSpent");
        lte(sharesReceived, expectedSharesReceived, "sharesReceived > expectedSharesReceived");
    }

    /// @dev Property: user pays pricePerShare + precision, the amount of shares user receives should be pricePerShare -
    /// precision
    /// @dev Property: user should always be able to mint less than maxMint
    function doomsday_mint(uint256 shares) public statelessTest {
        uint256 ppfsBefore = BaseVault(_getVault()).pricePerShare();
        (uint128 maxMint,,,,,,,,,) = asyncRequestManager.investments(IBaseVault(_getVault()), _getActor());

        vm.prank(_getActor());
        uint256 assetsSpent;
        try IBaseVault(_getVault()).mint(shares, _getActor()) returns (uint256 assets) {
            assetsSpent = assets;
        } catch {
            bool isFrozen = fullRestrictions.isFrozen(_getVault(), _getActor());
            (bool isMember,) = fullRestrictions.isMember(_getShareToken(), _getActor());
            if (shares < maxMint && !isFrozen && isMember) {
                t(false, "cant mint less than maxMint");
            }
        }
        uint256 assetsAsShares = IBaseVault(_getVault()).convertToShares(assetsSpent);

        uint256 expectedAssetsSpent = (assetsAsShares * ppfsBefore) + (10 ** MockERC20(_getAsset()).decimals());
        uint256 expectedSharesReceived = (assetsSpent / ppfsBefore) - (10 ** IShareToken(_getShareToken()).decimals());

        gte(assetsSpent, expectedAssetsSpent, "assetsSpent < expectedAssetsSpent");
        lte(assetsAsShares, expectedSharesReceived, "assetsAsShares > expectedSharesReceived");
    }

    /// @dev Property: user pays pricePerShare + precision, the amount of shares user receives should be pricePerShare -
    /// precision
    /// @dev Property: user should always be able to redeem less than maxWithdraw
    function doomsday_redeem(uint256 shares) public statelessTest {
        uint256 ppfsBefore = BaseVault(_getVault()).pricePerShare();
        (, uint128 maxWithdraw,,,,,,,,) = asyncRequestManager.investments(IBaseVault(_getVault()), _getActor());
        uint256 maxWithdrawAsShares = IBaseVault(_getVault()).convertToShares(maxWithdraw);

        vm.prank(_getActor());
        uint256 assetsReceived;
        try IBaseVault(_getVault()).redeem(shares, _getActor(), _getActor()) returns (uint256 assets) {
            assetsReceived = assets;
        } catch {
            bool isFrozen = fullRestrictions.isFrozen(_getVault(), _getActor());
            (bool isMember,) = fullRestrictions.isMember(_getShareToken(), _getActor());
            if (shares < maxWithdrawAsShares && !isFrozen && isMember) {
                t(false, "cant redeem less than maxWithdraw");
            }
        }
        uint256 assetsAsShares = IBaseVault(_getVault()).convertToShares(assetsReceived);

        uint256 expectedAssets = (shares * ppfsBefore) + (10 ** IShareToken(_getShareToken()).decimals());
        uint256 expectedAssetsAsShares = (IBaseVault(_getVault()).convertToAssets(shares) / ppfsBefore)
            - (10 ** IShareToken(_getShareToken()).decimals());

        lte(assetsReceived, expectedAssets, "assetsReceived > expectedAssets");
        gte(assetsAsShares, expectedAssetsAsShares, "assetsAsShares < expectedAssetsAsShares");
    }

    /// @dev Property: user pays pricePerShare + precision, the amount of shares user receives should be pricePerShare -
    /// precision
    /// @dev Property: user should always be able to withdraw less than maxWithdraw
    function doomsday_withdraw(uint256 assets) public statelessTest {
        uint256 ppfsBefore = BaseVault(_getVault()).pricePerShare();
        uint256 assetsAsSharesBefore = IBaseVault(_getVault()).convertToShares(assets);
        (, uint128 maxWithdraw,,,,,,,,) = asyncRequestManager.investments(IBaseVault(_getVault()), _getActor());

        vm.prank(_getActor());
        uint256 sharesReceived;
        try IBaseVault(_getVault()).withdraw(assets, _getActor(), _getActor()) returns (uint256 shares) {
            sharesReceived = shares;
        } catch {
            bool isFrozen = fullRestrictions.isFrozen(_getVault(), _getActor());
            (bool isMember,) = fullRestrictions.isMember(_getShareToken(), _getActor());
            if (assets < maxWithdraw && !isFrozen && isMember) {
                t(false, "cant withdraw less than maxWithdraw");
            }
        }
        uint256 sharesAsAssets = IBaseVault(_getVault()).convertToAssets(sharesReceived);

        uint256 expectedAssets = (assetsAsSharesBefore * ppfsBefore) + (10 ** IShareToken(_getShareToken()).decimals());
        uint256 expectedAssetsAsShares = (assets / ppfsBefore) - (10 ** IShareToken(_getShareToken()).decimals());

        gte(sharesAsAssets, expectedAssets, "sharesAsAssets < expectedAssets");
        lte(sharesReceived, expectedAssetsAsShares, "sharesReceived > expectedAssetsAsShares");
    }
}
