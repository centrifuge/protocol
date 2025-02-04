// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AssetId} from "src/types/AssetId.sol";
import {D18} from "src/types/D18.sol";

import {Conversion} from "src/libraries/Conversion.sol";

import {IBaseValuation} from "src/interfaces/IBaseValuation.sol";
import {IERC20Metadata} from "src/interfaces/IERC20Metadata.sol";
import {IAssetManager} from "src/interfaces/IAssetManager.sol";

import {Auth} from "src/Auth.sol";

abstract contract BaseValuation is Auth, IBaseValuation {
    /// @notice AssetManager dependency.
    IAssetManager public assetManager;

    constructor(IAssetManager assetManager_, address deployer) Auth(deployer) {
        assetManager = assetManager_;
    }

    /// @inheritdoc IBaseValuation
    function file(bytes32 what, address data) external auth {
        if (what == "assetManager") assetManager = IAssetManager(data);
        else revert FileUnrecognizedWhat();

        emit File(what, data);
    }

    /// @notice Obtain the correct decimals given an asset address
    function _getDecimals(address asset) internal view returns (uint8) {
        return assetManager.decimals(uint256(uint160(asset)));
    }
}
