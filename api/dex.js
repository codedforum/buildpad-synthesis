/**
 * BuildPad V2 — DexScreener Data (cached)
 * 60-second TTL cache for market data.
 */

const cache = {};
const TTL = 60000;

async function getDexData(address) {
  const cached = cache[address];
  if (cached && Date.now() - cached.ts < TTL) return cached.data;
  
  try {
    const r = await fetch(`https://api.dexscreener.com/latest/dex/tokens/${address}`);
    const d = await r.json();
    const pairs = (d.pairs || []).filter(p => (p.chainId || '').toLowerCase() === 'base');
    
    let vol24h = 0, buys24h = 0, sells24h = 0, liqUsd = 0;
    let priceUsd = null, fdv = null, mcap = null, priceChange24h = null;
    
    for (const p of pairs) {
      vol24h += parseFloat(p.volume?.h24 || 0);
      buys24h += parseInt(p.txns?.h24?.buys || 0);
      sells24h += parseInt(p.txns?.h24?.sells || 0);
      liqUsd += parseFloat(p.liquidity?.usd || 0);
      if (!priceUsd && p.priceUsd) priceUsd = p.priceUsd;
      if (!fdv && p.fdv) fdv = p.fdv;
      if (!mcap && p.marketCap) mcap = p.marketCap;
      if (priceChange24h === null && p.priceChange?.h24 !== undefined) priceChange24h = p.priceChange.h24;
    }
    
    const data = {
      hasPairs: pairs.length > 0,
      pairCount: pairs.length,
      priceUsd, fdv, marketCap: mcap,
      volume24h: vol24h,
      buys24h, sells24h,
      txns24h: buys24h + sells24h,
      liquidityUsd: liqUsd,
      priceChange24h,
    };
    
    cache[address] = { data, ts: Date.now() };
    return data;
  } catch (e) {
    return { hasPairs: false, error: e.message };
  }
}

module.exports = { getDexData };
