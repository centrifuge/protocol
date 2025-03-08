// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {BaseSetup} from "@chimera/BaseSetup.sol";
import {vm} from "@chimera/Hevm.sol";
import {EnumerableSet} from "./EnumerableSet.sol";

abstract contract ActorManager {
    using EnumerableSet for EnumerableSet.AddressSet;

    address private _actor;
    address private _defaultActor;

    EnumerableSet.AddressSet private _actors;

    // If the current target is address(0) then it has not been setup yet and should revert
    error ActorNotSetup();
    // Do not allow duplicates
    error ActorExists();
    // If the actor does not exist
    error ActorNotAdded();
    // Do not allow the default actor
    error DefaultActor();

    // TODO: We have defined the library
    // But we need to make this more explicit
    // So it's very clean in the story what's going on

    constructor() {
        // address(this) is initially set as the default actor
        _actors.add(address(this));
        _defaultActor = address(this);
        _actor = address(this);
    }

    modifier useActor() {
        vm.prank(_getActor());
        _;
    }

    // use this function to get the current active actor
    function _getActor() internal view returns (address) {
        return _actor;
    }

    // returns an actor different from the currently set one
    function _getDifferentActor() internal view returns (address differentActor) {
        address[] memory actors_ = _getActors();
        for (uint256 i; i < actors_.length; i++) {
            if (actors_[i] != _actor) {
                differentActor = actors_[i];
            }
        }
    }

    function _getRandomActor(uint256 entropy) internal view returns (address randomActor) {
        address[] memory actorsArray = _getActors();
        randomActor = actorsArray[entropy % actorsArray.length];
    }

    // Get regular users
    function _getActors() internal view returns (address[] memory) {
        return _actors.values();
    }

    function _enableActor(address target) internal {
        _actor = target;
    }

    function _addActor(address target) internal {
        if (_actors.contains(target)) {
            revert ActorExists();
        }

        // if (target == _defaultActor) {
        //     revert DefaultActor();
        // }

        _actors.add(target);
    }

    function _removeActor(address target) internal {
        if (!_actors.contains(target)) {
            revert ActorNotAdded();
        }

        // if (target == _defaultActor) {
        //     revert DefaultActor();
        // }

        _actors.remove(target);
    }

    /// @notice Set the default actor to the target actor
    /// @notice This is useful for forked testing where the default address(this) normally used as the admin actor can't
    /// be given admin privileges in the setup
    /// @param target The address of the new default actor
    function _setDefaultActor(address target) internal {
        // remove the current default actor
        _actors.remove(_defaultActor);
        // set the new default actor
        _defaultActor = target;
        // enable the new default actor as the current actor
        _enableActor(target);
    }

    // Note: expose this function _in `TargetFunctions` for actor switching
    function _switchActor(uint256 entropy) internal {
        address target = _actors.at(entropy % _actors.length());
        _enableActor(target);
    }
}
