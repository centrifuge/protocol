// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {vm} from "@chimera/Hevm.sol";

// Helpers
import {Panic} from "@recon/Panic.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {IBaseVault} from "src/spokes/interfaces/vaults/IBaseVaults.sol";
import {D18} from "src/misc/types/D18.sol";

import {BalanceSheet} from "src/spokes/BalanceSheet.sol";
import {BeforeAfter} from "test/integration/recon-end-to-end/BeforeAfter.sol";
import {Properties} from "test/integration/recon-end-to-end/properties/Properties.sol";

abstract contract BalanceSheetTargets is
    BaseTargetFunctions,
    Properties
{
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///


    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///

    function balanceSheet_deny() public asActor {
        balanceSheet.deny(_getActor());
    }

    function balanceSheet_deposit(uint256 tokenId, uint128 amount) public asActor {
        IBaseVault vault = IBaseVault(_getVault());
        balanceSheet.deposit(vault.poolId(), vault.scId(), vault.asset(), tokenId, amount);
    }

    function balanceSheet_file(bytes32 what, address data) public asActor {
        balanceSheet.file(what, data);
    }

    function balanceSheet_issue(uint128 shares) public asActor {
        IBaseVault vault = IBaseVault(_getVault());
        balanceSheet.issue(vault.poolId(), vault.scId(), _getActor(), shares);
    }

    function balanceSheet_noteDeposit(uint256 tokenId, uint128 amount) public asActor {
        IBaseVault vault = IBaseVault(_getVault());
        balanceSheet.noteDeposit(vault.poolId(), vault.scId(), vault.asset(), tokenId, _getActor(), amount);
    }

    function balanceSheet_overridePricePoolPerAsset(D18 value) public asActor {
        IBaseVault vault = IBaseVault(_getVault());
        AssetId assetId = hubRegistry.currency(vault.poolId());
        balanceSheet.overridePricePoolPerAsset(vault.poolId(), vault.scId(), assetId, value);
    }

    function balanceSheet_overridePricePoolPerShare(D18 value) public asActor {
        IBaseVault vault = IBaseVault(_getVault());
        balanceSheet.overridePricePoolPerShare(vault.poolId(), vault.scId(), value);
    }

    function balanceSheet_recoverTokens(address token, uint256 amount) public asActor {
        balanceSheet.recoverTokens(token, _getActor(), amount);
    }

    function balanceSheet_recoverTokens(address token, uint256 tokenId, uint256 amount) public asActor {
        balanceSheet.recoverTokens(token, tokenId, _getActor(), amount);
    }

    function balanceSheet_rely() public asActor {
        balanceSheet.rely(_getActor());
    }

    function balanceSheet_resetPricePoolPerAsset() public asActor {
        IBaseVault vault = IBaseVault(_getVault());
        AssetId assetId = hubRegistry.currency(vault.poolId());
        balanceSheet.resetPricePoolPerAsset(vault.poolId(), vault.scId(), assetId);
    }

    function balanceSheet_resetPricePoolPerShare() public asActor {
        IBaseVault vault = IBaseVault(_getVault());
        balanceSheet.resetPricePoolPerShare(vault.poolId(), vault.scId());
    }

    function balanceSheet_revoke(uint128 shares) public asActor {
        IBaseVault vault = IBaseVault(_getVault());
        balanceSheet.revoke(vault.poolId(), vault.scId(), shares);
    }

    function balanceSheet_transferSharesFrom(address to, uint256 amount) public asActor {
        IBaseVault vault = IBaseVault(_getVault());
        balanceSheet.transferSharesFrom(vault.poolId(), vault.scId(), _getActor(), _getRandomActor(uint256(uint160(to))), amount);
    }

    function balanceSheet_withdraw(uint256 tokenId, uint128 amount) public asActor {
        IBaseVault vault = IBaseVault(_getVault());
        balanceSheet.withdraw(vault.poolId(), vault.scId(), vault.asset(), tokenId, _getActor(), amount);
    }
}