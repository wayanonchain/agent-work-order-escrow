# Deployments

## Robinhood Chain mainnet (chain id 4663) — 01.10.2026

Verified on Blockscout (standard JSON input) and Sourcify (`exact_match`). Same source as the testnet
deployment; the full cycle was first run on a mainnet fork with the real USDG (`scripts/escrow_fork_smoke.py`, 45 checks).

| Contract | Address |
|---|---|
| AgentWorkOrderEscrow | [`0xa1AeEB37336d22db14c7b399B711F91391d79e34`](https://robinhoodchain.blockscout.com/address/0xa1AeEB37336d22db14c7b399B711F91391d79e34) |
| USDG (Paxos, proxy; 6 decimals, EIP-3009) | [`0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`](https://robinhoodchain.blockscout.com/address/0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168) |

Deploy tx [`0xd0f1…0810`](https://robinhoodchain.blockscout.com/tx/0xd0f136c80df4bc72cd9dcf0e6e0e36bc51eb429a50afc795011c5429b8740810),
block **77426407** (`ESCROW_START_BLOCK`), gas 2,835,004 (0.000058 ETH). Record: `broadcast/Deploy.s.sol/4663/`.
USDG's EIP-712 domain is `Global Dollar` / `1` / 4663 / token address (it has no `eip712Domain()`; the backend builds the
domain and checks it against `DOMAIN_SEPARATOR()`).

| Role | Address |
|---|---|
| Admin (`DEFAULT_ADMIN_ROLE`) + arbiter (owner) | `0x2B94E5E4eFE0c3b4893B8e4ed4291007472Ab302` |
| Pauser (separate wallet, own seed) | `0x34A6ea416d0fCf262535DD0F65A4FE37c5E63fd2` |
| Attester (Wayan backend; key only on the server, `/root/mainnet_attester.env`) | `0x6790008369234eb13f2cAbaFE3dF0352120e442B` |
| Treasury (provider payouts, `withdraw()`) | `0xc95a51717d8b7Ae2a8802183b736646F03653945` |
| Deployer (gas only, no role) | `0x7Aa44c81a2De041759147FAf8E57b1A73bA108Dc` |

Caps: 100 USDG per order, 1,000 USDG total open escrow. Checked after deploy: `token()` = USDG, roles as above, the
deployer holds no role, `paused()` = false, `solvency()` = 0/0/0.

## Robinhood Chain testnet (chain id 46630) — 27.09.2026

Both contracts are verified on Blockscout.

| Contract | Address |
|---|---|
| AgentWorkOrderEscrow | [`0x2a10FE1c3586987A5748E9d90D97F2765F84035c`](https://explorer.testnet.chain.robinhood.com/address/0x2a10FE1c3586987A5748E9d90D97F2765F84035c) |
| Mock USDG (6 decimals, EIP-3009; anyone can mint) | [`0xc69232046a0AD2D4FA717f48b2a7736d2F4bdCC9`](https://explorer.testnet.chain.robinhood.com/address/0xc69232046a0AD2D4FA717f48b2a7736d2F4bdCC9) |

USDG is not deployed on the testnet, so the escrow runs against the mock. On mainnet the token is USDG
`0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` (checked on-chain: 6 decimals, EIP-3009 `receiveWithAuthorization`).

| Role | Address |
|---|---|
| Admin, pauser, treasury (owner) | `0x2B94E5E4eFE0c3b4893B8e4ed4291007472Ab302` |
| Attester (Wayan backend, testnet key) | `0xA01911E3680f2FBE05750e900a2a317476740B15` |
| Arbiter (testnet key; a Safe on mainnet) | `0x27cE7E699C9b9136631ACa9D6521fb365e57f192` |
| Deployer (gas only, no role) | `0xB1725C60f1E0861D37FC1c7A98349452e3871727` |
| Demo buyer agent | `0x2AA14e31DD709CFD19eC9Ce5C834EeCbb631Ceb7` |

Caps: 1,000 USDG per order, 10,000 USDG total open escrow.

### Demo transactions (`script/Demo.s.sol`)

Three orders of 250 USDG each (research fee 100), paid by the buyer agent with one EIP-3009 signature.

1. **Delivered and released.**
   fund [`0x3d5d…1428`](https://explorer.testnet.chain.robinhood.com/tx/0x3d5dd3c09ded3284d43e97e14209fd91ae3961330791f823d0641a7e99881428) →
   accept [`0x826f…6f47`](https://explorer.testnet.chain.robinhood.com/tx/0x826facb7e0a14ae0d6049ddf5c6c807ed53e4f62917429d1cee018de26716f47) →
   evidence 100% [`0xdd83…6b1e`](https://explorer.testnet.chain.robinhood.com/tx/0xdd83b27131255805aa4e9808e37722aa2f869054b4860ef72716eef3b0276b1e) →
   deliver [`0x98f7…ed9a`](https://explorer.testnet.chain.robinhood.com/tx/0x98f7de39e1eb6b9228d1f7f0996a7fe175149553409d1916bfec56a010a0ed9a) →
   buyer confirms [`0xd650…f9bd`](https://explorer.testnet.chain.robinhood.com/tx/0xd6501af7ad1612bdaa09ea325b73dd2522b15b48ad9f13225c4cae5d67fcf9bd).
2. **Transcript gate failed (70% coverage), refunded.**
   fund [`0xdbc8…79c6`](https://explorer.testnet.chain.robinhood.com/tx/0xdbc8bc64b954bb2865fe06dbadf3046026c2ad9003066ab38816ff943a1879c6) →
   accept [`0xd587…0c4c`](https://explorer.testnet.chain.robinhood.com/tx/0xd587d5d1e3043de6409e6e1f7d8d31f659e19746f1f1f354b349a5e6c4ad0c4c) →
   evidence 70% [`0x20ee…bf31`](https://explorer.testnet.chain.robinhood.com/tx/0x20ee09a2644228e9ea90c082e2394602b33467f183df6547dafc6164a5f5bf31) →
   provider refund [`0xcc71…dd18`](https://explorer.testnet.chain.robinhood.com/tx/0xcc714b0a840352e6dacb3bbb347fc5d2b2ac606cef1f765c186ccb29e79fdd18)
   (research fee kept, 150 back to the buyer).
3. **Disputed and settled by the arbiter.**
   fund [`0x6d36…e1b0`](https://explorer.testnet.chain.robinhood.com/tx/0x6d36b6ffab3965ed84da7adfb2e52960398a27ea128f5469020c611cf14ae1b0) →
   accept [`0xf9bd…e7a8`](https://explorer.testnet.chain.robinhood.com/tx/0xf9bd0183abd1b190906f2175da4aef88fc2546a307a6f3f0785a63a0b497e7a8) →
   evidence [`0x1b38…4bcb`](https://explorer.testnet.chain.robinhood.com/tx/0x1b3833410190b5970acc47c7cb265776ee880705a7b7c637acb08c4a9c434bcb) →
   deliver [`0x4468…4204`](https://explorer.testnet.chain.robinhood.com/tx/0x4468181414917f70dd073beb28b60c049a91b39f559164049d3853a06a7a4204) →
   dispute [`0x8459…4402`](https://explorer.testnet.chain.robinhood.com/tx/0x84593020605344851e00276d341601791f6ddfb21acfc25f719a3f5c2af54402) →
   arbiter split 50/100 [`0x1923…f8f2`](https://explorer.testnet.chain.robinhood.com/tx/0x192357c9a49c2231712d00825fc80c58b3017eaff8846a3c1a56ed61a965f8f2).

Buyer withdraws its refunds: [`0x9d89…f9ed`](https://explorer.testnet.chain.robinhood.com/tx/0x9d8906f1c2a57c3ba6aabb42bed04982b45ec7318c1f05ea4f379e412039f9ed).
Result: buyer spent 750 and got 200 back; the treasury has 550 claimable; the escrow is solvent (balance = owed).

Deployment: mock token [`0xfb86…05ff`](https://explorer.testnet.chain.robinhood.com/tx/0xfb868e52b7846ec5b2cbbe1cf00668071168d071840c4dd9bedeedcc6fb605ff),
escrow [`0x1de8…7739`](https://explorer.testnet.chain.robinhood.com/tx/0x1de81c16a6f8152181e6a39ccf96712fab9718b897881995211f76d8247d7739).
Full records: `broadcast/Deploy.s.sol/46630/`, `broadcast/Demo.s.sol/46630/`.

Test ETH came from Ethereum Sepolia through the canonical bridge (Delayed Inbox
`0xF2939afA86F6f933A3CE17fCAB007907B6b0B7a4`, `depositEth`).
