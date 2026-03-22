/**
 * BuildPad V2 — Token Deployer (Base only)
 * 
 * Deploys clean ERC-20 tokens (BuildPadToken.sol).
 * No tax logic in token contract — fees handled by V4 hook at pool level.
 */

const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');
const { BASE } = require('./config');

// Load BuildPadToken ABI + bytecode
const CONTRACTS_DIR = path.join(__dirname, 'contracts');
let TOKEN_ABI, TOKEN_BIN;

try {
  TOKEN_ABI = JSON.parse(fs.readFileSync(path.join(CONTRACTS_DIR, 'BuildPadToken.abi'), 'utf8'));
  TOKEN_BIN = fs.readFileSync(path.join(CONTRACTS_DIR, 'BuildPadToken.bin'), 'utf8').trim();
} catch {
  // Fallback: inline minimal ABI for clean ERC-20 + Ownable + burn + tokenURI
  TOKEN_ABI = [
    'constructor(string name_, string symbol_, uint256 supply_, string uri_, address recipient_)',
    'function name() view returns (string)',
    'function symbol() view returns (string)',
    'function decimals() view returns (uint8)',
    'function totalSupply() view returns (uint256)',
    'function balanceOf(address) view returns (uint256)',
    'function transfer(address to, uint256 amount) returns (bool)',
    'function approve(address spender, uint256 amount) returns (bool)',
    'function allowance(address owner, address spender) view returns (uint256)',
    'function transferFrom(address from, address to, uint256 amount) returns (bool)',
    'function tokenURI() view returns (string)',
    'function setTokenURI(string uri_)',
    'function burn(uint256 amount)',
    'function owner() view returns (address)',
    'function transferOwnership(address newOwner)',
    'event Transfer(address indexed from, address indexed to, uint256 value)',
    'event Approval(address indexed owner, address indexed spender, uint256 value)',
  ];
  TOKEN_BIN = null;
}

/**
 * Deploy a clean ERC-20 token on Base
 * @param {ethers.Wallet} deployer - Deployer wallet (already connected to provider)
 * @param {object} opts - Token parameters
 * @param {string} opts.name - Token name
 * @param {string} opts.symbol - Token symbol
 * @param {number|string} opts.supply - Total supply (in whole tokens, not wei)
 * @param {string} [opts.tokenURI] - Optional metadata URI
 * @param {string} [opts.recipient] - Token recipient (default: deployer)
 * @returns {object} { address, txHash, name, symbol, supply, deployedAt }
 */
async function deployToken(deployer, opts) {
  const { name, symbol, supply = 1000000, tokenURI = '', recipient } = opts;
  const recipientAddr = recipient || deployer.address;
  
  if (!TOKEN_BIN) {
    throw new Error('BuildPadToken bytecode not found. Run: forge build in services/buildpad-v4-hook/ and copy ABI+BIN to contracts/');
  }
  
  const factory = new ethers.ContractFactory(TOKEN_ABI, '0x' + TOKEN_BIN, deployer);
  
  console.log(`[Deployer] Deploying ${name} (${symbol}) — ${supply} supply to ${recipientAddr}`);
  
  const contract = await factory.deploy(name, symbol, supply, tokenURI, recipientAddr, {
    gasLimit: 1500000,
  });
  
  await contract.waitForDeployment();
  const address = await contract.getAddress();
  
  console.log(`[Deployer] ✅ ${symbol} deployed at ${address}`);
  
  return {
    address,
    txHash: contract.deploymentTransaction().hash,
    name,
    symbol,
    supply: String(supply),
    decimals: 18,
    tokenURI,
    recipient: recipientAddr,
    deployedAt: new Date().toISOString(),
    method: 'v4-hook',
    chain: 'base',
    explorerUrl: `${BASE.explorer}/token/${address}`,
  };
}

/**
 * Get token info from on-chain
 * @param {ethers.Provider} provider
 * @param {string} address - Token contract address
 * @returns {object} Token metadata
 */
async function getTokenInfo(provider, address) {
  const contract = new ethers.Contract(address, TOKEN_ABI, provider);
  
  const [name, symbol, decimals, totalSupply, tokenURI, owner] = await Promise.all([
    contract.name().catch(() => 'Unknown'),
    contract.symbol().catch(() => '???'),
    contract.decimals().catch(() => 18),
    contract.totalSupply().catch(() => 0n),
    contract.tokenURI().catch(() => ''),
    contract.owner().catch(() => ethers.ZeroAddress),
  ]);
  
  return {
    address,
    name,
    symbol,
    decimals: Number(decimals),
    totalSupply: ethers.formatUnits(totalSupply, decimals),
    tokenURI,
    owner,
  };
}

module.exports = { deployToken, getTokenInfo, TOKEN_ABI, preloadRouter };

// Base Uniswap Router address
const BASE_ROUTER = '0x498581ff718922c3f8e6a244956af099b2652b2b';

/**
 * Pre-load Router with tokens for instant trading (CLAWD-style launch)
 * @param {ethers.Wallet} deployer - Deployer wallet
 * @param {string} tokenAddress - Already deployed token address
 * @param {number|string} amount - Amount of tokens to send to router (in whole tokens)
 * @returns {object} { txHash, routerBalance }
 */
async function preloadRouter(deployer, tokenAddress, amount) {
  const contract = new ethers.Contract(tokenAddress, TOKEN_ABI, deployer);
  const amountWei = ethers.parseUnits(String(amount), 18);
  
  console.log(`[RouterPreload] Approving Router ${BASE_ROUTER} for ${amount} tokens...`);
  
  // Approve router
  const approveTx = await contract.approve(BASE_ROUTER, amountWei, { gasLimit: 100000 });
  await approveTx.wait();
  console.log(`[RouterPreload] ✅ Approved: ${approveTx.hash}`);
  
  // Transfer to router
  console.log(`[RouterPreload] Transferring ${amount} tokens to Router...`);
  const transferTx = await contract.transfer(BASE_ROUTER, amountWei, { gasLimit: 100000 });
  await transferTx.wait();
  console.log(`[RouterPreload] ✅ Transferred: ${transferTx.hash}`);
  
  // Check router balance
  const routerBalance = await contract.balanceOf(BASE_ROUTER);
  
  return {
    txHash: transferTx.hash,
    routerBalance: ethers.formatUnits(routerBalance, 18),
    routerAddress: BASE_ROUTER,
  };
}
