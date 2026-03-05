// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IERC6909ExclOperator, IERC6909MetadataExt} from "../../../misc/interfaces/IERC6909.sol";

import {PoolId} from "../../../core/types/PoolId.sol";

import {IExecutorFactory} from "./IExecutorFactory.sol";

interface IReceiptToken is IERC6909ExclOperator, IERC6909MetadataExt {
    error NotPoolExecutor();

    /// @notice The ExecutorFactory that tracks executor deployments.
    function factory() external view returns (IExecutorFactory);

    /// @notice Mint new tokens for a specific tokenId and assign them to an owner.
    function mint(address owner, uint256 tokenId, uint256 amount) external;

    /// @notice Destroy supply of a given tokenId by amount.
    function burn(address owner, uint256 tokenId, uint256 amount) external;

    /// @notice Compute the ERC6909 token ID for a pool + asset pair.
    /// @param poolId Pool identifier (uint64).
    /// @param asset  Asset address.
    /// @return id    Token ID encoding both pool and asset.
    function toTokenId(PoolId poolId, address asset) external pure returns (uint256 id);
}
