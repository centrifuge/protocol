// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {vm} from "@chimera/Hevm.sol";

import {console2} from "forge-std/console2.sol";

// Helpers
import {Panic} from "@recon/Panic.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";
import {D18} from "src/misc/types/D18.sol";

import {BalanceSheet} from "src/spoke/BalanceSheet.sol";
import {BeforeAfter} from "test/integration/recon-end-to-end/BeforeAfter.sol";
import {Properties} from "test/integration/recon-end-to-end/properties/Properties.sol";

abstract contract BalanceSheetTargets is BaseTargetFunctions, Properties {
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///

    function balanceSheet_deny() public updateGhosts asActor {
        balanceSheet.deny(_getActor());
    }

    function balanceSheet_deposit(uint256 tokenId, uint128 amount) public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        balanceSheet.deposit(vault.poolId(), vault.scId(), vault.asset(), tokenId, amount);

        sumOfManagerDeposits[vault.asset()] += amount;
    }

    function balanceSheet_file(bytes32 what, address data) public updateGhosts asActor {
        balanceSheet.file(what, data);
    }

    function balanceSheet_issue(uint128 shares) public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();

        balanceSheet.issue(poolId, scId, _getActor(), shares);

        issuedBalanceSheetShares[poolId][scId] += shares;
        shareMints[vault.share()] += shares;
    }

    function balanceSheet_noteDeposit(uint256 tokenId, uint128 amount) public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        balanceSheet.noteDeposit(vault.poolId(), vault.scId(), vault.asset(), tokenId, amount);
    }

    function balanceSheet_overridePricePoolPerAsset(D18 value) public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        AssetId assetId = hubRegistry.currency(vault.poolId());
        balanceSheet.overridePricePoolPerAsset(vault.poolId(), vault.scId(), assetId, value);
    }

    function balanceSheet_overridePricePoolPerShare(D18 value) public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        balanceSheet.overridePricePoolPerShare(vault.poolId(), vault.scId(), value);
    }

    function balanceSheet_recoverTokens(address token, uint256 amount) public updateGhosts asActor {
        balanceSheet.recoverTokens(token, _getActor(), amount);
    }

    function balanceSheet_recoverTokens(address token, uint256 tokenId, uint256 amount) public updateGhosts asActor {
        balanceSheet.recoverTokens(token, tokenId, _getActor(), amount);
    }

    function balanceSheet_rely() public updateGhosts asActor {
        balanceSheet.rely(_getActor());
    }

    function balanceSheet_resetPricePoolPerAsset() public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        AssetId assetId = hubRegistry.currency(vault.poolId());
        balanceSheet.resetPricePoolPerAsset(vault.poolId(), vault.scId(), assetId);
    }

    function balanceSheet_resetPricePoolPerShare() public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        balanceSheet.resetPricePoolPerShare(vault.poolId(), vault.scId());
    }

    function balanceSheet_revoke(uint128 shares) public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();

        balanceSheet.revoke(poolId, scId, shares);

        revokedBalanceSheetShares[poolId][scId] += shares;
        shareMints[vault.share()] -= shares;
    }

    function balanceSheet_transferSharesFrom(address to, uint256 amount) public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        balanceSheet.transferSharesFrom(
            vault.poolId(), vault.scId(), _getActor(), _getActor(), _getRandomActor(uint256(uint160(to))), amount
        );
    }

    function balanceSheet_withdraw(uint256 tokenId, uint128 amount) public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        balanceSheet.withdraw(vault.poolId(), vault.scId(), vault.asset(), tokenId, _getActor(), amount);

        sumOfManagerWithdrawals[vault.asset()] += amount;
    }
}
