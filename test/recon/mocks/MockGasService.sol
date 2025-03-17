// SPDX-License-Identifier: GPL-2.0
pragma solidity 0.8.28;

contract MockGasService {

    /// --- Estimations ---
    function estimate(uint32, /*chainId*/ bytes calldata payload) public view returns (uint256) {
        // uses propMaxGas from echidna config
        return 12500000;
    }
}
