// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";

import {IBaseValuation} from "src/common/interfaces/IBaseValuation.sol";
import {IERC6909Decimals} from "src/misc/interfaces/IERC6909.sol";
import {AssetId} from "src/common/types/AssetId.sol";

abstract contract BaseValuation is Auth, IBaseValuation {
    /// @notice ERC6909 dependency.
    IERC6909Decimals public erc6909;

    constructor(IERC6909Decimals erc6909_, address deployer) Auth(deployer) {
        erc6909 = erc6909_;
    }

    /// @inheritdoc IBaseValuation
    function file(bytes32 what, address data) external auth {
        if (what == "erc6909") erc6909 = IERC6909Decimals(data);
        else revert FileUnrecognizedParam();

        emit File(what, data);
    }

    /// @notice Obtain the correct decimals given an asset address
    function _getDecimals(AssetId asset) internal view returns (uint8) {
        return erc6909.decimals(asset.raw());
    }
}
