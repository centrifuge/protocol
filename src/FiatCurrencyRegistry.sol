// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Currency} from "src/types/Currency.sol";
import {AddressLib} from "src/libraries/AddressLib.sol";

interface IFiatCurrencyRegistry {
    error IncompatibleAddress();

    function currencies(address target) external returns (address, uint8, string memory, string memory);

    function register(Currency calldata currency) external;

    function register(address addr, uint8 decimals, string calldata name, string calldata symbol) external;
}

contract FiatCurrencyRegistry is IFiatCurrencyRegistry {
    using AddressLib for address;

    mapping(address => Currency) public currencies;

    function register(Currency calldata currency) external {
        currencies[currency.addr] = currency;
    }

    function register(address addr, uint8 decimals, string calldata name, string calldata symbol) external {
        require(!addr.isContract(), IncompatibleAddress());

        currencies[addr] = Currency(addr, decimals, name, symbol);
    }
}
