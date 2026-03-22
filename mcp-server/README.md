# BuildPad MCP Server

Deploy tokens on Base & BSC through any MCP-compatible AI.

## Tools (7)

### Free
| Tool | Description |
|------|-------------|
| `get_stats` | Deployment statistics, chain breakdown |
| `list_tokens` | Browse deployed tokens |
| `get_token_info` | Details for a specific token |
| `get_deployer_balance` | Deployer wallet balance |

### Paid (x402)
| Tool | Price | Description |
|------|-------|-------------|
| `deploy_token` | $1.00 USDC | Deploy custom ERC-20 token |
| `deploy_random_token` | $1.00 USDC | Deploy random meme token |
| `claim_fees` | $0.10 USDC | Claim trading fees |

## Resources
- `buildpad://pricing` — Pricing and payment info
- `buildpad://chains` — Supported blockchains

## Prompts
- `deploy_token_guide` — Step-by-step deployment guide

## Setup

### STDIO (local)
```bash
python3 server.py
```

### HTTP (remote)
```bash
python3 server.py --http 8402
```

### Claude Desktop config
Add to `~/.config/claude/claude_desktop_config.json`:
```json
{
  "mcpServers": {
    "buildpad": {
      "command": "python3",
      "args": ["/path/to/server.py"]
    }
  }
}
```

## Payment Flow
1. AI calls `deploy_token(name, symbol)` without payment
2. Server returns x402 error with payment instructions
3. User sends USDC on Base to fee wallet
4. AI retries with `payment_tx` parameter
5. Server verifies payment on-chain → deploys token

## Stack
- MCP SDK 1.26.0 (FastMCP)
- BuildPad API (port 3005)
- x402 middleware (USDC on Base)
