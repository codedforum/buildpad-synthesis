// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title SwapHelper — V4 seed swap for BuildPad DexScreener indexing
contract SwapHelper is IUnlockCallback {
    using CurrencyLibrary for Currency;

    IPoolManager public immutable poolManager;
    address public owner;

    struct CallbackData {
        PoolKey key;
        address sender;
        uint256 amountIn;
    }

    constructor(IPoolManager _pm) {
        poolManager = _pm;
        owner = msg.sender;
    }

    /// @notice Swap ETH → Token through a V4 pool
    function seedSwap(PoolKey calldata key) external payable {
        require(msg.value > 0, "need ETH");
        poolManager.unlock(abi.encode(CallbackData(key, msg.sender, msg.value)));
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "only PM");
        CallbackData memory data = abi.decode(rawData, (CallbackData));

        // Swap: ETH (currency0) → Token (currency1)
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(data.amountIn), // negative = exactInput
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        BalanceDelta delta = poolManager.swap(data.key, params, "");

        // Settle: pay ETH to pool
        uint256 ethOwed = uint256(int256(-delta.amount0()));
        poolManager.settle{value: ethOwed}();

        // Take: receive tokens from pool  
        if (delta.amount1() > 0) {
            poolManager.take(data.key.currency1, data.sender, uint128(delta.amount1()));
        }

        return "";
    }

    receive() external payable {}

    function withdraw() external {
        require(msg.sender == owner);
        payable(owner).transfer(address(this).balance);
    }
}
