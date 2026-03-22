# BuildPad — Autonomous Token Infrastructure for AI Agents

**AI agents deploy tokens, create Uniswap V4 pools, and trade — paying with x402 micropayments on Base.**

> Built for [The Synthesis](https://synthesis.md) hackathon — Ethereum's first agentic builder event.

---

## What is BuildPad?

BuildPad is production infrastructure that lets any AI agent launch and manage ERC-20 tokens on Base through a single API call, paid via x402 (HTTP 402) micropayments in USDC.

This isn't a prototype. It's live on Base mainnet with **48 tokens deployed**, **10 Solidity contracts**, and a **full MCP server** any Claude/ChatGPT/VS Code agent can connect to.

### The Problem

AI agents need to move value onchain. But today:
- Deploying a token requires manual Solidity compilation, wallet management, and multi-step transactions
- There's no standard way for agents to **pay for infrastructure services** autonomously
- Uniswap V4 pool creation requires complex hook deployment and salt mining
- Agents can't verify, audit, or govern tokens they've launched

### The Solution

One API call. One USDC payment. Full pipeline:

```
Agent → MCP Tool Call → x402 Payment ($1 USDC) → Deploy Token → Create V4 Pool → Add LP → Seed Swap → DexScreener Listed
```

Total cost: ~$0.22 in gas + $1.00 x402 fee. Under 30 seconds.

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    AI AGENT (Any LLM)                   │
│         Claude · ChatGPT · Custom Agent · MCP Client    │
└──────────────────────┬──────────────────────────────────┘
                       │ MCP Protocol (JSON-RPC)
                       ▼
┌──────────────────────────────────────────────────────────┐
│              BuildPad MCP Server (7 Tools)               │
│  get_stats · list_tokens · get_token_info · deploy_token │
│  check_fees · claim_fees · get_analytics                 │
│                                                          │
│  ┌─────────────────────────────────────────────┐        │
│  │         x402 Payment Middleware              │        │
│  │  HTTP 402 → Agent pays USDC on Base → Access │        │
│  └─────────────────────────────────────────────┘        │
└──────────────────────┬──────────────────────────────────┘
                       │ REST API
                       ▼
┌──────────────────────────────────────────────────────────┐
│              BuildPad API (Express.js, Port 3005)        │
│                                                          │
│  Token Deploy Pipeline:                                  │
│  1. Deploy ERC-20 (BuildPadToken.sol)                   │
│  2. Create Uniswap V4 Pool (with BuildPadFeeHook)      │
│  3. Add Initial Liquidity                                │
│  4. Execute Seed Swap ($0.10 → triggers DexScreener)    │
│                                                          │
│  Advanced Features:                                      │
│  • Vesting schedules (VestingWalletCliff)                │
│  • LP locking (30-day min / permanent)                   │
│  • Merkle airdrops (public + whitelist)                  │
│  • On-chain governance (ERC-20 + Governor)               │
│  • Audit badges (ERC-1155 SBT)                           │
│  • Bonding curves (linear/exponential)                   │
│  • Graduation (bonding curve → V4 pool)                  │
└──────────────────────┬──────────────────────────────────┘
                       │ On-chain (Base Mainnet)
                       ▼
┌──────────────────────────────────────────────────────────┐
│                 Smart Contracts (Base L2)                 │
│                                                          │
│  BuildPadFeeHook    0xe0a19b19...485044  (V4 Hook)      │
│  SwapHelper         0x810CFEF5...2A9f84  (V4 Swap)      │
│  Graduator          0x185aa543...8f94    (Bonding→Pool)  │
│  Vesting            0xC0d0950b...CF98    (Cliff Vesting) │
│  LP Lock            0xf5F7DD72...1Ec0    (NFT Locker)   │
│  Airdrop            0x25AE80FF...B9C3    (Merkle Drop)  │
│  Audit Badge        0xE6A28165...2A9f    (SBT Badges)   │
│  Governance         0x6190D21d...985d    (On-chain Gov)  │
│                                                          │
│  ┌─────────────────────────────────────────────┐        │
│  │       Uniswap V4 PoolManager (Base)         │        │
│  │  0x498581fF718922c3f8e6A244956aF099B2652b2b │        │
│  └─────────────────────────────────────────────┘        │
└──────────────────────────────────────────────────────────┘
```

---

## Key Innovation: Sniper Trap Hook

Our Uniswap V4 hook (`BuildPadFeeHook`) implements an anti-bot mechanism:

```solidity
// First 150 blocks (~5 min): 80% fee → punishes sniper bots
// After 150 blocks: 3% fee → decays 0.1%/day → 0.5% floor (25 days)
```

This protects legitimate token launches from MEV bots that front-run new pools. The hook uses `afterSwapReturnDelta` to take a cut of swap output — a V4-native fee mechanism.

**Hook permissions**: `afterInitialize` + `afterSwap` + `afterSwapReturnDelta` (flags 0x1044)

---

## x402 Payment Protocol

BuildPad uses [x402](https://www.x402.org/) — Coinbase's open standard for HTTP micropayments:

```
1. Agent calls: POST /api/premium/deploy
2. Server returns: HTTP 402 + payment instructions (amount, recipient, chain)
3. Agent signs USDC transfer on Base
4. Agent retries with payment proof in X-PAYMENT header
5. Server verifies on-chain → executes deploy → returns token address
```

**Pricing:**
| Endpoint | Price | What You Get |
|----------|-------|-------------|
| `/api/premium/deploy` | $1.00 USDC | Full token deploy + V4 pool + LP + seed swap |
| `/api/premium/token/:addr` | $0.10 USDC | Detailed token analytics |
| `/api/premium/tokens` | $0.05 USDC | List all tokens with stats |

Revenue wallet: `0x9912B5793C6c0dC32Cf888295bC317df275685FF`

---

## MCP Server — 7 Agent Tools

The MCP server lets any AI connect to BuildPad as a tool provider:

```python
# server.py — FastMCP + x402 integration
@mcp.tool()
async def deploy_token(name: str, symbol: str, supply: int, fee_wallet: str) -> str:
    """Deploy an ERC-20 token with Uniswap V4 pool on Base.
    Requires x402 payment of $1.00 USDC."""
    
@mcp.tool()
async def get_stats() -> str:
    """Get BuildPad deployment statistics (free)"""
    
@mcp.tool()
async def list_tokens(chain: str = "all", limit: int = 20) -> str:
    """List deployed tokens with basic info (free)"""
    
@mcp.tool()
async def get_token_info(address: str) -> str:
    """Get detailed token analytics ($0.10 USDC via x402)"""
    
@mcp.tool()
async def check_fees(address: str) -> str:
    """Check accumulated hook fees for a token (free)"""
    
@mcp.tool()
async def claim_fees(address: str) -> str:
    """Claim accumulated fees from token swaps (free)"""
    
@mcp.tool()
async def get_analytics() -> str:
    """Get cross-chain analytics and revenue data (free)"""
```

### Connect to BuildPad

```json
{
  "mcpServers": {
    "buildpad": {
      "command": "python",
      "args": ["server.py"],
      "env": {
        "BUILDPAD_API": "https://smartcodedbot.com/api/buildpad"
      }
    }
  }
}
```

---

## Deployed Contracts (Base Mainnet)

| Contract | Address | Purpose |
|----------|---------|---------|
| **BuildPadFeeHook** | `0xe0a19b19E3e6980067Cbc8D983bCb11eAB485044` | V4 hook with sniper trap + decaying fees |
| **SwapHelper** | `0x810CFEF5f6fdDA9f300E70DdB1a2f9F6D0ffAe84` | Direct PoolManager.swap() via unlock callback |
| **Graduator** | `0x185aa543C7045902C6b03df26af3B8C597028f94` | Bonding curve → V4 pool graduation |
| **Vesting** | `0xC0d0950b5734cbA55872d1DAeF8aDEa09Ea0CF98` | VestingWalletCliff factory |
| **LP Lock** | `0xf5F7DD72b22b891Cbb3E54d830d79d52170e1Ec0` | V4 LP NFT locker (30d min / permanent) |
| **Airdrop** | `0x25AE80FF550c304FebD4878073ddC7D79AA1B9C3` | Merkle + public airdrops |
| **Audit Badge** | `0xE6A28165EDCC2Aa4E8fE18c278056412d4FF2A9f` | ERC-1155 SBT audit badges |
| **Governance** | `0x6190D21dB1Fbd1Afd06AF85eac9326376deC985d` | Lightweight on-chain governance |

All contracts deployed by: `0x0F4a26bC291D661e382DD3716dc6c09b952f2119`

---

## Demo: Agent Deploys a Token

```bash
# 1. Agent discovers BuildPad via MCP
$ mcp call buildpad get_stats
{
  "totalTokens": 48,
  "chains": { "base": 48 },
  "deployerBalance": "0.0036 ETH"
}

# 2. Agent deploys a token (x402 payment happens automatically)
$ mcp call buildpad deploy_token \
    --name "AgentCoin" \
    --symbol "AGENT" \
    --supply 1000000 \
    --fee_wallet "0x..."
{
  "token": "0x...",
  "pool": "0x...",
  "txHash": "0x...",
  "dexscreener": "https://dexscreener.com/base/0x..."
}

# 3. Token is live — tradeable on Uniswap V4, indexed on DexScreener
```

---

## Synthesis Tracks

### 🎯 Agents That Pay
BuildPad demonstrates autonomous agent payments via x402. Agents pay USDC for infrastructure services without human intervention — no API keys, no accounts, just cryptographic payment proofs.

### 🎯 Agents That Cooperate  
Via MCP, any agent can discover and use BuildPad's tools. Multiple agents can deploy tokens, create pools, and trade — all through a standardized protocol. The bonding curve + graduation mechanism enables agent-to-agent coordination on token launches.

### 🎯 Agents That Trust
Every action is on-chain and verifiable. The V4 hook's fee structure is transparent and deterministic. Audit badges (ERC-1155 SBTs) provide on-chain verification of smart contract audits.

---

## Tech Stack

- **Smart Contracts**: Solidity (Foundry), Uniswap V4, OpenZeppelin
- **Backend**: Node.js, Express, ethers.js v6
- **MCP Server**: Python, FastMCP
- **Payment**: x402 protocol (USDC on Base)
- **Chain**: Base L2 (EVM)
- **Infrastructure**: PM2, Nginx, VPS

---

## Repository Structure

```
├── contracts/
│   ├── src/                    # 10 Solidity contracts
│   │   ├── BuildPadFeeHook.sol # Uniswap V4 hook
│   │   ├── SwapHelper.sol      # Direct V4 swap helper
│   │   ├── BuildPadToken.sol   # ERC-20 token template
│   │   ├── BondingCurve.sol    # Bonding curve pricing
│   │   ├── BuildPadGraduator.sol
│   │   ├── BuildPadVesting.sol
│   │   ├── BuildPadLPLock.sol
│   │   ├── BuildPadAirdrop.sol
│   │   ├── BuildPadAuditBadge.sol
│   │   └── BuildPadGovernance.sol
│   ├── deployments.json        # All mainnet addresses
│   └── foundry.toml
├── mcp-server/
│   └── server.py               # FastMCP server (7 tools)
├── api/
│   ├── x402-middleware.js      # x402 payment verification
│   ├── deployer.js             # Token deployment logic
│   ├── hook.js                 # V4 hook interaction
│   ├── pool.js                 # Pool creation
│   └── dex.js                  # DexScreener integration
└── README.md
```

---

## Links

- **Live API**: `https://smartcodedbot.com/api/buildpad/`
- **MCP Server**: Port 8000 (STDIO or HTTP)
- **Frontend**: `https://smartcodedbot.com/buildpad/`
- **Analytics**: `https://smartcodedbot.com/api/buildpad-analytics/`
- **x402 Protocol**: [x402.org](https://www.x402.org/)

---

## Team

**SmartCodedBot** — An AI-operated infrastructure company building DeFi tooling on Base.

- **SmartCoded** ([@Smartcoded](https://x.com/Smartcoded)) — Founder & CEO
- **Oyelami** — AI Co-Founder & COO, autonomous operations agent

---

## License

MIT
