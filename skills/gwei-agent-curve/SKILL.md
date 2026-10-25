---
name: gwei-agent-curve
description: Buy or sell GWEI on BNB Chain with a Binance Agentic Wallet (baw CLI). GWEI is a bonding-curve token that only Agent ID wallets can buy; after 100 BNB it graduates to PancakeSwap.
version: 1.0.0
license: MIT
---

# GWEI — agent instructions

GWEI is an ERC-20 on BNB Chain (chain id 56) sold by an exponential bonding curve built into the token contract.
Only wallets holding a Binance **Agent ID** can buy from the curve. This file tells an AI agent exactly how to trade it
with the official Binance Agentic Wallet CLI (`baw`). Everything below uses only `baw` and plain JSON-RPC `eth_call`.

| | |
|---|---|
| GWEI token / curve contract | `0xe0db0b90cb649d75dfa7f0956ea9fa524ec4025d` |
| Agent ID registry (SPACE ID "Agent ID") | `0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F` |
| Chain | BNB Chain, `--binanceChainId 56` |
| Public RPC for reads | `https://bsc-rpc.publicnode.com` (fallback `https://bsc-dataseed.bnbchain.org`) |
| Website | https://gwe1.xyz/ |
| Machine-readable (addresses, ABI, selectors) | https://gwe1.xyz/gwei.json |
| Live holders, balances, recent trades | https://gwe1.xyz/data/holders.json |

## Rules enforced by the contract

- `buy` only from a wallet with an Agent ID (`isAgent(wallet) == true`), else it reverts `Binance Agent ID wallets only`.
- One buy is at most **0.1 BNB** (`--value` ≤ `100000000000000000`).
- A wallet may hold at most **1%** of supply (210,000 GWEI) while on the curve.
- 0.1% fee on every curve buy and sell.
- You cannot `sell` in the same block as your last `buy` — wait for the next block (a few seconds).
- GWEI cannot be transferred before graduation; only buy and sell on the curve work.
- When the curve holds 100 BNB it graduates: BNB + remaining GWEI go into a PancakeSwap V2 pool, LP burned.
  After that the curve is closed (buy/sell revert) and you trade on PancakeSwap (see the last section).

## 0. Preflight (once per session)

```bash
baw wallet status --json            # must be CONNECTED, otherwise: baw auth signin → scan in Binance App → baw auth verify
baw wallet settings --json          # devMode.enabled must be true (turn on Developer Mode in the Binance App if not)
baw wallet address --json           # take the address with binanceChainId "56" → WALLET
```

## 1. Read the contract state (eth_call)

All reads are `eth_call` to `0xe0db0b90cb649d75dfa7f0956ea9fa524ec4025d`. Encode a uint256/address argument as 64 hex chars, left-padded with zeros.

| read | calldata | returns |
|---|---|---|
| `graduated()` | `0xe7c2b772` | bool |
| `isAgent(address)` | `0x1ffbb064` + address | bool |
| `balanceOf(address)` | `0x70a08231` + address | GWEI, 18 decimals |
| `reserve()` | `0xcd3293de` | BNB on the curve, wei |
| `price()` | `0xa035b1fe` | BNB per GWEI ×1e18 |
| `quoteBuy(uint256 bnbWei)` | `0x4beb394c` + bnbWei | `(tokensOut, bnbUsed, refund)` |
| `quoteSell(uint256 gweiWei)` | `0xa64190c4` + amount | BNB you receive after fee, wei |

Example (check eligibility):

```bash
curl -s https://bsc-rpc.publicnode.com -H 'content-type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"eth_call","params":[{"to":"0xe0db0b90cb649d75dfa7f0956ea9fa524ec4025d","data":"0x1ffbb064000000000000000000000000<WALLET without 0x, lowercase>"},"latest"]}'
```

Result ending in `...0001` = eligible. If `graduated()` is true, skip to the last section.

## 2. Buy (curve)

1. Pick `VALUE` in wei, at most `100000000000000000` (0.1 BNB).
2. `quoteBuy(VALUE)` → first word = `tokensOut`.
3. `minTokens = tokensOut * 97 / 100` (3% slippage; use what the user asks for).
4. Calldata: `0xd96a094a` + uint256(minTokens).

```bash
baw contract-call preview --binanceChainId 56 --from WALLET --to 0xe0db0b90cb649d75dfa7f0956ea9fa524ec4025d --value VALUE --inputData 0xd96a094a<minTokens 64 hex> --json
```

5. Check `simulationResult.simulationCode == "000000000"` and no `simulationErrorDetail`. Show the user `parsedTx`, `balanceChanges`
   and any `risks`, get their confirmation, then:

```bash
baw contract-call execute --requestId <requestId from preview> --json
```

If the buy completes the curve (reserve reaches 100 BNB), the unused part of `VALUE` is refunded in the same transaction and
the token graduates.

## 3. Sell back to the curve

No approval is needed — the contract burns your GWEI and pays BNB from its reserve.

1. `AMOUNT` = GWEI to sell in wei (18 decimals). To sell everything use `balanceOf(WALLET)`.
2. `quoteSell(AMOUNT)` → `bnbOut`; `minBnb = bnbOut * 97 / 100`.
3. Calldata: `0xd79875eb` + uint256(AMOUNT) + uint256(minBnb), `--value 0`.

```bash
baw contract-call preview --binanceChainId 56 --from WALLET --to 0xe0db0b90cb649d75dfa7f0956ea9fa524ec4025d --value 0 --inputData 0xd79875eb<AMOUNT 64 hex><minBnb 64 hex> --json
baw contract-call execute --requestId <requestId> --json
```

## 4. Errors

| revert / error | meaning |
|---|---|
| `Binance Agent ID wallets only` | this wallet has no Agent ID |
| `buy must be 0 < BNB <= 0.1` | value is 0 or above 0.1 BNB |
| `wallet cap` | this buy would take the wallet above 1% of supply |
| `slippage` | price moved; quote again |
| `cannot sell in the block you bought` | wait a few seconds and retry |
| `graduated, trade on PancakeSwap` | curve closed, use section 5 |
| `351803 AGENT_DEV_MODE_RISK_BLOCKED` | Binance risk engine blocked the call; tell the user, do not retry blindly |
| devMode disabled | user must enable Developer Mode in the Binance App |

## 5. After graduation (PancakeSwap)

Once `graduated()` is true, GWEI is a normal token with a PancakeSwap V2 pool. Trades into or out of the pool pay a
fixed 0.1% fee in GWEI. Use the wallet's built-in swap (Developer Mode not needed):

```bash
# buy GWEI with 0.1 BNB
baw market-order swap --fromTokenQty 0.1 --fromToken 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE --toToken 0xe0db0b90cb649d75dfa7f0956ea9fa524ec4025d --binanceChainId 56 --slippage 3 --json
# sell 1000 GWEI for BNB
baw market-order swap --fromTokenQty 1000 --fromToken 0xe0db0b90cb649d75dfa7f0956ea9fa524ec4025d --toToken 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE --binanceChainId 56 --slippage 3 --json
```

Run `baw market-order quote` with the same arguments first if the user wants to see the price.
