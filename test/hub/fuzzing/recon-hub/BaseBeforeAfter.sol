// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

// Interfaces
import {EpochPointers, UserOrder} from "src/hub/interfaces/IShareClassManager.sol";
import {AccountId} from "src/hub/interfaces/IAccounting.sol";
import {IAccounting} from "src/hub/interfaces/IAccounting.sol";

// Types
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";

// Recon Utils
import {Helpers} from "test/hub/fuzzing/recon-hub/utils/Helpers.sol";
import {Setup} from "./Setup.sol";

enum OpType {
    GENERIC,
    DEPOSIT,
    REDEEM,
    BATCH // batch operations that make multiple calls in one transaction
}

// ghost variables for tracking state variable values before and after function calls
abstract contract BaseBeforeAfter {
    Vars internal _before;
    Vars internal _after;
    OpType internal currentOperation;

    struct Vars {
        uint128 ghostDebited;
        uint128 ghostCredited;
        uint32 ghostLatestRedeemApproval;
        mapping(PoolId poolId => uint32) ghostEpochId;
        mapping(ShareClassId scId => mapping(AssetId payoutAssetId => mapping(bytes32 investor => UserOrder pending)))
            ghostRedeemRequest;
        mapping(PoolId poolId => mapping(ShareClassId scId => mapping(AssetId assetId => uint128 assetAmountValue))) ghostHolding;
        mapping(PoolId poolId => mapping(AccountId accountId => int128 accountValue)) ghostAccountValue;
    }

    modifier updateGhosts() {
        currentOperation = OpType.GENERIC;
        __before();
        _;
        __after();
    }

    modifier updateGhostsWithType(OpType op) {
        currentOperation = op;
        __before();
        _;
        __after();
    }

    function __before() internal virtual {
    }

    function __after() internal virtual {
    }
}