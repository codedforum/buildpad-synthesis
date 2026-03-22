/**
 * BuildPad V2 — Base-only configuration
 * Single chain. No multi-chain complexity.
 */

const BASE = {
  name: 'Base',
  chainId: 8453,
  rpc: process.env.BASE_RPC || 'https://mainnet.base.org',
  explorer: 'https://basescan.org',
  
  // Uniswap V4 (official Base mainnet deployments)
  poolManager: '0x498581fF718922c3f8e6A244956aF099B2652b2b',
  positionManager: '0x7c5f5a4bbd8fd63184577525326123b519429bdc',
  quoter: '0x0d5e0f971ed27fbff6c2837bf31316121532048d',
  stateView: '0xa3c0c9b65bad0b08107aa264b0f3db444b867a71',
  universalRouter: '0x6ff5693b99212da76ad316178a184ab56d299b43',
  permit2: '0x000000000022D473030F116dDEE9F6B43aC78BA3',
  
  // SwapHelper (our deployed contract for V4 seed swaps via unlock callback)
  swapHelper: '0x810CFEF5f6fdDA9f300E70DdB1a2f9F6D0ffAe84',
  
  // Tokens
  weth: '0x4200000000000000000000000000000000000006',
  usdc: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913',
  
  // Wallets
  deployer: '0x0F4a26bC291D661e382DD3716dc6c09b952f2119',
  feeWallet: '0xCA8A3cDE66680728896BCf72aA7463828f38Df7A',     // Anonymous hook fee collection
  revenueWallet: '0x9912B5793C6c0dC32Cf888295bC317df275685FF', // x402 payment collection
  
  // BuildPad V4 Hook v3 — with 80% sniper trap
  hookAddress: process.env.HOOK_ADDRESS || '0xe0a19b19E3e6980067Cbc8D983bCb11eAB485044',
  
  // Sprint contracts (deployed Mar 14, 2026)
  graduator: '0x185aa543C7045902C6b03df26af3B8C597028f94',
  vestingFactory: '0xC0d0950b5734cbA55872d1DAeF8aDEa09Ea0CF98',
  lpLock: '0xf5F7DD72b22b891Cbb3E54d830d79d52170e1Ec0',
  airdrop: '0x25AE80FF550c304FebD4878073ddC7D79AA1B9C3',
  auditBadge: '0xE6A28165EDCC2Aa4E8fE18c278056412d4FF2A9f',
  governance: '0x6190D21dB1Fbd1Afd06AF85eac9326376deC985d',

  // Default fee config for new pools
  defaultFee: {
    initialBps: 300,      // 3%
    decayBpsPerDay: 10,   // 0.1%/day
    minBps: 50,           // 0.5% floor
    // Reaches floor in 25 days: (300-50)/10 = 25
  },
  
  // LP config
  lpEthAmount: '0.00005',  // Default ETH seed for LP
  lpTokenPercent: 40,       // 40% of supply goes to LP
};

// Token name generators
const TOKEN_THEMES = {
  defi: [
    'SafeYield Protocol', 'AlphaVault Finance', 'YieldMax Chain', 'LiquidPulse DeFi',
    'FluxNet Finance', 'NexGen Protocol', 'VaultChain DeFi', 'MetaFarm Protocol',
    'TurboSwap Finance', 'HyperBase DeFi', 'AeroYield Pro', 'SparkDeFi Chain',
    'QuantumSwap DeFi', 'NovaFi Chain', 'ZenithBase DeFi', 'OrbitYield Pro',
    'PrimeBase Chain', 'SynapseBase Pro', 'AtomSwap Chain', 'BlazeFi Protocol',
    'CrystalBase DeFi', 'PulseStake DeFi', 'VortexFi Chain', 'NeonSwap Pro',
  ],
  meme: [
    'Moon Mission', 'Degen Play', 'Diamond Hands', 'Rocket Fuel',
    'Ape In Pro', 'Send It Token', 'Lambo Fund', 'Green Candle',
    'Giga Brain', 'Alpha Call', 'Wagmi Token', 'Fren Zone',
    'Based Money', 'Pump Season', 'Chad Yield', 'Ser Pump',
  ],
  ai: [
    'Neural Finance', 'DeepSwap AI', 'Quantum AI Token', 'SynapticFi',
    'CortexChain', 'NeuralLink DeFi', 'AISwap Pro', 'DeepYield AI',
    'BrainNet Token', 'CogniSwap', 'LogicChain AI', 'MatrixFi Pro',
  ],
};

function generateSymbol(name) {
  const words = name.split(/\s+/);
  if (words.length >= 2) {
    const sym = words.map(w => w[0]).join('').toUpperCase();
    if (sym.length >= 2 && sym.length <= 5) return sym;
  }
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
  let s = '';
  for (let i = 0; i < 3 + Math.floor(Math.random() * 2); i++) {
    s += chars[Math.floor(Math.random() * chars.length)];
  }
  return s;
}

function randomSupply() {
  const bases = [100000, 250000, 500000, 1000000, 2000000, 5000000, 10000000];
  return bases[Math.floor(Math.random() * bases.length)];
}

function pickRandomToken() {
  const themes = Object.keys(TOKEN_THEMES);
  const theme = themes[Math.floor(Math.random() * themes.length)];
  const names = TOKEN_THEMES[theme];
  const name = names[Math.floor(Math.random() * names.length)];
  return { name, symbol: generateSymbol(name), supply: randomSupply(), theme };
}

module.exports = { BASE, TOKEN_THEMES, pickRandomToken, generateSymbol, randomSupply };
