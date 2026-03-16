// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IERC6909ExclOperator, IERC6909MetadataExt} from "../../../misc/interfaces/IERC6909.sol";

import {PoolId} from "../../../core/types/PoolId.sol";
import {ShareClassId} from "../../../core/types/ShareClassId.sol";
import {ITrustedContractUpdate} from "../../../core/utils/interfaces/IContractUpdate.sol";

interface IAccountingToken is IERC6909ExclOperator, IERC6909MetadataExt, ITrustedContractUpdate {
    event UpdateMinter(PoolId indexed poolId, address indexed minter, bool canMint);
    event Mint(
        PoolId indexed poolId, ShareClassId indexed scId, address indexed owner, uint256 tokenId, uint256 amount
    );
    event Burn(
        PoolId indexed poolId, ShareClassId indexed scId, address indexed owner, uint256 tokenId, uint256 amount
    );

    error NotMinter();

    /// @notice The ContractUpdater that manages minter permissions.
    function contractUpdater() external view returns (address);

    /// @notice Whether an address is an authorized minter for a pool.
    function minters(PoolId poolId, address who) external view returns (bool);

    /// @notice Mint new tokens for a specific tokenId and assign them to an owner.
    function mint(address owner, uint256 tokenId, uint256 amount, ShareClassId scId) external;

    /// @notice Destroy supply of a given tokenId by amount.
    function burn(address owner, uint256 tokenId, uint256 amount, ShareClassId scId) external;

    /// @notice Compute the ERC6909 token ID for a pool + asset pair.
    /// @param poolId    Pool identifier (uint64).
    /// @param asset     Asset address.
    /// @param liability Whether this is a liability token.
    /// @return id       Token ID encoding pool, asset, and liability flag.
    function toTokenId(PoolId poolId, address asset, bool liability) external pure returns (uint256 id);

    /// @notice Whether a token ID represents a liability.
    function isLiability(uint256 tokenId) external pure returns (bool);
}
