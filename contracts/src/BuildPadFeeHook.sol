// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title BuildPadFeeHook v3
/// @notice Uniswap V4 hook with SNIPER TRAP (80% fee first 5 blocks)
///         then decaying fee (3% → 0.5% over 25 days).
///         All fees sent to designated fee wallet.
contract BuildPadFeeHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    address public owner;
    address public feeWallet;

    struct PoolFeeConfig {
        uint16 feeBps;           // Normal fee after sniper period (300 = 3%)
        uint16 sniperFeeBps;     // Sniper trap fee (8000 = 80%)
        uint32 sniperEndBlock;   // Block number when sniper period ends
        uint16 decayBpsPerDay;   // Daily fee decay rate
        uint48 startTime;        // Timestamp when normal decay begins
        uint16 minFeeBps;        // Fee floor (50 = 0.5%)
        bool active;
    }

    // Default sniper config
    uint16 public defaultSniperFeeBps = 8000;  // 80%
    uint32 public defaultSniperBlocks = 5;      // ~10 seconds on Base (2s blocks)
    uint16 public defaultFeeBps = 300;           // 3%
    uint16 public defaultDecayBpsPerDay = 10;    // 0.1%/day
    uint16 public defaultMinFeeBps = 50;         // 0.5%

    mapping(PoolId => PoolFeeConfig) public poolFees;
    mapping(address => bool) public whitelisted;
    mapping(PoolId => uint256) public totalFeesCollected;

    event FeeCollected(PoolId indexed poolId, address indexed token, uint256 amount);
    event PoolFeeSet(PoolId indexed poolId, uint16 feeBps, uint16 sniperBps, uint32 sniperBlocks);
    event SniperTrapped(PoolId indexed poolId, address indexed sender, uint256 feeAmount, uint256 blockNumber);
    event FeeWalletUpdated(address indexed oldWallet, address indexed newWallet);
    event WhitelistUpdated(address indexed account, bool status);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(IPoolManager _poolManager, address _feeWallet, address _owner) BaseHook(_poolManager) {
        owner = _owner;
        feeWallet = _feeWallet;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─── Pool Initialization ────────────────────────────────────────

    function _afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();

        poolFees[poolId] = PoolFeeConfig({
            feeBps: defaultFeeBps,
            sniperFeeBps: defaultSniperFeeBps,
            sniperEndBlock: uint32(block.number) + defaultSniperBlocks,
            decayBpsPerDay: defaultDecayBpsPerDay,
            startTime: uint48(block.timestamp),
            minFeeBps: defaultMinFeeBps,
            active: true
        });

        emit PoolFeeSet(poolId, defaultFeeBps, defaultSniperFeeBps, defaultSniperBlocks);
        return this.afterInitialize.selector;
    }

    // ─── Swap Fee Logic ─────────────────────────────────────────────

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        if (whitelisted[sender]) {
            return (this.afterSwap.selector, 0);
        }

        PoolId poolId = key.toId();
        PoolFeeConfig memory config = poolFees[poolId];

        if (!config.active || (config.feeBps == 0 && block.number >= config.sniperEndBlock)) {
            return (this.afterSwap.selector, 0);
        }

        uint16 currentFee = _getCurrentFee(config);

        // Determine output amount and currency
        int128 outputAmount;
        Currency feeCurrency;

        if (params.zeroForOne) {
            outputAmount = delta.amount1();
            feeCurrency = key.currency1;
        } else {
            outputAmount = delta.amount0();
            feeCurrency = key.currency0;
        }

        // Only take fee from negative delta (output)
        if (outputAmount >= 0) {
            return (this.afterSwap.selector, 0);
        }

        uint256 absOutput = uint256(uint128(-outputAmount));
        uint256 feeAmount = (absOutput * currentFee) / 10000;

        if (feeAmount == 0) {
            return (this.afterSwap.selector, 0);
        }

        totalFeesCollected[poolId] += feeAmount;
        poolManager.take(feeCurrency, feeWallet, feeAmount);

        // Log sniper traps separately for analytics
        if (block.number < config.sniperEndBlock) {
            emit SniperTrapped(poolId, sender, feeAmount, block.number);
        }

        emit FeeCollected(poolId, Currency.unwrap(feeCurrency), feeAmount);
        return (this.afterSwap.selector, int128(int256(feeAmount)));
    }

    function _getCurrentFee(PoolFeeConfig memory config) internal view returns (uint16) {
        // Phase 1: Sniper trap — 80% fee for first N blocks
        if (block.number < config.sniperEndBlock) {
            return config.sniperFeeBps;
        }

        // Phase 2: Normal decaying fee (3% → 0.5%)
        if (config.decayBpsPerDay == 0) return config.feeBps;
        uint256 daysElapsed = (block.timestamp - config.startTime) / 1 days;
        uint256 totalDecay = daysElapsed * config.decayBpsPerDay;
        if (config.feeBps <= config.minFeeBps + uint16(totalDecay)) {
            return config.minFeeBps;
        }
        return config.feeBps - uint16(totalDecay);
    }

    // ─── View Functions ─────────────────────────────────────────────

    function getCurrentFee(PoolKey calldata key) external view returns (uint16 fee, bool isSniperPeriod) {
        PoolFeeConfig memory config = poolFees[key.toId()];
        fee = _getCurrentFee(config);
        isSniperPeriod = block.number < config.sniperEndBlock;
    }

    function getPoolConfig(PoolKey calldata key) external view returns (
        uint16 feeBps,
        uint16 sniperFeeBps,
        uint32 sniperEndBlock,
        uint16 currentFee,
        bool isSniperActive,
        uint256 feesCollected,
        bool active
    ) {
        PoolId poolId = key.toId();
        PoolFeeConfig memory config = poolFees[poolId];
        feeBps = config.feeBps;
        sniperFeeBps = config.sniperFeeBps;
        sniperEndBlock = config.sniperEndBlock;
        currentFee = _getCurrentFee(config);
        isSniperActive = block.number < config.sniperEndBlock;
        feesCollected = totalFeesCollected[poolId];
        active = config.active;
    }

    // ─── Admin Functions ────────────────────────────────────────────

    function setPoolFee(
        PoolKey calldata key,
        uint16 feeBps,
        uint16 decayBpsPerDay,
        uint16 minFeeBps
    ) external onlyOwner {
        require(feeBps <= 1000, "fee too high"); // Max 10% for manual override
        PoolId poolId = key.toId();
        PoolFeeConfig storage config = poolFees[poolId];
        config.feeBps = feeBps;
        config.decayBpsPerDay = decayBpsPerDay;
        config.minFeeBps = minFeeBps;
        config.startTime = uint48(block.timestamp);
        config.sniperEndBlock = 0; // Clear sniper period on manual override
        emit PoolFeeSet(poolId, feeBps, 0, 0);
    }

    function setDefaults(
        uint16 _sniperFeeBps,
        uint32 _sniperBlocks,
        uint16 _feeBps,
        uint16 _decayBpsPerDay,
        uint16 _minFeeBps
    ) external onlyOwner {
        require(_sniperFeeBps <= 9000, "sniper fee too high"); // Max 90%
        require(_feeBps <= 1000, "fee too high");
        defaultSniperFeeBps = _sniperFeeBps;
        defaultSniperBlocks = _sniperBlocks;
        defaultFeeBps = _feeBps;
        defaultDecayBpsPerDay = _decayBpsPerDay;
        defaultMinFeeBps = _minFeeBps;
    }

    function setFeeWallet(address _feeWallet) external onlyOwner {
        require(_feeWallet != address(0), "zero");
        emit FeeWalletUpdated(feeWallet, _feeWallet);
        feeWallet = _feeWallet;
    }

    function setWhitelist(address account, bool status) external onlyOwner {
        whitelisted[account] = status;
        emit WhitelistUpdated(account, status);
    }

    function togglePoolFees(PoolKey calldata key, bool active) external onlyOwner {
        poolFees[key.toId()].active = active;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero");
        owner = newOwner;
    }
}
