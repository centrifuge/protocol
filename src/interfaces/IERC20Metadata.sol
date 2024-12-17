// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IERC20Metadata {
    function decimals() external returns (uint8);
    function name() external returns (string calldata);
    function symbol() external returns (string calldata);
}
