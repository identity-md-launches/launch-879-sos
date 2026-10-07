// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SOS} from "../src/SOS.sol";
import {LaunchFactoryFixture, V4Actor} from "./helpers/LaunchFixtures.sol";

contract SOSLaunchTest is Test {
    PoolManager internal manager;
    LaunchFactoryFixture internal factory;
    SOS internal token;
    address internal constant DEV = address(0xDE7);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant DISTRIBUTOR = address(0xD157);
    uint64 internal constant LAUNCH = 42;
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        manager = new PoolManager(address(this));
        factory = new LaunchFactoryFixture(manager);
        token = factory.deployToken(DEV, LAUNCH);
    }

    function test_factoryReceivesEntireSupplyAndLaunchConfigurationIsImmutable() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.factory(), address(factory));
        assertEq(token.poolManager(), address(manager));
        assertEq(token.launchNumber(), LAUNCH);
        assertEq(token.dev(), DEV);
    }

    function test_swarmDistributionClaimsAndRemainderArriveWhole() public {
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        uint256 swarm = SUPPLY / 10;
        factory.distribute(token, DISTRIBUTOR, swarm);
        assertEq(token.balanceOf(DISTRIBUTOR), swarm);
        vm.prank(DISTRIBUTOR);
        token.transfer(ALICE, swarm / 3);
        vm.prank(DISTRIBUTOR);
        token.transfer(BOB, swarm - swarm / 3);
        assertEq(token.balanceOf(ALICE), swarm / 3);
        assertEq(token.balanceOf(BOB), swarm - swarm / 3);
        assertEq(token.balanceOf(DISTRIBUTOR), 0);
        factory.distribute(token, DEV, SUPPLY - swarm);
        assertEq(token.balanceOf(DEV), SUPPLY - swarm);
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ordinaryTransfersRemainTaxedAfterLaunch() public {
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        factory.distribute(token, ALICE, 1000 ether);
        vm.prank(ALICE);
        token.transfer(BOB, 100 ether);
        assertEq(token.balanceOf(BOB), 98 ether);
        assertEq(token.balanceOf(DEV), 1 ether);
        assertEq(token.totalSupply(), SUPPLY - 1 ether);
    }

    function test_transfersToFactoryAndDistributorAreTaxed() public {
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        factory.distribute(token, ALICE, 1000 ether);
        uint256 factoryBefore = token.balanceOf(address(factory));
        vm.startPrank(ALICE);
        token.transfer(address(factory), 100 ether);
        token.transfer(DISTRIBUTOR, 100 ether);
        vm.stopPrank();
        assertEq(token.balanceOf(address(factory)), factoryBefore + 98 ether);
        assertEq(token.balanceOf(DISTRIBUTOR), 98 ether);
        assertEq(token.balanceOf(DEV), 2 ether);
        assertEq(token.totalSupply(), SUPPLY - 2 ether);
    }

    function test_distributorLookupUsesExactLaunchAndDoesNotCacheZero() public {
        factory.distribute(token, DISTRIBUTOR, 300 ether);
        factory.setDistributor(LAUNCH + 1, DISTRIBUTOR);
        vm.prank(DISTRIBUTOR);
        token.transfer(ALICE, 100 ether);
        assertEq(token.balanceOf(ALICE), 98 ether);
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        vm.prank(DISTRIBUTOR);
        token.transfer(ALICE, 100 ether);
        assertEq(token.balanceOf(ALICE), 198 ether);
        factory.setDistributor(LAUNCH, BOB);
        vm.prank(DISTRIBUTOR);
        token.transfer(ALICE, 100 ether);
        assertEq(token.balanceOf(ALICE), 296 ether);
        assertEq(token.totalSupply(), SUPPLY - 2 ether);
    }

    function test_failedMalformedAndGasExhaustingRegistryCannotFreezeHolders() public {
        factory.distribute(token, ALICE, 1000 ether);
        for (uint8 mode = 1; mode <= 5; ++mode) {
            factory.setLookupMode(mode);
            vm.prank(ALICE);
            token.transfer(BOB, 100 ether);
            assertEq(token.balanceOf(BOB), uint256(mode) * 98 ether);
            assertEq(token.balanceOf(DEV), uint256(mode) * 1 ether);
            assertEq(token.totalSupply(), SUPPLY - uint256(mode) * 1 ether);
        }
        // Fast-path launch transfers also work without a successful registry lookup.
        factory.distribute(token, ALICE, 100 ether);
        vm.prank(ALICE);
        token.transfer(address(manager), 100 ether);
        assertEq(token.balanceOf(address(manager)), 100 ether);
    }

    function test_factoryWithoutCodeDoesNotFreezeOrdinaryTransfers() public {
        SOS configured = new SOS(DEV, address(0xFAC7), address(manager), LAUNCH);
        configured.transfer(ALICE, 100 ether);
        assertEq(configured.balanceOf(ALICE), 98 ether);
        assertEq(configured.balanceOf(DEV), 1 ether);
    }

    function test_allExemptOperatorsStillNeedAllowance() public {
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        factory.distribute(token, ALICE, 300 ether);
        address[3] memory operators = [address(factory), address(manager), DISTRIBUTOR];
        for (uint256 i; i < operators.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, operators[i], 0, 100 ether)
            );
            vm.prank(operators[i]);
            token.transferFrom(ALICE, BOB, 100 ether);
            vm.prank(ALICE);
            token.approve(operators[i], 100 ether);
            vm.prank(operators[i]);
            token.transferFrom(ALICE, BOB, 100 ether);
            assertEq(token.allowance(ALICE, operators[i]), 0);
        }
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 300 ether);
        assertEq(token.balanceOf(DEV), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ordinarySpenderCannotBorrowFactoryOrDistributorExemption() public {
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        factory.distribute(token, DISTRIBUTOR, 100 ether);
        vm.prank(address(factory));
        token.approve(BOB, 100 ether);
        vm.prank(DISTRIBUTOR);
        token.approve(BOB, 100 ether);
        vm.startPrank(BOB);
        token.transferFrom(address(factory), ALICE, 100 ether);
        token.transferFrom(DISTRIBUTOR, ALICE, 100 ether);
        vm.stopPrank();
        assertEq(token.balanceOf(ALICE), 196 ether);
        assertEq(token.balanceOf(DEV), 2 ether);
    }

    function test_allowanceRequiredEvenWhenSendingIntoManager() public {
        factory.distribute(token, ALICE, 100 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 100 ether));
        vm.prank(BOB);
        token.transferFrom(ALICE, address(manager), 100 ether);
        vm.prank(ALICE);
        token.approve(BOB, 100 ether);
        vm.prank(BOB);
        token.transferFrom(ALICE, address(manager), 100 ether);
        assertEq(token.balanceOf(address(manager)), 100 ether);
        assertEq(token.allowance(ALICE, BOB), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_realV4SingleSidedSeedAndBuySellSettleExactly() public {
        PoolKey memory key = _seedPool();
        V4Actor trader = new V4Actor(manager);
        vm.deal(address(trader), 10 ether);
        BalanceDelta buy = trader.swap(key, true, -0.01 ether, address(0));
        uint256 bought = token.balanceOf(address(trader));
        assertGt(bought, 0);
        assertEq(bought, uint128(buy.amount1()));
        uint256 managerBefore = token.balanceOf(address(manager));
        uint256 ethBefore = address(trader).balance;
        BalanceDelta sell = trader.swap(key, false, -int256(bought), address(0));
        assertEq(token.balanceOf(address(trader)), 0);
        assertEq(token.balanceOf(address(manager)), managerBefore + bought);
        assertEq(sell.amount1(), -int256(bought));
        assertGt(address(trader).balance, ethBefore);
        assertEq(token.balanceOf(DEV), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_realV4RouterTransferFromSellSettlesExactly() public {
        PoolKey memory key = _seedPool();
        V4Actor buyer = new V4Actor(manager);
        vm.deal(address(buyer), 10 ether);
        buyer.swap(key, true, -0.1 ether, address(0));
        uint256 amount = token.balanceOf(address(buyer)) / 2;
        factory.distribute(token, ALICE, amount);
        V4Actor router = new V4Actor(manager);
        vm.prank(ALICE);
        token.approve(address(router), amount);
        uint256 before = token.balanceOf(address(manager));
        router.swap(key, false, -int256(amount), ALICE);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.allowance(ALICE, address(router)), 0);
        assertEq(token.balanceOf(address(manager)), before + amount);
        assertGt(address(router).balance, 0);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(DEV), 0);
    }

    function testFuzz_factoryAndClaimTransfersAreExact(uint256 raw, uint256 rawClaim) public {
        uint256 amount = bound(raw, 0, SUPPLY);
        uint256 claim = bound(rawClaim, 0, amount);
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        factory.distribute(token, DISTRIBUTOR, amount);
        vm.prank(DISTRIBUTOR);
        token.transfer(ALICE, claim);
        assertEq(token.balanceOf(ALICE), claim);
        assertEq(token.balanceOf(DISTRIBUTOR), amount - claim);
        assertEq(token.balanceOf(address(factory)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(DEV), 0);
    }

    function _seedPool() private returns (PoolKey memory key) {
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        factory.distribute(token, DISTRIBUTOR, SUPPLY / 10);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(0)));
        manager.initialize(key, uint160(1 << 96));
        uint256 before = token.balanceOf(address(factory));
        BalanceDelta delta = factory.seed(key, -120, 0, 1_000_000 ether);
        assertEq(delta.amount0(), 0, "single-sided seed must not spend ETH");
        assertLt(delta.amount1(), 0);
        uint256 seeded = before - token.balanceOf(address(factory));
        assertGt(seeded, 0);
        assertEq(token.balanceOf(address(manager)), seeded);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
