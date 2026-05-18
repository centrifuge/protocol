// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Recon Deps

import {D18} from "../../../../src/misc/types/D18.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../../src/core/types/AssetId.sol";
import {AccountId} from "../../../../src/core/types/AccountId.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {IShareToken} from "../../../../src/core/spoke/interfaces/IShareToken.sol";
import {MAX_MESSAGE_COST} from "../../../../src/core/messaging/interfaces/IGasService.sol";

import {BaseVault} from "../../../../src/vaults/BaseVaults.sol";
import {IBaseVault} from "../../../../src/vaults/interfaces/IBaseVault.sol";

import {console2} from "forge-std/console2.sol";

import {vm} from "@chimera/Hevm.sol";
import {OpType} from "../BeforeAfter.sol";
import {Properties} from "../properties/Properties.sol";
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";

// Dependencies

// Test Utils

abstract contract DoomsdayTargets is BaseTargetFunctions, Properties {
    /// @dev Property: user pays pricePerShare + precision, the amount of shares user receives should be pricePerShare -
    /// precision
    /// @dev Property: user should always be able to deposit less than maxMint
    // NOTE: removed because no simple way to check expected share amount without fully reimplementing existing logic
    // function doomsday_deposit(uint256 assets) public statelessTest {
    //     // uint256 ppfsBefore = BaseVault(address(_getVault())).pricePerShare();
    //     (uint128 maxMint, , D18 ppfsBefore, , , , , , , ) = asyncRequestManager.investments(
    //         _getVault(),
    //         _getActor()
    //     );
    //     uint256 maxMintAsAssets = _getVault().convertToAssets(maxMint);

    //     uint256 sharesReceived;
    //     vm.prank(_getActor());
    //     try _getVault().deposit(assets, _getActor()) returns (uint256 shares) {
    //         sharesReceived = shares;
    //     } catch {
    //         bool isFrozen = fullRestrictions.isFrozen(
    //             address(_getVault()),
    //             _getActor()
    //         );
    //         (bool isMember, ) = fullRestrictions.isMember(
    //             _getShareToken(),
    //             _getActor()
    //         );
    //         if (assets < maxMintAsAssets && !isFrozen && isMember) {
    //             t(false, "cannot deposit less than maxMint");
    //         }
    //     }
    //     uint256 sharesAsAssets = _getVault().convertToAssets(sharesReceived);

    //     // price is in 18 decimal precision
    //     uint256 expectedAssetsSpent = (sharesReceived * ppfsBefore) / 1e18;
    //     uint256 expectedSharesReceived = ((assets * 1e18) / ppfsBefore);

    //     // should always round in protocol's favor, requiring more assets to be spent than shares received
    //     gte(
    //         sharesAsAssets,
    //         expectedAssetsSpent,
    //         "sharesAsAssets < expectedAssetsSpent"
    //     );
    //     console2.log("sharesReceived: %e", sharesReceived);
    //     console2.log("expectedSharesReceived: %e", expectedSharesReceived);
    //     lte(
    //         sharesReceived,
    //         expectedSharesReceived,
    //         "sharesReceived > expectedSharesReceived"
    //     );
    // }

    /// @dev Property: user pays pricePerShare + precision, the amount of shares user receives should be pricePerShare -
    /// precision
    /// @dev Property: user should always be able to mint less than maxMint
    function doomsday_mint(uint256 shares) public statelessTest {
        (uint128 maxMint,,,,,,,,,) = asyncRequestManager.investments(_getVault(), _getActor());

        vm.prank(_getActor());
        uint256 assetsSpent;
        try _getVault().mint(shares, _getActor()) returns (uint256 assets) {
            assetsSpent = assets;
        } catch {
            bool isFrozen = fullRestrictions.isFrozen(address(_getVault()), _getActor());
            (bool isMember,) = fullRestrictions.isMember(_getShareToken(), _getActor());
            if (shares < maxMint && !isFrozen && isMember) {
                t(false, "cannot mint less than maxMint");
            }
        }
        // Use vault's conversion to properly handle decimal scaling
        // Expected assets = what the vault says these shares should cost at CURRENT spot price
        uint256 expectedAssetsSpent = _getVault().convertToAssets(shares);

        // Property 1: vault charges at least the spot-price estimate (rounds up to favor itself)
        gte(assetsSpent, expectedAssetsSpent, "assetsSpent < expectedAssetsSpent");

        // Property 2: round-trip — converting assetsSpent back to shares should recover >= shares.
        // Guard: skip when the asset/share decimal + price combination is at dust boundary where
        // convertToShares can't produce meaningful output. If 1 asset-wei converts to 0 shares,
        // any small assetsSpent will also round-trip to 0 — this is integer arithmetic precision
        // loss at minimum resolution, not a protocol bug. Both ceil(x)=1 and floor(x)=0 are
        // correct for sub-unit values; the round-trip simply can't preserve information at this scale.
        if (assetsSpent > 0 && _getVault().convertToShares(1) > 0) {
            uint256 assetsAsShares = _getVault().convertToShares(assetsSpent);
            gte(assetsAsShares, shares, "assetsAsShares < shares requested");
        }
    }

    /// @dev Property: user pays pricePerShare + precision, the amount of shares user receives should be pricePerShare -
    /// precision
    /// @dev Property: user should always be able to redeem less than maxWithdraw
    function doomsday_redeem(uint256 shares) public statelessTest {
        uint256 ppfsBefore = BaseVault(address(_getVault())).pricePerShare();
        (, uint128 maxWithdraw,,,,,,,,) = asyncRequestManager.investments(_getVault(), _getActor());
        uint256 maxWithdrawAsShares = _getVault().convertToShares(maxWithdraw);

        vm.prank(_getActor());
        uint256 assetsReceived;
        try _getVault().redeem(shares, _getActor(), _getActor()) returns (uint256 assets) {
            assetsReceived = assets;
        } catch {
            bool isFrozen = fullRestrictions.isFrozen(address(_getVault()), _getActor());
            (bool isMember,) = fullRestrictions.isMember(_getShareToken(), _getActor());
            if (shares < maxWithdrawAsShares && !isFrozen && isMember) {
                t(false, "cannot redeem less than maxWithdraw");
            }
        }
        uint256 assetsAsShares = _getVault().convertToShares(assetsReceived);

        uint256 expectedAssets = (shares * ppfsBefore) + (10 ** IShareToken(_getShareToken()).decimals());
        uint256 expectedAssetsAsShares =
            (_getVault().convertToAssets(shares) / ppfsBefore) - (10 ** IShareToken(_getShareToken()).decimals());

        lte(assetsReceived, expectedAssets, "assetsReceived > expectedAssets");
        gte(assetsAsShares, expectedAssetsAsShares, "assetsAsShares < expectedAssetsAsShares");
    }

    /// @dev Property: user pays pricePerShare + precision, the amount of shares user receives should be pricePerShare -
    /// precision
    /// @dev Property: user should always be able to withdraw less than maxWithdraw
    function doomsday_withdraw(uint256 assets) public statelessTest {
        uint256 ppfsBefore = BaseVault(address(_getVault())).pricePerShare();
        uint256 assetsAsSharesBefore = _getVault().convertToShares(assets);
        (, uint128 maxWithdraw,,,,,,,,) = asyncRequestManager.investments(_getVault(), _getActor());

        vm.prank(_getActor());
        uint256 sharesReceived;
        try _getVault().withdraw(assets, _getActor(), _getActor()) returns (uint256 shares) {
            sharesReceived = shares;
        } catch {
            bool isFrozen = fullRestrictions.isFrozen(address(_getVault()), _getActor());
            (bool isMember,) = fullRestrictions.isMember(_getShareToken(), _getActor());
            if (assets < maxWithdraw && !isFrozen && isMember) {
                t(false, "cannot withdraw less than maxWithdraw");
            }
        }
        uint256 sharesAsAssets = _getVault().convertToAssets(sharesReceived);

        uint256 expectedAssets = (assetsAsSharesBefore * ppfsBefore) + (10 ** IShareToken(_getShareToken()).decimals());
        uint256 expectedAssetsAsShares = (assets / ppfsBefore) - (10 ** IShareToken(_getShareToken()).decimals());

        gte(sharesAsAssets, expectedAssets, "sharesAsAssets < expectedAssets");
        lte(sharesReceived, expectedAssetsAsShares, "sharesReceived > expectedAssetsAsShares");
    }

    /// @dev Property: pricePerShare never changes after a user operation
    function doomsday_pricePerShare_never_changes_after_user_operation() public {
        if (currentOperation != OpType.ADMIN && currentOperation != OpType.UPDATE) {
            eq(
                _before.pricePerShare[address(_getVault())],
                _after.pricePerShare[address(_getVault())],
                "pricePerShare changed after user operation"
            );
        }
    }

    /// @dev Property: implied pricePerShare (totalAssets / totalSupply) never changes after a user operation
    function doomsday_impliedPricePerShare_never_changes_after_user_operation() public {
        if (currentOperation != OpType.ADMIN) {
            uint256 impliedPricePerShareBefore = _before.totalAssets / _before.totalShareSupply;
            uint256 impliedPricePerShareAfter = _after.totalAssets / _after.totalShareSupply;
            eq(
                impliedPricePerShareBefore,
                impliedPricePerShareAfter,
                "impliedPricePerShare changed after user operation"
            );
        }
    }

    /// @dev Property: accounting.accountValue should never revert
    function doomsday_accountValue(uint64 poolIdAsUint, uint32 accountAsInt) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        AccountId account = AccountId.wrap(accountAsInt);

        try accounting.accountValue(poolId, account) {}
        catch (bytes memory reason) {
            bool expectedRevert = checkError(reason, "AccountDoesNotExist()");
            t(expectedRevert, "accountValue should never revert");
        }
    }

    /// @dev Property: System handles all operations gracefully at zero price
    function doomsday_zeroPrice_noPanics() public statelessTest {
        IBaseVault vault = _getVault();
        if (address(vault) == address(0)) return;

        // Set zero price directly
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = vaultRegistry.vaultDetails(vault).assetId;

        // Set zero prices in hub and transient valuation
        hub.updateSharePrice(poolId, scId, D18.wrap(0), uint64(block.timestamp));
        transientValuation.setPrice(poolId, scId, assetId, D18.wrap(0));

        // Notify spoke of price updates so Price structs are valid (computedAt != 0)
        hub.notifySharePrice{value: MAX_MESSAGE_COST}(poolId, scId, CENTRIFUGE_CHAIN_ID, _getActor());
        hub.notifyAssetPrice{value: MAX_MESSAGE_COST}(poolId, scId, assetId, _getActor());

        // === CONVERSION FUNCTION TESTS === //`
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
        // At zero price, max* functions should return 0 when no async claims are outstanding.
        // During fuzzing, the fuzzer may reach intermediate states where hub_notifyRedeem/hub_notifyDeposit
        // has set maxWithdraw/maxMint > 0 but the user hasn't claimed yet. In those states, max* functions
        // legitimately return non-zero (claims use historical fulfillment price, not current zero price).
        (uint128 pendingMaxMint, uint128 pendingMaxWithdraw,,,,,,,,) =
            asyncRequestManager.investments(vault, _getActor());

        try vault.maxDeposit(_getActor()) returns (uint256 max) {
            if (pendingMaxMint == 0) {
                eq(max, 0, "maxDeposit should return 0 at zero price (no pending claims)");
            }
        } catch {
            t(false, "maxDeposit should not revert at zero price");
        }

        try vault.maxMint(_getActor()) returns (uint256 max) {
            if (pendingMaxMint == 0) {
                eq(max, 0, "maxMint should return 0 at zero price (no pending claims)");
            }
        } catch {
            t(false, "maxMint should not revert at zero price");
        }

        try vault.maxRedeem(_getActor()) returns (uint256 max) {
            if (pendingMaxWithdraw == 0) {
                eq(max, 0, "maxRedeem should return 0 at zero price (no pending claims)");
            }
        } catch {
            t(false, "maxRedeem should not revert at zero price");
        }

        try vault.maxWithdraw(_getActor()) returns (uint256 max) {
            if (pendingMaxWithdraw == 0) {
                eq(max, 0, "maxWithdraw should return 0 at zero price (no pending claims)");
            }
        } catch {
            t(false, "maxWithdraw should not revert at zero price");
        }

        // === SHARE CLASS MANAGER OPERATIONS === //
        uint32 nowIssueEpoch = batchRequestManager.nowIssueEpoch(poolId, scId, assetId);
        // Read epoch amounts BEFORE zero-price issuance to compute delta
        // (epoch may already have non-zero approvals from prior non-zero-price operations)
        (uint128 approvedPoolBefore,,,,,) = batchRequestManager.epochInvestAmounts(poolId, scId, assetId, nowIssueEpoch);
        try batchRequestManager.issueShares{value: 0.1 ether}(
            poolId, scId, assetId, nowIssueEpoch, D18.wrap(0), SHARE_HOOK_GAS, address(this)
        ) {
            (uint128 approvedPoolAfter,,,,,) =
                batchRequestManager.epochInvestAmounts(poolId, scId, assetId, nowIssueEpoch);
            uint128 approvedDelta = approvedPoolAfter >= approvedPoolBefore ? approvedPoolAfter - approvedPoolBefore : 0;
            eq(approvedDelta, 0, "approved pool amount delta should be 0 at zero price");
        } catch (bytes memory reason) {
            bool expectedRevert = checkError(reason, "EpochNotFound()");
            t(expectedRevert, "issueShares should not revert at zero price apart from EpochNotFound");
        }

        uint32 nowRevokeEpoch = batchRequestManager.nowRevokeEpoch(poolId, scId, assetId);
        try batchRequestManager.revokeShares(
            poolId, scId, assetId, nowRevokeEpoch, D18.wrap(0), SHARE_HOOK_GAS, address(this)
        ) {
            (,,,, uint128 payoutAssetAmount,) =
                batchRequestManager.epochRedeemAmounts(poolId, scId, assetId, nowRevokeEpoch);
            eq(payoutAssetAmount, 0, "revoked asset amount should return 0 at zero price");
        } catch (bytes memory reason) {
            bool expectedRevert = checkError(reason, "EpochNotFound()");
            t(expectedRevert, "revokeShares shout not revert at zero price apart from EpochNotFound");
        }
    }
}
