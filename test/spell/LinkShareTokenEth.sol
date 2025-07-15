// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LinkShareToken, LinkShareTokenParams} from "./LinkShareToken.sol";
import {ISpoke} from "src/spoke/interfaces/ISpoke.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";

contract LinkShareTokenEth is LinkShareToken {
    constructor()
        LinkShareToken(
            ISpoke(address(0xd30Da1d7F964E5f6C2D9fE2AAA97517F6B23FA2B)),
            LinkShareTokenParams({
                poolId: PoolId.wrap(4139607887),
                shareClassId: ShareClassId.wrap(0x97aa65f23e7be09fcd62d0554d2e9273),
                shareToken: IShareToken(address(0x8c213ee79581Ff4984583C6a801e5263418C4b86))
            }),
            LinkShareTokenParams({
                poolId: PoolId.wrap(158696445),
                shareClassId: ShareClassId.wrap(0x57e1b211a9ce6306b69a414f274f9998),
                shareToken: IShareToken(address(0x5a0F93D040De44e78F251b03c43be9CF317Dcf64))
            })
        )
    {}
}
