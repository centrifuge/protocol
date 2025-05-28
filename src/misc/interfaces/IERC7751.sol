// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

/// [ERC-7751](https://eips.ethereum.org/EIPS/eip-7751): Wrapping of bubbled up reverts
/// Handling bubbled up reverts using custom errors with additional context.
interface IERC7751 {
    error WrappedError(address target, bytes4 selector, bytes reason, bytes details);
}
