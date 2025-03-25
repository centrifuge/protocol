// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";

import {IBaseInvestmentManager} from "src/vaults/interfaces/investments/IBaseInvestmentManager.sol";
import {IInvestmentManagerMapper} from "src/vaults/interfaces/investments/IInvestmentManagerMapper.sol";

// TODO(wischli): Docs
// TODO(wischli): Add to deployment
contract InvestmentManagerMapper is Auth, IInvestmentManagerMapper {
    IBaseInvestmentManager[] public investmentManagers;

    constructor(IBaseInvestmentManager[] memory managers, address deployer) Auth(deployer) {
        require(managers.length > 0, "InvestmentRouter/empty-constructor");
        for (uint256 i = 0; i < managers.length; i++) {
            addInvestmentManager(managers[i]);
        }
    }

    // Admin function to add a new investment manager
    function addInvestmentManager(IBaseInvestmentManager newManager) public auth {
        require(newManager.escrow() != address(0), "InvestmentRouter/invalid-manager");
        investmentManagers.push(newManager);
    }

    // Admin function to remove an investment manager by index
    function removeInvestmentManager(uint256 index) public auth {
        require(index < investmentManagers.length, "InvestmentRouter/index-out-of-bounds");

        investmentManagers[index] = investmentManagers[investmentManagers.length - 1];
        investmentManagers.pop();
    }

    function vaultKeysToInvestmentManager(uint64 poolId, bytes16 trancheId, uint128 assetId)
        public
        view
        returns (IBaseInvestmentManager)
    {
        address vault;

        for (uint256 i = 0; i < investmentManagers.length; i++) {
            IBaseInvestmentManager manager = investmentManagers[i];

            (bool success, bytes memory data) = address(manager).staticcall(
                abi.encodeWithSelector(IBaseInvestmentManager.vaultByAssetId.selector, poolId, trancheId, assetId)
            );

            if (success && data.length >= 32) {
                vault = abi.decode(data, (address));
                if (vault != address(0)) {
                    return IBaseInvestmentManager(manager);
                }
            }
        }

        revert("InvestmentRouter/VaultNotFound");
    }
}
