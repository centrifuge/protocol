// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IManifest} from "../../interfaces/ISupervisor.sol";

interface IDefaultManifest is IManifest {
    error NotAuthorized();
    error CannotRemoveSupervisor();

    function supervisor() external view returns (address);
    function grantManagerDelay() external view returns (uint48);
}
