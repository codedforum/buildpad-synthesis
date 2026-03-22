/**
 * Multi-chain config — Base + BSC
 * All fee wallets are ANONYMOUS (not linked to SmartCodedBot)
 */

const CHAINS = {
  base: {
    name: 'Base',
    rpc: 'https://mainnet.base.org',
    chainId: 8453,
    explorer: 'https://basescan.org',
    dex: 'Uniswap V4',
    weth: '0x4200000000000000000000000000000000000006',
    // V4 contracts
    v4PoolManager: '0x498581ff718922c3f8e6a244956af099b2652b2b',
    v4PositionManager: '0x7c5f5a4bbd8fd63184577525326123b519429bdc',
    permit2: '0x000000000022D473030F116dDEE9F6B43aC78BA3',
    // Anonymous fee wallet (NOT linked to us)
    feeWallet: '0xCA8A3cDE66680728896BCf72aA7463828f38Df7A',
    deployerKey: process.env.DEPLOYER_PRIVATE_KEY,
    gasToken: 'ETH',
    lpEthAmount: '0.00005',
  },
  bsc: {
    name: 'BSC',
    rpc: 'https://bsc-dataseed1.binance.org',
    chainId: 56,
    explorer: 'https://bscscan.com',
    dex: 'PancakeSwap V2',
    weth: '0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c', // WBNB
    // PancakeSwap V2
    routerV2: '0x10ED43C718714eb63d5aA57B78B54704E256024E',
    factoryV2: '0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73',
    // Anonymous fee wallet
    feeWallet: '0x9912B5793C6c0dC32Cf888295bC317df275685FF',
    deployerKey: process.env.BSC_DEPLOYER_PRIVATE_KEY,
    gasToken: 'BNB',
    lpEthAmount: '0.001', // BNB for LP
  }
};

// Token name generators — 100% organic looking, ZERO links to us
const TOKEN_THEMES = {
  defi: [
    'SafeYield Protocol', 'AlphaVault Finance', 'YieldMax Chain', 'LiquidPulse DeFi',
    'FluxNet Finance', 'NexGen Protocol', 'VaultChain DeFi', 'MetaFarm Protocol',
    'TurboSwap Finance', 'HyperBase DeFi', 'AeroYield Pro', 'SparkDeFi Chain',
    'QuantumSwap DeFi', 'NovaFi Chain', 'ZenithBase DeFi', 'OrbitYield Pro',
    'PrimeBase Chain', 'SynapseBase Pro', 'AtomSwap Chain', 'BlazeFi Protocol',
    'CrystalBase DeFi', 'PulseStake DeFi', 'VortexFi Chain', 'NeonSwap Pro',
    'PeakYield DeFi', 'StormVault Pro', 'NexaSwap Fi', 'RadiantYield',
  ],
  meme: [
    'Moon Mission', 'Degen Play', 'Diamond Hands', 'Rocket Fuel',
    'Ape In Pro', 'Send It Token', 'Lambo Fund', 'Green Candle',
    'Giga Brain', 'Alpha Call', 'Wagmi Token', 'Fren Zone',
    'Based Money', 'Pump Season', 'Chad Yield', 'Ser Pump',
    'Onchain Pro', 'Bull Run AI', 'Bag Holders', 'Exit Liquidity',
  ],
  ai: [
    'Neural Finance', 'DeepSwap AI', 'Quantum AI Token', 'SynapticFi',
    'CortexChain', 'NeuralLink DeFi', 'AISwap Pro', 'DeepYield AI',
    'BrainNet Token', 'CogniSwap', 'LogicChain AI', 'MatrixFi Pro',
    'TensorSwap', 'NexusAI DeFi', 'SentientFi', 'QuantumBrain',
  ],
  rwa: [
    'RealAsset Pro', 'TokenEstate', 'AssetChain Fi', 'PropSwap Token',
    'YieldBrick', 'EquityChain', 'BondSwap Pro', 'AssetVault DeFi',
    'RealFi Token', 'ChainAsset Pro', 'SecureYield RWA', 'TrustVault Fi',
  ],
};

function generateRandomSymbol(name) {
  // Create natural-looking symbol from name
  const words = name.split(/\s+/);
  if (words.length >= 2) {
    // Take first letters
    const sym = words.map(w => w[0]).join('').toUpperCase();
    if (sym.length >= 2 && sym.length <= 5) return sym;
  }
  // Random 3-4 letter symbol
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
  let s = '';
  for (let i = 0; i < 3 + Math.floor(Math.random() * 2); i++) {
    s += chars[Math.floor(Math.random() * chars.length)];
  }
  return s;
}

function generateRandomSupply() {
  const bases = [100000, 250000, 500000, 1000000, 2000000, 5000000, 10000000];
  return bases[Math.floor(Math.random() * bases.length)];
}

function pickRandomToken() {
  const themes = Object.keys(TOKEN_THEMES);
  const theme = themes[Math.floor(Math.random() * themes.length)];
  const names = TOKEN_THEMES[theme];
  const name = names[Math.floor(Math.random() * names.length)];
  return {
    name,
    symbol: generateRandomSymbol(name),
    supply: generateRandomSupply(),
    theme,
  };
}

module.exports = { CHAINS, TOKEN_THEMES, pickRandomToken, generateRandomSymbol, generateRandomSupply };
