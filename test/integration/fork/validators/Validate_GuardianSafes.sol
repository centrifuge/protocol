// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Env, EnvConfig} from "../../../../script/utils/EnvConfig.s.sol";

import {BaseValidator, ValidationContext} from "../../spell/utils/validation/BaseValidator.sol";

interface ISafeOwnerManager {
    function isOwner(address signer) external view returns (bool);
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
}

/// @title Validate_GuardianSafes
/// @notice Validates that the Protocol Guardian and Ops Guardian Safes are properly configured.
contract Validate_GuardianSafes is BaseValidator("GuardianSafes") {
    address constant OWNER_1 = 0xd55114BfE98a2ca16202Aa741BeE571765292616;
    address constant OWNER_2 = 0x080001dBE12fA46A1d7C03fa0Cbf1839E367F155;
    address constant OWNER_3 = 0x9eDec77dd2651Ce062ab17e941347018AD4eAEA9;
    address constant OWNER_4 = 0x4d47a7a89478745200Bd51c26bA87664538Df541;
    address constant OWNER_5 = 0xE9441B34f71659cCA2bfE90d98ee0e57D9CAD28F;
    address constant OWNER_6 = 0x5e7A86178252Aeae9cBDa30f9C342c71799A3EE1;
    address constant OWNER_7 = 0x701Da7A0c8ee46521955CC29D32943d47E2c02b9;
    address constant OWNER_8 = 0x044671aCf58340Ac9d7AB782D3F93D1943fE24Bf;
    address constant OWNER_9_DEFAULT = 0xb307f0b2eDdB84EF63f3F9dc99a3A1a66D68EB3a;
    address constant OWNER_9_PLUME = 0xa542A86f0fFd0A3F32C765D175935F1714437598;

    function validate(ValidationContext memory ctx) public override {
        if (!ctx.isMainnet) return;

        EnvConfig memory config = Env.load(ctx.networkName);

        _validateProtocolSafe(config.network.protocolAdmin, ctx.networkName);
        _validateOpsSafe(config.network.opsAdmin);
    }

    function _validateProtocolSafe(address safe, string memory networkName) internal {
        if (safe == address(0)) return;

        bool isPlume = keccak256(bytes(networkName)) == keccak256("plume");
        address owner9 = isPlume ? OWNER_9_PLUME : OWNER_9_DEFAULT;

        address[9] memory owners = [OWNER_1, OWNER_2, OWNER_3, OWNER_4, OWNER_5, OWNER_6, OWNER_7, OWNER_8, owner9];

        for (uint256 i = 0; i < owners.length; i++) {
            try ISafeOwnerManager(safe).isOwner(owners[i]) returns (bool result) {
                if (!result) {
                    _errors.push(
                        _buildError(
                            "isOwner",
                            "protocolSafe",
                            "true",
                            "false",
                            string.concat("Protocol Safe missing owner: ", vm.toString(owners[i]))
                        )
                    );
                }
            } catch {
                _errors.push(
                    _buildError("isOwner", "protocolSafe", "callable", "reverted", "isOwner() reverted on protocolSafe")
                );
                return;
            }
        }

        try ISafeOwnerManager(safe).getOwners() returns (address[] memory actualOwners) {
            if (actualOwners.length != owners.length) {
                _errors.push(
                    _buildError(
                        "ownerCount",
                        "protocolSafe",
                        vm.toString(owners.length),
                        vm.toString(actualOwners.length),
                        "Protocol Safe has unexpected number of owners"
                    )
                );
            }
        } catch {
            _errors.push(
                _buildError("getOwners", "protocolSafe", "callable", "reverted", "getOwners() reverted on protocolSafe")
            );
        }

        _checkThreshold(safe, "protocolSafe");
    }

    function _validateOpsSafe(address safe) internal {
        if (safe == address(0)) return;
        _checkThreshold(safe, "opsSafe");
    }

    function _checkThreshold(address safe, string memory label) internal {
        try ISafeOwnerManager(safe).getThreshold() returns (uint256 threshold) {
            if (threshold <= 1) {
                _errors.push(
                    _buildError(
                        "getThreshold",
                        label,
                        "> 1",
                        vm.toString(threshold),
                        string.concat(label, " threshold must be greater than 1")
                    )
                );
            }
        } catch {
            _errors.push(
                _buildError(
                    "getThreshold", label, "callable", "reverted", string.concat("getThreshold() reverted on ", label)
                )
            );
        }
    }
}
