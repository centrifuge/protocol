// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

// NOTE: understand this file as a backlog for interfaces that do not have an specific file yet (but should).

interface IERC6909 {
    function transfer(address receiver, uint256 id, uint256 amount) external returns (bool success);
    function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
        external
        returns (bool success);
}

interface IERC7726 {
    function getQuote(uint256 baseAmount, address base, address quote) external view returns (uint256 quoteAmount);
    function getIndicativeQuote(uint256 baseAmount, address base, address quote)
        external
        view
        returns (uint256 quoteAmount);
}

interface IPoolRegistry {
    function currencyOfPool(uint64 poolId) external view returns (address currency);
}

interface ILinearAccrual {
    function increaseNormalizedDebt(bytes32 rateId, uint128 prevNormalizedDebt, uint128 increment)
        external
        returns (uint128 newNormalizedDebt);

    function decreaseNormalizedDebt(bytes32 rateId, uint128 prevNormalizedDebt, uint128 decrement)
        external
        returns (uint128 newNormalizedDebt);

    function renormalizeDebt(bytes32 rateId, bytes32 newRateId, uint128 prevNormalizedDebt)
        external
        returns (uint128 newNormalizedDebt);

    function debt(bytes32 rateId, uint128 normalizedDebt) external view returns (uint128 debt);
}
