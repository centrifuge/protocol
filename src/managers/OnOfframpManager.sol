// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";
import {Recoverable} from "src/misc/Recoverable.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {MessageLib, UpdateContractType} from "src/common/libraries/MessageLib.sol";

import {IPoolEscrow} from "src/vaults/interfaces/IEscrow.sol";
import {IBalanceSheet} from "src/vaults/interfaces/IBalanceSheet.sol";

contract OnOfframpManager is Auth, Recoverable {
    using MathLib for uint256;

    error NotAllowedOnrampAsset();
    error NoOfframpDestinationSet();

    PoolId public immutable poolId;
    ShareClassId public immutable scId;

    IBalanceSheet public immutable balanceSheet;

    mapping(address asset => bool) public allowedOnrampAsset;
    mapping(address asset => address) public offrampDestination;
    // mapping(AssetId => address) public cctpDestination;

    constructor(PoolId poolId_, ShareClassId scId_, IBalanceSheet balanceSheet_, address deployer) Auth(deployer) {
        poolId = poolId_;
        scId = scId_;
        balanceSheet = balanceSheet_;
    }

    //----------------------------------------------------------------------------------------------
    // Owner actions
    //----------------------------------------------------------------------------------------------

    // TODO: add UpdateCOntract for storage mappings

    //----------------------------------------------------------------------------------------------
    // Permissionless actions
    //----------------------------------------------------------------------------------------------

    function onramp(address asset) external {
        require(allowedOnrampAsset[asset], NotAllowedOnrampAsset());

        uint128 amount = IERC20(asset).balanceOf(address(this)).toUint128();
        if (IERC20(asset).allowance(address(this), address(balanceSheet)) == 0) {
            SafeTransferLib.safeApprove(asset, address(balanceSheet), type(uint256).max);
        }

        balanceSheet.deposit(poolId, scId, asset, 0, address(this), amount);
    }

    function offramp(address asset) external {
        address offrampDestination_ = offrampDestination[asset];
        require(offrampDestination_ != address(0), NoOfframpDestinationSet());

        IPoolEscrow escrow = balanceSheet.poolEscrowProvider().escrow(poolId);
        uint128 amount = escrow.availableBalanceOf(scId, asset, 0);

        balanceSheet.withdraw(poolId, scId, asset, 0, offrampDestination_, amount);
    }
}
