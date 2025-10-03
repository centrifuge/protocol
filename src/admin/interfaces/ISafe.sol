// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

interface ISafe {
    function isOwner(address signer) external view returns (bool);
}
