// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {BaseTest} from "./BaseTest.sol";

// TODO(test-migration #6): these tests exercised hub.multicall semantics which were removed
// when BatchedMulticall was dropped from Hub. Reimplement using hub.await batches.
contract TestBatchingAndPayment is BaseTest {}
