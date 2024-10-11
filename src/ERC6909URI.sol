// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IERC6909URIExtension} from "src/interfaces/IERC6909URIExtension.sol";
import {StringLib} from "src/libraries/StringLib.sol";

abstract contract ERC6909URI is IERC6909URIExtension {
    using StringLib for string;

    /// @inheritdoc IERC6909URIExtension
    string public contractURI;

    /// @inheritdoc IERC6909URIExtension
    mapping(uint256 tokenId => string URI) public tokenURI;

    /// @dev        Optional method to set up the contract URI if needed.
    ///             Cannot be an empty string;
    /// @param URI  URI to a document defining the collection as a whole.
    function _setContractURI(string memory URI) internal virtual {
        require(!URI.isEmpty(), MissingContractURI());
        contractURI = URI;

        emit ContractURI(address(this), URI);
    }

    /// @notice     Provide URI specific to a particular tokenId.
    /// @param URI  URI to a document defining the collection as a whole.
    function _setTokenURI(uint256 tokenId, string memory URI) internal virtual {
        require(!URI.isEmpty(), MissingTokenURI(tokenId));
        tokenURI[tokenId] = URI;

        emit TokenURI(tokenId, URI);
    }
}
