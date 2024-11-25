// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC6909} from "src/ERC6909/ERC6909.sol";
import {StringLib} from "src/libraries/StringLib.sol";
import {Auth} from "src/Auth.sol";
import {IERC6909NFT} from "src/interfaces/ERC6909/IERC6909NFT.sol";
import {IERC6909URIExtension} from "src/interfaces/ERC6909/IERC6909URIExtension.sol";

contract ERC6909NFT is IERC6909NFT, ERC6909, Auth {
    using StringLib for string;

    uint8 constant MAX_SUPPLY = 1;

    uint256 public latestTokenId;

    /// @inheritdoc IERC6909URIExtension
    string public contractURI;
    /// @inheritdoc IERC6909URIExtension
    mapping(uint256 tokenId => string URI) public tokenURI;

    constructor(address _owner) Auth(_owner) {}

    /// @inheritdoc IERC6909NFT
    function setTokenURI(uint256 tokenId, string memory URI) public auth {
        tokenURI[tokenId] = URI;

        emit TokenURISet(tokenId, URI);
    }

    /// @inheritdoc IERC6909NFT
    function mint(address owner, string memory tokenURI_) public auth returns (uint256 tokenId) {
        require(!tokenURI_.isEmpty(), EmptyURI());

        tokenId = ++latestTokenId;

        _mint(owner, tokenId, MAX_SUPPLY);

        setTokenURI(tokenId, tokenURI_);
    }

    /// @inheritdoc IERC6909NFT
    function burn(uint256 tokenId) external {
        _burn(msg.sender, tokenId, 1);
    }

    // @inheritdoc IERC6909NFT
    function setContractURI(string calldata URI) external auth {
        contractURI = URI;

        emit ContractURISet(address(this), URI);
    }
}
