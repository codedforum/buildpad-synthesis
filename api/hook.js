/**
 * BuildPad V2 — V4 Hook Interaction Layer (v3 hook with sniper trap)
 * 
 * Reads fee config, manages hook settings.
 * Talks to BuildPadFeeHook v3 deployed on Base.
 * Features: 80% sniper trap (5 blocks) → 3% decaying → 0.5% floor
 */

const { ethers } = require('ethers');
const { BASE } = require('./config');

const HOOK_ABI = [
  // Read
  'function owner() view returns (address)',
  'function feeWallet() view returns (address)',
  'function defaultSniperFeeBps() view returns (uint16)',
  'function defaultSniperBlocks() view returns (uint32)',
  'function defaultFeeBps() view returns (uint16)',
  'function defaultDecayBpsPerDay() view returns (uint16)',
  'function defaultMinFeeBps() view returns (uint16)',
  'function getCurrentFee(tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key) view returns (uint16 fee, bool isSniperPeriod)',
  'function getPoolConfig(tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key) view returns (uint16 feeBps, uint16 sniperFeeBps, uint32 sniperEndBlock, uint16 currentFee, bool isSniperActive, uint256 feesCollected, bool active)',
  'function totalFeesCollected(bytes32 poolId) view returns (uint256)',
  'function whitelisted(address) view returns (bool)',
  'function poolFees(bytes32 poolId) view returns (uint16 feeBps, uint16 sniperFeeBps, uint32 sniperEndBlock, uint16 decayBpsPerDay, uint48 startTime, uint16 minFeeBps, bool active)',
  // Write (owner only)
  'function setPoolFee(tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, uint16 feeBps, uint16 decayBpsPerDay, uint16 minFeeBps)',
  'function setDefaults(uint16 sniperFeeBps, uint32 sniperBlocks, uint16 feeBps, uint16 decayBpsPerDay, uint16 minFeeBps)',
  'function setFeeWallet(address _feeWallet)',
  'function setWhitelist(address account, bool status)',
  'function togglePoolFees(tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, bool active)',
  'function transferOwnership(address newOwner)',
  // Events
  'event FeeCollected(bytes32 indexed poolId, address indexed token, uint256 amount)',
  'event SniperTrapped(bytes32 indexed poolId, address indexed sender, uint256 feeAmount, uint256 blockNumber)',
  'event PoolFeeSet(bytes32 indexed poolId, uint16 feeBps, uint16 sniperBps, uint32 sniperBlocks)',
];

function getHook(providerOrSigner) {
  if (!BASE.hookAddress) return null;
  return new ethers.Contract(BASE.hookAddress, HOOK_ABI, providerOrSigner);
}

function buildPoolKey(tokenAddress) {
  return {
    currency0: ethers.ZeroAddress,  // Native ETH
    currency1: tokenAddress,
    fee: 0x800000,  // Dynamic fee flag
    tickSpacing: 60,
    hooks: BASE.hookAddress,
  };
}

function computePoolId(poolKey) {
  const encoded = ethers.AbiCoder.defaultAbiCoder().encode(
    ['address', 'address', 'uint24', 'int24', 'address'],
    [poolKey.currency0, poolKey.currency1, poolKey.fee, poolKey.tickSpacing, poolKey.hooks]
  );
  return ethers.keccak256(encoded);
}

async function getPoolFeeInfo(provider, tokenAddress) {
  const hook = getHook(provider);
  if (!hook) return { error: 'Hook not deployed yet' };
  
  const poolKey = buildPoolKey(tokenAddress);
  const poolId = computePoolId(poolKey);
  
  try {
    const config = await hook.poolFees(poolId);
    
    const currentBlock = await provider.getBlockNumber();
    const isSniperActive = currentBlock < Number(config.sniperEndBlock);
    const blocksRemaining = isSniperActive ? Number(config.sniperEndBlock) - currentBlock : 0;
    
    // Compute current fee
    let currentFeeBps;
    if (isSniperActive) {
      currentFeeBps = Number(config.sniperFeeBps);
    } else if (Number(config.decayBpsPerDay) === 0) {
      currentFeeBps = Number(config.feeBps);
    } else {
      const daysElapsed = Math.floor((Date.now() / 1000 - Number(config.startTime)) / 86400);
      const totalDecay = daysElapsed * Number(config.decayBpsPerDay);
      currentFeeBps = Math.max(Number(config.minFeeBps), Number(config.feeBps) - totalDecay);
    }
    
    const daysToFloor = Number(config.decayBpsPerDay) > 0
      ? Math.ceil((Number(config.feeBps) - Number(config.minFeeBps)) / Number(config.decayBpsPerDay))
      : Infinity;
    
    const totalFees = await hook.totalFeesCollected(poolId).catch(() => 0n);
    
    return {
      poolId,
      active: config.active,
      // Sniper trap info
      sniperTrap: {
        active: isSniperActive,
        feeBps: Number(config.sniperFeeBps),
        feePercent: (Number(config.sniperFeeBps) / 100).toFixed(0) + '%',
        endBlock: Number(config.sniperEndBlock),
        blocksRemaining,
        secondsRemaining: blocksRemaining * 2,  // ~2s per Base block
      },
      // Normal fee info
      initialFeeBps: Number(config.feeBps),
      currentFeeBps,
      currentFeePercent: (currentFeeBps / 100).toFixed(2) + '%',
      decayBpsPerDay: Number(config.decayBpsPerDay),
      minFeeBps: Number(config.minFeeBps),
      startTime: Number(config.startTime),
      daysToFloor: Math.max(0, daysToFloor),
      totalFeesCollected: ethers.formatEther(totalFees),
    };
  } catch (e) {
    return { error: e.message };
  }
}

async function getHookInfo(provider) {
  const hook = getHook(provider);
  if (!hook) return { deployed: false, address: null };
  
  try {
    const [owner, feeWallet] = await Promise.all([
      hook.owner(),
      hook.feeWallet(),
    ]);
    
    return {
      deployed: true,
      address: BASE.hookAddress,
      owner,
      feeWallet,
      chain: 'base',
      chainId: BASE.chainId,
      sniperTrap: '80% for 150 blocks (~5 min)',
      normalFee: '3% → 0.5% over 25 days',
    };
  } catch (e) {
    return { deployed: false, error: e.message };
  }
}

async function setPoolFee(signer, tokenAddress, feeBps, decayBpsPerDay, minFeeBps) {
  const hook = getHook(signer);
  if (!hook) throw new Error('Hook not deployed');
  const poolKey = buildPoolKey(tokenAddress);
  const tx = await hook.setPoolFee(poolKey, feeBps, decayBpsPerDay, minFeeBps);
  await tx.wait();
  return { txHash: tx.hash, feeBps, decayBpsPerDay, minFeeBps };
}

module.exports = {
  getHook, buildPoolKey, computePoolId,
  getPoolFeeInfo, getHookInfo, setPoolFee, HOOK_ABI,
};
