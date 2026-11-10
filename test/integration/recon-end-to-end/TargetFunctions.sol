// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {GapTargets} from "./targets/GapTargets.sol";
import {NavTargets} from "./targets/NavTargets.sol";
import {ExitTargets} from "./targets/ExitTargets.sol";
import {ParamTargets} from "./targets/ParamTargets.sol";
import {OracleTargets} from "./targets/OracleTargets.sol";
import {ProRataTargets} from "./targets/ProRataTargets.sol";
import {DoomsdayTargets} from "./targets/DoomsdayTargets.sol";
import {GasBoundTargets} from "./targets/GasBoundTargets.sol";
import {StrangerTargets} from "./targets/StrangerTargets.sol";
import {VaultGapTargets} from "./targets/VaultGapTargets.sol";
import {AtomicityTargets} from "./targets/AtomicityTargets.sol";
import {ShareTokenTargets} from "./targets/ShareTokenTargets.sol";
import {BalanceSheetTargets} from "./targets/BalanceSheetTargets.sol";
import {ConservationTargets} from "./targets/ConservationTargets.sol";
import {MultiRequestTargets} from "./targets/MultiRequestTargets.sol";
import {ExtremeAmountTargets} from "./targets/ExtremeAmountTargets.sol";
import {PoolIsolationTargets} from "./targets/PoolIsolationTargets.sol";
import {VaultAssuranceTargets} from "./targets/VaultAssuranceTargets.sol";
import {OrderIndependenceTargets} from "./targets/OrderIndependenceTargets.sol";

abstract contract TargetFunctions is
    OracleTargets,
    ParamTargets,
    GapTargets,
    NavTargets,
    VaultGapTargets,
    ConservationTargets,
    MultiRequestTargets,
    ProRataTargets,
    VaultAssuranceTargets,
    ExtremeAmountTargets,
    BalanceSheetTargets,
    ShareTokenTargets,
    PoolIsolationTargets,
    DoomsdayTargets,
    ExitTargets,
    GasBoundTargets,
    AtomicityTargets,
    OrderIndependenceTargets,
    StrangerTargets
{}
