// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC6909} from "src/misc/ERC6909.sol";
import {StringLib} from "src/misc/libraries/StringLib.sol";
import {Auth} from "src/misc/Auth.sol";
import {IERC6909NFT, IERC6909URIExt} from "src/misc/interfaces/IERC6909.sol";

contract ERC6909NFT is ERC6909, Auth, IERC6909NFT {
    using StringLib for string;

    uint8 constant MAX_SUPPLY = 1;

    uint256 public latestTokenId;

    /// @inheritdoc IERC6909URIExt
    string public contractURI;
    /// @inheritdoc IERC6909URIExt
    mapping(uint256 tokenId => string URI) public tokenURI;

    constructor(address deployer) Auth(deployer) {}

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
