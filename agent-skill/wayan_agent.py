#!/usr/bin/env python3
"""Short commands for an agent that buys Wayan Warrior research for its human and pays through the escrow.

One command per step the human cares about, plain-English output, no JSON to paste into a chat:

    connect   --invite wpi_... --name "Katya Hermes"   register once (secrets go to a 0600 file)
    intake    [--lang en|ru]                           Wayan's niches and brief questions, numbered
    brief     --niche 4 --lang en [--cta-text ...]     build the brief from a Wayan niche + answers
    plan                                               how Wayan reads the niche + packages and prices
    order     --scripts 3                              approval, quote, escrow offer, checked on-chain
    pay       --yes                                    pay into the escrow, then start the research
    wait                                               follow the research and the escrow to delivery
    confirm   --yes                                    release the payment to Wayan
    status                                             wallet, order and research state

State lives in ~/.wayan-escrow (client.env and order.json, mode 0600). The wallet is the one from
escrow_buyer.py (new-wallet / import-key). Needs: pip install eth-account (pysocks for a SOCKS proxy).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import escrow_buyer as eb  # noqa: E402

DEFAULT_BASE = "https://wayanwarrior.pro"
ORDER_ACTIONS = ["commerce.quote.manage", "commerce.payment.manage", "analysis.job.launch"]
SCOPES = "recommend quote pay render read_artifacts"
DONE_STATES = {"done", "failed", "manual_review", "fallback_ready"}


class AgentError(Exception):
    """A refusal or failure to show the human in plain words. Never contains a secret."""


# ------------------------------------------------------------------ local state


def write_private(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write(text)
    os.chmod(path, 0o600)


class State:
    def __init__(self, home: Path):
        self.home = home
        self.client_file = home / "client.env"
        self.order_file = home / "order.json"

    def client(self) -> dict[str, str]:
        if not self.client_file.exists():
            raise AgentError("not connected yet: run `connect --invite wpi_... --name \"<agent name>\"` first")
        values = dict(line.split("=", 1) for line in self.client_file.read_text().splitlines() if "=" in line)
        return {"client_id": values.get("WAYAN_CLIENT_ID", ""), "client_secret": values.get("WAYAN_CLIENT_SECRET", "")}

    def save_client(self, client_id: str, secret: str) -> None:
        write_private(self.client_file, f"WAYAN_CLIENT_ID={client_id}\nWAYAN_CLIENT_SECRET={secret}\n")

    def order(self) -> dict[str, Any]:
        return json.loads(self.order_file.read_text()) if self.order_file.exists() else {}

    def save_order(self, data: dict[str, Any]) -> None:
        write_private(self.order_file, json.dumps(data, indent=2, ensure_ascii=False))


# ------------------------------------------------------------------ Wayan API


class Wayan:
    def __init__(self, base: str, state: State):
        self.base = base.rstrip("/")
        self.state = state
        self._token = ""

    def request(self, method: str, path: str, body: Any = None, headers: dict[str, str] | None = None,
                form: str | None = None, auth: bool = True) -> dict[str, Any]:
        h = {"Accept": "application/json", "User-Agent": "wayan-agent/1", **(headers or {})}
        data = None
        if form is not None:
            h["Content-Type"] = "application/x-www-form-urlencoded"
            data = form.encode()
        elif body is not None:
            h["Content-Type"] = "application/json"
            data = json.dumps(body).encode()
        if auth:
            h["Authorization"] = "Bearer " + self.token()
        req = urllib.request.Request(self.base + path, data=data, headers=h, method=method)
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return json.loads(resp.read() or b"{}")
        except urllib.error.HTTPError as exc:
            detail = exc.read()[:600].decode(errors="replace")
            raise AgentError(f"Wayan answered {exc.code} on {method} {path.split('?')[0]}: {detail}") from None
        except urllib.error.URLError as exc:
            raise AgentError(f"cannot reach Wayan ({exc.reason})") from None

    def token(self) -> str:
        if not self._token:
            import base64

            c = self.state.client()
            basic = base64.b64encode(f"{c['client_id']}:{c['client_secret']}".encode()).decode()
            resp = self.request("POST", "/oauth/token", headers={"Authorization": "Basic " + basic},
                                form=f"grant_type=client_credentials&scope={urllib.parse.quote(SCOPES)}", auth=False)
            self._token = resp["access_token"]
        return self._token

    def write(self, path: str, body: Any, key: str, approval: str | None = None) -> dict[str, Any]:
        headers = {"Idempotency-Key": key}
        if approval:
            headers["X-Wayan-Approval-Id"] = approval
        return self.request("POST", path, body, headers)


# ------------------------------------------------------------------ brief


def build_brief(intake: dict[str, Any], args: argparse.Namespace) -> dict[str, Any]:
    niches = intake["niches"]
    niche = next((n for n in niches if str(n["number"]) == str(args.niche) or n["id"] == args.niche), None)
    if niche is None:
        raise AgentError("pick a niche from `intake` by its number or id; Wayan works only with its own niches")
    d = niche["defaults"]
    dm = (args.dm_keyword or d.get("dm_keyword") or "GUIDE").strip()
    lead_magnet = args.lead_magnet or d.get("lead_magnet") or "checklist"
    niche_text = d["niche"] + (f"; {args.detail.strip()}" if args.detail else "")
    context = {
        "external_customer_id": args.customer,
        "language": args.lang,
        "niche": niche_text[:400],
        "audience": args.audience or d["audience"],
        "goal": args.goal or d["goal"],
        "tone": args.tone or ("expert and practical" if args.lang == "en" else "экспертно и по делу"),
        "market": args.market,
        "source_mode": "known_sources" if args.sources else "discover_experts",
        "sources": args.sources or "",
        "search_intent": args.search_intent or f"Find proven TikTok creators and videos about {niche['label']}",
        "target_platform": "tiktok",
        "campaign_goal": args.campaign_goal or d.get("campaign_goal") or "leads",
        "offer_name": args.offer_name or "",
        "lead_magnet": lead_magnet,
        "cta_text": args.cta_text or (f"Comment {dm} and I'll send you the {lead_magnet.replace('_', ' ')}."
                                      if args.lang == "en" else f"Напишите {dm} в комментариях, и я пришлю материал."),
        "cta_style": args.cta_style or d.get("cta_style") or "direct",
        "dm_keyword": dm,
        "brief_confirmed": False,
    }
    return {"niche_id": niche["id"], "niche_label": niche["label"], "context": context}


def brief_lines(brief: dict[str, Any]) -> list[str]:
    c = brief["context"]
    return [
        f"Niche: {brief['niche_label']}",
        f"Language: {'English' if c['language'] == 'en' else 'Russian'}  |  Market: {c['market']}",
        f"Audience: {c['audience']}",
        f"Goal: {c['goal']}",
        f"Tone: {c['tone']}",
        f"Reference videos: {'your sources' if c['source_mode'] == 'known_sources' else 'Wayan finds the experts'}",
        f"Lead goal: {c['campaign_goal']}  |  Lead magnet: {c['lead_magnet']}",
        f"Call to action: {c['cta_text']}  (style {c['cta_style']}, keyword {c['dm_keyword']})",
    ]


# ------------------------------------------------------------------ chain


def chain_for(args: argparse.Namespace, escrow: str | None = None, rpc_url: str | None = None,
              explorer: str | None = None) -> eb.Chain:
    """The escrow Wayan names in its capabilities, on the public RPC it names (unless overridden)."""
    rpc = args.rpc_url if args.rpc_url != eb.DEFAULT_RPC_URL else (rpc_url or args.rpc_url)
    return eb.Chain(eb.make_rpc(rpc, args.proxy), escrow or args.escrow, explorer or args.explorer)


def order_chain(args: argparse.Namespace, order: dict[str, Any]) -> eb.Chain:
    return chain_for(args, order.get("escrow"), order.get("rpc_url"), order.get("explorer"))


def wallet(args: argparse.Namespace) -> tuple[str, str]:
    key = eb.load_key(Path(args.key_file).expanduser())
    return key, eb.Account.from_key(key).address


def money(chain: eb.Chain, who: str) -> tuple[str, str, int]:
    token = chain.token()
    dec = chain.decimals(token)
    return eb.fmt(chain.eth_balance(who), 18), eb.fmt(chain.erc20_balance(token, who), dec), dec


# ------------------------------------------------------------------ commands


def cmd_connect(api: Wayan, state: State, args: argparse.Namespace) -> None:
    if state.client_file.exists() and not args.force:
        print(f"Already connected as {state.client()['client_id']}. Use --force to register again.")
        return
    reg = api.request("POST", "/a2a/v1/partners/register",
                      {"invite_token": args.invite, "display_name": args.name}, auth=False)
    oauth = reg.get("oauth") or {}
    if not oauth.get("client_id") or not oauth.get("client_secret"):
        raise AgentError("registration did not return OAuth credentials")
    state.save_client(oauth["client_id"], oauth["client_secret"])
    print(f"Connected to Wayan Warrior as {oauth['client_id']}. Credentials saved in {state.client_file} (private).")


def cmd_intake(api: Wayan, state: State, args: argparse.Namespace) -> None:
    intake = api.request("GET", f"/a2a/v1/intake?lang={args.lang}", auth=False)
    order = state.order()
    order["intake"] = intake
    state.save_order(order)
    print("Ask your human first: English or Russian? (English if they do not say; keep that language for the whole"
          " order and do not switch on your own.) Then these, one at a time, with numbered options.\n")
    print("Niches (Wayan works only with these):")
    for n in intake["niches"]:
        print(f"  {n['number']:>2}. {n['label']}" + (f" - {n['hint']}" if n.get("hint") else ""))
    print("\nThen:")
    for step in intake["steps"][2:]:
        line = f"  - {step['question']}"
        options = step.get("options")
        if isinstance(options, dict):
            line += ": " + ", ".join(f"{k} ({v})" for k, v in options.items())
        elif step["field"] == "script_count":
            line += ": " + ", ".join(f"{o['label']} = {o['script_count']} scripts, {o['amount']} {o['token']}"
                                     for o in options)
        elif step.get("default_from"):
            line += " (default from the niche)"
        print(line)
    print("\nNext: `brief --niche <number> --lang <en|ru>` plus any answers that differ from the niche defaults.")


def cmd_brief(api: Wayan, state: State, args: argparse.Namespace) -> None:
    order = state.order()
    intake = order.get("intake")
    if not intake or intake.get("language") != args.lang:
        intake = api.request("GET", f"/a2a/v1/intake?lang={args.lang}", auth=False)
    brief = build_brief(intake, args)
    if order.get("order_id"):  # keep the previous order's ids instead of overwriting them
        write_private(state.home / f"order-{int(time.time())}.json", json.dumps(order, indent=2, ensure_ascii=False))
    state.save_order({"intake": intake, "brief": brief})
    print(f"Show your human this brief and ask: is this right? (Talk to them in "
          f"{'English' if args.lang == 'en' else 'Russian'}.)\n")
    print("\n".join("  " + line for line in brief_lines(brief)))
    print("\nNext: `plan`.")


def cmd_plan(api: Wayan, state: State, args: argparse.Namespace) -> None:
    order = state.order()
    if "brief" not in order:
        raise AgentError("no brief yet: run `brief --niche <number> --lang <en|ru>` first")
    rec = api.request("POST", "/api/a2a/recommend", order["brief"]["context"])
    order["recommend"] = rec
    state.save_order(order)
    check = rec.get("niche_check") or {}
    r = rec["recommendation"]
    print("Ask your human, word for word:")
    print(f"  {check.get('ask_your_human', 'Is this your niche?')}\n")
    print("Packages:")
    for o in r["options"]:
        star = "  <- recommended" if o["script_count"] == r["script_count"] else ""
        print(f"  {o['label']}: {o['script_count']} scripts, {o['amount']} {o['token']}. {o.get('description', '')}{star}")
    print(f"\nWhy: {r.get('reason', '')}")
    print("Next: after your human confirms the niche and picks a package, `order --scripts <3|5|10>`.")


def cmd_order(api: Wayan, state: State, args: argparse.Namespace) -> None:
    order = state.order()
    if "brief" not in order:
        raise AgentError("no brief yet: run `brief` and `plan` first")
    context = {**order["brief"]["context"], "brief_confirmed": True}
    customer = context["external_customer_id"]
    keys = order.setdefault("keys", {})
    if not order.get("approval_id"):
        req = api.write("/api/a2a/approval-requests", {
            "external_customer_id": customer, "actions": ORDER_ACTIONS, "uses": 10, "expires_in_minutes": 240,
            "reason": f"{args.scripts} scripts for {order['brief']['niche_label']}",
        }, keys.setdefault("approval", uuid.uuid4().hex))
        approval = (req.get("approval") or {}).get("approval_id")
        request_id = req["request"]["request_id"]
        deadline = time.time() + args.approval_timeout
        if not approval:
            print("Waiting for Wayan to approve the order...", flush=True)
        while not approval:
            if time.time() > deadline:
                raise AgentError("Wayan has not approved the order yet; run `order` again in a few minutes")
            time.sleep(5)
            got = api.request("GET", f"/api/a2a/approval-requests/{request_id}")["request"]
            if got["status"] == "rejected":
                raise AgentError(f"Wayan declined the order: {got.get('decision_reason') or 'no reason given'}")
            approval = got.get("approval_id") if got["status"] == "approved" else None
        order["approval_id"] = approval
        state.save_order(order)
    approval = order["approval_id"]
    if not order.get("quote_id") or order.get("script_count") != args.scripts:
        q = api.write("/api/a2a/quotes", {"context": context, "script_count": args.scripts},
                      keys.setdefault(f"quote{args.scripts}", uuid.uuid4().hex), approval)
        order.update(quote_id=q["quote"]["id"], script_count=args.scripts, confirmed_brief=q["confirmed_brief"],
                     amount=q["quote"]["amount"], token=q["quote"]["token"])
        order.pop("offer", None)
        state.save_order(order)
    key, buyer = wallet(args)
    caps = api.request("GET", "/api/a2a/capabilities")
    escrow = caps.get("escrow") or {}
    if not escrow.get("enabled"):
        raise AgentError("Wayan's escrow is switched off right now; nothing was charged")
    offer = api.write("/api/a2a/payments/escrow/offer",
                      {"external_customer_id": customer, "quote_id": order["quote_id"], "buyer_address": buyer},
                      keys.setdefault("offer" + order["quote_id"], uuid.uuid4().hex), approval)
    chain = chain_for(args, escrow.get("contract"), escrow.get("public_rpc_url"), escrow.get("explorer_url"))
    checked = eb.verify_offer(chain, eb.unwrap_offer(offer), buyer)
    q, token = checked["q"], checked["token"]
    dec = chain.decimals(token)
    mainnet = checked["chain_id"] in eb.MAINNET_CHAIN_IDS
    if mainnet:
        eb.check_network(chain.chain_id(), "payment")
        eb.check_spend_limit(chain.chain_id(), q["amount"], dec)
    order.update(offer=offer, order_id=eb.hex0x(checked["order_id"]), escrow=chain.escrow, network="mainnet" if mainnet else "testnet",
                 rpc_url=escrow.get("public_rpc_url"), explorer=escrow.get("explorer_url"))
    state.save_order(order)
    eth, usd, _ = money(chain, buyer)
    short = chain.erc20_balance(token, buyer) < q["amount"]
    amount, fee = eb.fmt(q["amount"], dec), eb.fmt(q["researchAmount"], dec)
    print("The offer checks out on-chain: signed by Wayan, paid into the escrow, exact amount, not expired.\n")
    if mainnet:
        print("REAL MONEY: this is Robinhood Chain mainnet. Say so to your human.\n")
    print(f"Ask your human: pay {amount} {escrow.get('token_symbol', 'USDG')} for {args.scripts} scripts "
          f"({order['brief']['niche_label']})?")
    print(f"  The money stays in the escrow contract until Wayan delivers. {fee} of it is the research fee, "
          "earned once Wayan proves its research; the rest is released on delivery. If Wayan fails, you get it back.")
    print(f"  Your wallet: {usd} {escrow.get('token_symbol', 'USDG')}, {eth} ETH for gas.")
    if short:
        print(f"  Not enough: top up {buyer} before paying.")
    print("\nNext: after a clear yes, `pay --yes`.")


def cmd_pay(api: Wayan, state: State, args: argparse.Namespace) -> None:
    order = state.order()
    if not order.get("offer"):
        raise AgentError("no checked offer: run `order` first")
    key, buyer = wallet(args)
    chain = order_chain(args, order)
    customer = order["brief"]["context"]["external_customer_id"]
    if not order.get("funded_tx"):
        checked = eb.verify_offer(chain, eb.unwrap_offer(order["offer"]), buyer)
        eb.check_network(chain.chain_id(), "payment")
        eb.check_spend_limit(chain.chain_id(), checked["q"]["amount"], chain.decimals(checked["token"]))
        if not args.yes:
            print(f"Dry run: would pay {order['amount']} {order['token']} into the escrow. Add --yes after your human agrees.")
            return
        print("Paying into the Wayan escrow...", flush=True)
        auth = eb.sign_authorization(checked["typed"], key)
        sent = eb.send_tx(chain, key, chain.escrow, eb.fund_calldata(checked["quote"], checked["signature"], auth),
                          True, "payment")
        order["funded_tx"] = sent.get("tx_hash")
        state.save_order(order)
    print("Paid. Waiting for Wayan to confirm the payment (about a minute)...", flush=True)
    # One verify nudges Wayan to look at the chain now (each approved write uses one approval use);
    # after that only read the quote, which costs nothing. Wayan also confirms on its own every minute.
    verified = api.write("/api/a2a/payments/escrow/verify",
                         {"external_customer_id": customer, "quote_id": order["quote_id"]},
                         order["keys"].setdefault("verify" + order["quote_id"], uuid.uuid4().hex), order["approval_id"])
    status = verified.get("quote_status")
    deadline = time.time() + args.confirm_timeout
    while status != "paid_confirmed":
        time.sleep(10)
        status = api.request("GET", f"/api/a2a/quotes/{order['quote_id']}?external_customer_id="
                             f"{urllib.parse.quote(customer)}")["quote"]["status"]
        if time.time() > deadline and status != "paid_confirmed":
            raise AgentError("Wayan has not confirmed the payment yet; run `pay` again in a minute (it will not pay twice)")
    if not order.get("job_id"):
        cb = order["confirmed_brief"]
        job = api.write("/api/a2a/analyze/jobs", {"external_customer_id": customer, "quote_id": order["quote_id"],
                                                   "brief": cb["brief"], "brief_sha256": cb["brief_sha256"]},
                        order["keys"].setdefault("launch", uuid.uuid4().hex), order["approval_id"])
        order["job_id"] = job["job_id"]
        state.save_order(order)
    print("Payment confirmed. Research started. Next: `wait` (about 3 to 10 minutes).")


def print_scripts(result: dict[str, Any]) -> None:
    for i, s in enumerate(result.get("scripts") or [], start=1):
        print(f"\nScript {i}: {s.get('title', '')}")
        print(f"  Hook: {s.get('hook', '')}")
        print(f"  Body: {s.get('body', '')}")
        print(f"  Call to action: {s.get('cta', '')}")


def cmd_wait(api: Wayan, state: State, args: argparse.Namespace) -> None:
    order = state.order()
    if not order.get("job_id"):
        raise AgentError("no research running: run `pay --yes` first")
    customer = order["brief"]["context"]["external_customer_id"]
    chain = order_chain(args, order)
    last_msg, last_state = "", ""
    deadline = time.time() + args.timeout
    while True:
        job = api.request("GET", f"/api/a2a/analyze/jobs/{order['job_id']}?external_customer_id={urllib.parse.quote(customer)}")
        msg = job.get("progress_message") or job.get("progress_stage") or job["status"]
        if msg != last_msg:
            print(f"Research: {msg}", flush=True)
            last_msg = msg
        try:
            escrow_state = chain.order(eb.b32(order["order_id"]))["state_name"]
        except eb.BuyerError:
            escrow_state = last_state
        if escrow_state != last_state:
            print(f"Escrow: {escrow_state}", flush=True)
            last_state = escrow_state
        if job["status"] in DONE_STATES:
            break
        if time.time() > deadline:
            raise AgentError("still running; run `wait` again")
        time.sleep(15)
    order["job_status"] = job["status"]
    state.save_order(order)
    if job["status"] != "done":
        print(f"Research ended as {job['status']}. Wayan's owner reviews it; if Wayan failed, the escrow refunds you.")
        return
    result = job.get("result") or {}
    write_private(state.home / "scripts.json", json.dumps(result.get("scripts") or [], indent=2, ensure_ascii=False))
    print("\nDelivered. Show your human the scripts:")
    print_scripts(result)
    print("\nNext: if your human is happy, `confirm --yes` releases the payment to Wayan.")


def cmd_confirm(api: Wayan, state: State, args: argparse.Namespace) -> None:
    order = state.order()
    if not order.get("order_id"):
        raise AgentError("no order to confirm")
    key, _buyer = wallet(args)
    chain = order_chain(args, order)
    if not args.yes:
        print("Dry run: would release the payment to Wayan. Add --yes after your human agrees.")
        return
    eb.send_tx(chain, key, chain.escrow, eb.encode_call("confirmRelease(bytes32)", ["bytes32"], [eb.b32(order["order_id"])]),
               True, "release")
    print("Payment released to Wayan. Order closed.")


def cmd_status(api: Wayan, state: State, args: argparse.Namespace) -> None:
    order = state.order()
    key, buyer = wallet(args)
    chain = order_chain(args, order)
    eth, usd, _ = money(chain, buyer)
    print(f"Wallet {buyer}: {usd} USDG, {eth} ETH")
    if order.get("order_id"):
        print(f"Order {order['order_id'][:10]}...: escrow {chain.order(eb.b32(order['order_id']))['state_name']}, "
              f"research {order.get('job_status') or ('running' if order.get('job_id') else 'not started')}")


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--base", default=os.environ.get("WAYAN_BASE_URL", DEFAULT_BASE))
    p.add_argument("--home", default=os.environ.get("WAYAN_AGENT_HOME", "~/.wayan-escrow"))
    p.add_argument("--rpc-url", default=os.environ.get("ESCROW_RPC_URL", eb.DEFAULT_RPC_URL))
    p.add_argument("--proxy", default=os.environ.get("ESCROW_RPC_PROXY"))
    p.add_argument("--escrow", default=os.environ.get("ESCROW_CONTRACT", eb.DEFAULT_ESCROW))
    p.add_argument("--explorer", default=os.environ.get("ESCROW_EXPLORER_URL", eb.DEFAULT_EXPLORER))
    p.add_argument("--key-file", default=os.environ.get("WAYAN_BUYER_KEY_FILE") or eb.default_key_file())
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("connect")
    c.add_argument("--invite", required=True)
    c.add_argument("--name", required=True)
    c.add_argument("--force", action="store_true")
    i = sub.add_parser("intake")
    i.add_argument("--lang", choices=["en", "ru"], default="en")
    b = sub.add_parser("brief")
    b.add_argument("--niche", required=True, help="number or id from `intake`")
    b.add_argument("--lang", choices=["en", "ru"], required=True)
    b.add_argument("--customer", default=os.environ.get("WAYAN_CUSTOMER_ID", "me"))
    b.add_argument("--market", choices=["auto", "en_us", "ru_cis", "global"], default="auto")
    for flag in ("detail", "audience", "goal", "tone", "sources", "search-intent", "campaign-goal", "lead-magnet",
                 "offer-name", "cta-text", "cta-style", "dm-keyword"):
        b.add_argument(f"--{flag}")
    sub.add_parser("plan")
    o = sub.add_parser("order")
    o.add_argument("--scripts", type=int, choices=[3, 5, 10], required=True)
    o.add_argument("--approval-timeout", type=int, default=600)
    y = sub.add_parser("pay")
    y.add_argument("--yes", action="store_true")
    y.add_argument("--confirm-timeout", type=int, default=300)
    w = sub.add_parser("wait")
    w.add_argument("--timeout", type=int, default=1800)
    f = sub.add_parser("confirm")
    f.add_argument("--yes", action="store_true")
    sub.add_parser("status")
    args = p.parse_args(argv)
    state = State(Path(args.home).expanduser())
    api = Wayan(args.base, state)
    handlers = {"connect": cmd_connect, "intake": cmd_intake, "brief": cmd_brief, "plan": cmd_plan,
                "order": cmd_order, "pay": cmd_pay, "wait": cmd_wait, "confirm": cmd_confirm, "status": cmd_status}
    try:
        handlers[args.cmd](api, state, args)
    except (AgentError, eb.BuyerError) as exc:
        print(f"Stopped: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
