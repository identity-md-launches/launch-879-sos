// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
import {SOS} from "../src/SOS.sol";
import {Deploy} from "../script/Deploy.s.sol";

contract SOSTest is Test {
    SOS internal token;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant DEV = address(0xDE7);
    address internal constant SPENDER = address(0x5EED);
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        vm.prank(ALICE);
        token = new SOS(DEV, address(0), address(0), 0);
    }

    function test_initialSupplyAndMetadata() public view {
        assertEq(token.name(), "SOS");
        assertEq(token.symbol(), "SOS");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(ALICE), SUPPLY);
        assertEq(token.balanceOf(DEV), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.dev(), DEV);
        assertEq(token.BURN_BPS(), 100);
        assertEq(token.DEV_TAX_BPS(), 100);
    }

    function test_constructorEmitsSingleFullMint() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), BOB, SUPPLY);
        vm.prank(BOB);
        SOS second = new SOS(DEV, address(0), address(0), 0);
        assertEq(second.balanceOf(BOB), SUPPLY);
    }

    function test_standaloneDeployerCanBeDevAndStillPaysBurn() public {
        vm.prank(DEV);
        SOS standalone = new SOS(DEV, address(0), address(0), 0);
        assertEq(standalone.balanceOf(DEV), SUPPLY);
        vm.prank(DEV);
        standalone.transfer(BOB, 100 ether);
        assertEq(standalone.balanceOf(BOB), 98 ether);
        assertEq(standalone.balanceOf(DEV), SUPPLY - 99 ether);
        assertEq(standalone.totalSupply(), SUPPLY - 1 ether);
    }

    function test_transferBurnsOnePercentAndPaysDevOnePercent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(ALICE, address(0), 1 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(ALICE, DEV, 1 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(ALICE, BOB, 98 ether);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 100 ether));
        assertEq(token.balanceOf(ALICE), SUPPLY - 100 ether);
        assertEq(token.balanceOf(BOB), 98 ether);
        assertEq(token.balanceOf(DEV), 1 ether);
        assertEq(token.totalSupply(), SUPPLY - 1 ether);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function test_zeroTransferEmitsAndSucceedsWithoutBalance() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(BOB, ALICE, 0);
        vm.prank(BOB);
        assertTrue(token.transfer(ALICE, 0));
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(BOB, ALICE, 0));
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_roundingBoundaries() public {
        uint256[6] memory amounts = [uint256(1), 99, 100, 101, 199, 200];
        uint256[6] memory fees = [uint256(0), 0, 1, 1, 1, 2];
        for (uint256 i; i < amounts.length; ++i) {
            uint256 bobBefore = token.balanceOf(BOB);
            uint256 supplyBefore = token.totalSupply();
            uint256 devBefore = token.balanceOf(DEV);
            vm.prank(ALICE);
            token.transfer(BOB, amounts[i]);
            assertEq(token.balanceOf(BOB) - bobBefore, amounts[i] - 2 * fees[i]);
            assertEq(supplyBefore - token.totalSupply(), fees[i]);
            assertEq(token.balanceOf(DEV) - devBefore, fees[i]);
        }
    }

    function test_approveAndTransferFromSpendGrossAmount() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(ALICE, SPENDER, 150 ether);
        vm.prank(ALICE);
        assertTrue(token.approve(SPENDER, 150 ether));
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, BOB, 100 ether));
        assertEq(token.allowance(ALICE, SPENDER), 50 ether);
        assertEq(token.balanceOf(BOB), 98 ether);
        assertEq(token.balanceOf(DEV), 1 ether);
        assertEq(token.balanceOf(ALICE), SUPPLY - 100 ether);
        assertEq(token.totalSupply(), SUPPLY - 1 ether);
    }

    function test_infiniteAllowanceAndRevocation() public {
        vm.prank(ALICE);
        token.approve(SPENDER, type(uint256).max);
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 100 ether);
        assertEq(token.allowance(ALICE, SPENDER), type(uint256).max);
        vm.prank(ALICE);
        token.approve(SPENDER, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 1);
    }

    function test_insufficientAllowanceRevertsWithoutChangingBalances() public {
        vm.prank(ALICE);
        token.approve(SPENDER, 98 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 98 ether, 100 ether)
        );
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 100 ether);
        assertEq(token.balanceOf(ALICE), SUPPLY);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(DEV), 0);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.allowance(ALICE, SPENDER), 98 ether);
    }

    function test_balanceFailureRestoresSpentAllowance() public {
        vm.prank(BOB);
        token.approve(SPENDER, 100 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, BOB, 0, 100 ether));
        vm.prank(SPENDER);
        token.transferFrom(BOB, ALICE, 100 ether);
        assertEq(token.allowance(BOB, SPENDER), 100 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_selfTransferStillChargesFees() public {
        vm.prank(ALICE);
        token.transfer(ALICE, 100 ether);
        assertEq(token.balanceOf(ALICE), SUPPLY - 2 ether);
        assertEq(token.balanceOf(DEV), 1 ether);
        assertEq(token.totalSupply(), SUPPLY - 1 ether);
    }

    function test_transferToDevCombinesNetAndTax() public {
        vm.prank(ALICE);
        token.transfer(DEV, 100 ether);
        assertEq(token.balanceOf(DEV), 99 ether);
        assertEq(token.balanceOf(ALICE), SUPPLY - 100 ether);
        assertEq(token.totalSupply(), SUPPLY - 1 ether);
    }

    function test_transferFromDevAndDevSelfTransfer() public {
        vm.prank(ALICE);
        token.transfer(DEV, 1000 ether);
        vm.prank(DEV);
        token.transfer(BOB, 100 ether);
        assertEq(token.balanceOf(DEV), 891 ether);
        assertEq(token.balanceOf(BOB), 98 ether);
        vm.prank(DEV);
        token.transfer(DEV, 100 ether);
        assertEq(token.balanceOf(DEV), 890 ether);
        assertEq(token.totalSupply(), SUPPLY - 12 ether);
    }

    function test_selfAndDevTransfersRequireGrossBalance() public {
        vm.prank(ALICE);
        token.transfer(DEV, 100 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, DEV, 99 ether, 100 ether)
        );
        vm.prank(DEV);
        token.transfer(BOB, 100 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, DEV, 99 ether, 100 ether)
        );
        vm.prank(DEV);
        token.transfer(DEV, 100 ether);
        assertEq(token.balanceOf(DEV), 99 ether);
    }

    function test_invalidAddressesAndConfiguration() public {
        _assertConstructorReverts(address(0), address(0), address(0), 0, SOS.InvalidDev.selector);
        _assertConstructorReverts(DEV, ALICE, address(0), 1, SOS.InvalidLaunchConfiguration.selector);
        _assertConstructorReverts(DEV, address(0), ALICE, 1, SOS.InvalidLaunchConfiguration.selector);
        _assertConstructorReverts(DEV, address(0), address(0), 1, SOS.InvalidLaunchConfiguration.selector);
        _assertConstructorReverts(DEV, ALICE, ALICE, 1, SOS.InvalidLaunchConfiguration.selector);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(ALICE);
        token.transfer(address(0), 100 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(ALICE);
        token.transfer(address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(ALICE);
        token.approve(address(0), 100 ether);
        // transferFrom validates the allowance owner before reaching _transfer.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.transferFrom(address(0), ALICE, 0);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(ALICE), SUPPLY);
        assertEq(token.balanceOf(DEV), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.allowance(ALICE, address(0)), 0);
        assertEq(token.allowance(address(0), address(this)), 0);
    }

    function _assertConstructorReverts(
        address dev,
        address factory,
        address manager,
        uint64 launchNumber,
        bytes4 expectedError
    ) private {
        // Raw CREATE avoids Foundry 1.8.3 rewriting `new SOS` to deployCode,
        // whose expected revert can terminate the test before later checks run.
        bytes memory code = abi.encodePacked(type(SOS).creationCode, abi.encode(dev, factory, manager, launchNumber));
        address deployed;
        uint256 returnSize;
        assembly ("memory-safe") {
            deployed := create(0, add(code, 0x20), mload(code))
            returnSize := returndatasize()
        }
        bytes memory reason = new bytes(returnSize);
        assembly ("memory-safe") {
            returndatacopy(add(reason, 0x20), 0, returnSize)
        }
        assertEq(deployed, address(0), "invalid constructor succeeded");
        assertEq(reason, abi.encodeWithSelector(expectedError), "unexpected constructor revert");
    }

    function test_zeroRecipientRestoresAllowance() public {
        vm.prank(ALICE);
        token.approve(SPENDER, 100 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, address(0), 100 ether);
        assertEq(token.allowance(ALICE, SPENDER), 100 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_noAdministrativeEntryPoints() public {
        bytes[12] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", BOB, SUPPLY),
            abi.encodeWithSignature("burnFrom(address,uint256)", ALICE, SUPPLY),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("blacklist(address)", ALICE),
            abi.encodeWithSignature("seize(address)", ALICE),
            abi.encodeWithSignature("setDev(address)", BOB),
            abi.encodeWithSignature("setTax(uint256)", 10000),
            abi.encodeWithSignature("setFeeExempt(address,bool)", BOB, true),
            abi.encodeWithSignature("transferOwnership(address)", BOB),
            abi.encodeWithSignature("upgradeTo(address)", BOB),
            abi.encodeWithSignature("initialize(address)", BOB),
            abi.encodeWithSignature("setFactory(address)", BOB)
        ];
        address[3] memory callers = [ALICE, DEV, BOB];
        for (uint256 i; i < callers.length; ++i) {
            for (uint256 j; j < calls.length; ++j) {
                vm.prank(callers[i]);
                (bool ok,) = address(token).call(calls[j]);
                assertFalse(ok);
            }
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(ALICE), SUPPLY);
        vm.prank(ALICE);
        token.transfer(BOB, 100 ether);
        assertEq(token.balanceOf(BOB), 98 ether);
    }

    function test_runtimeContainsNoProhibitedOpcodes() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
            } else {
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
            }
        }
    }

    function testFuzz_transferConservesSupply(uint256 raw) public {
        uint256 amount = bound(raw, 0, SUPPLY);
        vm.prank(ALICE);
        token.transfer(BOB, amount);
        assertEq(token.balanceOf(ALICE), SUPPLY - amount);
        assertEq(token.balanceOf(BOB), amount - 2 * (amount / 100));
        assertEq(token.balanceOf(DEV), amount / 100);
        assertEq(token.totalSupply(), SUPPLY - amount / 100);
        assertEq(token.balanceOf(ALICE) + token.balanceOf(BOB) + token.balanceOf(DEV), token.totalSupply());
    }

    function testFuzz_transferFromChargesGrossAllowance(uint256 raw, uint256 extraRaw) public {
        uint256 amount = bound(raw, 0, SUPPLY);
        uint256 extra = bound(extraRaw, 0, SUPPLY);
        vm.prank(ALICE);
        token.approve(SPENDER, amount + extra);
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, amount);
        assertEq(token.allowance(ALICE, SPENDER), extra);
        assertEq(token.balanceOf(BOB), amount - 2 * (amount / 100));
        assertEq(token.balanceOf(DEV), amount / 100);
        assertEq(token.totalSupply(), SUPPLY - amount / 100);
    }

    function testFuzz_excessiveGrossAmountReverts(uint256 raw) public {
        uint256 amount = bound(raw, SUPPLY + 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, SUPPLY, amount));
        vm.prank(ALICE);
        token.transfer(ALICE, amount);
        assertEq(token.totalSupply(), SUPPLY);
    }
}

contract DeployTest is Test {
    function test_explicitConfigurationAndConstructorRecipient() public {
        vm.chainId(11155111);
        Deploy script = new Deploy();
        SOS token = script.deploy(address(0xDE7));
        assertEq(token.dev(), address(0xDE7));
        assertEq(token.balanceOf(address(script)), token.INITIAL_SUPPLY());
        assertEq(token.factory(), address(0));
    }

    function test_localExample() public {
        vm.chainId(31337);
        SOS token = (new Deploy()).run();
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function test_wrongChainReverts() public {
        Deploy script = new Deploy();
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnsupportedChain.selector, 1));
        script.deploy(address(0xDE7));
    }
}
