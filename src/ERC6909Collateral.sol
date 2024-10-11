// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {ERC6909URI} from "src/ERC6909URI.sol";
import {ERC6909Metadata} from "src/ERC6909Metadata.sol";
import {ERC6909} from "src/ERC6909.sol";
import {StringLib} from "src/libraries/StringLib.sol";
import {Auth} from "src/Auth.sol";

contract ERC6909Collateral is Auth, ERC6909, ERC6909URI {
    using StringLib for string;
    using StringLib for uint256;

    /// Errors
    error MissingBaseURI();

    /// Events
    event BaseURI(address indexed target, string URI);

    /// @notice     Used as base URI for token URI
    /// @dev        Use the tokenId to concatenate at the end of the baseURI
    string public baseURI;

    uint256 public latestTokenId;

    constructor(address _owner, string memory _baseURI) Auth(_owner) {
        if (!_baseURI.isEmpty()) {
            baseURI = _baseURI;
        }
    }

    /// @dev    Call for non-fungible tokens
    function mint(address receiver, uint256 tokenId) external auth {
        _mint(receiver, tokenId, 1);
    }

    /// @dev    Call for fungible tokens
    function mint(address receiver, uint256 tokenId, uint256 amount) external auth {
        _mint(receiver, tokenId, amount);
    }

    function _burn(address sender, uint256 tokenId, uint256 amount) external auth {
        balanceOf[sender][tokenId] -= amount;

        emit Transfer(msg.sender, sender, address(0), tokenId, amount);
    }

    function setBaseURI(string calldata URI) external auth returns (bool) {
        require(!URI.isEmpty(), MissingBaseURI());
        baseURI = URI;

        emit BaseURI(address(this), URI);

        return true;
    }

    function setContractURI(string calldata URI) external auth {
        _setContractURI(URI);
    }

    function _mint(address receiver, uint256 tokenId, uint256 amount) internal {
        require(!baseURI.isEmpty(), MissingBaseURI());

        _setTokenURI(tokenId, string.concat(baseURI, (++latestTokenId).toString()));

        balanceOf[receiver][tokenId] += amount;

        emit Transfer(msg.sender, address(0), receiver, tokenId, amount);
    }
}
