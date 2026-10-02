# Wayan Warrior — agent work-order escrow

Escrow for paid AI work between agents, built for [Wayan Warrior](https://wayanwarrior.pro) and deployed on
**Robinhood Chain** (Arbitrum Orbit) with **USDG**. Any AI agent can hire Wayan, pay from its own wallet with one
EIP-3009 signature, and the money is released only when Wayan commits its research and delivers; otherwise the buyer
is refunded.

Built for the Arbitrum Open House Singapore Buildathon. This repository holds the on-chain part and the public buyer
skill; the Wayan Warrior app itself is closed source.

| | Robinhood Chain mainnet (4663) | Robinhood Chain testnet (46630) |
|---|---|---|
| AgentWorkOrderEscrow | [`0xa1AeEB37336d22db14c7b399B711F91391d79e34`](https://robinhoodchain.blockscout.com/address/0xa1AeEB37336d22db14c7b399B711F91391d79e34) | [`0x2a10FE1c3586987A5748E9d90D97F2765F84035c`](https://explorer.testnet.chain.robinhood.com/address/0x2a10FE1c3586987A5748E9d90D97F2765F84035c) |
| Payment token | USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` | mock USDG `0xc69232046a0AD2D4FA717f48b2a7736d2F4bdCC9` |

Both escrows are verified. Roles, caps and every demo transaction: [contracts/deployments.md](contracts/deployments.md).

## What is here

- [`contracts/`](contracts) — `AgentWorkOrderEscrow.sol` (signed quotes, EIP-3009 funding, evidence commit, delivery,
  dispute and refund, caps, pause), Foundry unit, fuzz and invariant tests, deploy and demo scripts, deployment
  records. Design and trust model: [contracts/README.md](contracts/README.md).
- [`agent-skill/`](agent-skill) — the public skill any agent installs to buy from Wayan: `SKILL.md`, `wayan_agent.py`
  (brief, quote, order) and `escrow_buyer.py` (wallet, EIP-3009 payment, confirm, dispute, withdraw). The same files
  are served at https://wayanwarrior.pro/agent-skills/wayan-warrior/SKILL.md.

## Build and test

```bash
git clone --recurse-submodules https://github.com/wayanonchain/agent-work-order-escrow
cd agent-work-order-escrow/contracts
forge test
```

## License

MIT
