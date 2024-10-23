// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

// NOTE: understand this file as a backlog for interfaces that do not have an specific file yet (but should).

interface IERC6909 {
    function transfer(address receiver, uint256 id, uint256 amount) external returns (bool success);
    function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
        external
        returns (bool success);
    function decimals(uint256 tokenId) external view returns (uint8);
    function balanceOf(address owner, uint256 id) external returns (uint256 amount);
}

interface IERC7726 {
    function getQuote(uint256 baseAmount, address base, address quote) external view returns (uint256 quoteAmount);
}

interface IPoolRegistry {
    function currencyOfPool(uint64 poolId) external view returns (address currency);
}

interface ILinearAccrual {
    function modifyNormalizedDebt(bytes32 rateId, int128 prevNormalizedDebt, int128 increment)
        external
        returns (int128 newNormalizedDebt);

    function renormalizeDebt(bytes32 rateId, bytes32 newRateId, int128 prevNormalizedDebt)
        external
        returns (int128 newNormalizedDebt);

    function debt(bytes32 rateId, int128 normalizedDebt) external view returns (int128 debt);
}
