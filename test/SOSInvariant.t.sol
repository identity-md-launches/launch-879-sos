// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SOS} from "../src/SOS.sol";

contract SOSHandler is Test {
    SOS public token;
    address[5] public actors;
    uint256 public burned;

    constructor() {
        actors = [address(this), address(0xDE7), address(0xA11CE), address(0xB0B), address(0xCA11)];
        token = new SOS(actors[1], address(0), address(0), 0);
    }

    function move(uint256 fromSeed, uint256 toSeed, uint256 raw) external {
        address from = actors[fromSeed % actors.length];
        uint256 amount = bound(raw, 0, token.balanceOf(from));
        burned += amount / 100;
        vm.prank(from);
        token.transfer(actors[toSeed % actors.length], amount);
    }

    function moveApproved(uint256 fromSeed, uint256 toSeed, uint256 spenderSeed, uint256 raw, bool unlimited) external {
        address from = actors[fromSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        uint256 amount = bound(raw, 0, token.balanceOf(from));
        vm.prank(from);
        token.approve(spender, unlimited ? type(uint256).max : amount);
        burned += amount / 100;
        vm.prank(spender);
        token.transferFrom(from, actors[toSeed % actors.length], amount);
        assertEq(token.allowance(from, spender), unlimited ? type(uint256).max : 0);
    }
}

contract SOSInvariantTest is Test {
    SOSHandler internal handler;
    SOS internal token;

    function setUp() public {
        handler = new SOSHandler();
        token = handler.token();
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = SOSHandler.move.selector;
        selectors[1] = SOSHandler.moveApproved.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_supplyEqualsBalancesAndInitialSupplyMinusBurns() public view {
        uint256 balances;
        for (uint256 i; i < 5; ++i) {
            balances += token.balanceOf(handler.actors(i));
        }
        assertEq(balances, token.totalSupply());
        assertEq(token.totalSupply() + handler.burned(), token.INITIAL_SUPPLY());
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }
}
