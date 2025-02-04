// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AssetId} from "src/types/AssetId.sol";
import {D18} from "src/types/D18.sol";

import {Conversion} from "src/libraries/Conversion.sol";

import {IBaseValuation} from "src/interfaces/IBaseValuation.sol";
import {IERC6909MetadataExt} from "src/interfaces/ERC6909/IERC6909MetadataExt.sol";

import {Auth} from "src/Auth.sol";

abstract contract BaseValuation is Auth, IBaseValuation {
    /// @notice ERC6909 dependency.
    IERC6909MetadataExt public erc6909;

    constructor(IERC6909MetadataExt erc6909_, address deployer) Auth(deployer) {
        erc6909 = erc6909_;
    }

    /// @inheritdoc IBaseValuation
    function file(bytes32 what, address data) external auth {
        if (what == "erc6909") erc6909 = IERC6909MetadataExt(data);
        else revert FileUnrecognizedWhat();

        emit File(what, data);
    }

    /// @notice Obtain the correct decimals given an asset address
    function _getDecimals(address asset) internal view returns (uint8) {
        return erc6909.decimals(uint160(asset));
    }
}
