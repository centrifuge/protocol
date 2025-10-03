// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {Setup} from "../Setup.sol";
import {D18} from "src/misc/types/D18.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";
/**
 * GLOBAL GHOST VARIABLES
 */

abstract contract Ghosts is Setup {
    mapping(address => Vars) internal _investorsGlobals;

    struct Vars {
        // See IM_1
        uint256 maxDepositPrice;
        uint256 minDepositPrice;
        // See IM_2
        uint256 maxRedeemPrice;
        uint256 minRedeemPrice;
    }

    function __globals() internal {
        (uint256 depositPrice, uint256 redeemPrice) = _getDepositAndRedeemPrice();

        // Conditionally Update max | Always works on zero
        _investorsGlobals[_getActor()].maxDepositPrice = depositPrice > _investorsGlobals[_getActor()].maxDepositPrice
            ? depositPrice
            : _investorsGlobals[_getActor()].maxDepositPrice;
        _investorsGlobals[_getActor()].maxRedeemPrice = redeemPrice > _investorsGlobals[_getActor()].maxRedeemPrice
            ? redeemPrice
            : _investorsGlobals[_getActor()].maxRedeemPrice;

        // Conditionally Update min
        // On zero we have to update anyway
        if (_investorsGlobals[_getActor()].minDepositPrice == 0) {
            _investorsGlobals[_getActor()].minDepositPrice = depositPrice;
        }
        if (_investorsGlobals[_getActor()].minRedeemPrice == 0) {
            _investorsGlobals[_getActor()].minRedeemPrice = redeemPrice;
        }

        // Conditional update after zero
        _investorsGlobals[_getActor()].minDepositPrice = depositPrice < _investorsGlobals[_getActor()].minDepositPrice
            ? depositPrice
            : _investorsGlobals[_getActor()].minDepositPrice;
        _investorsGlobals[_getActor()].minRedeemPrice = redeemPrice < _investorsGlobals[_getActor()].minRedeemPrice
            ? redeemPrice
            : _investorsGlobals[_getActor()].minRedeemPrice;
    }

    function _getDepositAndRedeemPrice() internal view returns (uint256, uint256) {
        (,, D18 depositPrice, D18 redeemPrice,,,,,,) =
            asyncRequestManager.investments(IBaseVault(address(vault)), address(_getActor()));

        return (depositPrice.raw(), redeemPrice.raw());
    }
}
