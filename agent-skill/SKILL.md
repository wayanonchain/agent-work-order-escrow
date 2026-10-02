---
name: wayan-warrior
description: Connect to Wayan Warrior (an AI research agent that turns live TikTok evidence into scripts), take your human through Wayan's brief (language, niche, audience, lead goal, package), and pay for it from your own wallet through Wayan's on-chain escrow after your human says yes. Use when your human asks you to order TikTok research or scripts from Wayan Warrior, or to pay Wayan.
version: 3.0.0
metadata:
  provider: Wayan Warrior (https://wayanwarrior.pro)
  works_with: any agent that can run Python 3 (Hermes, OpenClaw, Claude, Codex, custom agents)
  helpers: https://wayanwarrior.pro/agent-skills/wayan-warrior/wayan_agent.py and escrow_buyer.py
---

# Wayan Warrior for agents

Wayan Warrior studies live TikTok videos in a niche (views, hooks, transcripts) and writes scripts
from that evidence. You take your human through Wayan's brief, show them the price, pay from your own
wallet after their "yes", and bring back the scripts. The payment waits in an escrow contract until
Wayan proves its research and delivers.

## The fast path (use this)

Every step is one short command of `wayan_agent.py`. Always use these commands; do not build API requests
by hand (hand-made requests are what fail with 400). The commands print plain English: pass their
questions to your human in your own words, in the conversation language. Never paste JSON, curl commands,
hashes or keys into the conversation.

**Conversation language.** English by default. Ask once (step 1) and keep that language for the whole
order, even if your human or a tool answers in another language, until your human explicitly asks you to
switch. The scripts' language is the brief's `--lang`, which is the same choice.

**Setup (once, before talking to your human):**

```bash
mkdir -p ~/.wayan-escrow && cd ~/.wayan-escrow
curl -fsSO https://wayanwarrior.pro/agent-skills/wayan-warrior/wayan_agent.py
curl -fsSO https://wayanwarrior.pro/agent-skills/wayan-warrior/escrow_buyer.py
python3 -m pip install eth-account pysocks
python3 escrow_buyer.py new-wallet          # your wallet; prints only the address. Skip if you have one.
python3 wayan_agent.py connect --invite wpi_... --name "<your name>"
python3 wayan_agent.py status               # your balance; ask your human to top up if it is short
```

**With your human. Stop and ask only where it says ASK:**

1. **ASK: "English or Russian?"** (English if they do not say.) Use that language with your human from
   now on and do not switch on your own.
2. `python3 wayan_agent.py intake --lang <en|ru>` prints Wayan's niches as a numbered list and the brief
   questions. **ASK** your human to pick a niche by number (Wayan works only with these niches; never
   invent one), then the few answers that differ from the niche's defaults: who they want to reach,
   lead goal, call to action, keyword. Keep it to one or two short messages.
3. `python3 wayan_agent.py brief --niche <number> --lang <en|ru> --customer <your human's id>` plus only
   the answers that differ (`--audience`, `--goal`, `--detail`, `--campaign-goal`, `--lead-magnet`,
   `--cta-text`, `--dm-keyword`, `--sources` with their TikTok links). It prints the brief.
4. `python3 wayan_agent.py plan` prints how Wayan reads the niche and the packages with prices.
   **ASK** your human: the niche question as printed, then which package.
5. `python3 wayan_agent.py order --scripts <3|5|10>` gets Wayan's approval, the quote and the escrow
   offer, and checks the offer on-chain. **ASK** your human the payment question it prints.
6. After a clear yes: `python3 wayan_agent.py pay --yes`. It pays, waits for Wayan to confirm and starts
   the research. Tell your human "Paid, research is running, about 3 to 10 minutes."
7. `python3 wayan_agent.py wait` follows the research and the escrow until delivery and prints the
   scripts. Show them to your human in plain words.
8. **ASK** if they are happy; if yes, `python3 wayan_agent.py confirm --yes` releases the payment. If not,
   tell them what is wrong and see "When something fails".

Commands are safe to rerun: `pay --yes` never pays twice, `order` reuses the approval and the quote.

## Rules you never break

1. **Never ask for a private key or seed phrase in chat, and never print one.** If a key is needed,
   your human types it into a hidden prompt in a terminal (step A4a). If your human pastes a key into
   the conversation, tell them it is exposed and they should move the funds to a new account.
2. **Never send keys, tokens or secrets to the Wayan API.** Wayan rejects such payloads.
3. **Your human decides every payment.** Before paying, show the amount, the token, the network and
   what they get. Wait for an explicit "yes" to *that* payment. On-chain commands are dry runs until you
   add `--yes`.
4. **Read the network from Wayan, don't assume it.** `GET /api/a2a/capabilities` → `escrow` shows
   `chain_id`, `contract`, `token` and `explorer_url`. The helper refuses any offer that does not match
   the chain.
5. **Never guess or expand the niche.** Send the niche in your human's own words. If it is short or
   ambiguous (one word, an abbreviation, a brand or product name such as "x ray"), ask what it is and
   who it is for before anything else. Do not add an audience, industry or search terms they did not
   give you.
6. **Mainnet means real money.** `capabilities.escrow.network` says `testnet` or `mainnet`. On mainnet
   (Robinhood Chain, chain id 4663, real USDG) the helpers refuse to pay until your human sets
   `WAYAN_ALLOW_MAINNET=1` and a per-payment ceiling `WAYAN_MAX_PAYMENT=<USDG>` in your environment.
   Tell your human it is real money before every payment, and never set or raise the ceiling yourself.
   Your wallet should hold only what your human is ready to spend through you.

## Appendix: the raw API (only if you cannot run the helpers)

The helpers above call exactly these endpoints. The brief questionnaire with Wayan's niches is public:
`GET /a2a/v1/intake?lang=en`.

### A1. Connect (once)

Partner access is by invitation. Your human gets an invite token (`wpi_...`) from the Wayan owner and
gives it to you. Redeem it once:

```bash
curl -s -X POST https://wayanwarrior.pro/a2a/v1/partners/register -H 'Content-Type: application/json' \
  -d '{"invite_token":"wpi_...","display_name":"<agent name> for <human name>"}'
```

The response shows `client_id` and `client_secret` exactly once. Keep them in your secret store or
environment (`WAYAN_CLIENT_ID`, `WAYAN_CLIENT_SECRET`), never in the conversation. Tokens last 15
minutes; get a new one when you get a 401:

```bash
TOKEN=$(curl -s -X POST https://wayanwarrior.pro/oauth/token -u "$WAYAN_CLIENT_ID:$WAYAN_CLIENT_SECRET" \
  -d grant_type=client_credentials -d scope='recommend quote pay render read_artifacts' | jq -r .access_token)
curl -s https://wayanwarrior.pro/api/a2a/capabilities -H "Authorization: Bearer $TOKEN"
```

Conventions for every call under `/api/a2a/`:
- `Authorization: Bearer $TOKEN`.
- `Idempotency-Key` on every write: 8 to 120 characters, new for each action, the same only to retry it.
- `external_customer_id`: your stable id for your human, for example `katya`. Use the same value everywhere.

### A2. Brief and packages

1. Collect the brief: niche, audience, goal, tone, market (`auto`, `ru_cis`, `en_us`, `global`), known
   experts' TikTok links or "find experts for me", call to action, DM keyword, lead magnet. If a field
   is invalid, the API error lists the allowed choices.
2. `POST /api/a2a/recommend` with that context (the context fields at the top level of the body, not
   wrapped). It returns `recommendation` (the recommended package and all `options` with `script_count`
   3, 5 or 10, `amount`, `token` and a reason) and `niche_check`.
3. **Confirm the niche first.** Show your human `niche_check.ask_your_human` as it is: it says how Wayan
   reads the niche and which hashtags the research starts from. If they say no, fix the brief in their
   words and call `recommend` again. Never skip this: a wrong niche means paying for research in the
   wrong market.
4. Show the options in plain words: what each one includes, its price, and the one Wayan recommends.
   Mention what they can order later from the same scripts: a carousel (free local render), carousel
   visuals and a video (quoted separately). Get a clear "yes" to the package.

### A3. Approval and quote

Paid writes need an approval from the Wayan owner. Ask for one per order:

```bash
curl -s -X POST https://wayanwarrior.pro/api/a2a/approval-requests -H "Authorization: Bearer $TOKEN" \
  -H "Idempotency-Key: $(uuidgen)" -H 'Content-Type: application/json' -d '{
  "external_customer_id":"katya",
  "actions":["commerce.quote.manage","commerce.payment.manage","analysis.job.launch"],
  "uses":10, "expires_in_minutes":240,
  "reason":"Research + scripts for my human"}'
```

If `status` is `pending`, tell your human that Wayan is reviewing the order, and poll
`GET /api/a2a/approval-requests/{request_id}?external_customer_id=katya` until it is `approved`. Send its
`approval_id` as `X-Wayan-Approval-Id` on every write below. If you get
`gatekeeper_approval_required` or `gatekeeper_approval_invalid`, ask for a new approval.

Then create the quote: `POST /api/a2a/quotes` with
`{"context": {...brief..., "brief_confirmed": true}, "script_count": <chosen>}`. Keep `quote.id`,
`quote.amount`, `confirmed_brief.brief` and `confirmed_brief.brief_sha256`.

### A4. Pay

Look at `capabilities.escrow`. If `enabled` is true and you have your own funded wallet (below), use
**A4a**. Otherwise use **A4b**.

#### A4a. Escrow (the money stays in a contract until Wayan delivers)

The escrow holds the payment on-chain. Wayan gets it only after it commits its research evidence
and delivers; if it fails the evidence gate, your human gets a refund from the contract. You send the
transaction yourself, because the contract accepts it only from the buyer named in the quote.

Current network (testnet): Robinhood Chain testnet, chain id `46630`, RPC
`https://rpc.testnet.chain.robinhood.com`, explorer `https://explorer.testnet.chain.robinhood.com`,
escrow `0x2a10FE1c3586987A5748E9d90D97F2765F84035c`, token mock USDG (anyone can mint it). The helper
uses these by default. If `capabilities.escrow` names another contract or chain, pass
`--escrow <contract>` and `--rpc-url <that chain's public RPC>` to every helper command; the helper
then refuses any offer for a different contract or chain.

**Install the helper (once):**

```bash
mkdir -p ~/.wayan-escrow && cd ~/.wayan-escrow
curl -fsSO https://wayanwarrior.pro/agent-skills/wayan-warrior/escrow_buyer.py
python3 -m pip install eth-account pysocks
```

**Your wallet (once).** You pay from your own wallet, like an employee with a company card: your human
tops it up, you pay after their "yes" in the chat. There is no MetaMask pop-up for each payment.
- *Default:* `python3 escrow_buyer.py new-wallet` creates your wallet and prints only its address. Give
  your human the address and ask them to top it up.
- *Alternative:* your human wants you to use an existing MetaMask account. Only they type its key, in a
  terminal where you run: `python3 ~/.wayan-escrow/escrow_buyer.py import-key` (hidden input). Never
  ask for the key in chat.

The key stays in `~/.wayan-escrow/buyer.env` (mode 600); `address` prints only the address.

**Funding.** Your human sends your address, for example from their MetaMask, a little ETH for gas
(about 0.001 ETH covers several payments) and the token. On testnet you can also mint the mock token:
`python3 escrow_buyer.py mint --amount 1000`, then `--yes` after your human agrees. `status` shows ETH,
token balance and refunds to withdraw. If the balance is lower than the price, tell your human how much
to send before they choose a package.

**Pay:**

```bash
curl -s -X POST https://wayanwarrior.pro/api/a2a/payments/escrow/offer -H "Authorization: Bearer $TOKEN" \
  -H "Idempotency-Key: $(uuidgen)" -H "X-Wayan-Approval-Id: $APPROVAL_ID" -H 'Content-Type: application/json' \
  -d "{\"external_customer_id\":\"katya\",\"quote_id\":\"$QUOTE_ID\",\"buyer_address\":\"$(python3 ~/.wayan-escrow/escrow_buyer.py address)\"}" \
  > ~/.wayan-escrow/offer.json
python3 ~/.wayan-escrow/escrow_buyer.py pay --offer ~/.wayan-escrow/offer.json          # dry run
```

The dry run checks the offer against the chain, not against the API response: the quote is signed by
a key holding Wayan's attester role, the buyer is this wallet, the money goes to the escrow for exactly
the quoted amount, the quote has not expired, and the order is not already paid. Show your human the
summary (amount, research fee, deadlines). After their "yes", run the same command with `--yes`. You
get the transaction link and the `order_id`.

Wayan confirms the payment after about 20 blocks. Poll
`GET /api/a2a/quotes/{quote_id}?external_customer_id=katya` until `quote.status` is `paid_confirmed`,
or ask for an immediate check with `POST /api/a2a/payments/escrow/verify`
`{"external_customer_id":"katya","quote_id":"..."}`.

#### A4b. Invoice (your human pays from their own wallet, you hold no key)

1. `POST /api/a2a/quotes/{quote_id}/invoice` with `{"external_customer_id":"katya"}` (with the approval
   header). The invoice has `amount_text` (the exact amount to send), `token`, `chain`, `pay_to_address`
   and `expires_at`. The amount is unique to this invoice: a hair under the list price, never issued twice.
2. Show those to your human. They send exactly `amount_text`, down to the last digit, from their own wallet
   on that chain (today USDC on Solana, for example from Phantom) and give you the transaction id. A
   different amount, or a transfer for an expired invoice, is settled by Wayan's owner by hand, not automatically.
3. `POST /api/a2a/payments/crypto/verify` with `{"external_customer_id":"katya","invoice_id":"...","txid":"..."}`.
   `payment.status` `pending_confirmations` means nothing was decided yet (young transaction or RPC down):
   repeat the same call after `retry_after_seconds`. Retry until the invoice is `confirmed` and the quote
   is `paid_confirmed`.

### A5. Launch and deliver

`POST /api/a2a/analyze/jobs` with
`{"external_customer_id":"katya","quote_id":"...","brief":<confirmed_brief.brief>,"brief_sha256":"..."}`
(with the approval header). Poll the returned `poll_url`; research takes about 10 to 20 minutes.
Statuses: `queued`, `running`, `done`, `failed`, `manual_review`. When it is `done`, show your human
the scripts and offer the next options (carousel, visuals, video) from `capabilities`.

**Escrow only, after delivery:**
- `python3 escrow_buyer.py order --order-id <id>` shows the state: `Accepted` → `EvidenceCommitted`
  (Wayan proved its research) → `Delivered`.
- Your human is satisfied: `confirm --order-id <id>` (dry run, then `--yes`) releases the payment. If
  nobody disputes, anyone can release it once the dispute window ends.
- Something is wrong: `dispute --order-id <id> --reason "..."` within the dispute window. An arbiter
  decides.
- Refunds (failed evidence gate, missed deadline, arbiter split) wait in the contract: `withdraw`.

## When something fails

- `503` on a quote, offer or invoice: payments or research are switched off right now. Nothing was
  charged. Tell your human and try later.
- `409` on an offer: an open offer for this quote exists for another buyer address. Use that address
  or wait until it expires.
- `failed` or `manual_review` after payment: the Wayan owner reviews it. Escrow orders that fail before
  any research call are refunded automatically.
- The helper refuses an offer: do **not** pay. Show the error to your human and to the Wayan owner.
- RPC does not resolve (some regions block `*.robinhood.com`): use `--proxy socks5h://host:port` or
  `ESCROW_RPC_PROXY`.
