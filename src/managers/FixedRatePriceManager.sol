// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "../misc/Auth.sol";
import {D18, d18} from "../misc/types/D18.sol";
import {MathLib} from "../misc/libraries/MathLib.sol";
import {IMulticall} from "../misc/interfaces/IMulticall.sol";

import {PoolId} from "../common/types/PoolId.sol";
import {ShareClassId} from "../common/types/ShareClassId.sol";
import {MAX_MESSAGE_COST} from "../common/interfaces/IGasService.sol";

import {IHub} from "../hub/interfaces/IHub.sol";
import {IShareClassManager} from "../hub/interfaces/IShareClassManager.sol";

contract FixedRatePriceManager is Auth {
    error PeriodNotElapsed();

    uint64 public immutable rate;
    PoolId public immutable poolId;
    ShareClassId public immutable scId;
    uint64 public immutable period = 1 days;

    IHub public immutable hub;
    IShareClassManager public immutable shareClassManager;

    uint16[] public networks;

    uint64 public lastUpdate = 0;

    constructor(PoolId poolId_, ShareClassId scId_, IHub hub_, uint64 period_, uint64 rate_, address deployer)
        Auth(deployer)
    {
        poolId = poolId_;
        scId = scId_;

        hub = hub_;
        shareClassManager = hub_.shareClassManager();

        period = period_;
        rate = rate_;

        lastUpdate = uint64(block.timestamp);
    }

    //----------------------------------------------------------------------------------------------
    // Network management
    //----------------------------------------------------------------------------------------------

    /// @dev Ensure the number of network updates can fit in a single block
    function setNetworks(uint16[] calldata centrifugeIds) external auth {
        networks = centrifugeIds;
    }

    //----------------------------------------------------------------------------------------------
    // Price updates
    //----------------------------------------------------------------------------------------------

    function update(PoolId poolId_, ShareClassId scId_) external {
        require(poolId == poolId_);
        require(scId == scId_);
        // TODO: check msg.sender
        require(lastUpdate + period <= block.timestamp, PeriodNotElapsed());

        (, D18 prevPrice) = shareClassManager.metrics(scId);
        uint256 updates = (uint64(block.timestamp) - lastUpdate) / period;
        D18 price = d18(uint128(MathLib.rpow(rate, updates, prevPrice.raw()))) * prevPrice;
        lastUpdate += uint64(updates * period);

        uint256 networkCount = networks.length;
        bytes[] memory cs = new bytes[](networkCount + 1);
        cs[0] = abi.encodeWithSelector(hub.updateSharePrice.selector, poolId, scId, price);

        for (uint256 i; i < networkCount; i++) {
            cs[i + 1] = abi.encodeWithSelector(hub.notifySharePrice.selector, poolId, scId, networks[i]);
        }

        IMulticall(address(hub)).multicall{value: MAX_MESSAGE_COST * (cs.length)}(cs);
    }
}
