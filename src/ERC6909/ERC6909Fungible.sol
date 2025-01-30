// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Auth} from "src/Auth.sol";
import {ERC6909} from "src/ERC6909/ERC6909.sol";
import {IERC6909Fungible} from "src/interfaces/ERC6909/IERC6909Fungible.sol";
import {IERC6909TotalSupplyExt} from "src/interfaces/ERC6909/IERC6909TotalSupplyExt.sol";

contract ERC6909Fungible is IERC6909Fungible, IERC6909TotalSupplyExt, ERC6909, Auth {
    mapping(uint256 => uint256) public totalSupply;

    constructor(address _owner) Auth(_owner) {}

    /// @inheritdoc IERC6909Fungible
    function mint(address owner, uint256 tokenId, uint256 amount) external auth {
        _mint(owner, tokenId, amount);

        totalSupply[tokenId] += amount;
    }

    /// @inheritdoc IERC6909Fungible
    function burn(address owner, uint256 tokenId, uint256 amount) external auth {
        _burn(owner, tokenId, amount);

        // totalSupply is the sum of all balances.
        unchecked {
            totalSupply[tokenId] -= amount;
        }
    }

    /// @inheritdoc IERC6909Fungible
    function authTransferFrom(address spender, address sender, address receiver, uint256 tokenId, uint256 amount)
        external
        auth
        returns (bool)
    {
        return _transferFrom(spender, sender, receiver, tokenId, amount);
    }
}
