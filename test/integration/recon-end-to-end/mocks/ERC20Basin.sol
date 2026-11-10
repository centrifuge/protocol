// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "../../../../src/misc/ERC20.sol";

import {IGroveBasinLike} from "../../../../src/vaults/liquidity/interfaces/IBasinLiquidityRoute.sol";

/// @dev Stands in for the Grove basin with a real token balance. What it advertises and what it can pay
///      are set separately, so the fuzzer can make a quote the venue then fails to honour.
contract ERC20Basin is IGroveBasinLike {
    ERC20 public immutable asset;
    address public immutable liquidityProvider;
    uint256 public advertised;

    constructor(ERC20 asset_, address liquidityProvider_) {
        asset = asset_;
        liquidityProvider = liquidityProvider_;
    }

    function advertise(uint256 amount) external {
        advertised = amount;
    }

    function previewWithdraw(address, uint256 max) external view returns (uint256, uint256) {
        uint256 assets = advertised < max ? advertised : max;
        return (assets, assets);
    }

    function withdraw(address, address receiver, uint256 max) external returns (uint256 paid) {
        uint256 balance = asset.balanceOf(address(this));
        paid = balance < max ? balance : max;
        asset.transfer(receiver, paid);
    }
}
