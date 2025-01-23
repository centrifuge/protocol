// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AssetId} from "src/types/AssetId.sol";
import {D18} from "src/types/D18.sol";

import {Conversion} from "src/libraries/Conversion.sol";

import {IBaseERC7726} from "src/interfaces/IBaseERC7726.sol";
import {IERC20Metadata} from "src/interfaces/IERC20Metadata.sol";
import {IAssetManager} from "src/interfaces/IAssetManager.sol";

import {Auth} from "src/Auth.sol";

abstract contract BaseERC7726 is Auth, IBaseERC7726 {
    /// @notice AssetManager dependency.
    IAssetManager public assetManager;

    constructor(IAssetManager assetManager_, address deployer) Auth(deployer) {
        assetManager = assetManager_;
    }

    /// @inheritdoc IBaseERC7726
    function file(bytes32 what, address data) external auth {
        if (what == "assetManager") assetManager = IAssetManager(data);
        else revert FileUnrecognizedWhat();

        emit File(what, data);
    }

    /// @notice Obtain the correct decimals given an asset address
    function _getDecimals(address asset) internal view returns (uint8) {
        return assetManager.decimals(uint160(asset));
    }
}
