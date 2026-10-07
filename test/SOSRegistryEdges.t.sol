// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SOS, ILaunchFactory} from "src/SOS.sol";
import {LaunchFactoryFixture} from "./helpers/LaunchFixtures.sol";

/// forge-config: default.fuzz.runs = 1000
contract SOSRegistryEdgesTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    // Last byte zero lets a 31-byte reply impersonate ALICE if the length check is removed.
    address internal constant ALICE = address(0xA1100);
    address internal constant BOB = address(0xB0B);
    address internal constant DEV = address(0xDE7);
    uint64 internal constant LAUNCH = type(uint64).max;
    LaunchFactoryFixture internal factory;
    SOS internal token;

    function setUp() public {
        factory = new LaunchFactoryFixture(IPoolManager(address(0x9001)));
        token = factory.deployToken(DEV, LAUNCH);
        factory.distribute(token, ALICE, 100 ether);
    }

    function testFuzz_dirtyAddressWordCannotImpersonateDistributor(uint96 rawUpperBits) public {
        uint256 upperBits = bound(uint256(rawUpperBits), 1, type(uint96).max);
        bytes memory reply = abi.encode(bytes32((upperBits << 160) | uint160(ALICE)));
        _mockReply(reply);
        _assertOrdinaryTransfer();
    }

    function test_truncatedReplyCannotImpersonateDistributor() public {
        // Copying these 31 bytes into a zeroed word produces ALICE, but this is invalid ABI.
        _mockReply(abi.encodePacked(bytes31(uint248(uint160(ALICE) >> 8))));
        _assertOrdinaryTransfer();
    }

    function test_trailingWordCannotImpersonateDistributor() public {
        _mockReply(abi.encode(ALICE, uint256(123)));
        _assertOrdinaryTransfer();
    }

    function test_validWordForMaximumLaunchNumberEnablesExactClaim() public {
        factory.setDistributor(LAUNCH, ALICE);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 100 ether));
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 100 ether);
        assertEq(token.balanceOf(DEV), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function _mockReply(bytes memory reply) private {
        vm.mockCall(address(factory), abi.encodeCall(ILaunchFactory.distributorOf, (LAUNCH)), reply);
    }

    function _assertOrdinaryTransfer() private {
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 100 ether));
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 98 ether);
        assertEq(token.balanceOf(DEV), 1 ether);
        assertEq(token.totalSupply(), SUPPLY - 1 ether);
    }
}
