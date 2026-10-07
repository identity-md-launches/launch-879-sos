// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
import {SOS} from "src/SOS.sol";

/// forge-config: default.fuzz.runs = 1000
contract SOSEdgeCasesTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant DEV = address(0xDE7);
    address internal constant SPENDER = address(0x5EED);
    SOS internal token;

    function setUp() public {
        vm.prank(ALICE);
        token = new SOS(DEV, address(0), address(0), 0);
    }

    function test_fullInitialSupplyCanMoveAndCannotBeSpentAgain() public {
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, SUPPLY));
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 980_000_000 ether);
        assertEq(token.balanceOf(DEV), 10_000_000 ether);
        assertEq(token.totalSupply(), 990_000_000 ether);
        bytes32 beforeState = _state();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(BOB, 1);
        assertEq(_state(), beforeState);
    }

    function test_fullSupplySelfTransferFromSpendsGrossAllowance() public {
        vm.prank(ALICE);
        token.approve(SPENDER, SUPPLY + 7);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, ALICE, SUPPLY));
        assertEq(token.balanceOf(ALICE), 980_000_000 ether);
        assertEq(token.balanceOf(DEV), 10_000_000 ether);
        assertEq(token.totalSupply(), 990_000_000 ether);
        assertEq(token.allowance(ALICE, SPENDER), 7);
    }

    function test_devCanDeployAndTransferEntireGrossBalance() public {
        vm.prank(DEV);
        SOS devOwned = new SOS(DEV, address(0), address(0), 0);
        assertEq(devOwned.balanceOf(DEV), SUPPLY);
        vm.prank(DEV);
        assertTrue(devOwned.transfer(BOB, SUPPLY));
        assertEq(devOwned.balanceOf(DEV), 10_000_000 ether);
        assertEq(devOwned.balanceOf(BOB), 980_000_000 ether);
        assertEq(devOwned.totalSupply(), 990_000_000 ether);
    }

    function test_devCannotBeTheTokenBeingConstructed() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(SOS.InvalidDev.selector);
        new SOS(predicted, address(0), address(0), 0);
    }

    function test_ownerCallingTransferFromStillNeedsApproval() public {
        bytes32 beforeState = _state();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 100));
        vm.prank(ALICE);
        token.transferFrom(ALICE, ALICE, 100);
        assertEq(_state(), beforeState);
        vm.startPrank(ALICE);
        token.approve(ALICE, 100);
        assertTrue(token.transferFrom(ALICE, ALICE, 100));
        vm.stopPrank();
        assertEq(token.allowance(ALICE, ALICE), 0);
        assertEq(token.balanceOf(ALICE), SUPPLY - 2);
        assertEq(token.balanceOf(DEV), 1);
        assertEq(token.totalSupply(), SUPPLY - 1);
    }

    function test_approvalsReplaceAndRevocationPreventsReuse() public {
        vm.startPrank(ALICE);
        token.approve(SPENDER, type(uint256).max);
        token.approve(SPENDER, 200);
        vm.stopPrank();
        assertEq(token.allowance(ALICE, SPENDER), 200);
        assertEq(token.balanceOf(ALICE), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 100);
        assertEq(token.allowance(ALICE, SPENDER), 100);
        vm.prank(ALICE);
        token.approve(SPENDER, 0);
        bytes32 beforeState = _state();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 100));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 100);
        assertEq(_state(), beforeState);
    }

    function test_exactApprovalCannotBeSpentTwice() public {
        vm.prank(ALICE);
        token.approve(SPENDER, 100);
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 100);
        bytes32 beforeState = _state();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 100));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 100);
        assertEq(_state(), beforeState);
    }

    function test_uint256MaxTransferFromRevertsWithoutOverflowOrAllowanceLoss() public {
        vm.prank(ALICE);
        token.approve(SPENDER, type(uint256).max);
        bytes32 beforeState = _state();
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, SUPPLY, type(uint256).max)
        );
        vm.prank(SPENDER);
        token.transferFrom(ALICE, DEV, type(uint256).max);
        assertEq(_state(), beforeState);
    }

    function testFuzz_zeroRecipientRollsBackFiniteAndInfiniteAllowance(uint256 raw, bool infinite) public {
        uint256 amount = bound(raw, 0, SUPPLY);
        vm.prank(ALICE);
        token.approve(SPENDER, infinite ? type(uint256).max : amount);
        bytes32 beforeState = _state();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, address(0), amount);
        assertEq(_state(), beforeState);
    }

    function testFuzz_netApprovalNeverAuthorizesGrossTransfer(uint256 raw) public {
        uint256 amount = bound(raw, 100, SUPPLY);
        uint256 net = amount - 2 * (amount / 100);
        vm.prank(ALICE);
        token.approve(SPENDER, net);
        bytes32 beforeState = _state();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, net, amount));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, amount);
        assertEq(_state(), beforeState);
    }

    /// @dev Metamorphic oracle: delegation must not alter transfer economics, including address aliases.
    function testFuzz_directAndDelegatedTransfersAgree(uint256 raw, uint8 recipient, bool devSender, bool infinite)
        public
    {
        address owner = devSender ? DEV : ALICE;
        vm.startPrank(owner);
        SOS direct = new SOS(DEV, address(0), address(0), 0);
        SOS delegated = new SOS(DEV, address(0), address(0), 0);
        uint256 amount = bound(raw, 0, SUPPLY);
        address to = recipient % 3 == 0 ? owner : recipient % 3 == 1 ? DEV : BOB;
        delegated.approve(SPENDER, infinite ? type(uint256).max : amount);
        assertTrue(direct.transfer(to, amount));
        vm.stopPrank();
        vm.prank(SPENDER);
        assertTrue(delegated.transferFrom(owner, to, amount));
        assertEq(delegated.totalSupply(), direct.totalSupply());
        assertEq(delegated.balanceOf(ALICE), direct.balanceOf(ALICE));
        assertEq(delegated.balanceOf(DEV), direct.balanceOf(DEV));
        assertEq(delegated.balanceOf(BOB), direct.balanceOf(BOB));
        assertEq(delegated.allowance(owner, SPENDER), infinite ? type(uint256).max : 0);
    }

    /// @dev This checks the floor inequalities, independently of recomputing the implementation's division.
    function testFuzz_feeRoundingAndLogsAccountForEveryWei(uint256 raw) public {
        uint256 amount = bound(raw, 0, SUPPLY);
        vm.recordLogs();
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, amount));
        uint256 burned = SUPPLY - token.totalSupply();
        uint256 tax = token.balanceOf(DEV);
        uint256 received = token.balanceOf(BOB);
        assertEq(tax, burned);
        assertLe(100 * tax, amount);
        assertLt(amount, 100 * (tax + 1));
        assertEq(received + tax + burned, amount);
        assertEq(token.balanceOf(ALICE), SUPPLY - amount);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, tax == 0 ? 1 : 3);
        uint256 logged;
        for (uint256 i; i < logs.length; ++i) {
            assertEq(logs[i].emitter, address(token));
            assertEq(logs[i].topics.length, 3);
            assertEq(logs[i].topics[0], keccak256("Transfer(address,address,uint256)"));
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(ALICE))));
            address expectedTo = tax == 0 || i == 2 ? BOB : i == 0 ? address(0) : DEV;
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(expectedTo))));
            uint256 value = abi.decode(logs[i].data, (uint256));
            assertEq(value, expectedTo == BOB ? received : tax);
            logged += value;
        }
        assertEq(logged, amount);
    }

    function _state() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                token.totalSupply(),
                token.balanceOf(ALICE),
                token.balanceOf(BOB),
                token.balanceOf(DEV),
                token.balanceOf(address(0)),
                token.balanceOf(address(token)),
                token.allowance(ALICE, SPENDER)
            )
        );
    }
}
