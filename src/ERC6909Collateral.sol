// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {ERC6909} from "src/ERC6909.sol";
import {StringLib} from "src/libraries/StringLib.sol";
import {Auth} from "src/Auth.sol";
import {IERC6909URIExtension} from "src/interfaces/IERC6909URIExtension.sol";
import {IERC6909MetadataExtension} from "src/interfaces/IERC6909MetadataExtension.sol";

contract ERC6909Collateral is Auth, ERC6909, IERC6909URIExtension, IERC6909MetadataExtension {
    using StringLib for string;
    using StringLib for uint256;

    uint256 public latestTokenId;

    /// @inheritdoc IERC6909URIExtension
    string public contractURI;
    /// @inheritdoc IERC6909URIExtension
    mapping(uint256 tokenId => string URI) public tokenURI;
    /// @inheritdoc IERC6909MetadataExtension
    mapping(uint256 tokenId => string name) public name;
    /// @inheritdoc IERC6909MetadataExtension
    mapping(uint256 tokenId => string symbol) public symbol;
    /// @inheritdoc IERC6909MetadataExtension
    mapping(uint256 tokenId => uint8 decimals) public decimals;

    constructor(address _owner) Auth(_owner) {}

    /// @notice             Provide URI specific to a particular tokenId.
    /// @param _URI         URI to a document defining the collection as a whole.
    function _setTokenURI(uint256 tokenId, string memory _URI) internal virtual {
        require(!_URI.isEmpty(), MissingTokenURI(tokenId));
        tokenURI[tokenId] = _URI;

        emit TokenURI(tokenId, _URI);
    }

    /// @notice             Adds supply
    /// @dev                Call for non-fungible tokens
    function mint(address _owner, string calldata _tokenURI) external auth {
        mint(_owner, _tokenURI, 1);
    }

    /// @dev                Call for fungible tokens
    ///
    /// @param _owner       Creates suppy of a given _tokenId by _amount for _owner
    /// @param _tokenURI    URI pointing to the metadata for the newly created item
    /// @param _amount      Amount of newly created supply
    function mint(address _owner, string calldata _tokenURI, uint256 _amount) public auth {
        uint256 _tokenId = latestTokenId++;

        _setTokenURI(_tokenId, _tokenURI);

        balanceOf[_owner][_tokenId] = _amount;

        emit Transfer(msg.sender, address(0), _owner, _tokenId, _amount);
    }

    /// @notice             Destroy supply of a given _tokenId by _amount for _owner
    ///
    /// @param _owner       Owner of the item
    /// @param _tokenId     Item which have reduced supply
    /// @param _amount      Amount to be burnt
    function burn(address _owner, uint256 _tokenId, uint256 _amount) external auth {
        uint256 _balance = balanceOf[_owner][_tokenId];
        require(_balance >= _amount, InsufficientBalance(_owner, _tokenId, _balance, _amount));

        balanceOf[_owner][_tokenId] -= _amount;

        emit Transfer(msg.sender, _owner, address(0), _tokenId, _amount);
    }

    /// @dev                Optional method to set up the contract URI if needed.
    ///                     Cannot be an empty string;
    /// @param _URI         URI to a document defining the collection as a whole.
    function setContractURI(string calldata _URI) external auth {
        require(!_URI.isEmpty(), MissingContractURI());
        contractURI = _URI;

        emit ContractURI(address(this), _URI);
    }

    // TODO: Do we want to apply some limit to the name?
    function setName(uint256 _tokenId, string calldata _name) public auth {
        require(!_name.isEmpty(), MissingName(_tokenId));
        name[_tokenId] = _name;
    }

    // TODO: Do we want to apply some limit to the symbol?
    function setSymbol(uint256 _tokenId, string calldata _symbol) public auth {
        require(!_symbol.isEmpty(), MissingSymbol(_tokenId));
        symbol[_tokenId] = _symbol;
    }

    function setSymbol(uint256 _tokenId, uint8 _decimals) public auth {
        require(_decimals > 0, MissingDecimals(_tokenId));
        decimals[_tokenId] = _decimals;
    }
}
