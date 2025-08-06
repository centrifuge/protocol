// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IAxelarAdapter} from "../../adapters/interfaces/IAxelarAdapter.sol";
import {IWormholeAdapter} from "../../adapters/interfaces/IWormholeAdapter.sol";

interface IAdapterWirer {
    error NotTheAuthorizedAdmin();
    error FileUnrecognizedParam();

    /// @notice Emitted when a call to `file()` was performed.
    event File(bytes32 indexed what, address addr);

    /// @notice Wire the local Wormhole adapter to a remote one.
    /// The adapter must rely on this contract
    /// @param localAdapter The local Wormhole adapter to configure
    /// @param centrifugeId The remote chain's chain ID
    /// @param wormholeId The remote chain's Wormhole ID
    /// @param adapter The remote chain's Wormhole adapter address
    function wireWormholeAdapter(IWormholeAdapter localAdapter, uint16 centrifugeId, uint16 wormholeId, address adapter)
        external;

    /// @notice Wire the local Axelar adapter to a remote one.
    /// The adapter must rely on this contract
    /// @param localAdapter The local Axelar adapter to configure
    /// @param centrifugeId The remote chain's chain ID
    /// @param axelarId The remote chain's Axelar ID
    /// @param adapter The remote chain's Axelar adapter address
    function wireAxelarAdapter(
        IAxelarAdapter localAdapter,
        uint16 centrifugeId,
        string calldata axelarId,
        string calldata adapter
    ) external;
}
