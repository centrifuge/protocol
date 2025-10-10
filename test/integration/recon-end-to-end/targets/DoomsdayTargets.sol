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
        uint256 ppfsBefore = BaseVault(address(_getVault())).pricePerShare();
        (uint128 maxMint, , , , , , , , , ) = asyncRequestManager.investments(
            _getVault(),
            _getActor()
        );
        uint256 maxMintAsAssets = _getVault().convertToAssets(maxMint);

        uint256 sharesReceived;
        vm.prank(_getActor());
        try _getVault().deposit(assets, _getActor()) returns (uint256 shares) {
            sharesReceived = shares;
        } catch {
            bool isFrozen = fullRestrictions.isFrozen(
                address(_getVault()),
                _getActor()
            );
            (bool isMember, ) = fullRestrictions.isMember(
                _getShareToken(),
                _getActor()
            );
            if (assets < maxMintAsAssets && !isFrozen && isMember) {
                t(false, "cant deposit less than maxMint");
            }
        }
        uint256 sharesAsAssets = _getVault().convertToAssets(sharesReceived);

        // price is in 18 decimal precision
        uint256 expectedAssetsSpent = (sharesReceived * ppfsBefore) / 1e18;
        uint256 expectedSharesReceived = ((assets * 1e18) / ppfsBefore);

        // should always round in protocol's favor, requiring more assets to be spent than shares received
        gte(
            sharesAsAssets,
            expectedAssetsSpent,
            "sharesAsAssets < expectedAssetsSpent"
        );
        lte(
            sharesReceived,
            expectedSharesReceived,
            "sharesReceived > expectedSharesReceived"
        );
    }

    /// @dev Property: user pays pricePerShare + precision, the amount of shares user receives should be pricePerShare -
    /// precision
    /// @dev Property: user should always be able to mint less than maxMint
    function doomsday_mint(uint256 shares) public statelessTest {
        uint256 ppfsBefore = BaseVault(address(_getVault())).pricePerShare();
        (uint128 maxMint, , , , , , , , , ) = asyncRequestManager.investments(
            _getVault(),
            _getActor()
        );

        vm.prank(_getActor());
        uint256 assetsSpent;
        try _getVault().mint(shares, _getActor()) returns (uint256 assets) {
            assetsSpent = assets;
        } catch {
            bool isFrozen = fullRestrictions.isFrozen(
                address(_getVault()),
                _getActor()
            );
            (bool isMember, ) = fullRestrictions.isMember(
                _getShareToken(),
                _getActor()
            );
            if (shares < maxMint && !isFrozen && isMember) {
                t(false, "cant mint less than maxMint");
            }
        }
        uint256 assetsAsShares = _getVault().convertToShares(assetsSpent);

        uint256 expectedAssetsSpent = (assetsAsShares * ppfsBefore) +
            (10 ** MockERC20(_getAsset()).decimals());
        uint256 expectedSharesReceived = (assetsSpent / ppfsBefore) -
            (10 ** IShareToken(_getShareToken()).decimals());

        gte(
            assetsSpent,
            expectedAssetsSpent,
            "assetsSpent < expectedAssetsSpent"
        );
        lte(
            assetsAsShares,
            expectedSharesReceived,
            "assetsAsShares > expectedSharesReceived"
        );
    }

    /// @dev Property: user pays pricePerShare + precision, the amount of shares user receives should be pricePerShare -
    /// precision
    /// @dev Property: user should always be able to redeem less than maxWithdraw
    function doomsday_redeem(uint256 shares) public statelessTest {
        uint256 ppfsBefore = BaseVault(address(_getVault())).pricePerShare();
        (, uint128 maxWithdraw, , , , , , , , ) = asyncRequestManager
            .investments(_getVault(), _getActor());
        uint256 maxWithdrawAsShares = _getVault().convertToShares(maxWithdraw);

        vm.prank(_getActor());
        uint256 assetsReceived;
        try _getVault().redeem(shares, _getActor(), _getActor()) returns (
            uint256 assets
        ) {
            assetsReceived = assets;
        } catch {
            bool isFrozen = fullRestrictions.isFrozen(
                address(_getVault()),
                _getActor()
            );
            (bool isMember, ) = fullRestrictions.isMember(
                _getShareToken(),
                _getActor()
            );
            if (shares < maxWithdrawAsShares && !isFrozen && isMember) {
                t(false, "cant redeem less than maxWithdraw");
            }
        }
        uint256 assetsAsShares = _getVault().convertToShares(assetsReceived);

        uint256 expectedAssets = (shares * ppfsBefore) +
            (10 ** IShareToken(_getShareToken()).decimals());
        uint256 expectedAssetsAsShares = (_getVault().convertToAssets(shares) /
            ppfsBefore) - (10 ** IShareToken(_getShareToken()).decimals());

        lte(assetsReceived, expectedAssets, "assetsReceived > expectedAssets");
        gte(
            assetsAsShares,
            expectedAssetsAsShares,
            "assetsAsShares < expectedAssetsAsShares"
        );
    }

    /// @dev Property: user pays pricePerShare + precision, the amount of shares user receives should be pricePerShare -
    /// precision
    /// @dev Property: user should always be able to withdraw less than maxWithdraw
    function doomsday_withdraw(uint256 assets) public statelessTest {
        uint256 ppfsBefore = BaseVault(address(_getVault())).pricePerShare();
        uint256 assetsAsSharesBefore = _getVault().convertToShares(assets);
        (, uint128 maxWithdraw, , , , , , , , ) = asyncRequestManager
            .investments(_getVault(), _getActor());

        vm.prank(_getActor());
        uint256 sharesReceived;
        try _getVault().withdraw(assets, _getActor(), _getActor()) returns (
            uint256 shares
        ) {
            sharesReceived = shares;
        } catch {
            bool isFrozen = fullRestrictions.isFrozen(
                address(_getVault()),
                _getActor()
            );
            (bool isMember, ) = fullRestrictions.isMember(
                _getShareToken(),
                _getActor()
            );
            if (assets < maxWithdraw && !isFrozen && isMember) {
                t(false, "cant withdraw less than maxWithdraw");
            }
        }
        uint256 sharesAsAssets = _getVault().convertToAssets(sharesReceived);

        uint256 expectedAssets = (assetsAsSharesBefore * ppfsBefore) +
            (10 ** IShareToken(_getShareToken()).decimals());
        uint256 expectedAssetsAsShares = (assets / ppfsBefore) -
            (10 ** IShareToken(_getShareToken()).decimals());

        gte(sharesAsAssets, expectedAssets, "sharesAsAssets < expectedAssets");
        lte(
            sharesReceived,
            expectedAssetsAsShares,
            "sharesReceived > expectedAssetsAsShares"
        );
    }

    /// @dev Property: pricePerShare never changes after a user operation
    function doomsday_pricePerShare_never_changes_after_user_operation()
        public
    {
        if (
            currentOperation != OpType.ADMIN &&
            currentOperation != OpType.UPDATE
        ) {
            eq(
                _before.pricePerShare,
                _after.pricePerShare,
                "pricePerShare changed after user operation"
            );
        }
    }

    /// @dev Property: implied pricePerShare (totalAssets / totalSupply) never changes after a user operation
    function doomsday_impliedPricePerShare_never_changes_after_user_operation()
        public
    {
        if (currentOperation != OpType.ADMIN) {
            uint256 impliedPricePerShareBefore = _before.totalAssets /
                _before.totalShareSupply;
            uint256 impliedPricePerShareAfter = _after.totalAssets /
                _after.totalShareSupply;
            eq(
                impliedPricePerShareBefore,
                impliedPricePerShareAfter,
                "impliedPricePerShare changed after user operation"
            );
        }
    }

    /// @dev Property: accounting.accountValue should never revert
    function doomsday_accountValue(
        uint64 poolIdAsUint,
        uint32 accountAsInt
    ) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        AccountId account = AccountId.wrap(accountAsInt);

        try accounting.accountValue(poolId, account) {} catch (
            bytes memory reason
        ) {
            bool expectedRevert = checkError(reason, "AccountDoesNotExist()");
            t(expectedRevert, "accountValue should never revert");
        }
    }

    /// @dev Doomsday test: System handles all operations gracefully at zero price
    function doomsday_zeroPrice_noPanics() public statelessTest {
        IBaseVault vault = _getVault();
        if (address(vault) == address(0)) return;

        // Set zero price directly
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = spoke.vaultDetails(vault).assetId;
        hub.updateSharePrice(poolId, scId, D18.wrap(0));

        // === CONVERSION FUNCTION TESTS === //
        try vault.convertToShares(1e18) returns (uint256 shares) {
            eq(shares, 0, "convertToShares should return 0 at zero price");
        } catch {
            t(false, "convertToShares should not panic at zero price");
        }

        try vault.convertToAssets(1e18) returns (uint256 assets) {
            eq(assets, 0, "convertToAssets should return 0 at zero price");
        } catch {
            t(false, "convertToAssets should not panic at zero price");
        }

        try BaseVault(address(vault)).pricePerShare() returns (uint256 pps) {
            eq(pps, 0, "pricePerShare should be 0");
        } catch {
            t(false, "pricePerShare should not panic at zero price");
        }

        // === VAULT OPERATION TESTS === //
        try vault.maxDeposit(_getActor()) returns (uint256 max) {
            console2.log("DEBUG: maxDeposit returned:", max);
            console2.log(
                "DEBUG: pool per share:",
                D18.unwrap(spoke.pricePoolPerShare(poolId, scId, false))
            );
            eq(max, 0, "maxDeposit handled zero price");
        } catch {
            t(false, "maxDeposit should not revert at zero price");
        }

        try vault.maxMint(_getActor()) returns (uint256 max) {
            eq(max, 0, "maxMint should return 0 at zero price");
        } catch {
            t(false, "maxMint shout not revert at zero price");
        }

        try vault.maxRedeem(_getActor()) returns (uint256 max) {
            eq(max, 0, "maxRedeem should return 0 at zero price");
        } catch {
            t(false, "maxRedeem shout not revert at zero price");
        }

        try vault.maxWithdraw(_getActor()) returns (uint256 max) {
            eq(max, 0, "maxWithdraw should return 0 at zero price");
        } catch {
            t(false, "maxWithdraw shout not revert at zero price");
        }

        // === SHARE CLASS MANAGER OPERATIONS === //
        uint32 nowIssueEpoch = shareClassManager.nowIssueEpoch(scId, assetId);
        try
            shareClassManager.issueShares(
                poolId,
                scId,
                assetId,
                nowIssueEpoch,
                D18.wrap(0)
            )
        returns (uint128 issued, uint128, uint128) {
            eq(issued, 0, "issued shares should return 0 at zero price");
        } catch (bytes memory reason) {
            bool expectedRevert = checkError(reason, "EpochNotFound()");
            t(
                expectedRevert,
                "issueShares shout not revert at zero price apart from EpochNotFound"
            );
        }

        uint32 nowRevokeEpoch = shareClassManager.nowRevokeEpoch(scId, assetId);
        try
            shareClassManager.revokeShares(
                poolId,
                scId,
                assetId,
                nowRevokeEpoch,
                D18.wrap(0)
            )
        returns (uint128, uint128 assetAmount, uint128) {
            eq(
                assetAmount,
                0,
                "revoked asset amount should return 0 at zero price"
            );
        } catch (bytes memory reason) {
            bool expectedRevert = checkError(reason, "EpochNotFound()");
            t(
                expectedRevert,
                "issueShares shout not revert at zero price apart from EpochNotFound"
            );
        }
    }
}
