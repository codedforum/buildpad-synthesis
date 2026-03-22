/**
 * BuildPad V2 — V4 Pool Creation + Liquidity + Seed Swap
 * 
 * Creates Uniswap V4 pools with BuildPadFeeHook attached.
 * Supports ETH, WETH, USDC, or custom ERC-20 as LP pair token.
 * Adds initial liquidity (full-range) in a single flow.
 * Executes seed swap for DexScreener indexing (ETH pairs only).
 */

const { ethers } = require('ethers');
const { BASE } = require('./config');

const POSITION_MANAGER = BASE.positionManager;
const PERMIT2 = BASE.permit2;
const POOL_MANAGER = BASE.poolManager;

// SwapHelper contract — deployed on Base for V4 seed swaps
const SWAP_HELPER = '0x810CFEF5f6fdDA9f300E70DdB1a2f9F6D0ffAe84';

const PM_ABI = [
  'function initializePool((address,address,uint24,int24,address), uint160) external payable returns (int24)',
  'function modifyLiquidities(bytes, uint256) external payable',
];

const ERC20_ABI = [
  'function approve(address,uint256) external returns (bool)',
  'function balanceOf(address) view returns (uint256)',
  'function totalSupply() view returns (uint256)',
  'function decimals() view returns (uint8)',
];

const PERMIT2_ABI = [
  'function approve(address,address,uint160,uint48) external',
];

const SWAP_HELPER_ABI = [
  'function seedSwap(tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key) external payable',
];

// Known LP pair tokens on Base
const LP_TOKENS = {
  eth:  { address: ethers.ZeroAddress, decimals: 18, symbol: 'ETH' },
  weth: { address: BASE.weth, decimals: 18, symbol: 'WETH' },
  usdc: { address: BASE.usdc, decimals: 6, symbol: 'USDC' },
};

/**
 * Resolve LP pair token info from identifier.
 * @param {string} lpToken - 'eth', 'weth', 'usdc', or a hex address
 * @param {ethers.Provider} provider
 * @returns {{ address, decimals, symbol, isNative }}
 */
async function resolvePairToken(lpToken, provider) {
  const key = (lpToken || 'eth').toLowerCase();
  if (LP_TOKENS[key]) {
    return { ...LP_TOKENS[key], isNative: key === 'eth' };
  }
  // Custom ERC-20 address
  const addr = ethers.getAddress(key);
  const tc = new ethers.Contract(addr, ERC20_ABI, provider);
  let decimals = 18, symbol = 'TOKEN';
  try { decimals = Number(await tc.decimals()); } catch {}
  try { symbol = await tc.symbol(); } catch {}
  return { address: addr, decimals, symbol, isNative: false };
}

/**
 * Check if deployer has enough balance for an LP operation.
 * Returns { sufficient, balance, required, gasOk, ethBalance }
 */
async function checkDeployerBalance(provider, deployerAddress, lpToken, lpAmount) {
  const pair = await resolvePairToken(lpToken, provider);
  const GAS_RESERVE = ethers.parseEther('0.005');

  const ethBal = await provider.getBalance(deployerAddress);
  const gasOk = ethBal >= GAS_RESERVE;

  if (pair.isNative) {
    const required = ethers.parseEther(lpAmount || '0') + GAS_RESERVE;
    return {
      sufficient: ethBal >= required,
      token: 'ETH',
      balance: ethers.formatEther(ethBal),
      required: ethers.formatEther(required),
      lpAmount: lpAmount || '0',
      gasReserve: '0.005',
      gasOk: true,
    };
  }

  // ERC-20 pair
  const erc20 = new ethers.Contract(pair.address, ERC20_ABI, provider);
  const tokenBal = await erc20.balanceOf(deployerAddress);
  const requiredWei = pair.decimals === 18
    ? ethers.parseEther(lpAmount || '0')
    : ethers.parseUnits(lpAmount || '0', pair.decimals);

  return {
    sufficient: tokenBal >= requiredWei && gasOk,
    token: pair.symbol,
    tokenAddress: pair.address,
    balance: ethers.formatUnits(tokenBal, pair.decimals),
    required: ethers.formatUnits(requiredWei, pair.decimals),
    lpAmount,
    gasOk,
    ethBalance: ethers.formatEther(ethBal),
  };
}

/**
 * Create a V4 pool with hook and add initial liquidity.
 * Supports ETH, WETH, USDC, or custom ERC-20 as the LP pair token.
 */
async function createPoolWithHook(signer, provider, tokenAddress, opts = {}) {
  const hookAddress = BASE.hookAddress;
  if (!hookAddress) throw new Error('Hook address not configured');

  // Resolve pair token
  const pair = await resolvePairToken(opts.lpToken || 'eth', provider);
  const lpAmountStr = opts.lpAmount || opts.ethAmount || BASE.lpEthAmount;
  const tokenPercent = opts.tokenPercent || BASE.lpTokenPercent;

  // Parse pair amount in correct decimals
  const pairWei = pair.decimals === 18
    ? ethers.parseEther(lpAmountStr)
    : ethers.parseUnits(lpAmountStr, pair.decimals);

  const coder = ethers.AbiCoder.defaultAbiCoder();

  // Wait for contract to be indexed by RPC node
  await sleep(8000);
  const token = new ethers.Contract(tokenAddress, ERC20_ABI, signer);
  let totalSupply;
  for (let attempt = 0; attempt < 5; attempt++) {
    try {
      totalSupply = await token.totalSupply();
      break;
    } catch (e) {
      console.log(`[Pool]   totalSupply attempt ${attempt + 1} failed, retrying...`);
      await sleep(3000);
    }
  }
  if (!totalSupply) { 
      console.log("[Pool] Warning: Could not get totalSupply, using fallback");
      // Use 1B as default for most tokens
      totalSupply = 1000000000000n; // 1B at 18 decimals
    }('Could not read token totalSupply after 3 attempts');
  const tokenAmount = totalSupply * BigInt(tokenPercent) / 100n;

  // Sort currencies — V4 requires currency0 < currency1 by address
  let currency0, currency1, amount0, amount1;
  if (pair.address.toLowerCase() < tokenAddress.toLowerCase()) {
    currency0 = pair.address;
    currency1 = tokenAddress;
    amount0 = pairWei;
    amount1 = tokenAmount;
  } else {
    currency0 = tokenAddress;
    currency1 = pair.address;
    amount0 = tokenAmount;
    amount1 = pairWei;
  }

  console.log(`[Pool] Creating pool for ${tokenAddress}`);
  console.log(`[Pool] Pair: ${pair.symbol} (${pair.isNative ? 'native' : pair.address})`);
  console.log(`[Pool] ${pair.symbol}: ${lpAmountStr} | Tokens: ${ethers.formatEther(tokenAmount)} (${tokenPercent}%)`);
  console.log(`[Pool] Hook: ${hookAddress}`);

  const poolKey = [currency0, currency1, 0x800000, 60, hookAddress];

  // ── Step 1: Approve all tokens through Permit2 ──
  console.log('[Pool] Step 1: Approving tokens...');

  let nonce = await provider.getTransactionCount(signer.address, 'latest');

  // Approve deployed token → Permit2
  const approveTx = await token.approve(PERMIT2, ethers.MaxUint256, { gasLimit: 60000, nonce });
  await approveTx.wait();
  console.log('[Pool]   Token → Permit2 ✅');

  await sleep(2000);
  nonce = await provider.getTransactionCount(signer.address, 'latest');

  // Permit2 → PositionManager for deployed token
  const permit2 = new ethers.Contract(PERMIT2, PERMIT2_ABI, signer);
  const permit2Tx = await permit2.approve(
    tokenAddress, POSITION_MANAGER,
    BigInt('0xffffffffffffffffffffffffffffffffffffffff'),
    BigInt(Math.floor(Date.now() / 1000) + 86400),
    { gasLimit: 80000, nonce }
  );
  await permit2Tx.wait();
  console.log('[Pool]   Permit2(token) → PositionManager ✅');

  // If ERC-20 pair (WETH, USDC, custom), also approve pair token
  if (!pair.isNative) {
    await sleep(2000);
    nonce = await provider.getTransactionCount(signer.address, 'latest');

    const pairToken = new ethers.Contract(pair.address, ERC20_ABI, signer);
    const pairApproveTx = await pairToken.approve(PERMIT2, ethers.MaxUint256, { gasLimit: 60000, nonce });
    await pairApproveTx.wait();
    console.log(`[Pool]   ${pair.symbol} → Permit2 ✅`);

    await sleep(2000);
    nonce = await provider.getTransactionCount(signer.address, 'latest');

    const pairPermit2Tx = await permit2.approve(
      pair.address, POSITION_MANAGER,
      BigInt('0xffffffffffffffffffffffffffffffffffffffff'),
      BigInt(Math.floor(Date.now() / 1000) + 86400),
      { gasLimit: 80000, nonce }
    );
    await pairPermit2Tx.wait();
    console.log(`[Pool]   Permit2(${pair.symbol}) → PositionManager ✅`);
  }

  // ── Step 2: Initialize pool with hook ──
  console.log('[Pool] Step 2: Initializing pool with hook...');

  // sqrtPriceX96 = sqrt(currency1_amount / currency0_amount) * 2^96
  const priceRatio = Number(amount1) / Number(amount0);
  const sqrtPrice = BigInt(Math.floor(Math.sqrt(priceRatio) * Number(2n ** 96n)));

  await sleep(4000);
  nonce = await provider.getTransactionCount(signer.address, 'latest');

  const pm = new ethers.Contract(POSITION_MANAGER, PM_ABI, signer);
  const initTx = await pm.initializePool(poolKey, sqrtPrice, { gasLimit: 500000, nonce });
  const initReceipt = await initTx.wait();
  console.log(`[Pool]   Pool initialized ✅ (gas: ${initReceipt.gasUsed})`);

  // ── Step 3: Add initial liquidity (full range) ──
  console.log('[Pool] Step 3: Adding liquidity...');

  const liquidity = BigInt(Math.floor(Math.sqrt(Number(amount0) * Number(amount1))));

  const actionsHex = '0x0212121414';
  const mintParams = coder.encode(
    ['tuple(address,address,uint24,int24,address)', 'int24', 'int24', 'uint256', 'uint128', 'uint128', 'address', 'bytes'],
    [poolKey, -887220, 887220, liquidity, amount0, amount1, signer.address, '0x']
  );

  const unlockData = coder.encode(['bytes', 'bytes[]'], [actionsHex, [
    mintParams,
    coder.encode(['address'], [currency0]),
    coder.encode(['address'], [currency1]),
    coder.encode(['address', 'address'], [currency0, signer.address]),
    coder.encode(['address', 'address'], [currency1, signer.address]),
  ]]);

  await sleep(4000);
  nonce = await provider.getTransactionCount(signer.address, 'latest');

  // Only send native ETH value if ETH is the pair
  const ethValue = pair.isNative ? pairWei : 0n;

  let gasEstimate;
  try {
    gasEstimate = await pm.modifyLiquidities.estimateGas(unlockData, Math.floor(Date.now() / 1000) + 600, { value: ethValue });
  } catch { gasEstimate = 600000n; }

  const lpTx = await pm.modifyLiquidities(unlockData, Math.floor(Date.now() / 1000) + 600, {
    value: ethValue, gasLimit: gasEstimate * 130n / 100n, nonce
  });
  const lpReceipt = await lpTx.wait();
  console.log(`[Pool]   LP minted ✅ (gas: ${lpReceipt.gasUsed})`);

  const poolId = computePoolId(poolKey);

  console.log(`[Pool] ✅ Pool created with hook!`);
  console.log(`[Pool]   Pool ID: ${poolId.substring(0, 20)}...`);

  return {
    poolId,
    poolKey: { currency0, currency1, fee: 0x800000, tickSpacing: 60, hooks: hookAddress },
    initTxHash: initReceipt.hash,
    lpTxHash: lpReceipt.hash,
    liquidity: liquidity.toString(),
    lpToken: pair.symbol,
    lpTokenAddress: pair.address,
    lpAmount: lpAmountStr,
    tokenAmount: ethers.formatEther(tokenAmount),
    hookAddress,
    hookFee: '3.00% → 0.50% (25 days)',
  };
}

/**
 * Execute a $0.10 seed swap (ETH → token) via SwapHelper contract.
 * Triggers DexScreener indexing.
 */
async function seedSwap(signer, provider, tokenAddress, poolKeyArray) {
  const swapEth = ethers.parseEther('0.00005'); // ~$0.10
  
  console.log('[Swap] Seeding pool with $0.10 swap for DexScreener indexing...');
  
  const helper = new ethers.Contract(SWAP_HELPER, SWAP_HELPER_ABI, signer);
  
  await sleep(3000);
  const nonce = await provider.getTransactionCount(signer.address, 'pending');
  
  try {
    // Pass poolKey as array to avoid ethers named-components issue
    const tx = await helper.seedSwap(poolKeyArray, { value: swapEth, gasLimit: 300000, nonce });
    const receipt = await tx.wait();
    console.log(`[Swap] Seed swap ✅ (tx: ${receipt.hash}, gas: ${receipt.gasUsed})`);
    return { txHash: receipt.hash, ethSpent: '0.00005', status: 'success' };
  } catch (e) {
    console.log(`[Swap] Seed swap failed: ${e.message.substring(0, 120)}`);
    return { error: e.message, status: 'failed' };
  }
}

function computePoolId(poolKey) {
  const coder = ethers.AbiCoder.defaultAbiCoder();
  const encoded = coder.encode(
    ['address', 'address', 'uint24', 'int24', 'address'],
    poolKey
  );
  return ethers.keccak256(encoded);
}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

/**
 * Set initial price by executing a targeted swap.
 * This sets the FDV by controlling the first trade price.
 * Works WITHOUT adding liquidity - just first swap sets price.
 */
async function setInitialPrice(signer, tokenAddress, quoteToken, targetFdv, totalSupply) {
  console.log(`[FDV] Setting initial price for $${targetFdv} FDV...`);
  
  // Calculate target price: FDV / supply
  const pricePerToken = Number(targetFdv) / Number(totalSupply);
  console.log(`[FDV] Target price: $${pricePerToken} per token`);
  
  const lpToken = LP_TOKENS[quoteToken] || LP_TOKENS.eth;
  const swapValueUSD = 1;
  
  let swapAmount;
  if (quoteToken === 'usdc') {
    swapAmount = ethers.parseUnits(String(swapValueUSD), 6);
  } else {
    swapAmount = ethers.parseEther(String(swapValueUSD / 2000));
  }
  
  console.log(`[FDV] First swap: $${swapValueUSD} ${quoteToken.toUpperCase()} → token`);
  
  const helper = new ethers.Contract(SWAP_HELPER, [
    'function exactInputSingle((address tokenIn, address tokenOut, uint24 fee, address recipient, uint256 deadline, uint256 amountIn, uint256 amountOutMinimum, uint160 sqrtPriceLimitX96)) returns (uint256 amountOut)'
  ], signer);
  
  try {
    const tx = await helper.exactInputSingle({
      tokenIn: lpToken.address,
      tokenOut: tokenAddress,
      fee: 3000,
      recipient: signer.address,
      deadline: Math.floor(Date.now() / 1000) + 600,
      amountIn: swapAmount,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0
    }, { gasLimit: 500000 });
    
    const receipt = await tx.wait();
    console.log(`[FDV] First swap ✅ (tx: ${receipt.hash})`);
    
    return { txHash: receipt.hash, price: pricePerToken, fdv: targetFdv };
  } catch (e) {
    console.log(`[FDV] First swap failed: ${e.message.substring(0, 100)}`);
    return { error: e.message };
  }
}

module.exports = { createPoolWithHook, createPoolWithFDV, computePoolId, seedSwap, checkDeployerBalance, resolvePairToken, setInitialPrice, LP_TOKENS };

/**
 * Create V4 pool with target FDV via pool initialization.

/**
 * Create V4 pool with target FDV via pool initialization.
 * No liquidity needed - sets FDV directly via sqrtPriceX96!
 */
async function createPoolWithFDV(signer, provider, tokenAddress, quoteToken, targetFdv, totalSupply) {
  console.log(`[FDV-Pool] Creating pool with target FDV: $${targetFdv}...`);
  
  const hookAddress = BASE.hookAddress;
  if (!hookAddress) throw new Error('Hook not configured');
  
  // Calculate target price: FDV / supply (USD per token)
  const pricePerToken = Number(targetFdv) / Number(totalSupply);
  console.log(`[FDV-Pool] Target price: $${pricePerToken} per token`);
  
  const lpToken = LP_TOKENS[quoteToken] || LP_TOKENS.eth;
  const ethPrice = 2000;
  
  // Convert USD price to quote token
  let priceInQuote;
  if (quoteToken === 'usdc') {
    priceInQuote = pricePerToken;
  } else {
    priceInQuote = pricePerToken / ethPrice;
  }
  
  console.log(`[FDV-Pool] Price in ${lpToken.symbol}: ${priceInQuote}`);
  
  // Calculate sqrtPriceX96 for V4 pool initialization
  // sqrtPriceX96 = sqrt(price) * 2^96
  // For very small prices, we need high precision
  
  // Use bigint for precision
  // Multiply by 10^36 to handle small prices, then take sqrt
  const precision = 36;
  const priceScaled = BigInt(Math.round(priceInQuote * Math.pow(10, precision)));
  const sqrtPriceX96 = BigInt(Math.round(Math.sqrt(Number(priceScaled)) * Math.pow(2, 48)));
  
  console.log(`[FDV-Pool] sqrtPriceX96: ${sqrtPriceX96}`);
  
  // Create pool key
  const lpAddr = lpToken.isNative ? ethers.ZeroAddress : lpToken.address;
  let poolKey;
  if (lpAddr.toLowerCase() < tokenAddress.toLowerCase()) {
    poolKey = [lpAddr, tokenAddress, 0x800000, 60, hookAddress];
  } else {
    poolKey = [tokenAddress, lpAddr, 0x800000, 60, hookAddress];
  }
  
  // Approve tokens
  console.log('[FDV-Pool] Approving...');
  const token = new ethers.Contract(tokenAddress, ERC20_ABI, signer);
  await token.approve(PERMIT2, ethers.MaxUint256, { gasLimit: 100000 });
  
  if (!lpToken.isNative) {
    const pairToken = new ethers.Contract(lpToken.address, ERC20_ABI, signer);
    await pairToken.approve(PERMIT2, ethers.MaxUint256, { gasLimit: 100000 });
  }
  
  // Initialize pool
  console.log('[FDV-Pool] Initializing pool...');
  const pm = new ethers.Contract(POSITION_MANAGER, PM_ABI, signer);
  
  try {
    // Use minimum sqrtPrice for very small prices
    const minSqrt = 65535n;
    const finalSqrt = sqrtPriceX96 > minSqrt ? sqrtPriceX96 : minSqrt;
    
    console.log(`[FDV-Pool] Using sqrtPriceX96: ${finalSqrt}`);
    
    const initTx = await pm.initializePool(poolKey, finalSqrt, { gasLimit: 500000 });
    const receipt = await initTx.wait();
    console.log(`[FDV-Pool] Pool initialized ✅`);
    
    return { 
      success: true, 
      poolId: computePoolId(poolKey), 
      targetFdv, 
      pricePerToken, 
      initTxHash: receipt.hash 
    };
  } catch (e) {
    console.log(`[FDV-Pool] Error: ${e.message.slice(0, 100)}`);
    return { error: e.message };
  }
}
