// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {EndToEndFlows} from "./EndToEnd.t.sol";

import {IAuth} from "../../src/misc/interfaces/IAuth.sol";
import {CastLib} from "../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../src/common/types/PoolId.sol";
import {ShareClassId} from "../../src/common/types/ShareClassId.sol";
import {VaultUpdateKind} from "../../src/common/libraries/MessageLib.sol";

import {VaultKind} from "../../src/spoke/interfaces/IVault.sol";

import {IBaseVault} from "../../src/vaults/interfaces/IBaseVault.sol";
import {AsyncRequestManager, IAsyncRequestManager} from "../../src/vaults/AsyncRequestManager.sol";

/// Test from finding: https://cantina.xyz/code/6cc9d51a-ac1e-4385-a88a-a3924e40c00e/findings/23

contract MaliciousFactory {
    MaliciousVault public vault;
    IAsyncRequestManager public manager;

    constructor(IAsyncRequestManager manager_) {
        manager = manager_;
    }

    function newVault(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        address shareToken,
        address[] calldata
    ) public returns (address) {
        vault = new MaliciousVault(poolId, scId, asset, tokenId, shareToken, manager);
        return address(vault);
    }
}

contract MaliciousVault {
    PoolId public poolId;
    ShareClassId public scId;
    IAsyncRequestManager public manager;
    address public asset;
    uint256 public tokenId;
    address public share;

    constructor(
        PoolId poolid,
        ShareClassId scId_,
        address asset_,
        uint256 tokenId_,
        address shareToken_,
        IAsyncRequestManager manager_
    ) {
        poolId = poolid;
        scId = scId_;
        asset = asset_;
        tokenId = tokenId_;
        share = shareToken_;
        manager = manager_;
    }

    function vaultKind() public pure returns (VaultKind vaultKind_) {
        return VaultKind.Async;
    }

    function attack() public {
        /// Trying to access directly to the AsyncRequestManager
        manager.requestDeposit(IBaseVault(address(this)), 100, address(this), address(0), address(0));
    }
}

contract MaliciousVaultAttackTest is EndToEndFlows {
    using CastLib for *;

    function testAttack() public {
        _configurePool(false);

        MaliciousFactory maliciousFactory = new MaliciousFactory(s.asyncRequestManager);

        /// A malicious vault can be added but will not acquire any privilege
        vm.startPrank(FM);
        h.hub.updateVault{value: GAS}(
            POOL_A, SC_1, s.usdcId, bytes32(bytes20(address(maliciousFactory))), VaultUpdateKind.DeployAndLink, 0
        );

        MaliciousVault maliciousVault = maliciousFactory.vault();

        /// But the malicious vault can not attack interacting with the asyncRequestManager
        vm.expectRevert(IAuth.NotAuthorized.selector);
        maliciousVault.attack();
    }
}
