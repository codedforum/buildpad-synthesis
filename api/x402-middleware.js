/**
 * x402 Payment Middleware for Express
 * 
 * Implements HTTP 402 Payment Required protocol (x402 standard by Coinbase).
 * Wraps any Express endpoint to require USDC payment before access.
 * 
 * Flow:
 * 1. Client hits paid endpoint → gets 402 with payment details
 * 2. Client sends USDC to specified address on Base
 * 3. Client retries with X-PAYMENT header (tx hash)
 * 4. Middleware verifies payment on-chain → grants access
 * 
 * @see https://www.x402.org
 */

const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

// Base L2 provider
const BASE_RPC = process.env.BASE_RPC || 'https://mainnet.base.org';
const provider = new ethers.JsonRpcProvider(BASE_RPC);

// Accepted payment tokens on Base
const ACCEPTED_TOKENS = {
  USDC: {
    address: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913',
    decimals: 6,
    symbol: 'USDC',
    name: 'USD Coin'
  },
  fxUSD: {
    address: '0x55380fe7A1910dFf29A47B622057ab4139DA42C5',
    decimals: 18,
    symbol: 'fxUSD',
    name: 'f(x) USD'
  }
};

const USDC_ADDRESS = ACCEPTED_TOKENS.USDC.address;
const FXUSD_ADDRESS = ACCEPTED_TOKENS.fxUSD.address;

const ERC20_TRANSFER_ABI = [
  'event Transfer(address indexed from, address indexed to, uint256 value)'
];
const usdc = new ethers.Contract(USDC_ADDRESS, ERC20_TRANSFER_ABI, provider);
const fxusd = new ethers.Contract(FXUSD_ADDRESS, ERC20_TRANSFER_ABI, provider);

// Payment recipient (SmartCodedBot fee wallet)
const PAYMENT_WALLET = process.env.X402_WALLET || process.env.FEE_WALLET || '0x9912B5793C6c0dC32Cf888295bC317df275685FF';

// Payment tracking
const PAYMENTS_FILE = path.join(__dirname, 'data', 'x402-payments.json');

function loadPayments() {
  try {
    return JSON.parse(fs.readFileSync(PAYMENTS_FILE, 'utf8'));
  } catch { return { verified: {}, pending: {} }; }
}

function savePayments(data) {
  fs.writeFileSync(PAYMENTS_FILE, JSON.stringify(data, null, 2));
}

/**
 * Verify a USDC transfer on Base
 * @param {string} txHash - Transaction hash to verify
 * @param {number} expectedAmount - Expected USDC amount (human-readable, e.g. 1.00)
 * @returns {object} { valid, from, amount, error }
 */
async function verifyPayment(txHash, expectedAmount) {
  try {
    const receipt = await provider.getTransactionReceipt(txHash);
    if (!receipt) return { valid: false, error: 'Transaction not found' };
    if (receipt.status !== 1) return { valid: false, error: 'Transaction failed' };
    
    // Check both USDC and fxUSD Transfer events
    const tokenChecks = [
      { contract: usdc, decimals: 6, symbol: 'USDC' },
      { contract: fxusd, decimals: 18, symbol: 'fxUSD' }
    ];

    for (const { contract, decimals, symbol } of tokenChecks) {
      for (const log of receipt.logs) {
        try {
          if (log.address.toLowerCase() !== contract.target.toLowerCase()) continue;
          const parsed = contract.interface.parseLog({ topics: log.topics, data: log.data });
          if (parsed && parsed.name === 'Transfer') {
            const to = parsed.args.to.toLowerCase();
            const amount = Number(ethers.formatUnits(parsed.args.amount, decimals));
            
            if (to === PAYMENT_WALLET.toLowerCase() && amount >= expectedAmount) {
              return {
                valid: true,
                from: parsed.args.from,
                amount,
                currency: symbol,
                blockNumber: receipt.blockNumber,
                txHash
              };
            }
          }
        } catch { continue; }
      }
    }
    
    return { valid: false, error: 'No matching USDC or fxUSD transfer found' };
  } catch (e) {
    return { valid: false, error: e.message };
  }
}

/**
 * Express middleware factory for x402 payment-gated endpoints
 * 
 * @param {object} opts
 * @param {number} opts.price - Price in USDC (e.g. 0.01 for 1 cent)
 * @param {string} opts.description - What the payment is for
 * @param {string} opts.network - Network name (default: 'base')
 * @param {number} opts.maxAge - Max age of payment in seconds (default: 3600)
 * @param {boolean} opts.singleUse - Whether payment can only be used once (default: true)
 */
function x402(opts = {}) {
  const {
    price = 0.01,
    description = 'API access',
    network = 'base',
    maxAge = 3600,
    singleUse = true
  } = opts;

  return async (req, res, next) => {
    // Check for payment header
    const paymentHeader = req.headers['x-payment'] || req.headers['x-402-payment'];
    
    if (!paymentHeader) {
      // Return 402 with payment details
      return res.status(402).json({
        status: 402,
        error: 'Payment Required',
        x402: {
          version: '1',
          price: {
            amount: String(price),
            currency: 'USDC or fxUSD',
            decimals: 6
          },
          payTo: PAYMENT_WALLET,
          network: network,
          chainId: 8453,
          tokens: [
            { address: USDC_ADDRESS, symbol: 'USDC', decimals: 6 },
            { address: FXUSD_ADDRESS, symbol: 'fxUSD', decimals: 18 }
          ],
          token: USDC_ADDRESS, // backwards compat
          description,
          maxAge,
          accepts: ['x-payment', 'x-402-payment'],
          instructions: `Send ${price} USDC or fxUSD to ${PAYMENT_WALLET} on Base, then retry with header X-PAYMENT: <txHash>`
        }
      });
    }

    // Verify payment
    const txHash = paymentHeader.trim();
    if (!/^0x[a-fA-F0-9]{64}$/.test(txHash)) {
      return res.status(400).json({ error: 'Invalid transaction hash format' });
    }

    // Check if already verified (cache)
    const payments = loadPayments();
    
    if (payments.verified[txHash]) {
      const cached = payments.verified[txHash];
      
      // Check single-use
      if (singleUse && cached.used) {
        return res.status(402).json({
          error: 'Payment already used',
          x402: { price: { amount: String(price), currency: 'USDC' }, payTo: PAYMENT_WALLET, network, chainId: 8453 }
        });
      }
      
      // Check max age
      const age = (Date.now() / 1000) - cached.timestamp;
      if (age > maxAge) {
        return res.status(402).json({
          error: 'Payment expired',
          x402: { price: { amount: String(price), currency: 'USDC' }, payTo: PAYMENT_WALLET, network, chainId: 8453 }
        });
      }
      
      // Mark as used
      if (singleUse) cached.used = true;
      cached.lastUsed = Date.now() / 1000;
      cached.useCount = (cached.useCount || 0) + 1;
      savePayments(payments);
      
      req.x402 = cached;
      return next();
    }

    // Verify on-chain
    const result = await verifyPayment(txHash, price);
    
    if (!result.valid) {
      return res.status(402).json({
        error: `Payment verification failed: ${result.error}`,
        x402: { price: { amount: String(price), currency: 'USDC' }, payTo: PAYMENT_WALLET, network, chainId: 8453 }
      });
    }

    // Store verified payment
    payments.verified[txHash] = {
      from: result.from,
      amount: result.amount,
      blockNumber: result.blockNumber,
      timestamp: Date.now() / 1000,
      endpoint: req.path,
      used: singleUse,
      useCount: 1,
      lastUsed: Date.now() / 1000
    };
    savePayments(payments);

    req.x402 = payments.verified[txHash];
    next();
  };
}

/**
 * Revenue tracking endpoint
 */
function x402Stats(req, res) {
  const payments = loadPayments();
  const verified = Object.values(payments.verified);
  const totalRevenue = verified.reduce((sum, p) => sum + (p.amount || 0), 0);
  const totalPayments = verified.length;
  const last24h = verified.filter(p => (Date.now()/1000 - p.timestamp) < 86400);
  
  res.json({
    totalRevenue: `${totalRevenue.toFixed(2)} USDC`,
    totalPayments,
    last24h: {
      payments: last24h.length,
      revenue: `${last24h.reduce((s,p) => s + (p.amount||0), 0).toFixed(2)} USDC`
    },
    wallet: PAYMENT_WALLET,
    network: 'base',
    token: USDC_ADDRESS
  });
}

module.exports = { x402, x402Stats, verifyPayment };
