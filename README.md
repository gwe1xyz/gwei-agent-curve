# GWEI: the agent-only token on BNB Chain

**GWEI** is an agent-only bonding-curve token on BNB Chain. Only **Binance Agentic Wallets** holding a
**SPACE ID Agent ID (.ai)** can buy it; a normal wallet reverts. This repo is the agent skill that lets your
AI agent buy and sell GWEI through the Binance Agentic Wallet `baw` CLI, plus the verified contract source.

- Agent-only: the contract checks the Agent ID registry `0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F` on every buy
- Exponential bonding curve, max 0.1 BNB per buy, max 1% of supply per wallet
- Sell back to the curve anytime; every BNB paid in stays in the contract as the reserve
- No owner, no admin key, no team tokens, no presale
- Graduates to a PancakeSwap V2 pool at 100 BNB, LP burned; anyone can trade it after that
- 0.1% fee on curve trades and on PancakeSwap trades after graduation

Website with live curve, AI holder leaderboard and a command builder: **https://gwe1.xyz**

## Install the skill

```bash
npx skills add gwe1xyz/gwei-agent-curve
```

Mirror: `npx skills add https://gwe1.xyz/gwei-skill.git`

Works with Claude Code, OpenClaw and other agents that load `SKILL.md` skills. It needs the official
Binance Agentic Wallet `baw` CLI (`npm i -g @binance/agentic-wallet`), a signed-in wallet with an Agent ID,
and Developer Mode enabled in the Binance App.

Then ask your agent, for example:

> Buy GWEI with 0.1 BNB, 3% slippage. Preview first and show me the result before executing.

## What the skill does

- checks the wallet is connected, has Developer Mode and holds an Agent ID
- reads live quotes from the contract (`quoteBuy` / `quoteSell`) and applies your slippage
- builds the calldata, runs `baw contract-call preview`, shows you the simulation, and only runs `execute` after you confirm
- after graduation, routes trades through `baw market-order swap` on PancakeSwap

No scripts, no keys, no dependencies beyond `baw`. Everything is in [`skills/gwei-agent-curve/SKILL.md`](skills/gwei-agent-curve/SKILL.md).

## Contract

- BNB Chain (chain id 56): [`0xe0db0b90cb649d75dfa7f0956ea9fa524ec4025d`](https://bscscan.com/address/0xe0db0b90cb649d75dfa7f0956ea9fa524ec4025d#code), source verified on BscScan
- Source: [`contracts/AgentCurveToken.sol`](contracts/AgentCurveToken.sol)
- Curve: minted supply `m(e) = K·(1 − e^(−e/S))` with K = 21,000,000 and S = 100 BNB; price `S / (K − m)`; at 100 BNB the remaining supply and the reserve seed the PancakeSwap pool at the same price

## Links

- Website: https://gwe1.xyz
- Agent docs: https://gwe1.xyz/skill.md · https://gwe1.xyz/llms.txt · https://gwe1.xyz/gwei.json

Trading new tokens is risky; bonding-curve prices move fast and selling back may return less than you paid. Nothing here is financial advice.

License: MIT
