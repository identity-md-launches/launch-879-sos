// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SOS} from "../../src/SOS.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @dev Test-only controller for the same sync/transfer/settle and take flows used in the pinned floor.
contract V4Actor is IUnlockCallback {
    IPoolManager public immutable manager;
    address internal immutable controller = msg.sender;

    struct Action {
        PoolKey key;
        bool seed;
        bool zeroForOne;
        int256 amount;
        int24 lower;
        int24 upper;
        address payer;
    }

    modifier onlyController() {
        require(msg.sender == controller, "test controller only");
        _;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    receive() external payable {}

    function seed(PoolKey memory key, int24 lower, int24 upper, uint128 liquidity)
        external
        onlyController
        returns (BalanceDelta)
    {
        return abi.decode(
            manager.unlock(abi.encode(Action(key, true, false, int256(uint256(liquidity)), lower, upper, address(0)))),
            (BalanceDelta)
        );
    }

    function swap(PoolKey memory key, bool zeroForOne, int256 amount, address payer)
        external
        onlyController
        returns (BalanceDelta)
    {
        return abi.decode(
            manager.unlock(abi.encode(Action(key, false, zeroForOne, amount, 0, 0, payer))), (BalanceDelta)
        );
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        Action memory action = abi.decode(data, (Action));
        BalanceDelta delta;
        if (action.seed) {
            (delta,) = manager.modifyLiquidity(
                action.key, ModifyLiquidityParams(action.lower, action.upper, action.amount, bytes32(0)), ""
            );
        } else {
            uint160 limit = action.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
            delta = manager.swap(action.key, SwapParams(action.zeroForOne, action.amount, limit), "");
        }
        _settle(action.key.currency0, delta.amount0(), action.payer);
        _settle(action.key.currency1, delta.amount1(), action.payer);
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 delta, address payer) private {
        if (delta > 0) {
            manager.take(currency, address(this), uint128(delta));
        } else if (delta < 0) {
            uint256 debt = uint256(-int256(delta));
            if (Currency.unwrap(currency) == address(0)) {
                require(manager.settle{value: debt}() == debt, "native shortfall");
            } else {
                manager.sync(currency);
                IERC20 asset = IERC20(Currency.unwrap(currency));
                if (payer == address(0)) require(asset.transfer(address(manager), debt), "transfer failed");
                else require(asset.transferFrom(payer, address(manager), debt), "transferFrom failed");
                require(manager.settle() == debt, "token shortfall");
            }
        }
    }
}

contract LaunchFactoryFixture is V4Actor {
    mapping(uint64 => address) private distributors;
    uint8 public lookupMode;

    constructor(IPoolManager manager_) V4Actor(manager_) {}

    function deployToken(address dev, uint64 number) external onlyController returns (SOS) {
        return new SOS(dev, address(this), address(manager), number);
    }

    function setDistributor(uint64 number, address distributor) external onlyController {
        distributors[number] = distributor;
    }

    function setLookupMode(uint8 mode) external onlyController {
        lookupMode = mode;
    }

    function distributorOf(uint64 number) external view returns (address) {
        uint8 mode = lookupMode;
        if (mode == 1) revert("registry failure");
        if (mode == 2) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        if (mode == 3) {
            assembly ("memory-safe") {
                mstore(0, not(0))
                return(0, 32)
            }
        }
        if (mode == 4) {
            // Consume all forwarded gas. The token still has gas for an ordinary taxed transfer.
            assembly ("memory-safe") {
                invalid()
            }
        }
        if (mode == 5) {
            assembly ("memory-safe") {
                let p := mload(0x40)
                mstore(p, 0)
                return(p, 4096)
            }
        }
        return distributors[number];
    }

    function distribute(SOS token, address to, uint256 amount) external onlyController {
        require(token.transfer(to, amount), "distribution failed");
    }
}
