// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IERC6909MetadataExtension} from "src/interfaces/IERC6909MetadataExtension.sol";
import {StringLib} from "src/libraries/StringLib.sol";
import {Auth} from "src/Auth.sol";

abstract contract ERC6909Metadata is IERC6909MetadataExtension, Auth {
    using StringLib for string;

    mapping(uint256 tokenId => string name) public name;
    mapping(uint256 tokenId => string symbol) public symbol;
    mapping(uint256 tokenId => uint8 decimals) public decimals;

    // TODO: Do we want to apply some limit to the name?
    function _setName(uint256 _tokenId, string calldata _name) internal virtual auth {
        require(!_name.isEmpty(), MissingName(_tokenId));
        name[_tokenId] = _name;
    }

    // TODO: Do we want to apply some limit to the symbol?
    function _setSymbol(uint256 _tokenId, string calldata _symbol) internal virtual auth {
        require(!_symbol.isEmpty(), MissingSymbol(_tokenId));
        symbol[_tokenId] = _symbol;
    }

    function _setSymbol(uint256 _tokenId, uint8 _decimals) internal virtual auth {
        require(_decimals > 0, MissingDecimals(_tokenId));
        decimals[_tokenId] = _decimals;
    }
}
