// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

address constant ETH_ADDRESS = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

interface IRecoverable {
    /// @notice Used to recover any ERC-20 token.
    /// @dev    This method is called only by authorized entities
    /// @param  token It could be 0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
    ///         to recover locked native ETH or token compatible with ERC20.
    /// @param  to Receiver of the funds
    /// @param  amount Amount to send to the receiver.
    function recoverTokens(address token, address to, uint256 amount) external;

    /// @notice Used to recover any ERC-20 or ERC-6909 token.
    /// @dev    This method is called only by authorized entities
    /// @param  token It could be 0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
    ///         to recover locked native ETH or token compatible with ERC20 or ERC6909.
    /// @param  tokenId The token id, i.e. non-zero if the underlying token is ERC6909 and else zero.
    /// @param  to Receiver of the funds
    /// @param  amount Amount to send to the receiver.
    function recoverTokens(address token, uint256 tokenId, address to, uint256 amount) external;
}
