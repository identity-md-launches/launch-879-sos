// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {SOS} from "../src/SOS.sol";

/// @notice Offline deployment rehearsal. Production custom launches use ProjectFactory.launchCustom.
contract Deploy is Script {
    error UnsupportedChain(uint256 chainId);

    /// @dev Local-only example. 0xD3E is a fixture, not the requester's address.
    function run() external returns (SOS) {
        require(block.chainid == 31337, "example is local only");
        return deploy(address(0xD3E));
    }

    /// @notice Rehearse a standalone deployment with an explicit Dev address.
    /// @dev No private keys, RPC configuration, environment reads, or broadcasting.
    function deploy(address dev) public returns (SOS token) {
        if (block.chainid != 31337 && block.chainid != 11155111) revert UnsupportedChain(block.chainid);
        token = new SOS(dev, address(0), address(0), 0);
    }
}
