// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonDeployer} from "../../script/CommonDeployer.s.sol";

import "forge-std/Test.sol";

contract SaltGenerationTestBase is Test, CommonDeployer {
    bytes32 public constant VERSION_HASHED = keccak256(abi.encodePacked("3"));
    bytes32 public constant VERSION_NOT_HASHED = bytes32(bytes("3"));

    // Creation tx: https://etherscan.io/tx/0xdd9bf5ea37b05df6740229060823966977e7875330fdb9a57066086b413f2721
    bytes32 public constant ASYNC_REQUEST_MANAGER_SALT =
        0x207ee5f00083b0114e7edeb0210e8e19a14552e1d0f05b908acf43e8b6768d58;
    address public constant ASYNC_REQUEST_MANAGER_ADDRESS = 0xf06f89A1b6C601235729A689595571B7455Dd433;

    // Creation tx: https://etherscan.io/tx/0x7abb5ac9e683c151f430f97bb812340706db27b77f8c46998e2c4657bf6fcb87
    bytes32 public constant ASYNC_VAULT_FACTORY_SALT =
        0x72f886aad0b3f2a37f35ed368e557396be04bbfd54aeb2ddbd7502522d8641a7;
    address public constant ASYNC_VAULT_FACTORY_ADDRESS = 0xed9D489BB79c7CB58c522f36Fc6944eAA95Ce385;

    // Creation tx: https://etherscan.io/tx/0x0f08fa1cdb5888cf2d636545c0183baa7e36a0b2c5e32b2c6f6c9a4b06c6b997
    bytes32 public constant SYNC_DEPOSIT_VAULT_FACTORY_SALT =
        0xed489e1d5b5012ea883215229b0a1dce152dc4d713a4ef196fda319d39ba7e5e;
    address public constant SYNC_DEPOSIT_VAULT_FACTORY_ADDRESS = 0x21BF2544b5A0B03c8566a16592ba1b3B192B50Bc;

    function _testAsyncRequestManagerSalt() public view {
        assertEq(
            generateSalt("asyncRequestManager-2"),
            ASYNC_REQUEST_MANAGER_SALT,
            "asyncRequestManager salt must match Etherscan"
        );

        assertEq(
            generateSalt("asyncRequestManager-2"),
            keccak256(abi.encodePacked("asyncRequestManager-2", VERSION_NOT_HASHED)),
            "asyncRequestManager salt pattern"
        );
    }

    function _testAsyncVaultFactorySalt() public view {
        assertEq(
            generateSalt("asyncVaultFactory-2"), ASYNC_VAULT_FACTORY_SALT, "asyncVaultFactory salt must match Etherscan"
        );

        assertEq(
            generateSalt("asyncVaultFactory-2"),
            keccak256(abi.encodePacked("asyncVaultFactory-2", VERSION_NOT_HASHED)),
            "asyncVaultFactory salt pattern"
        );
    }

    function _testSyncDepositVaultFactorySalt() public view {
        assertEq(
            generateSalt("syncDepositVaultFactory-2"),
            SYNC_DEPOSIT_VAULT_FACTORY_SALT,
            "syncDepositVaultFactory salt must match Etherscan"
        );

        assertEq(
            generateSalt("syncDepositVaultFactory-2"),
            keccak256(abi.encodePacked("syncDepositVaultFactory-2", VERSION_NOT_HASHED)),
            "syncDepositVaultFactory salt pattern"
        );
    }
}

/// @dev This test ensures the incorrectly used unhashed version of v3.0.1 generates the correct salt
contract SaltGenerationTestVersionHashed is SaltGenerationTestBase {
    function setUp() public {
        version = VERSION_HASHED;
    }

    function testAsyncRequestManagerSalt() public view {
        _testAsyncRequestManagerSalt();
    }

    function testAsyncVaultFactorySalt() public view {
        _testAsyncVaultFactorySalt();
    }

    function testSyncDepositVaultFactorySalt() public view {
        _testSyncDepositVaultFactorySalt();
    }
}

/// @dev This test ensures the correctly used hashed version of v3.0.1 generates the same salt as the unhashed version
contract SaltGenerationTestVersionNotHashed is SaltGenerationTestBase {
    function setUp() public {
        version = VERSION_NOT_HASHED;
    }

    function testAsyncRequestManagerSalt() public view {
        _testAsyncRequestManagerSalt();
    }

    function testAsyncVaultFactorySalt() public view {
        _testAsyncVaultFactorySalt();
    }

    function testSyncDepositVaultFactorySalt() public view {
        _testSyncDepositVaultFactorySalt();
    }
}
