// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../misc/interfaces/IAuth.sol";
import {IERC20} from "../misc/interfaces/IERC20.sol";

import {Root} from "../admin/Root.sol";

Root constant ROOT_V2 = Root(0x0C1fDfd6a1331a875EA013F3897fc8a76ada5DfC);
Root constant ROOT_V3 = Root(0x7Ed48C31f2fdC40d37407cBaBf0870B2b688368f);

address constant CFG = 0xcccCCCcCCC33D538DBC2EE4fEab0a7A1FF4e8A94;
address constant WCFG = 0xc221b7E65FfC80DE234bbB6667aBDd46593D34F0;
address constant WCFG_MULTISIG = 0x3C9D25F2C76BFE63485AE25D524F7f02f2C03372;
address constant CHAINBRIDGE_ERC20_HANDLER = 0x84D1e77F472a4aA697359168C4aF4ADD4D2a71fa;
address constant CREATE3_PROXY = 0x28E6eED839a5E03D92f7A5C459430576081fadFb;
address constant IOU_CFG = 0xACF3c07BeBd65d5f7d86bc0bc716026A0C523069;

address constant TRANCHE_JTRSY = 0x8c213ee79581Ff4984583C6a801e5263418C4b86; // ETH_JTRSY, BASE_JTRSY, ARBITRUM_JTRSY
address constant TRANCHE_JAAA = 0x5a0F93D040De44e78F251b03c43be9CF317Dcf64; // ETH_JAAA, BASE_JAAA
address constant ESCROW_V2 = 0x0000000005F458Fd6ba9EEb5f365D83b7dA913dD;
address constant TREASURY = 0xb3DacC732509Ba6B7F25Ad149e56cA44fE901AB9;

IERC20 constant USDC_ETHEREUM = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
IERC20 constant USDC_BASE = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
IERC20 constant USDC_ARBITRUM = IERC20(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);

uint256 constant ETHEREUM_CHAIN_ID = 1;
uint256 constant BASE_CHAIN_ID = 8453;
uint256 constant ARBITRUM_CHAIN_ID = 42161;

interface EscrowV2Like is IAuth {
    function approveMax(address token, address spender) external;
}

contract V2CleaningsSpell {
    bool public done;
    string public constant description = "Pending cleanings from V2";

    function cast() external {
        require(!done, "Spell already executed");
        done = true;

        _updateCFGWards();
        _disableRootV2FromShareTokensV2();
        _moveFundsFromEscrowToTreasury();

        ROOT_V2.deny(address(this));
        ROOT_V3.deny(address(this));
    }

    function _updateCFGWards() internal {
        // Check if CFG exists
        if (CFG.code.length > 0) {
            // Mainnet CFG only has the v2 root relied, need to replace with v3 root
            if (block.chainid == ETHEREUM_CHAIN_ID) {
                ROOT_V2.relyContract(CFG, address(ROOT_V3));
                ROOT_V3.denyContract(CFG, IOU_CFG);
                ROOT_V3.denyContract(CFG, address(ROOT_V2));
            }

            // Deny CREATE3 proxy on new chains
            if (block.chainid != ETHEREUM_CHAIN_ID) {
                ROOT_V3.denyContract(CFG, CREATE3_PROXY);
            }
        }

        // Check if WCFG exists (only in Ethereum)
        if (WCFG.code.length > 0) {
            Root(ROOT_V2).relyContract(WCFG, address(ROOT_V3));
            ROOT_V3.denyContract(WCFG, WCFG_MULTISIG);
            ROOT_V3.denyContract(WCFG, CHAINBRIDGE_ERC20_HANDLER);
            ROOT_V3.denyContract(WCFG, address(ROOT_V2));
        }
    }

    function _disableRootV2FromShareTokensV2() internal {
        address[] memory shareTokens = new address[](2);
        shareTokens[0] = TRANCHE_JTRSY;
        shareTokens[1] = TRANCHE_JAAA;

        for (uint256 i; i < shareTokens.length; i++) {
            IAuth shareTokenV2 = IAuth(shareTokens[i]);

            // forgefmt: disable-next-item
            if (address(shareTokenV2).code.length > 0 &&
                shareTokenV2.wards(address(ROOT_V2)) == 1 &&
                shareTokenV2.wards(address(ROOT_V3)) == 1
            ) {
                ROOT_V3.relyContract(address(shareTokenV2), address(this));
                shareTokenV2.deny(address(ROOT_V2));
                ROOT_V3.denyContract(address(shareTokenV2), address(this));
            }
        }
    }

    function _moveFundsFromEscrowToTreasury() internal {
        if (ESCROW_V2.code.length > 0) {
            IERC20 usdc;
            if (block.chainid == ETHEREUM_CHAIN_ID) {
                usdc = USDC_ETHEREUM;
            } else if (block.chainid == BASE_CHAIN_ID) {
                usdc = USDC_BASE;
            } else if (block.chainid == ARBITRUM_CHAIN_ID) {
                usdc = USDC_ARBITRUM;
            }

            ROOT_V2.relyContract(address(ESCROW_V2), address(this));

            EscrowV2Like(ESCROW_V2).approveMax(address(usdc), address(this));
            usdc.transferFrom(ESCROW_V2, TREASURY, usdc.balanceOf(ESCROW_V2));

            ROOT_V2.denyContract(address(ESCROW_V2), address(this));
        }
    }
}
