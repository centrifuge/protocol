// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import "src/ERC6909/ERC6909Errors.sol";
import {ERC6909} from "src/ERC6909/ERC6909.sol";
import {StringLib} from "src/libraries/StringLib.sol";
import {Auth} from "src/Auth.sol";
import {IERC6909URIExtension} from "src/interfaces/ERC6909/IERC6909URIExtension.sol";
import {IERC6909MetadataExtension} from "src/interfaces/ERC6909/IERC6909MetadataExtension.sol";
import {OverflowUint256} from "src/Errors.sol";

contract ERC6909Collateral is Auth, ERC6909, IERC6909URIExtension, IERC6909MetadataExtension {
    using StringLib for string;
    using StringLib for uint256;

    uint8 public constant MIN_DECIMALS = 2;

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

    mapping(uint256 tokenId => uint256 total) public totalSupply;

    constructor(address _owner) Auth(_owner) {}

    /// @notice             Provide URI for a specific tokenId.
    /// @param _URI         URI to a document defining the collection as a whole.
    function setTokenURI(uint256 _tokenId, string memory _URI) public auth {
        tokenURI[_tokenId] = _URI;

        emit TokenURI(_tokenId, _URI);
    }

    /// @dev                For non-fungible tokens, call with amount = 1, for fungible it could be any amount
    ///
    /// @param _owner       Creates suppy of a given _tokenId by _amount for _owner
    /// @param _tokenURI    URI fortestBurningToken the newly minted token
    /// @param _amount      Amount of newly created supply
    /// @return _tokenId    Id of the newly minted token
    function mint(address _owner, string memory _tokenURI, uint256 _amount) public auth returns (uint256 _tokenId) {
        require(_owner != address(0), ERC6909Collateral_Mint_EmptyOwner());
        require(!_tokenURI.isEmpty(), ERC6909Collateral_Mint_EmptyURI());
        require(_amount > 0, ERC6909Collateral_Mint_EmptyAmount());

        _tokenId = ++latestTokenId;

        balanceOf[_owner][_tokenId] = _amount;

        totalSupply[_tokenId] = _amount;

        setTokenURI(_tokenId, _tokenURI);

        emit Transfer(msg.sender, address(0), _owner, _tokenId, _amount);
    }

    /// @dev                Used to increase the supply for a given _tokenId
    ///
    /// @param _owner       Creates suppy of a given _tokenId by _amount for _owner
    /// @param _tokenId     The token id  of the item which supply will be increased
    /// @param _amount      Amount by which the supply for _tokenId of _owner is increase by
    /// @return             New supply of item with _tokenId
    function mint(address _owner, uint256 _tokenId, uint256 _amount) public auth returns (uint256) {
        uint256 balance = balanceOf[_owner][_tokenId];
        require(_tokenId <= latestTokenId, ERC6909Collateral_Mint_UnknownTokenId(_owner, _tokenId));

        unchecked {
            uint256 totalSupply_ = totalSupply[_tokenId];
            require(totalSupply_ + _amount >= totalSupply_, OverflowUint256(totalSupply_, _amount));
        }

        uint256 newBalance = balance + _amount;
        balanceOf[_owner][_tokenId] = newBalance;

        emit Transfer(msg.sender, address(0), _owner, _tokenId, _amount);

        return newBalance;
    }

    /// @notice             Destroy supply of a given _tokenId by _amount for _owner
    ///
    /// @param _owner       Owner of the item
    /// @param _tokenId     Item which have reduced supply
    /// @param _amount      Amount to be burnt
    /// @return             Amount that is left after burning the _amount tokens
    function burn(address _owner, uint256 _tokenId, uint256 _amount) external auth returns (uint256) {
        uint256 _balance = balanceOf[_owner][_tokenId];
        require(_balance >= _amount, ERC6909Collateral_Burn_InsufficientBalance(_owner, _tokenId));

        /// @dev    The require check above guarantees that you cannot burn more than you have.
        unchecked {
            _balance -= _amount;
        }

        /// @dev    The sum of all balances MUST be equal to totalSupply.
        ///         The require check above means you cannot burn more than the balance hence cannot underflow.
        unchecked {
            totalSupply[_tokenId] -= _amount;
        }

        balanceOf[_owner][_tokenId] = _balance;

        emit Transfer(msg.sender, _owner, address(0), _tokenId, _amount);

        return _balance;
    }

    /// @dev                Optional method to set up the contract URI if needed.
    /// @param _URI         URI to a document defining the collection as a whole.
    function setContractURI(string calldata _URI) external auth {
        contractURI = _URI;

        emit ContractURI(address(this), _URI);
    }

    function setName(uint256 _tokenId, string calldata _name) external auth {
        name[_tokenId] = _name;
    }

    function setSymbol(uint256 _tokenId, string calldata _symbol) external auth {
        symbol[_tokenId] = _symbol;
    }

    function setDecimals(uint256 _tokenId, uint8 _decimals) external auth {
        require(_decimals >= MIN_DECIMALS, ERC6909Collateral_SetDecimal_LessThanMinimalDecimal(MIN_DECIMALS, _decimals));
        decimals[_tokenId] = _decimals;
    }
}
