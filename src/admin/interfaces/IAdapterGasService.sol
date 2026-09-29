// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IMessageGas} from "../../core/messaging/interfaces/IMessageGas.sol";

/// @title  IAdapterGasService
/// @notice What an adapter needs from the gas service, on top of the message properties the core reads.
/// @dev    Adapters reach the gas service through `MultiAdapter.messageGas()`, which is typed as
///         the core interface and must stay that way: the core has no business knowing that a receive
///         path has a cost. Adapters cast to this, which is where that knowledge belongs, because the
///         gas service is not a core contract and may assume things about the adapters it prices.
interface IAdapterGasService is IMessageGas {
    error UnknownAdapter();

    /// @notice Gas an adapter must reserve for its own receive path on `centrifugeId`, on top of the
    ///         message gas limit it is asked to deliver. In gas, not in the native token `estimate` quotes.
    /// @dev    An adapter names itself and nothing else: what its receive path consumes and what each
    ///         chain charges for it are both held by the gas service, so a repricing, a rebenchmark or a
    ///         new chain never reaches adapter code. `adapter` is a short-string id, the same way
    ///         {IMultiAdapter-file} names a dependency, so adapters can be added or retired without
    ///         holding an order or leaving a retired index behind.
    function receiveCost(uint16 centrifugeId, bytes32 adapter) external view returns (uint128);
}
