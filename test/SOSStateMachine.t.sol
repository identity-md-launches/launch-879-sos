// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SOS} from "src/SOS.sol";
import {LaunchFactoryFixture} from "./helpers/LaunchFixtures.sol";

/// @dev An economic ledger driven only by successful inputs, never by observed token balances.
/// Approvals and spends are separate actions so allowances survive across random calls.
contract SOSLedgerHandler is Test {
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    uint64 internal constant LAUNCH = 42;
    SOS public token;
    LaunchFactoryFixture public registry;
    address[7] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    uint256 public burned;
    uint256 public taxedMoves;
    uint256 public exactMoves;
    uint256 public rejectedCalls;
    uint256 public delegatedMoves;
    address public distributor;
    uint8 public lookupMode;
    bool public immutable launchMode;

    constructor(bool withLaunch) {
        launchMode = withLaunch;
        actors = [
            address(this),
            address(0xDE7),
            address(0xA11CE),
            address(0xB0B),
            address(0x9001),
            address(0xD157),
            address(0xD158)
        ];
        if (withLaunch) {
            // Token-level role testing; the existing launch suite exercises the real v4 manager.
            registry = new LaunchFactoryFixture(IPoolManager(actors[4]));
            actors[0] = address(registry);
            token = registry.deployToken(actors[1], LAUNCH);
            distributor = actors[5];
            registry.setDistributor(LAUNCH, distributor);
        } else {
            token = new SOS(actors[1], address(0), address(0), 0);
        }
        expectedBalance[actors[0]] = SUPPLY;
        // Fund every role through the public API, including Dev and both potential distributors.
        for (uint256 i = 1; i < actors.length; ++i) {
            _move(actors[0], actors[i], SUPPLY / 10);
        }
        // Make real delegated spends reachable from the first call; later approvals can revoke them.
        for (uint256 i; i < actors.length; ++i) {
            _approve(actors[i], actors[(i + 1) % actors.length], i % 2 == 0 ? SUPPLY / 2 : type(uint256).max);
        }
        taxedMoves = 0;
        exactMoves = 0;
    }

    function move(uint256 fromSeed, uint256 toSeed, uint256 raw) external {
        address from = _actor(fromSeed);
        _move(from, _actor(toSeed), _amount(raw, expectedBalance[from]));
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 raw, uint8 mode) external {
        uint256 amount = mode % 3 == 0 ? 0 : mode % 3 == 1 ? type(uint256).max : bound(raw, 0, SUPPLY);
        _approve(_actor(ownerSeed), _actor(spenderSeed), amount);
    }

    function spend(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 raw) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowed = expectedAllowance[owner][spender];
        uint256 cap = expectedBalance[owner] < allowed ? expectedBalance[owner] : allowed;
        uint256 amount = _amount(raw, cap);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        if (allowed != type(uint256).max) expectedAllowance[owner][spender] -= amount;
        _book(owner, to, spender, amount);
        if (amount != 0) delegatedMoves++;
    }

    function rejectOverspend(uint256 ownerSeed, uint256 toSeed, uint256 raw, bool delegated) external {
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 held = expectedBalance[owner];
        uint256 amount = raw % 2 == 0 ? held + 1 : type(uint256).max;
        address spender = actors[(ownerSeed % actors.length + 1) % actors.length];
        if (delegated) _approve(owner, spender, type(uint256).max);
        bytes memory data = delegated
            ? abi.encodeCall(token.transferFrom, (owner, to, amount))
            : abi.encodeCall(token.transfer, (to, amount));
        vm.prank(delegated ? spender : owner);
        (bool ok, bytes memory result) = address(token).call(data);
        assertFalse(ok, "gross balance is mandatory, even for self/Dev/exempt transfers");
        assertEq(result, abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, held, amount));
        rejectedCalls++;
    }

    function rejectAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 raw) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 amount = bound(raw, 1, SUPPLY);
        _approve(owner, spender, amount - 1);
        vm.prank(spender);
        (bool ok, bytes memory result) = address(token).call(abi.encodeCall(token.transferFrom, (owner, owner, amount)));
        assertFalse(ok, "self transfers and launch roles still need gross allowance");
        assertEq(
            result,
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, amount - 1, amount)
        );
        rejectedCalls++;
    }

    function rejectZeroRecipient(uint256 ownerSeed, uint256 raw) external {
        address owner = _actor(ownerSeed);
        address spender = actors[(ownerSeed % actors.length + 1) % actors.length];
        uint256 amount = _amount(raw, expectedBalance[owner]);
        _approve(owner, spender, amount);
        vm.prank(spender);
        (bool ok, bytes memory result) =
            address(token).call(abi.encodeCall(token.transferFrom, (owner, address(0), amount)));
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        rejectedCalls++;
    }

    function changeRegistry(uint256 distributorSeed, uint8 mode) external {
        require(launchMode, "launch handler only");
        // Changes model the external lookup dependency, not an SOS admin capability.
        distributor = distributorSeed % 3 == 0 ? address(0) : actors[5 + distributorSeed % 2];
        lookupMode = mode % 6;
        registry.setDistributor(LAUNCH, distributor);
        registry.setLookupMode(lookupMode);
    }

    function assertLedger() external view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            address owner = actors[i];
            assertEq(token.balanceOf(owner), expectedBalance[owner], "holder ledger diverged");
            sum += token.balanceOf(owner);
            for (uint256 j; j < actors.length; ++j) {
                assertEq(token.allowance(owner, actors[j]), expectedAllowance[owner][actors[j]], "allowance diverged");
            }
        }
        assertEq(sum, token.totalSupply(), "tokens escaped tracked holders");
        assertEq(token.totalSupply(), SUPPLY - burned, "only specified burns may change supply");
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.dev(), actors[1]);
    }

    function _move(address from, address to, uint256 amount) private {
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _book(from, to, from, amount);
    }

    function _approve(address owner, address spender, uint256 amount) private {
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function _book(address from, address to, address operator, uint256 amount) private {
        // Exact launch flows are specified by the protected floor. Other transfers pay two 1% legs.
        bool exact = launchMode
            && (operator == actors[0]
                || operator == actors[4]
                || to == actors[4]
                || (lookupMode == 0 && distributor != address(0) && operator == distributor));
        uint256 fee = exact ? 0 : amount * 100 / 10_000;
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount - 2 * fee;
        expectedBalance[actors[1]] += fee;
        burned += fee;
        if (fee > 0) taxedMoves++;
        if (exact && amount > 0) exactMoves++;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function _amount(uint256 raw, uint256 cap) private pure returns (uint256) {
        // Regularly reach empty/full balances and both sides of the fee threshold.
        if (raw % 5 == 0) return cap;
        if (raw % 5 == 1) return 0;
        if (raw % 5 == 2) return cap < 99 ? cap : 99;
        if (raw % 5 == 3) return cap < 100 ? cap : 100;
        return bound(raw, 0, cap);
    }
}

abstract contract SOSLedgerInvariantBase is Test {
    SOSLedgerHandler internal handler;

    function _setUpLedger(bool launch) internal {
        handler = new SOSLedgerHandler(launch);
        bytes4[] memory selectors = new bytes4[](launch ? 7 : 6);
        selectors[0] = SOSLedgerHandler.move.selector;
        selectors[1] = SOSLedgerHandler.approve.selector;
        selectors[2] = SOSLedgerHandler.spend.selector;
        selectors[3] = SOSLedgerHandler.rejectOverspend.selector;
        selectors[4] = SOSLedgerHandler.rejectAllowance.selector;
        selectors[5] = SOSLedgerHandler.rejectZeroRecipient.selector;
        if (launch) selectors[6] = SOSLedgerHandler.changeRegistry.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
        handler.assertLedger();
    }

    function invariant_balancesSupplyAndAllowancesMatchLedger() public view {
        handler.assertLedger();
    }

    /// @dev A deterministic reachability check complements random runs without probabilistic assertions.
    function test_handlerExercisesTaxSpendingRevocationAndRollback() public {
        handler.move(2, 3, 103);
        handler.approve(2, 3, 1000, 2);
        handler.spend(2, 3, 1, 100);
        handler.approve(2, 3, 0, 0);
        handler.rejectAllowance(2, 3, 100);
        handler.rejectOverspend(1, 1, 0, true);
        handler.rejectZeroRecipient(2, 100);
        handler.assertLedger();
        assertGt(handler.taxedMoves(), 0);
        assertGt(handler.delegatedMoves(), 0);
        assertEq(handler.rejectedCalls(), 3);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract SOSStandaloneLedgerInvariantTest is SOSLedgerInvariantBase {
    function setUp() public {
        _setUpLedger(false);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract SOSLaunchLedgerInvariantTest is SOSLedgerInvariantBase {
    function setUp() public {
        _setUpLedger(true);
    }

    function test_registryTransitionsExerciseExactAndTaxedClaims() public {
        handler.move(5, 2, 103);
        assertEq(handler.exactMoves(), 1);
        handler.changeRegistry(1, 0); // Then rotate to actor 6.
        handler.move(5, 2, 103);
        assertEq(handler.taxedMoves(), 1);
        handler.move(6, 2, 103);
        assertEq(handler.exactMoves(), 2);
        handler.changeRegistry(1, 1); // Reverting registry must not freeze a holder.
        handler.move(6, 2, 103);
        assertEq(handler.taxedMoves(), 2);
        handler.assertLedger();
    }
}
