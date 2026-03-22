// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Minimal WETH interface for wrapping ETH.
interface IWETH {
    function deposit() external payable;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice Minimal Permit2 interface for token approvals.
interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @notice Minimal PoolManager interface for pool initialization.
interface IPoolManagerMinimal {
    function initialize(
        PoolKeyStruct calldata key,
        uint160 sqrtPriceX96
    ) external returns (int24 tick);
}

/// @notice Minimal PositionManager interface for adding liquidity.
interface IPositionManagerMinimal {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function nextTokenId() external view returns (uint256);
}

/// @dev Struct matching Uniswap V4 PoolKey layout.
struct PoolKeyStruct {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @title BuildPadGraduator
/// @author BuildPad (SmartCodedBot)
/// @notice Receives graduated tokens from BondingCurve contracts and creates
///         a Uniswap V4 pool with the BuildPadFeeHook. All LP is locked
///         permanently in this contract (anti-rug).
/// @dev Only callable by registered bonding curve contracts. The hook's
///      afterInitialize automatically activates the sniper trap on pool creation.
contract BuildPadGraduator is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Constants (Base Chain) ─────────────────────────────────────────

    address public constant WETH = 0x4200000000000000000000000000000000000006;
    address public constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address public constant POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
    address public constant HOOK = 0xe0a19b19E3e6980067Cbc8D983bCb11eAB485044;
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // V4 pool config
    uint24 public constant POOL_FEE = 3000;        // 0.3% (dynamic fee via hook)
    int24 public constant TICK_SPACING = 60;        // Standard for 0.3% fee tier
    int24 public constant MIN_TICK = -887220;       // Full range lower tick (aligned to spacing 60)
    int24 public constant MAX_TICK = 887220;        // Full range upper tick (aligned to spacing 60)

    // ─── State ──────────────────────────────────────────────────────────

    /// @notice Registered bonding curve contracts that may call graduate().
    mapping(address => bool) public authorizedCurves;

    /// @notice Tracks graduated tokens → prevents double graduation.
    mapping(address => bool) public graduatedTokens;

    /// @notice LP token IDs held permanently (locked).
    mapping(address => uint256) public lockedLPTokens;

    // ─── Events ─────────────────────────────────────────────────────────

    event CurveAuthorized(address indexed curve, bool authorized);
    event GraduationComplete(
        address indexed tokenAddress,
        address indexed curve,
        uint256 ethAmount,
        uint256 tokenAmount,
        uint256 lpTokenId
    );

    // ─── Errors ─────────────────────────────────────────────────────────

    error NotAuthorizedCurve();
    error AlreadyGraduated();
    error ZeroAmount();
    error ZeroAddress();
    error TransferFailed();
    error PoolCreationFailed();

    // ─── Constructor ────────────────────────────────────────────────────

    constructor() Ownable(msg.sender) {}

    // ─── Admin ──────────────────────────────────────────────────────────

    /// @notice Authorize or deauthorize a bonding curve contract.
    /// @param curve     Address of the BondingCurve contract.
    /// @param authorized Whether it's allowed to call graduate().
    function authorizeCurve(address curve, bool authorized) external onlyOwner {
        if (curve == address(0)) revert ZeroAddress();
        authorizedCurves[curve] = authorized;
        emit CurveAuthorized(curve, authorized);
    }

    // ─── Graduation Entry Point ─────────────────────────────────────────

    /// @notice Called by a bonding curve when graduation threshold is reached.
    ///         Wraps ETH to WETH, creates V4 pool, adds full-range liquidity.
    /// @param tokenAddress The graduated ERC20 token address.
    /// @param tokenAmount  Amount of tokens to pair with ETH for LP.
    function graduate(address tokenAddress, uint256 tokenAmount) external payable nonReentrant {
        if (!authorizedCurves[msg.sender]) revert NotAuthorizedCurve();
        if (graduatedTokens[tokenAddress]) revert AlreadyGraduated();
        if (msg.value == 0) revert ZeroAmount();
        if (tokenAmount == 0) revert ZeroAmount();

        graduatedTokens[tokenAddress] = true;

        // Pull tokens from the bonding curve
        IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), tokenAmount);

        // Wrap ETH → WETH
        IWETH(WETH).deposit{value: msg.value}();

        // Sort tokens for V4 (currency0 < currency1)
        (address currency0, address currency1, uint256 amount0, uint256 amount1) = _sortTokens(
            WETH, tokenAddress, msg.value, tokenAmount
        );

        // Calculate initial sqrtPriceX96 based on amounts
        uint160 sqrtPriceX96 = _calculateSqrtPrice(amount0, amount1);

        // 1. Initialize the V4 pool
        PoolKeyStruct memory poolKey = PoolKeyStruct({
            currency0: currency0,
            currency1: currency1,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: HOOK
        });

        IPoolManagerMinimal(POOL_MANAGER).initialize(poolKey, sqrtPriceX96);

        // 2. Approve tokens via Permit2 for PositionManager
        IERC20(currency0).approve(PERMIT2, type(uint256).max);
        IERC20(currency1).approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(currency0, POSITION_MANAGER, type(uint160).max, type(uint48).max);
        IPermit2(PERMIT2).approve(currency1, POSITION_MANAGER, type(uint160).max, type(uint48).max);

        // 3. Add full-range liquidity via PositionManager
        uint256 lpTokenId = _addFullRangeLiquidity(
            poolKey, amount0, amount1
        );

        // Store the LP token ID — locked permanently in this contract
        lockedLPTokens[tokenAddress] = lpTokenId;

        emit GraduationComplete(tokenAddress, msg.sender, msg.value, tokenAmount, lpTokenId);
    }

    // ─── Internal: Add Liquidity ────────────────────────────────────────

    /// @dev Constructs the modifyLiquidities calldata for a full-range mint.
    ///      Uses V4 PositionManager's MINT_POSITION + SETTLE_PAIR actions.
    function _addFullRangeLiquidity(
        PoolKeyStruct memory poolKey,
        uint256 amount0Max,
        uint256 amount1Max
    ) internal returns (uint256 lpTokenId) {
        lpTokenId = IPositionManagerMinimal(POSITION_MANAGER).nextTokenId();

        // Calculate liquidity from amounts (simplified — PositionManager handles exact math)
        // We encode: [MINT_POSITION, SETTLE_PAIR, TAKE_PAIR]
        // Action codes for V4 PositionManager:
        //   MINT_POSITION = 0x01
        //   SETTLE_PAIR   = 0x0b  (11)
        //   TAKE_PAIR     = 0x0c  (12)
        //   CLOSE_CURRENCY = 0x11 (17)

        // Encode actions
        bytes memory actions = abi.encodePacked(
            uint8(0x01), // MINT_POSITION
            uint8(0x11), // CLOSE_CURRENCY (currency0)
            uint8(0x11)  // CLOSE_CURRENCY (currency1)
        );

        // Encode params for MINT_POSITION
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            poolKey,
            MIN_TICK,
            MAX_TICK,
            _calculateLiquidity(amount0Max, amount1Max),
            amount0Max,
            amount1Max,
            address(this), // LP owner = this contract (locked)
            bytes("")      // hookData
        );
        params[1] = abi.encode(poolKey.currency0);
        params[2] = abi.encode(poolKey.currency1);

        bytes memory unlockData = abi.encode(actions, params);

        IPositionManagerMinimal(POSITION_MANAGER).modifyLiquidities(
            unlockData,
            block.timestamp + 300 // 5 minute deadline
        );
    }

    // ─── Internal: Helpers ──────────────────────────────────────────────

    /// @dev Sort tokens so currency0 < currency1 (V4 requirement).
    function _sortTokens(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB
    ) internal pure returns (address currency0, address currency1, uint256 amount0, uint256 amount1) {
        if (tokenA < tokenB) {
            (currency0, currency1, amount0, amount1) = (tokenA, tokenB, amountA, amountB);
        } else {
            (currency0, currency1, amount0, amount1) = (tokenB, tokenA, amountB, amountA);
        }
    }

    /// @dev Approximate sqrtPriceX96 from token amounts.
    ///      sqrtPriceX96 = sqrt(amount1/amount0) * 2^96
    ///      Uses a simplified integer sqrt for on-chain computation.
    function _calculateSqrtPrice(uint256 amount0, uint256 amount1) internal pure returns (uint160) {
        // price = amount1 / amount0
        // sqrtPrice = sqrt(price) * 2^96
        // To avoid overflow: sqrt(amount1 * 2^192 / amount0)
        
        // Simplified: use the ratio scaled by 2^192 then sqrt
        // For safety, we use a balanced approach
        if (amount0 == 0 || amount1 == 0) {
            // Default to 1:1 price
            return uint160(1 << 96);
        }

        // Calculate price ratio with 96-bit precision
        // sqrtPriceX96 = sqrt(amount1 / amount0) * 2^96
        uint256 ratio = (amount1 * 1e18) / amount0;
        uint256 sqrtRatio = _sqrt(ratio);
        // Scale: sqrt(ratio) * 2^96 / sqrt(1e18)
        // sqrt(1e18) ≈ 1e9
        uint256 result = (sqrtRatio * (1 << 96)) / 1e9;
        
        return uint160(result);
    }

    /// @dev Calculate liquidity from amounts for full-range position.
    ///      Simplified approximation — PositionManager clamps to actual available.
    function _calculateLiquidity(uint256 amount0, uint256 amount1) internal pure returns (uint128) {
        // For full-range, liquidity ≈ sqrt(amount0 * amount1)
        uint256 liq = _sqrt(amount0 * amount1);
        return uint128(liq > type(uint128).max ? type(uint128).max : liq);
    }

    /// @dev Integer square root (Babylonian method).
    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }

    // ─── View Functions ─────────────────────────────────────────────────

    /// @notice Check if a token has been graduated through this contract.
    function isGraduated(address tokenAddress) external view returns (bool) {
        return graduatedTokens[tokenAddress];
    }

    /// @notice Get the locked LP token ID for a graduated token.
    function getLPTokenId(address tokenAddress) external view returns (uint256) {
        return lockedLPTokens[tokenAddress];
    }

    // ─── Receive ────────────────────────────────────────────────────────

    /// @dev Accept ETH from bonding curves during graduation.
    receive() external payable {}
}
