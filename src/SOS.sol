// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface ILaunchFactory {
    function distributorOf(uint64 launchNumber) external view returns (address);
}

/// @notice Fixed-supply SOS: ordinary transfers burn 1% and pay 1% to Dev.
/// @dev Launch exemptions preserve exact settlement for the IMD factory, claims and v4 pools.
contract SOS is ERC20 {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant BURN_BPS = 100;
    uint256 public constant DEV_TAX_BPS = 100;
    uint256 private constant DISTRIBUTOR_LOOKUP_GAS = 30_000;

    address public immutable dev;
    address public immutable factory;
    address public immutable poolManager;
    uint64 public immutable launchNumber;

    error InvalidDev();
    error InvalidLaunchConfiguration();

    /// @param dev_ Permanent recipient of the 1% SOS tax; never inferred from the deploying factory.
    /// @param factory_ IMD factory, or zero to disable all launch exemptions.
    /// @param poolManager_ IMD PoolManager, or zero when factory_ is zero.
    /// @param launchNumber_ Factory's distributor lookup key; zero when launch exemptions are disabled.
    // Zero factory/manager are intentional standalone-mode sentinels, validated together below.
    // forge-lint: disable-next-line(missing-zero-check)
    constructor(address dev_, address factory_, address poolManager_, uint64 launchNumber_) ERC20("SOS", "SOS") {
        if (dev_ == address(0) || dev_ == address(this)) revert InvalidDev();
        if (
            (factory_ == address(0)) != (poolManager_ == address(0)) || (factory_ == address(0) && launchNumber_ != 0)
                || (factory_ != address(0) && factory_ == poolManager_)
        ) revert InvalidLaunchConfiguration();

        dev = dev_;
        factory = factory_;
        poolManager = poolManager_;
        launchNumber = launchNumber_;
        _mint(msg.sender, INITIAL_SUPPLY);
    }

    function _update(address from, address to, uint256 amount) internal override {
        // Minting occurs only in the constructor. There is no external mint/burn or admin API.
        if (from == address(0)) {
            super._update(from, to, amount);
            return;
        }

        // Check the gross amount first, including self-transfers and transfers from/to Dev.
        // Checking only each fee leg would let credited balances fund an oversized transfer.
        uint256 held = balanceOf(from);
        if (held < amount) revert ERC20InsufficientBalance(from, held, amount);

        uint256 fee = amount / 100;
        if (fee == 0 || _isLaunchTransfer(to)) {
            super._update(from, to, amount);
            return;
        }

        // Base calls do not recurse into this override: fee payments are never taxed again.
        super._update(from, address(0), fee);
        super._update(from, dev, fee);
        super._update(from, to, amount - fee - fee);
    }

    function _isLaunchTransfer(address to) private view returns (bool) {
        if (factory == address(0)) return false;
        address operator = _msgSender();
        // A trader/router, not the manager, sends tokens in while settling a v4 sell.
        if (operator == factory || operator == poolManager || to == poolManager) return true;
        address distributor = _distributor();
        return distributor != address(0) && operator == distributor;
    }

    /// @dev A failed lookup must not freeze ordinary transfers. Bound both gas and copied returndata;
    /// STATICCALL prevents the registry from changing token state during its lookup.
    function _distributor() private view returns (address distributor) {
        bytes memory data = abi.encodeCall(ILaunchFactory.distributorOf, (launchNumber));
        address registry = factory;
        uint256 gasLimit = DISTRIBUTOR_LOOKUP_GAS;
        bool ok;
        uint256 size;
        uint256 result;
        assembly ("memory-safe") {
            let output := mload(0x40)
            mstore(output, 0)
            ok := staticcall(gasLimit, registry, add(data, 32), mload(data), output, 32)
            size := returndatasize()
            result := mload(output)
        }
        if (ok && size == 32 && result <= type(uint160).max) {
            // The explicit upper bound above guarantees an untruncated ABI address.
            // forge-lint: disable-next-line(unsafe-typecast)
            distributor = address(uint160(result));
        }
    }
}
