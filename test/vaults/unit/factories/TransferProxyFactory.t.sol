// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {TransferProxy, TransferProxyFactory} from "src/vaults/factories/TransferProxyFactory.sol";
import {ERC20} from "src/vaults/token/ERC20.sol";
import {MockUSDC} from "test/vaults/mocks/MockUSDC.sol";
import {MockGateway} from "test/vaults/mocks/MockGateway.sol";
import {MockPoolManager} from "test/vaults/mocks/MockPoolManager.sol";
import {ITransferProxyFactory} from "src/vaults/interfaces/factories/ITransferProxy.sol";
import "test/vaults/BaseTest.sol";

contract TransferProxyFactoryTest is BaseTest {
    function testFile() public {
        ITransferProxyFactory factory = ITransferProxyFactory(transferProxyFactory);

        root.denyContract(address(factory), self);
        vm.expectRevert(bytes("Auth/not-authorized"));
        factory.file("poolManager", self);

        root.relyContract(address(factory), self);
        factory.file("poolManager", self);

        assertEq(address(factory.poolManager()), self);

        vm.expectRevert(bytes("TransferProxyFactory/file-unrecognized-param"));
        factory.file("random", self);

        TransferProxy proxy = TransferProxy(factory.newTransferProxy(""));

        vm.expectRevert(bytes("Auth/not-authorized"));
        proxy.file("poolManager", self);

        root.relyContract(address(proxy), self);
        proxy.file("poolManager", self);

        assertEq(address(proxy.poolManager()), self);

        vm.expectRevert(bytes("TransferProxy/file-unrecognized-param"));
        proxy.file("random", self);
    }

    function testTransferProxy(bytes32 destination, bytes32 otherDestination) public {
        vm.assume(destination != otherDestination);

        ITransferProxyFactory factory = ITransferProxyFactory(transferProxyFactory);
        TransferProxy proxy = TransferProxy(factory.newTransferProxy(destination));
        assertEq(factory.poolManager(), address(poolManager));
        assertEq(factory.proxies(destination), address(proxy));
        assertEq(address(proxy.poolManager()), address(poolManager));
        assertEq(proxy.destination(), destination);

        // Proxies cannot be deployed twice
        vm.expectRevert(bytes("TransferProxyFactory/already-deployed"));
        factory.newTransferProxy(destination);

        erc20.mint(address(this), 100);
        erc20.transfer(address(proxy), 100);

        vm.expectRevert(bytes("PoolManager/unknown-asset"));
        proxy.transfer(address(erc20));

        poolManager.addAsset(1, address(erc20));

        assertEq(erc20.balanceOf(address(proxy)), 100);
        assertEq(erc20.balanceOf(address(escrow)), 0);

        // Transfers are processed as expected
        proxy.transfer(address(erc20));

        // Proxies are unique per destination
        assertTrue(factory.newTransferProxy(otherDestination) != address(proxy));

        assertEq(erc20.balanceOf(address(proxy)), 0);
        assertEq(erc20.balanceOf(address(escrow)), 100);
    }

    function testTransferProxyWithUSDC(bytes32 destination) public {
        ITransferProxyFactory factory = ITransferProxyFactory(transferProxyFactory);
        TransferProxy proxy = TransferProxy(factory.newTransferProxy(destination));

        MockUSDC usdc = new MockUSDC(6);
        usdc.mint(address(this), 100);
        usdc.transfer(address(proxy), 100);
        poolManager.addAsset(1, address(usdc));

        assertEq(usdc.balanceOf(address(proxy)), 100);
        assertEq(usdc.balanceOf(address(escrow)), 0);

        // Transfers are processed as expected
        proxy.transfer(address(usdc));

        assertEq(usdc.balanceOf(address(proxy)), 0);
        assertEq(usdc.balanceOf(address(escrow)), 100);
    }

    function testTransferProxyRecovery(bytes32 destination) public {
        ITransferProxyFactory factory = ITransferProxyFactory(transferProxyFactory);
        TransferProxy proxy = TransferProxy(factory.newTransferProxy(destination));

        address to = makeAddr("RecoveryAddress");

        erc20.mint(address(this), 100);
        erc20.transfer(address(proxy), 100);

        assertEq(erc20.balanceOf(address(proxy)), 100);

        vm.expectRevert(bytes("Auth/not-authorized"));
        proxy.recoverTokens(address(erc20), to, 100);

        root.recoverTokens(address(proxy), address(erc20), to, 100);

        assertEq(erc20.balanceOf(address(proxy)), 0);
        assertEq(erc20.balanceOf(to), 100);
    }

    function testTransferProxyShouldBeDeterministic(bytes32 destination) public {
        address predictedAddress = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            transferProxyFactory,
                            destination,
                            keccak256(abi.encodePacked(type(TransferProxy).creationCode, abi.encode(destination)))
                        )
                    )
                )
            )
        );
        ITransferProxyFactory factory = ITransferProxyFactory(transferProxyFactory);
        TransferProxy proxy = TransferProxy(factory.newTransferProxy(destination));

        assertEq(address(proxy), predictedAddress);
        assertEq(factory.getAddress(destination), address(proxy));
    }
}
