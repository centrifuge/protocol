// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../src/core/types/AssetId.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";
import {VaultDetails, ISpokeRegistry} from "../../../src/core/spoke/interfaces/ISpokeRegistry.sol";

import {Root} from "../../../src/admin/Root.sol";

import "forge-std/Test.sol";

import {ShareToken} from "../../../src/token/ShareToken.sol";
import {IShareToken} from "../../../src/token/interfaces/IShareToken.sol";
import {ITransferHook} from "../../../src/token/interfaces/ITransferHook.sol";
import {ShareTokenRegistrar} from "../../../src/token/ShareTokenRegistrar.sol";
import {IShareTokenRegistrar} from "../../../src/token/interfaces/IShareTokenRegistrar.sol";

contract ShareTokenRegistrarTest is Test {
    string constant NAME = "Test Share";
    string constant SYMBOL = "TSH";
    uint8 constant DECIMALS = 6;
    bytes32 constant SALT = bytes32(uint256(42));

    address root = address(new Root(48 hours, address(this)));
    address envoy = makeAddr("envoy");
    address spokeRegistry = makeAddr("spokeRegistry");
    ShareTokenRegistrar registrar = new ShareTokenRegistrar(root, address(this));

    function setUp() public {
        registrar.file("envoy", envoy);
    }

    function _newToken() internal returns (address) {
        return registrar.newToken(NAME, SYMBOL, DECIMALS, SALT, "");
    }

    /// @dev Set `hook` on `token` via the envoy SetHook path (hooks are no longer set through a direct method).
    function _setHook(address token, address hook) internal {
        PoolId poolId = PoolId.wrap(1);
        ShareClassId scId = ShareClassId.wrap(bytes16(uint128(2)));
        registrar.file("spokeRegistry", spokeRegistry);
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.shareTokenAndRegistrar.selector, poolId, scId),
            abi.encode(token, address(registrar))
        );
        vm.prank(envoy);
        registrar.fromHub(poolId, abi.encode(IShareTokenRegistrar.RegistrarCall.SetHook, scId.raw(), hook));
    }

    function testShareShouldBeDeterministic(
        string memory name,
        string memory symbol,
        bytes32 registrarSalt,
        bytes32 tokenSalt,
        uint8 decimals
    ) public {
        decimals = uint8(bound(decimals, 0, 18));
        ShareTokenRegistrar registrar_ = new ShareTokenRegistrar{salt: registrarSalt}(root, address(this));

        address predictedAddress = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            address(registrar_),
                            tokenSalt,
                            keccak256(abi.encodePacked(type(ShareToken).creationCode, abi.encode(decimals)))
                        )
                    )
                )
            )
        );

        address token = registrar_.newToken(name, symbol, decimals, tokenSalt, "");

        assertEq(token, predictedAddress);
        assertEq(registrar_.previewTokenAddress(name, symbol, decimals, tokenSalt, ""), token);
    }

    function testNewTokenWards() public {
        address token = _newToken();

        assertEq(IAuth(token).wards(root), 1);
        assertEq(IAuth(token).wards(address(registrar)), 1);
    }

    /// @dev Cross-pool isolation regression: a token is only operable by the registrar that deployed it.
    ///      A foreign registrar (e.g. one a different pool chose) cannot mint another registrar's token,
    ///      so pointing a share class at a foreign token cannot grant control over it.
    function testForeignRegistrarCannotOperateToken() public {
        address token = _newToken();
        ShareTokenRegistrar foreignRegistrar = new ShareTokenRegistrar(root, address(this));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        foreignRegistrar.mint(token, makeAddr("receiver"), 100);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        foreignRegistrar.authTransferFrom(token, address(this), address(this), makeAddr("to"), 100);
    }

    function testNewTokenNotAuthorized() public {
        vm.prank(makeAddr("notAuthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registrar.newToken(NAME, SYMBOL, DECIMALS, SALT, "");
    }

    function testMint() public {
        address token = _newToken();
        address receiver = makeAddr("receiver");

        registrar.mint(token, receiver, 100);
        assertEq(IShareToken(token).balanceOf(receiver), 100);

        vm.prank(makeAddr("notAuthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registrar.mint(token, receiver, 100);
    }

    function testBurnPullsToCallerBeforeBurning() public {
        address token = _newToken();
        address owner = makeAddr("owner");

        registrar.mint(token, owner, 100);

        // The calling contract grants the registrar an allowance for the pulled-then-burned amount
        IShareToken(token).approve(address(registrar), 60);
        registrar.burn(token, owner, 60);

        assertEq(IShareToken(token).balanceOf(owner), 40);
        assertEq(IShareToken(token).balanceOf(address(this)), 0);
        assertEq(IShareToken(token).totalSupply(), 40);

        vm.prank(makeAddr("notAuthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registrar.burn(token, owner, 40);
    }

    function testAuthTransferFrom() public {
        address token = _newToken();
        address from = makeAddr("from");
        address to = makeAddr("to");

        registrar.mint(token, from, 100);
        registrar.authTransferFrom(token, from, from, to, 70);

        assertEq(IShareToken(token).balanceOf(from), 30);
        assertEq(IShareToken(token).balanceOf(to), 70);

        vm.prank(makeAddr("notAuthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registrar.authTransferFrom(token, from, from, to, 30);
    }

    function testSetMetadata() public {
        address token = _newToken();

        registrar.updateMetadata(token, "New Name", SYMBOL);
        assertEq(IShareToken(token).name(), "New Name");
        assertEq(IShareToken(token).symbol(), SYMBOL);

        vm.expectRevert(IShareTokenRegistrar.OldMetadata.selector);
        registrar.updateMetadata(token, "New Name", SYMBOL);

        vm.prank(makeAddr("notAuthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registrar.updateMetadata(token, "Other", SYMBOL);
    }

    function testFromHubSetHook() public {
        address token = _newToken();
        address hook = makeAddr("hook");
        registrar.file("spokeRegistry", spokeRegistry);

        PoolId poolId = PoolId.wrap(1);
        ShareClassId scId = ShareClassId.wrap(bytes16(uint128(2)));
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.shareTokenAndRegistrar.selector, poolId, scId),
            abi.encode(token, address(registrar))
        );

        bytes memory payload = abi.encode(IShareTokenRegistrar.RegistrarCall.SetHook, scId.raw(), hook);

        vm.prank(envoy);
        registrar.fromHub(poolId, payload);
        assertEq(IShareToken(token).hook(), hook);

        // Setting the same hook again reverts
        vm.prank(envoy);
        vm.expectRevert(IShareTokenRegistrar.OldHook.selector);
        registrar.fromHub(poolId, payload);

        // Only the envoy may drive fromHub
        vm.expectRevert(IShareTokenRegistrar.NotEnvoy.selector);
        registrar.fromHub(poolId, payload);
    }

    function testUpdateRestriction() public {
        address token = _newToken();
        address hook = makeAddr("hook");
        bytes memory update = hex"0102";

        vm.expectRevert(IShareTokenRegistrar.InvalidHook.selector);
        registrar.updateRestriction(token, update);

        _setHook(token, hook);

        vm.mockCall(hook, abi.encodeWithSelector(ITransferHook.updateRestriction.selector, token, update), "");
        vm.expectCall(hook, abi.encodeWithSelector(ITransferHook.updateRestriction.selector, token, update));
        registrar.updateRestriction(token, update);

        vm.prank(makeAddr("notAuthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registrar.updateRestriction(token, update);
    }

    function testFromHubSetVault() public {
        address token = _newToken();
        address asset = makeAddr("asset");
        address vault = makeAddr("vault");

        registrar.file("spokeRegistry", spokeRegistry);

        PoolId poolId = PoolId.wrap(1);
        ShareClassId scId = ShareClassId.wrap(bytes16(uint128(2)));
        AssetId assetId = AssetId.wrap(3);

        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.shareTokenAndRegistrar.selector, poolId, scId),
            abi.encode(token, address(registrar))
        );
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(bytes4(keccak256("idToAsset(uint128,bool)")), assetId),
            abi.encode(asset, uint256(0))
        );
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.vaultDetails.selector, vault),
            abi.encode(
                VaultDetails({poolId: poolId, scId: scId, assetId: assetId, asset: asset, tokenId: 0, isLinked: true})
            )
        );

        bytes memory payload = abi.encode(IShareTokenRegistrar.RegistrarCall.SetVault, scId.raw(), assetId.raw(), vault);

        vm.prank(envoy);
        registrar.fromHub(poolId, payload);
        assertEq(IShareToken(token).vault(asset), vault);

        // Only the envoy may drive fromHub
        vm.expectRevert(IShareTokenRegistrar.NotEnvoy.selector);
        registrar.fromHub(poolId, payload);
    }

    function testFromHubSetVaultClearsWithAddressZero() public {
        address token = _newToken();
        address asset = makeAddr("asset");
        address vault = makeAddr("vault");

        registrar.file("spokeRegistry", spokeRegistry);

        PoolId poolId = PoolId.wrap(1);
        ShareClassId scId = ShareClassId.wrap(bytes16(uint128(2)));
        AssetId assetId = AssetId.wrap(3);

        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.shareTokenAndRegistrar.selector, poolId, scId),
            abi.encode(token, address(registrar))
        );
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(bytes4(keccak256("idToAsset(uint128,bool)")), assetId),
            abi.encode(asset, uint256(0))
        );
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.vaultDetails.selector, vault),
            abi.encode(
                VaultDetails({poolId: poolId, scId: scId, assetId: assetId, asset: asset, tokenId: 0, isLinked: true})
            )
        );

        vm.prank(envoy);
        registrar.fromHub(
            poolId, abi.encode(IShareTokenRegistrar.RegistrarCall.SetVault, scId.raw(), assetId.raw(), vault)
        );
        assertEq(IShareToken(token).vault(asset), vault);

        vm.prank(envoy);
        registrar.fromHub(
            poolId, abi.encode(IShareTokenRegistrar.RegistrarCall.SetVault, scId.raw(), assetId.raw(), address(0))
        );
        assertEq(IShareToken(token).vault(asset), address(0));
    }

    function testFromHubRejectsVaultMismatch() public {
        address token = _newToken();
        registrar.file("spokeRegistry", spokeRegistry);

        PoolId poolId = PoolId.wrap(1);
        ShareClassId scId = ShareClassId.wrap(bytes16(uint128(2)));
        AssetId assetId = AssetId.wrap(3);
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.shareTokenAndRegistrar.selector, poolId, scId),
            abi.encode(token, address(registrar))
        );
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(bytes4(keccak256("idToAsset(uint128,bool)")), assetId),
            abi.encode(makeAddr("asset"), uint256(0))
        );
        // The requested vault is not linked in the registry
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.vaultDetails.selector, makeAddr("vault")),
            abi.encode(
                VaultDetails({
                    poolId: poolId, scId: scId, assetId: assetId, asset: makeAddr("asset"), tokenId: 0, isLinked: false
                })
            )
        );

        bytes memory payload =
            abi.encode(IShareTokenRegistrar.RegistrarCall.SetVault, scId.raw(), assetId.raw(), makeAddr("vault"));

        vm.prank(envoy);
        vm.expectRevert(IShareTokenRegistrar.VaultMismatch.selector);
        registrar.fromHub(poolId, payload);
    }

    function testFromHubRejectsForeignRegistrar() public {
        address token = _newToken();
        registrar.file("spokeRegistry", spokeRegistry);

        PoolId poolId = PoolId.wrap(1);
        ShareClassId scId = ShareClassId.wrap(bytes16(uint128(2)));
        AssetId assetId = AssetId.wrap(3);

        // The share class is served by a different registrar, so this registrar must refuse.
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.shareTokenAndRegistrar.selector, poolId, scId),
            abi.encode(token, makeAddr("otherRegistrar"))
        );

        bytes memory payload =
            abi.encode(IShareTokenRegistrar.RegistrarCall.SetVault, scId.raw(), assetId.raw(), makeAddr("vault"));

        vm.prank(envoy);
        vm.expectRevert(IShareTokenRegistrar.NotRegistrar.selector);
        registrar.fromHub(poolId, payload);
    }

    function testFromHubRejectsNonZeroTokenId() public {
        address token = _newToken();
        registrar.file("spokeRegistry", spokeRegistry);

        PoolId poolId = PoolId.wrap(1);
        ShareClassId scId = ShareClassId.wrap(bytes16(uint128(2)));
        AssetId assetId = AssetId.wrap(3);

        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.shareTokenAndRegistrar.selector, poolId, scId),
            abi.encode(token, address(registrar))
        );
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(bytes4(keccak256("idToAsset(uint128,bool)")), assetId),
            abi.encode(makeAddr("asset"), uint256(1))
        );

        bytes memory payload =
            abi.encode(IShareTokenRegistrar.RegistrarCall.SetVault, scId.raw(), assetId.raw(), makeAddr("vault"));

        vm.prank(envoy);
        vm.expectRevert(IShareTokenRegistrar.NonZeroTokenId.selector);
        registrar.fromHub(poolId, payload);
    }

    function testFromHubUpdateWardRely() public {
        address token = _newToken();
        address ward = makeAddr("ward");
        registrar.file("spokeRegistry", spokeRegistry);

        PoolId poolId = PoolId.wrap(1);
        ShareClassId scId = ShareClassId.wrap(bytes16(uint128(2)));

        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.shareTokenAndRegistrar.selector, poolId, scId),
            abi.encode(token, address(registrar))
        );

        bytes memory payload = abi.encode(IShareTokenRegistrar.RegistrarCall.UpdateWard, scId.raw(), ward, true);

        vm.prank(envoy);
        registrar.fromHub(poolId, payload);
        assertEq(IAuth(token).wards(ward), 1);
    }

    function testFromHubUpdateWardDeny() public {
        address token = _newToken();
        address ward = makeAddr("ward");
        registrar.file("spokeRegistry", spokeRegistry);

        PoolId poolId = PoolId.wrap(1);
        ShareClassId scId = ShareClassId.wrap(bytes16(uint128(2)));

        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.shareTokenAndRegistrar.selector, poolId, scId),
            abi.encode(token, address(registrar))
        );

        vm.startPrank(envoy);
        registrar.fromHub(poolId, abi.encode(IShareTokenRegistrar.RegistrarCall.UpdateWard, scId.raw(), ward, true));
        registrar.fromHub(poolId, abi.encode(IShareTokenRegistrar.RegistrarCall.UpdateWard, scId.raw(), ward, false));
        vm.stopPrank();

        assertEq(IAuth(token).wards(ward), 0);
    }

    function testFromHubUpdateWardCannotDenySelf() public {
        address token = _newToken();
        registrar.file("spokeRegistry", spokeRegistry);

        PoolId poolId = PoolId.wrap(1);
        ShareClassId scId = ShareClassId.wrap(bytes16(uint128(2)));

        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.shareTokenAndRegistrar.selector, poolId, scId),
            abi.encode(token, address(registrar))
        );

        bytes memory payload =
            abi.encode(IShareTokenRegistrar.RegistrarCall.UpdateWard, scId.raw(), address(registrar), false);

        vm.prank(envoy);
        vm.expectRevert(IShareTokenRegistrar.CannotDenySelf.selector);
        registrar.fromHub(poolId, payload);
    }

    function testFromHubRejectsValue() public {
        registrar.file("spokeRegistry", spokeRegistry);
        vm.deal(envoy, 1 ether);

        PoolId poolId = PoolId.wrap(1);
        ShareClassId scId = ShareClassId.wrap(bytes16(uint128(2)));
        bytes memory payload = abi.encode(IShareTokenRegistrar.RegistrarCall.SetHook, scId.raw(), makeAddr("hook"));

        vm.prank(envoy);
        vm.expectRevert(IShareTokenRegistrar.UnexpectedValue.selector);
        registrar.fromHub{value: 1}(poolId, payload);
    }

    function testFromHubUnknownCall() public {
        address token = _newToken();
        registrar.file("spokeRegistry", spokeRegistry);

        PoolId poolId = PoolId.wrap(1);
        ShareClassId scId = ShareClassId.wrap(bytes16(uint128(2)));
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.shareTokenAndRegistrar.selector, poolId, scId),
            abi.encode(token, address(registrar))
        );

        bytes memory payload = abi.encode(uint8(99), scId.raw());

        vm.prank(envoy);
        vm.expectRevert(IShareTokenRegistrar.UnknownRegistrarCall.selector);
        registrar.fromHub(poolId, payload);
    }

    function testFile() public {
        address newEnvoy = makeAddr("newEnvoy");

        vm.expectEmit();
        emit IShareTokenRegistrar.File("envoy", newEnvoy);
        registrar.file("envoy", newEnvoy);
        assertEq(registrar.envoy(), newEnvoy);

        vm.expectEmit();
        emit IShareTokenRegistrar.File("spokeRegistry", spokeRegistry);
        registrar.file("spokeRegistry", spokeRegistry);
        assertEq(address(registrar.spokeRegistry()), spokeRegistry);
    }

    function testFileUnrecognizedParam() public {
        vm.expectRevert(IShareTokenRegistrar.FileUnrecognizedParam.selector);
        registrar.file("unknown", makeAddr("data"));
    }

    function testFileNotAuthorized() public {
        vm.prank(makeAddr("notAuthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registrar.file("spokeRegistry", spokeRegistry);
    }
}
