// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAdapterWirer} from "./interfaces/IAdapterWirer.sol";

import {IAxelarAdapter} from "../adapters/interfaces/IAxelarAdapter.sol";
import {IWormholeAdapter} from "../adapters/interfaces/IWormholeAdapter.sol";

contract AdapterWirer is IAdapterWirer {
    address public admin;

    constructor(address admin_) {
        admin = admin_;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, NotTheAuthorizedAdmin());
        _;
    }

    function file(bytes32 what, address data) external onlyAdmin {
        if (what == "admin") admin = data;
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    /// @inheritdoc IAdapterWirer
    function wireWormholeAdapter(IWormholeAdapter localAdapter, uint16 centrifugeId, uint16 wormholeId, address adapter)
        external
        onlyAdmin
    {
        localAdapter.file("sources", centrifugeId, wormholeId, adapter);
        localAdapter.file("destinations", centrifugeId, wormholeId, adapter);
    }

    /// @inheritdoc IAdapterWirer
    function wireAxelarAdapter(
        IAxelarAdapter localAdapter,
        uint16 centrifugeId,
        string calldata axelarId,
        string calldata adapter
    ) external onlyAdmin {
        localAdapter.file("sources", axelarId, centrifugeId, adapter);
        localAdapter.file("destinations", centrifugeId, axelarId, adapter);
    }
}
