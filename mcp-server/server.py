"""
BuildPad MCP Server — Token Deployment as AI Tools

Exposes BuildPad's token infrastructure via Model Context Protocol.
Any MCP-compatible AI (Claude, ChatGPT, VS Code) can deploy tokens,
check stats, and manage fees through this server.

x402 payment integration: premium tools require USDC payment on Base.

Usage:
  python server.py                    # STDIO transport (local)
  python server.py --http 8402        # HTTP transport (remote)
"""

import os
import sys
import json
import asyncio
import logging
from typing import Any, Optional

import httpx
from mcp.server.fastmcp import FastMCP

# ═══════════════════════════════════════════════════════════════
#                       CONFIGURATION
# ═══════════════════════════════════════════════════════════════

BUILDPAD_API = os.getenv("BUILDPAD_API", "http://localhost:3005")
FEE_WALLET = os.getenv("FEE_WALLET", "0x9912B5793C6c0dC32Cf888295bC317df275685FF")
USDC_BASE = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"

# Logging — stderr only (STDIO transport safety)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    stream=sys.stderr,
)
log = logging.getLogger("buildpad-mcp")

# ═══════════════════════════════════════════════════════════════
#                      MCP SERVER INIT
# ═══════════════════════════════════════════════════════════════

mcp = FastMCP("BuildPad")

# HTTP client for BuildPad API
_client: Optional[httpx.AsyncClient] = None

async def get_client() -> httpx.AsyncClient:
    global _client
    if _client is None or _client.is_closed:
        _client = httpx.AsyncClient(base_url=BUILDPAD_API, timeout=30.0)
    return _client


# ═══════════════════════════════════════════════════════════════
#                     FREE TOOLS (No payment)
# ═══════════════════════════════════════════════════════════════

@mcp.tool()
async def get_stats() -> str:
    """Get BuildPad deployment statistics — total tokens deployed, chain breakdown, deployer balances.
    
    Returns JSON with token counts per chain, deployer wallet balances, and recent deployment activity.
    Free to use, no payment required.
    """
    client = await get_client()
    try:
        resp = await client.get("/api/stats")
        resp.raise_for_status()
        data = resp.json()
        return json.dumps(data, indent=2)
    except Exception as e:
        return json.dumps({"error": str(e)})


@mcp.tool()
async def list_tokens(chain: str = "all", limit: int = 20) -> str:
    """List deployed tokens with basic info — name, symbol, address, chain, deploy date.
    
    Args:
        chain: Filter by chain — "base", "bsc", or "all" (default: all)
        limit: Maximum tokens to return (default: 20, max: 100)
    
    Returns JSON array of token objects.
    Free to use, no payment required.
    """
    client = await get_client()
    try:
        resp = await client.get("/api/tokens")
        resp.raise_for_status()
        data = resp.json()
        tokens = data.get("tokens", data) if isinstance(data, dict) else data
        
        if not isinstance(tokens, list):
            return json.dumps(data, indent=2)
        
        if chain != "all":
            tokens = [t for t in tokens if t.get("chain", "base") == chain]
        
        tokens = tokens[:min(limit, 100)]
        return json.dumps({"count": len(tokens), "tokens": tokens}, indent=2)
    except Exception as e:
        return json.dumps({"error": str(e)})


@mcp.tool()
async def get_token_info(address: str) -> str:
    """Get detailed info for a specific token by contract address.
    
    Args:
        address: Token contract address (0x...)
    
    Returns JSON with name, symbol, supply, chain, deploy tx, and more.
    Free to use, no payment required.
    """
    client = await get_client()
    try:
        resp = await client.get(f"/api/token/{address}")
        resp.raise_for_status()
        return json.dumps(resp.json(), indent=2)
    except Exception as e:
        return json.dumps({"error": str(e)})


@mcp.tool()
async def get_deployer_balance(chain: str = "base") -> str:
    """Check deployer wallet balance on a specific chain.
    
    Args:
        chain: "base" or "bsc" (default: base)
    
    Returns deployer address, ETH/BNB balance, and gas status.
    Free to use, no payment required.
    """
    client = await get_client()
    try:
        resp = await client.get("/api/balance", params={"chain": chain})
        resp.raise_for_status()
        return json.dumps(resp.json(), indent=2)
    except Exception as e:
        return json.dumps({"error": str(e)})


# ═══════════════════════════════════════════════════════════════
#                   PAID TOOLS (x402 payment)
# ═══════════════════════════════════════════════════════════════

@mcp.tool()
async def deploy_token(
    name: str,
    symbol: str,
    supply: str = "1000000",
    chain: str = "base",
    payment_tx: str = "",
) -> str:
    """Deploy a new ERC-20 token with tax/fee mechanism on Base or BSC.
    
    REQUIRES PAYMENT: $1.00 USDC on Base.
    Send 1 USDC to 0x9912B5793C6c0dC32Cf888295bC317df275685FF on Base,
    then pass the transaction hash as payment_tx.
    
    Args:
        name: Token name (e.g., "Moon Token")
        symbol: Token symbol (e.g., "MOON")
        supply: Total supply (default: 1,000,000)
        chain: Deploy chain — "base" or "bsc" (default: base)
        payment_tx: Transaction hash of USDC payment (required)
    
    Returns deploy transaction hash and contract address.
    
    Token features:
    - 3% buy/sell tax (configurable, decays over time)
    - Auto liquidity on Uniswap V4 (Base) or PancakeSwap (BSC)
    - Pool lock for 30 days
    - Owner can adjust tax, enable trading, withdraw fees
    """
    if not payment_tx:
        return json.dumps({
            "error": "Payment required",
            "x402": {
                "price": "1.00",
                "currency": "USDC",
                "payTo": FEE_WALLET,
                "network": "base",
                "chainId": 8453,
                "token": USDC_BASE,
                "instructions": f"Send 1.00 USDC to {FEE_WALLET} on Base, then retry with the tx hash as payment_tx"
            }
        })
    
    client = await get_client()
    try:
        resp = await client.post("/api/premium/deploy", 
            json={"name": name, "symbol": symbol, "supply": supply, "chain": chain},
            headers={"X-PAYMENT": payment_tx}
        )
        
        if resp.status_code == 402:
            return json.dumps({
                "error": "Payment not verified",
                "details": resp.json(),
                "instructions": f"Send 1.00 USDC to {FEE_WALLET} on Base and provide the correct tx hash"
            })
        
        resp.raise_for_status()
        data = resp.json()
        log.info(f"Token deployed: {data.get('address')} ({name}/{symbol}) on {chain}")
        return json.dumps(data, indent=2)
    except Exception as e:
        return json.dumps({"error": str(e)})


@mcp.tool()
async def deploy_random_token(chain: str = "base", payment_tx: str = "") -> str:
    """Deploy a randomly generated meme token with AI-picked name and symbol.
    
    REQUIRES PAYMENT: $1.00 USDC on Base.
    Send 1 USDC to 0x9912B5793C6c0dC32Cf888295bC317df275685FF on Base.
    
    Args:
        chain: Deploy chain — "base" or "bsc" (default: base)
        payment_tx: Transaction hash of USDC payment (required)
    
    Returns deploy details including the randomly generated name/symbol.
    """
    if not payment_tx:
        return json.dumps({
            "error": "Payment required",
            "x402": {
                "price": "1.00",
                "currency": "USDC",
                "payTo": FEE_WALLET,
                "network": "base",
                "chainId": 8453,
                "token": USDC_BASE,
                "instructions": f"Send 1.00 USDC to {FEE_WALLET} on Base, then retry with tx hash"
            }
        })
    
    client = await get_client()
    try:
        resp = await client.post("/api/premium/deploy-random",
            json={"chain": chain},
            headers={"X-PAYMENT": payment_tx}
        )
        resp.raise_for_status()
        return json.dumps(resp.json(), indent=2)
    except Exception as e:
        return json.dumps({"error": str(e)})


@mcp.tool()
async def claim_fees(token_address: str, payment_tx: str = "") -> str:
    """Claim accumulated trading fees from a deployed token.
    
    REQUIRES PAYMENT: $0.10 USDC on Base.
    
    Args:
        token_address: Contract address of the token to claim fees from
        payment_tx: Transaction hash of USDC payment (required)
    
    Returns claim transaction details and amount collected.
    """
    if not payment_tx:
        return json.dumps({
            "error": "Payment required",
            "x402": {
                "price": "0.10",
                "currency": "USDC",
                "payTo": FEE_WALLET,
                "network": "base",
                "chainId": 8453,
                "token": USDC_BASE,
                "instructions": f"Send 0.10 USDC to {FEE_WALLET} on Base, then retry"
            }
        })
    
    client = await get_client()
    try:
        resp = await client.post("/api/claim-fees",
            json={"address": token_address},
            headers={"X-PAYMENT": payment_tx}
        )
        resp.raise_for_status()
        return json.dumps(resp.json(), indent=2)
    except Exception as e:
        return json.dumps({"error": str(e)})


# ═══════════════════════════════════════════════════════════════
#                      RESOURCES
# ═══════════════════════════════════════════════════════════════

@mcp.resource("buildpad://pricing")
async def get_pricing() -> str:
    """BuildPad pricing and payment information."""
    return json.dumps({
        "currency": "USDC",
        "network": "Base (chainId: 8453)",
        "payTo": FEE_WALLET,
        "token": USDC_BASE,
        "tools": {
            "deploy_token": {"price": "1.00 USDC", "description": "Deploy a new token"},
            "deploy_random_token": {"price": "1.00 USDC", "description": "Deploy random meme token"},
            "claim_fees": {"price": "0.10 USDC", "description": "Claim trading fees"},
            "get_stats": {"price": "FREE", "description": "Deployment statistics"},
            "list_tokens": {"price": "FREE", "description": "List deployed tokens"},
            "get_token_info": {"price": "FREE", "description": "Token details"},
            "get_deployer_balance": {"price": "FREE", "description": "Deployer balance"},
        },
        "payment_flow": "Send USDC to payTo address on Base → pass tx hash as payment_tx parameter"
    }, indent=2)


@mcp.resource("buildpad://chains")
async def get_chains() -> str:
    """Supported blockchain networks for token deployment."""
    return json.dumps({
        "base": {
            "name": "Base",
            "chainId": 8453,
            "dex": "Uniswap V4",
            "gasToken": "ETH",
            "features": ["Tax tokens", "V4 hooks", "Pool lock", "Auto-LP"]
        },
        "bsc": {
            "name": "BNB Smart Chain",
            "chainId": 56,
            "dex": "PancakeSwap",
            "gasToken": "BNB",
            "features": ["Tax tokens", "Pool lock", "Auto-LP"]
        }
    }, indent=2)


# ═══════════════════════════════════════════════════════════════
#                      PROMPTS
# ═══════════════════════════════════════════════════════════════

@mcp.prompt()
async def deploy_token_guide() -> str:
    """Step-by-step guide for deploying a token on BuildPad."""
    return """# Deploy a Token on BuildPad

## Step 1: Choose your token details
- Name: What's your token called?
- Symbol: 3-5 letter ticker (e.g., MOON, DOGE)
- Supply: Total tokens to create (default: 1,000,000)
- Chain: Base (recommended) or BSC

## Step 2: Pay the deployment fee
- Send 1.00 USDC to 0x9912B5793C6c0dC32Cf888295bC317df275685FF on Base
- Save the transaction hash

## Step 3: Deploy
Call deploy_token with your details and payment tx hash.

## What you get:
- ERC-20 token with 3% buy/sell tax (decays over time)
- Auto liquidity on Uniswap V4 (Base) or PancakeSwap (BSC)
- Pool locked for 30 days
- Owner controls: adjust tax, enable trading, claim fees
"""


# ═══════════════════════════════════════════════════════════════
#                        MAIN
# ═══════════════════════════════════════════════════════════════

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="BuildPad MCP Server")
    parser.add_argument("--http", type=int, help="Run HTTP transport on this port")
    args = parser.parse_args()
    
    if args.http:
        log.info(f"Starting BuildPad MCP server on HTTP port {args.http}")
        os.environ["MCP_HTTP_PORT"] = str(args.http)
        os.environ["MCP_HTTP_HOST"] = "0.0.0.0"
        mcp.run(transport="streamable-http")
    else:
        log.info("Starting BuildPad MCP server on STDIO")
        mcp.run()
