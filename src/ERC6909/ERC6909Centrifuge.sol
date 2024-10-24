// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import "src/ERC6909/ERC6909Errors.sol";
import {ERC6909} from "src/ERC6909/ERC6909.sol";
import {StringLib} from "src/libraries/StringLib.sol";
import {Auth} from "src/Auth.sol";
import {IERC6909Centrifuge} from "src/interfaces/ERC6909/IERC6909Centrifuge.sol";
import {IERC6909URIExtension} from "src/interfaces/ERC6909/IERC6909URIExtension.sol";

contract ERC6909Centrifuge is IERC6909Centrifuge, ERC6909, Auth {
    using StringLib for string;
    using StringLib for uint256;

    uint8 public constant MIN_DECIMALS = 2;

    uint256 public latestTokenId;

    /// @inheritdoc IERC6909URIExtension
    string public contractURI;
    /// @inheritdoc IERC6909URIExtension
    mapping(uint256 tokenId => string URI) public tokenURI;
    /// @inheritdoc IERC6909Centrifuge
    mapping(uint256 tokenId => uint256 total) public totalSupply;

    constructor(address _owner) Auth(_owner) {}

    /// @inheritdoc IERC6909Centrifuge
    function setTokenURI(uint256 _tokenId, string memory _URI) public auth {
        tokenURI[_tokenId] = _URI;

        emit TokenURI(_tokenId, _URI);
    }

    /// @inheritdoc IERC6909Centrifuge
    function mint(address _owner, string memory _tokenURI, uint256 _amount) public auth returns (uint256 _tokenId) {
        require(_owner != address(0), ERC6909Centrifuge_Mint_EmptyOwner());
        require(!_tokenURI.isEmpty(), ERC6909Centrifuge_Mint_EmptyURI());
        require(_amount > 0, ERC6909Centrifuge_Mint_EmptyAmount());

        _tokenId = ++latestTokenId;

        balanceOf[_owner][_tokenId] = _amount;

        totalSupply[_tokenId] = _amount;

        setTokenURI(_tokenId, _tokenURI);

        emit Transfer(msg.sender, address(0), _owner, _tokenId, _amount);
    }

    /// @inheritdoc IERC6909Centrifuge
    function mint(address _owner, uint256 _tokenId, uint256 _amount) public auth returns (uint256) {
        uint256 balance = balanceOf[_owner][_tokenId];
        require(_tokenId <= latestTokenId, ERC6909Centrifuge_Mint_UnknownTokenId(_owner, _tokenId));

        unchecked {
            uint256 totalSupply_ = totalSupply[_tokenId];
            uint256 newSupply = totalSupply_ + _amount;
            require(newSupply >= totalSupply_, ERC6909Centrifuge_Mint_MaxSupplyReached());
            totalSupply[_tokenId] = newSupply;
        }

        uint256 newBalance = balance + _amount;
        balanceOf[_owner][_tokenId] = newBalance;

        emit Transfer(msg.sender, address(0), _owner, _tokenId, _amount);

        return newBalance;
    }

    /// @inheritdoc IERC6909Centrifuge
    function burn(uint256 _tokenId, uint256 _amount) external returns (uint256) {
        address _owner = msg.sender;
        uint256 _balance = balanceOf[msg.sender][_tokenId];
        require(_balance >= _amount, ERC6909Centrifuge_Burn_InsufficientBalance(msg.sender, _tokenId));

        /// @dev    The require check above guarantees that you cannot burn more than you have.
        unchecked {
            _balance -= _amount;
        }

        /// @dev    The sum of all balances MUST be equal to totalSupply.
        ///         The require check above means you cannot burn more than the balance hence cannot underflow.
        unchecked {
            totalSupply[_tokenId] -= _amount;
        }

        balanceOf[msg.sender][_tokenId] = _balance;

        emit Transfer(msg.sender, _owner, address(0), _tokenId, _amount);

        return _balance;
    }

    // @inheritdoc IERC6909Centrifuge
    function setContractURI(string calldata _URI) external auth {
        contractURI = _URI;

        emit ContractURI(address(this), _URI);
    }
}
