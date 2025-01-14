// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IERC20Metadata {
    function decimals() external view returns (uint8);
    function name() external view returns (string calldata);
    function symbol() external view returns (string calldata);
}
