// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IInvestorPermissions} from "src/interfaces/IInvestorPermissions.sol";
import {Auth} from "src/Auth.sol";

struct InvestorPermission {
    uint64 validUntil;
    bool frozen;
}

// TODO(@wischli): Write tests
contract InvestorPermissions is Auth, IInvestorPermissions {
    // @dev: Value for until is arbitrary because we ignore it for now but need to distinguish between default and
    // non-default storage entries
    uint64 private constant _DEFAUL_VALIDITY = type(uint64).max;

    mapping(bytes16 shareClassId => mapping(address user => InvestorPermission)) public permissions;

    constructor(address deployer) Auth(deployer) {}

    function add(bytes16 shareClassId, address target) external {
        permissions[shareClassId][target] = InvestorPermission(_DEFAUL_VALIDITY, false);

        emit IInvestorPermissions.Added(shareClassId, target);
    }

    function remove(bytes16 shareClassId, address target) external {
        delete permissions[shareClassId][target];

        emit IInvestorPermissions.Removed(shareClassId, target);
    }

    function freeze(bytes16 shareClassId, address target) external {
        InvestorPermission storage perm = permissions[shareClassId][target];

        require(perm.validUntil == _DEFAUL_VALIDITY, IInvestorPermissions.Missing());
        require(perm.frozen == false, AlreadyFrozen());

        perm.frozen = true;

        emit IInvestorPermissions.Frozen(shareClassId, target);
    }

    function unfreeze(bytes16 shareClassId, address target) external {
        InvestorPermission storage perm = permissions[shareClassId][target];

        require(perm.validUntil == _DEFAUL_VALIDITY, IInvestorPermissions.Missing());
        require(perm.frozen == true, NotFrozen());

        permissions[shareClassId][target].frozen = false;

        emit IInvestorPermissions.Unfrozen(shareClassId, target);
    }

    function isFrozenInvestor(bytes16 shareClassId, address target) public view returns (bool) {
        InvestorPermission memory perm = permissions[shareClassId][target];

        return perm.validUntil == _DEFAUL_VALIDITY && perm.frozen == true;
    }

    function isUnfrozenInvestor(bytes16 shareClassId, address target) public view returns (bool) {
        InvestorPermission memory perm = permissions[shareClassId][target];
        return perm.validUntil == _DEFAUL_VALIDITY && perm.frozen == false;
    }
}
