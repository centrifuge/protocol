// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {ERC6909} from "src/ERC6909/ERC6909.sol";
import {StringLib} from "src/libraries/StringLib.sol";
import {Auth} from "src/Auth.sol";
import {IERC6909Centrifuge} from "src/interfaces/ERC6909/IERC6909Centrifuge.sol";
import {IERC6909URIExtension} from "src/interfaces/ERC6909/IERC6909URIExtension.sol";

contract ERC6909Centrifuge is IERC6909Centrifuge, ERC6909, Auth {
    using StringLib for string;
    using StringLib for uint256;

    uint256 public latestTokenId;

    /// @inheritdoc IERC6909URIExtension
    string public contractURI;
    /// @inheritdoc IERC6909URIExtension
    mapping(uint256 tokenId => string URI) public tokenURI;
    /// @inheritdoc IERC6909Centrifuge
    mapping(uint256 tokenId => uint256 total) public totalSupply;

    constructor(address _owner) Auth(_owner) {}

    /// @inheritdoc IERC6909Centrifuge
    function setTokenURI(uint256 tokenId, string memory URI) public auth {
        tokenURI[tokenId] = URI;

        emit TokenURISet(tokenId, URI);
    }

    /// @inheritdoc IERC6909Centrifuge
    function mint(address owner, string memory tokenURI_, uint256 amount) public auth returns (uint256 tokenId) {
        require(owner != address(0), EmptyOwner());
        require(!tokenURI_.isEmpty(), EmptyURI());
        require(amount > 0, EmptyAmount());

        tokenId = ++latestTokenId;

        balanceOf[owner][tokenId] = amount;

        totalSupply[tokenId] = amount;

        setTokenURI(tokenId, tokenURI_);

        emit Transfer(msg.sender, address(0), owner, tokenId, amount);
    }

    /// @inheritdoc IERC6909Centrifuge
    function mint(address owner, uint256 tokenId, uint256 amount) public auth returns (uint256) {
        uint256 balance = balanceOf[owner][tokenId];
        require(tokenId <= latestTokenId, UnknownTokenId(owner, tokenId));

        unchecked {
            uint256 totalSupply_ = totalSupply[tokenId];
            uint256 newSupply = totalSupply_ + amount;
            require(newSupply >= totalSupply_, MaxSupplyReached());
            totalSupply[tokenId] = newSupply;
        }

        uint256 newBalance = balance + amount;
        balanceOf[owner][tokenId] = newBalance;

        emit Transfer(msg.sender, address(0), owner, tokenId, amount);

        return newBalance;
    }

    /// @inheritdoc IERC6909Centrifuge
    function burn(uint256 tokenId, uint256 amount) external returns (uint256) {
        uint256 balance = balanceOf[msg.sender][tokenId];
        require(balance >= amount, InsufficientBalance(msg.sender, tokenId));

        ///         The require check above guarantees that you cannot burn more than you have.
        unchecked {
            balance -= amount;
        }

        ///         The sum of all balances MUST be equal to totalSupply.
        ///         The require check above means you cannot burn more than the balance hence cannot underflow.
        unchecked {
            totalSupply[tokenId] -= amount;
        }

        balanceOf[msg.sender][tokenId] = balance;

        emit Transfer(msg.sender, msg.sender, address(0), tokenId, amount);

        return balance;
    }

    // @inheritdoc IERC6909Centrifuge
    function setContractURI(string calldata URI) external auth {
        contractURI = URI;

        emit ContractURISet(address(this), URI);
    }
}
