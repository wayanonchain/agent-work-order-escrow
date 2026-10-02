# AgentWorkOrderEscrow

**Live on Robinhood Chain mainnet** with real USDG: escrow `0xa1AeEB37336d22db14c7b399B711F91391d79e34`, verified on Blockscout and Sourcify. The full cycle was proven first on testnet (`0x2a10FE1c3586987A5748E9d90D97F2765F84035c`): three demo orders and external agent orders. Addresses, roles and transactions: [deployments.md](deployments.md).

Escrow for paid AI work between agents, built for Wayan Warrior's agent-to-agent (A2A) API and deployed on
**Robinhood Chain** (Arbitrum Orbit) with **USDG**. The same code deploys on Arbitrum One with USDC.

A buyer (a person or an agent) locks stablecoins under a quote signed by Wayan's backend. Wayan records each
milestone on-chain as a hash, and money moves only by these rules:

| Step | Who | What happens on-chain |
|---|---|---|
| Fund | buyer | `fundWithAuthorization` (one EIP-3009 signature, no `approve`) or `fund` (after `approve`/`permit`). The quote price and terms are bound by the attester's EIP-712 signature. |
| Accept | attester | Wayan takes the order before `acceptDeadline`. |
| Commit evidence | attester | Merkle root of the evidence set (live videos + transcripts) and transcript coverage. The research fee is earned here. |
| Deliver | attester | Artifact bundle hash + provenance hash. Blocked while coverage is below the quoted minimum (Wayan's transcript gate). |
| Release | buyer, or anyone after the dispute window | The rest goes to Wayan's treasury. |
| Refund | anyone after a missed deadline; attester at any time before delivery | Everything not yet earned goes back to the buyer. |
| Dispute | buyer within the window → arbiter | The arbiter splits the remainder; if it never acts, the buyer is refunded after 30 days. |

Payouts are pull-based: settlements credit balances and each party calls `withdraw()`. USDG's issuer can freeze an
address, so one frozen party never blocks the other.

## Design decisions

- **Signed quotes.** Nobody can fund an order on terms Wayan did not offer. Each quote id can be used once. The
  signature is bound to the chain, the contract, the buyer and `validUntil`.
- **The buyer pays its own gas.** Only the buyer can submit its authorization, so a signature seen in the mempool
  cannot be used to force an order open.
- **Treasury snapshot.** An order pays the treasury it was funded with, even if the admin later changes it.
- **Issuer controls (USDG).** Funding checks the balance actually received, so a fee-on-transfer upgrade is rejected.
  There is no `withdrawTo`: frozen funds stay claimable until the freeze is lifted, never routed around it. An issuer
  wipe of the escrow itself shows up in `solvency()` and cannot be prevented by the contract.
- **Pause** stops new orders and forward milestones; every exit (release, refund, dispute, withdraw) stays open.
- **Caps** per order and on total open escrow.
- **Immutable.** No proxy: a new version is a new deployment, and old orders finish in the old one.
- **Trust model.** The attester (Wayan's backend) reports milestones; evidence is committed as hashes, not verified
  on-chain. A compromised attester can at most earn the research fee of funded orders and mark fake deliveries, which
  the buyer can dispute. On compromise, `revokeRole(ATTESTER_ROLE, key)` immediately.
- Deadlines use `block.timestamp` and are hours to days long, so sequencer timestamp drift is irrelevant. An action is
  allowed exactly at the deadline and expires one second after it.

## Build and test

```bash
forge build
forge test            # 42 unit + fuzz tests, 4 invariants (solvency, conservation, per-order accounting, cap)
forge coverage --report summary --no-match-coverage "test|script"
```

The tests use `MockPaxosToken`, a USDG stand-in with 6 decimals, EIP-3009, freeze, wipe, pause and a transfer fee.
Static analysis: Slither and Aderyn report no high or medium findings. The remaining notes are timestamp use,
role centralization and the `fund` transfer source; all are intended and documented above.

## Demo (local)

```bash
anvil &
forge script script/Demo.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

Against a deployed escrow (testnet): `ESCROW=<address> DEPLOYER_KEY=… ATTESTER_KEY=… BUYER_KEY=… ARBITER_KEY=… forge script script/Demo.s.sol --rpc-url robinhood_testnet --broadcast --slow`.

Three orders from a buyer agent that pays with one signature:
1. delivered with 100% transcript coverage and released;
2. transcript gate failed (70%), research fee kept, the rest refunded at once;
3. disputed and split by the arbiter.

## Deploy

```bash
# Robinhood Chain testnet (46630). Without testnet USDG, DEPLOY_MOCK_TOKEN=true deploys the mock instead.
TOKEN=0x... ADMIN=<safe> ATTESTER=<backend key> ARBITER=<safe> PAUSER=<safe> TREASURY=<wallet> \
PER_ORDER_CAP=1000000000 TOTAL_OPEN_ESCROW_CAP=10000000000 \
forge script script/Deploy.s.sol --rpc-url robinhood_testnet --account <keystore> --broadcast \
  --verify --verifier blockscout --verifier-url <explorer>/api/
```

| Network | Chain id | Token |
|---|---|---|
| Robinhood Chain | 4663 | USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` (6 decimals, EIP-3009 checked on-chain) |
| Robinhood Chain testnet | 46630 | no USDG; mock token, see `deployments.md` |
| Arbitrum One | 42161 | USDC `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` |
| Arbitrum Sepolia | 421614 | USDC `0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d` |

