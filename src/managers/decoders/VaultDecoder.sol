// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseDecoder} from "src/managers/decoders/BaseDecoder.sol";

contract VaultDecoder is BaseDecoder {
    // @desc deposit into the ERC4626 vault
    // @tag receiver:address:the address of the receiver of the vault tokens
    function deposit(uint256, address receiver) external view virtual returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(receiver);
    }

    // @desc mint tokens from the ERC4626 vault
    // @tag receiver:address:the address of the receiver of the vault tokens
    function mint(uint256, address receiver) external pure virtual returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(receiver);
    }

    // @desc withdraw tokens from the ERC4626 vault
    // @tag receiver:address:the address of the receiver of the vault tokens
    // @tag owner:address:the address of the owner of the vault tokens
    function withdraw(uint256, address receiver, address owner)
        external
        view
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(receiver, owner);
    }

    // @desc redeem tokens from the ERC4626 vault
    // @tag receiver:address:the address of the receiver of the vault tokens
    // @tag owner:address:the address of the owner of the vault tokens
    function redeem(uint256, address receiver, address owner)
        external
        view
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(receiver, owner);
    }

    // @desc submit deposit request into the ERC7540 vault
    // @tag controller:address:the address of the controller of the request
    // @tag owner:address:the address of the owner of the assets
    function requestDeposit(uint256, address controller, address owner)
        external
        view
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(controller, owner);
    }

    // @desc submit redeem request into the ERC7540 vault
    // @tag controller:address:the address of the controller of the request
    // @tag owner:address:the address of the owner of the shares
    function requestRedeem(uint256, address controller, address owner)
        external
        view
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(controller, owner);
    }

    // @desc cancel deposit request into the ERC7887 vault
    // @tag controller:address:the address of the controller of the request
    function cancelDepositRequest(uint256, address controller)
        external
        view
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(controller);
    }

    // @desc cancel redeem request into the ERC7887 vault
    // @tag controller:address:the address of the controller of the request
    function cancelRedeemRequest(uint256, address controller)
        external
        view
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(controller);
    }
}
