#!/usr/bin/env python3
"""Buyer-agent side of AgentWorkOrderEscrow: any partner agent (Hermes, OpenClaw, Claude, a custom agent) pays Wayan through the escrow.

Wayan's backend returns an escrow offer for an A2A quote (``POST /api/a2a/payments/escrow/offer``): the Quote
struct signed by Wayan's attester plus the EIP-3009 typed data the buyer must sign. This script is everything
the buyer does after that, from its own wallet:

    new-wallet   create the buyer wallet (key goes to a 0600 env file, only the address is printed)
    import-key   store an existing wallet's key (e.g. exported from MetaMask), read without echo
    address      print the buyer address (never the key)
    status       ETH for gas, test USDG, escrow balance to withdraw
    mint         mint mock USDG to the buyer (testnet mock token only)
    pay          check the offer against the chain, sign the EIP-3009 authorization, call fundWithAuthorization
    order        read an order's on-chain state
    confirm      confirmRelease after Wayan delivered
    dispute      openDispute after delivery
    withdraw     withdraw refunds credited to the buyer

Every transaction is a dry run (gas estimate + summary) unless ``--yes`` is given. The buyer pays its own gas:
the contract only accepts ``fundWithAuthorization`` from the buyer named in the quote.

Before paying, the offer is checked against the chain, not trusted as sent: the quote digest must equal the
contract's ``quoteDigest``, its signer must hold ``ATTESTER_ROLE``, the buyer must be this wallet, the transfer must
go to the escrow for exactly the quote amount, and the token's EIP-712 domain must match the token's own
``DOMAIN_SEPARATOR``. The private key is never printed, logged or put in an exception.

Needs: ``pip install eth-account`` (and ``pysocks`` when the RPC is reached through a SOCKS proxy, see --help).
"""

from __future__ import annotations

import argparse
import json
import os
import secrets
import stat
import sys
import time
from decimal import Decimal
from pathlib import Path
from typing import Any, Callable
from urllib import error as urlerror
from urllib import request as urlrequest

from eth_abi import decode as abi_decode
from eth_abi import encode as abi_encode
from eth_account import Account
from eth_account.messages import encode_typed_data
from eth_utils import keccak, to_checksum_address

# Robinhood Chain testnet deployment (contracts/deployments.md).
DEFAULT_CHAIN_ID = 46630
DEFAULT_RPC_URL = "https://rpc.testnet.chain.robinhood.com"
DEFAULT_ESCROW = "0x2a10FE1c3586987A5748E9d90D97F2765F84035c"
DEFAULT_EXPLORER = "https://explorer.testnet.chain.robinhood.com"
DEFAULT_KEY_FILE = "~/.wayan-escrow/buyer.env"
LEGACY_KEY_FILE = "~/.wayan-escrow/hermes-buyer.env"  # first Hermes demo; still read when it is the only one
KEY_ENV = "WAYAN_BUYER_KEY"
LEGACY_KEY_ENVS = ("HERMES_BUYER_KEY",)
TESTNET_CHAIN_IDS = {46630}
# Real money: Robinhood Chain mainnet. Refused unless the human opted in (WAYAN_ALLOW_MAINNET=1) and set a
# per-payment ceiling in token units (WAYAN_MAX_PAYMENT, e.g. 50). Both live in the agent's environment.
MAINNET_CHAIN_IDS = {4663}
MAINNET_OPT_IN_ENV = "WAYAN_ALLOW_MAINNET"
MAX_PAYMENT_ENV = "WAYAN_MAX_PAYMENT"


def mainnet_allowed() -> bool:
    return os.environ.get(MAINNET_OPT_IN_ENV, "").strip() == "1"


def check_network(chain_id: int, label: str) -> None:
    if chain_id in TESTNET_CHAIN_IDS or (chain_id in MAINNET_CHAIN_IDS and mainnet_allowed()):
        return
    if chain_id in MAINNET_CHAIN_IDS:
        raise BuyerError(f"{label}: this is Robinhood Chain mainnet (real money); your human must set "
                         f"{MAINNET_OPT_IN_ENV}=1 and {MAX_PAYMENT_ENV}=<max per payment> first")
    raise BuyerError(f"{label}: unknown network {chain_id}; this helper pays only on Robinhood Chain")


def check_spend_limit(chain_id: int, amount_units: int, decimals: int) -> None:
    """On mainnet every payment must fit the ceiling the human set; testnet has no ceiling."""
    if chain_id not in MAINNET_CHAIN_IDS:
        return
    raw = os.environ.get(MAX_PAYMENT_ENV, "").strip()
    try:
        ceiling = int(Decimal(raw) * (Decimal(10) ** decimals)) if raw else 0
    except Exception:  # noqa: BLE001 - a malformed ceiling is no ceiling
        ceiling = 0
    if ceiling <= 0:
        raise BuyerError(f"set {MAX_PAYMENT_ENV}=<max per payment in tokens> before paying on mainnet")
    if amount_units > ceiling:
        raise BuyerError(f"this payment ({fmt(amount_units, decimals)}) is above your limit {MAX_PAYMENT_ENV}={raw}")

QUOTE_TUPLE = "(bytes32,address,uint256,uint256,uint16,uint64,uint64,uint64,uint64,bytes32)"
AUTH_TUPLE = "(uint256,uint256,bytes32,uint8,bytes32,bytes32)"
QUOTE_KEYS = (
    "quoteId", "buyer", "amount", "researchAmount", "minCoverageBps",
    "validUntil", "acceptDeadline", "deliveryDeadline", "disputeWindow", "termsHash",
)
ORDER_TUPLE = (
    "(address,address,uint8,uint16,uint16,uint64,uint64,uint64,uint64,uint64,uint256,uint256,uint256,"
    "bytes32,bytes32,bytes32,bytes32)"
)
ORDER_KEYS = (
    "buyer", "provider_treasury", "state", "min_coverage_bps", "coverage_bps", "accept_deadline",
    "delivery_deadline", "dispute_window", "delivered_at", "disputed_at", "amount", "research_amount",
    "settled", "quote_digest", "evidence_root", "deliverable_hash", "provenance_hash",
)
STATES = ("None", "Funded", "Accepted", "EvidenceCommitted", "Delivered", "Disputed", "Released", "Refunded",
          "Resolved")
ATTESTER_ROLE = keccak(text="ATTESTER_ROLE")
EIP712_DOMAIN_FIELDS = [
    {"name": "name", "type": "string"},
    {"name": "version", "type": "string"},
    {"name": "chainId", "type": "uint256"},
    {"name": "verifyingContract", "type": "address"},
]


class BuyerError(Exception):
    """A refusal or failure the operator should read. Never contains the private key."""


# ------------------------------------------------------------------ encoding helpers


def selector(signature: str) -> bytes:
    return keccak(text=signature)[:4]


def encode_call(signature: str, arg_types: list[str], args: list[Any]) -> bytes:
    return selector(signature) + abi_encode(arg_types, args)


def b32(value: Any) -> bytes:
    raw = str(value or "")
    raw = raw[2:] if raw.startswith("0x") else raw
    out = bytes.fromhex(raw)
    if len(out) != 32:
        raise BuyerError("expected a 32-byte hex value")
    return out


def hex0x(value: bytes) -> str:
    return "0x" + bytes(value).hex()


def address(value: Any) -> str:
    raw = str(value or "").strip()
    if len(raw) != 42 or not raw.startswith("0x"):
        raise BuyerError(f"invalid address: {raw[:50]!r}")
    return to_checksum_address(raw)


def quote_tuple(quote: dict[str, Any]) -> tuple:
    try:
        return (
            b32(quote["quoteId"]),
            address(quote["buyer"]),
            int(quote["amount"]),
            int(quote["researchAmount"]),
            int(quote["minCoverageBps"]),
            int(quote["validUntil"]),
            int(quote["acceptDeadline"]),
            int(quote["deliveryDeadline"]),
            int(quote["disputeWindow"]),
            b32(quote["termsHash"]),
        )
    except KeyError as exc:
        raise BuyerError(f"offer quote is missing {exc.args[0]}") from None


def order_id_for(chain_id: int, escrow: str, quote_id: bytes) -> bytes:
    return keccak(abi_encode(["uint256", "address", "bytes32"], [chain_id, address(escrow), quote_id]))


def domain_separator(domain: dict[str, Any]) -> bytes:
    typehash = keccak(text="EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
    return keccak(abi_encode(
        ["bytes32", "bytes32", "bytes32", "uint256", "address"],
        [typehash, keccak(text=str(domain["name"])), keccak(text=str(domain["version"])),
         int(domain["chainId"]), address(domain["verifyingContract"])],
    ))


def split_signature(signature: str) -> tuple[bytes, bytes, int]:
    raw = b32_free(signature)
    if len(raw) != 65:
        raise BuyerError("quote signature must be 65 bytes")
    v = raw[64]
    return raw[:32], raw[32:64], v + 27 if v < 27 else v


def b32_free(value: str) -> bytes:
    raw = str(value or "")
    return bytes.fromhex(raw[2:] if raw.startswith("0x") else raw)


def units(amount: Any, decimals: int) -> int:
    value = Decimal(str(amount)) * (Decimal(10) ** decimals)
    if value != value.to_integral_value() or value <= 0:
        raise BuyerError("amount must be positive and fit the token decimals")
    return int(value)


def fmt(amount_units: int, decimals: int) -> str:
    return f"{Decimal(int(amount_units)) / (Decimal(10) ** decimals):f}"


# ------------------------------------------------------------------ key file


def default_key_file() -> str:
    """buyer.env, unless only the key file of the first Hermes demo exists."""
    if not Path(DEFAULT_KEY_FILE).expanduser().exists() and Path(LEGACY_KEY_FILE).expanduser().exists():
        return LEGACY_KEY_FILE
    return DEFAULT_KEY_FILE


def write_wallet(path: Path, key: str) -> str:
    """Write ``key`` to ``path`` (0600, refuses to overwrite) and return only the address."""
    if path.exists():
        raise BuyerError(f"{path} already exists; refusing to overwrite a wallet")
    key = key.strip()
    if key and not key.startswith("0x"):
        key = "0x" + key
    try:
        acct = Account.from_key(key)
    except Exception:  # noqa: BLE001 - never echo the key back
        raise BuyerError("not a valid private key (expected 64 hex characters)") from None
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write(f"# Buyer agent wallet for the Wayan escrow (testnet only).\n"
                 f"WAYAN_BUYER_ADDRESS={acct.address}\n{KEY_ENV}={key}\n")
    return acct.address


def create_wallet(path: Path) -> str:
    """Write a new key to ``path`` (0600, refuses to overwrite) and return only the address."""
    return write_wallet(path, "0x" + secrets.token_hex(32))


def read_secret(prompt: str) -> str:
    """The key comes from a hidden prompt, or from stdin when piped; never from argv (shell history, ps)."""
    if sys.stdin.isatty():
        import getpass

        return getpass.getpass(prompt)
    return sys.stdin.readline()


def load_key(path: Path | None) -> str:
    key = next((os.environ.get(name, "").strip() for name in (KEY_ENV, *LEGACY_KEY_ENVS)
                if os.environ.get(name, "").strip()), "")
    if not key and path is not None and path.exists():
        mode = stat.S_IMODE(path.stat().st_mode)
        if mode & 0o077:
            raise BuyerError(f"{path} is readable by others (mode {oct(mode)}); run: chmod 600 {path}")
        for line in path.read_text().splitlines():
            if line.split("=", 1)[0] in (KEY_ENV, *LEGACY_KEY_ENVS):
                key = line.split("=", 1)[1].strip()
    if not key:
        raise BuyerError(f"no buyer key: set {KEY_ENV} or create one with `new-wallet`")
    try:
        Account.from_key(key)
    except Exception:  # noqa: BLE001 - never echo the key back
        raise BuyerError("buyer key is not a valid private key") from None
    return key


# ------------------------------------------------------------------ JSON-RPC


def make_rpc(url: str, proxy: str | None = None, timeout: float = 20) -> Callable[[str, list], Any]:
    handlers = []
    if proxy:
        if not proxy.startswith(("socks5://", "socks5h://")):
            raise BuyerError("only socks5:// or socks5h:// proxies are supported")
        try:
            import socks  # type: ignore
            from sockshandler import SocksiPyHandler  # type: ignore
        except ImportError:
            raise BuyerError("SOCKS proxy needs `pip install pysocks`") from None
        host_port = proxy.split("://", 1)[1]
        host, _, port = host_port.partition(":")
        handlers.append(SocksiPyHandler(socks.SOCKS5, host, int(port or 1080), rdns=proxy.startswith("socks5h")))
    opener = urlrequest.build_opener(*handlers)
    counter = {"id": 0}

    def rpc(method: str, params: list) -> Any:
        counter["id"] += 1
        body = json.dumps({"jsonrpc": "2.0", "id": counter["id"], "method": method, "params": params}).encode()
        # Public RPCs behind Cloudflare answer 403 to urllib's default User-Agent.
        headers = {"Content-Type": "application/json", "User-Agent": "wayan-warrior-buyer/1"}
        req = urlrequest.Request(url, data=body, headers=headers, method="POST")
        try:
            with opener.open(req, timeout=timeout) as resp:
                data = json.loads(resp.read().decode())
        except (urlerror.URLError, TimeoutError, OSError, ValueError) as exc:
            raise BuyerError(f"RPC {method} failed: {type(exc).__name__}: {exc}") from None
        if data.get("error"):
            err = data["error"]
            raise BuyerError(f"RPC {method}: {err.get('message') if isinstance(err, dict) else err}")
        return data.get("result")

    return rpc


def to_int(value: Any) -> int:
    return int(value, 16) if isinstance(value, str) else int(value)


class Chain:
    def __init__(self, rpc: Callable[[str, list], Any], escrow: str, explorer: str = DEFAULT_EXPLORER):
        self.rpc = rpc
        self.escrow = address(escrow)
        self.explorer = explorer.rstrip("/")

    def call(self, to: str, data: bytes) -> bytes:
        return b32_free(self.rpc("eth_call", [{"to": to, "data": hex0x(data)}, "latest"]) or "0x")

    def chain_id(self) -> int:
        return to_int(self.rpc("eth_chainId", []))

    def token(self) -> str:
        (tok,) = abi_decode(["address"], self.call(self.escrow, selector("token()")))
        return to_checksum_address(tok)

    def erc20_balance(self, token: str, who: str) -> int:
        return abi_decode(["uint256"], self.call(token, encode_call("balanceOf(address)", ["address"], [who])))[0]

    def decimals(self, token: str) -> int:
        return abi_decode(["uint8"], self.call(token, selector("decimals()")))[0]

    def eth_balance(self, who: str) -> int:
        return to_int(self.rpc("eth_getBalance", [who, "latest"]))

    def claimable(self, who: str) -> int:
        return abi_decode(["uint256"], self.call(self.escrow, encode_call("claimable(address)", ["address"], [who])))[0]

    def quote_digest(self, quote: tuple) -> bytes:
        data = encode_call(f"quoteDigest({QUOTE_TUPLE})", [QUOTE_TUPLE], [quote])
        return abi_decode(["bytes32"], self.call(self.escrow, data))[0]

    def has_attester_role(self, who: str) -> bool:
        data = encode_call("hasRole(bytes32,address)", ["bytes32", "address"], [ATTESTER_ROLE, who])
        return abi_decode(["bool"], self.call(self.escrow, data))[0]

    def token_domain_separator(self, token: str) -> bytes:
        return abi_decode(["bytes32"], self.call(token, selector("DOMAIN_SEPARATOR()")))[0]

    def order(self, order_id: bytes) -> dict[str, Any]:
        raw = self.call(self.escrow, encode_call("getOrder(bytes32)", ["bytes32"], [order_id]))
        (values,) = abi_decode([ORDER_TUPLE], raw)
        order = dict(zip(ORDER_KEYS, values))
        order["state_name"] = STATES[order["state"]] if order["state"] < len(STATES) else "Unknown"
        for key in ("quote_digest", "evidence_root", "deliverable_hash", "provenance_hash"):
            order[key] = hex0x(order[key])
        return order

    def tx_link(self, tx_hash: str) -> str:
        return f"{self.explorer}/tx/{tx_hash}"


# ------------------------------------------------------------------ offer checks + signing


def unwrap_offer(doc: dict[str, Any]) -> dict[str, Any]:
    """Accept the raw endpoint response or just its ``escrow`` object."""
    offer = doc.get("escrow", doc) if isinstance(doc, dict) else None
    if not isinstance(offer, dict) or "quote" not in offer:
        raise BuyerError("offer JSON has no escrow quote (expected the /escrow/offer response)")
    return offer


def verify_offer(chain: Chain, offer: dict[str, Any], buyer: str, now: int | None = None) -> dict[str, Any]:
    """Check the offer against the chain and return what `pay` needs. Raises BuyerError on any mismatch."""
    now = int(time.time()) if now is None else now
    chain_id = chain.chain_id()
    if int(offer.get("chain_id") or chain_id) != chain_id:
        raise BuyerError(f"offer is for chain {offer.get('chain_id')}, RPC is chain {chain_id}")
    if address(offer.get("escrow_contract") or chain.escrow) != chain.escrow:
        raise BuyerError("offer names a different escrow contract than the one configured")
    quote = quote_tuple(offer["quote"])
    q = dict(zip(QUOTE_KEYS, quote))
    if q["buyer"] != address(buyer):
        raise BuyerError(f"quote is for buyer {q['buyer']}, this wallet is {address(buyer)}")
    if q["validUntil"] <= now:
        raise BuyerError("quote has expired; ask Wayan for a new offer")
    # Same bounds as the contract's _open: a zero research fee is allowed.
    if q["amount"] <= 0 or q["researchAmount"] > q["amount"]:
        raise BuyerError("quote research amount is not within the order amount")

    digest = chain.quote_digest(quote)
    r, s, v = split_signature(offer.get("quote_signature", ""))
    signer = Account._recover_hash(digest, vrs=(v, int.from_bytes(r, "big"), int.from_bytes(s, "big")))
    if not chain.has_attester_role(signer):
        raise BuyerError(f"quote is signed by {signer}, which is not an attester of this escrow")

    token = chain.token()
    if offer.get("token") and address(offer["token"] if isinstance(offer["token"], str)
                                      else offer["token"].get("address")) != token:
        raise BuyerError("offer names a different token than the escrow holds")
    order_id = order_id_for(chain_id, chain.escrow, q["quoteId"])
    if offer.get("order_id") and b32(offer["order_id"]) != order_id:
        raise BuyerError("offer order_id does not match the quote")

    typed = (((offer.get("pay") or {}).get("one_signature") or {}).get("receive_with_authorization"))
    if not isinstance(typed, dict):
        raise BuyerError("offer has no receive_with_authorization typed data")
    msg = typed.get("message") or {}
    if typed.get("primaryType") != "ReceiveWithAuthorization":
        raise BuyerError("typed data is not a ReceiveWithAuthorization")
    if address(msg.get("from")) != q["buyer"] or address(msg.get("to")) != chain.escrow:
        raise BuyerError("authorization must move funds from this buyer to the escrow")
    if int(msg.get("value", -1)) != q["amount"]:
        raise BuyerError("authorization value differs from the quote amount")
    domain = typed.get("domain") or {}
    if address(domain.get("verifyingContract")) != token or int(domain.get("chainId", 0)) != chain_id:
        raise BuyerError("authorization domain is not this token on this chain")
    if domain_separator(domain) != chain.token_domain_separator(token):
        raise BuyerError("authorization domain does not match the token's DOMAIN_SEPARATOR")
    if int(msg.get("validBefore", 0)) <= now:
        raise BuyerError("authorization window has already closed")

    return {"quote": quote, "q": q, "signature": b32_free(offer["quote_signature"]), "typed": typed,
            "order_id": order_id, "token": token, "chain_id": chain_id, "signer": signer}


def sign_authorization(typed: dict[str, Any], key: str) -> tuple:
    """Sign the EIP-3009 typed data; return the contract's Authorization tuple."""
    msg = typed["message"]
    full = {
        "types": {"EIP712Domain": EIP712_DOMAIN_FIELDS,
                  "ReceiveWithAuthorization": typed["types"]["ReceiveWithAuthorization"]},
        "primaryType": "ReceiveWithAuthorization",
        "domain": typed["domain"],
        "message": {**msg, "value": int(msg["value"]), "validAfter": int(msg["validAfter"]),
                    "validBefore": int(msg["validBefore"]), "nonce": b32(msg["nonce"])},
    }
    signed = Account.sign_message(encode_typed_data(full_message=full), private_key=key)
    return (int(msg["validAfter"]), int(msg["validBefore"]), b32(msg["nonce"]), signed.v,
            signed.r.to_bytes(32, "big"), signed.s.to_bytes(32, "big"))


def fund_calldata(quote: tuple, quote_signature: bytes, auth: tuple) -> bytes:
    sig = f"fundWithAuthorization({QUOTE_TUPLE},bytes,{AUTH_TUPLE})"
    return encode_call(sig, [QUOTE_TUPLE, "bytes", AUTH_TUPLE], [quote, quote_signature, auth])


# ------------------------------------------------------------------ transactions


def send_tx(chain: Chain, key: str, to: str, data: bytes, send: bool, label: str) -> dict[str, Any]:
    # Testnet only: a buyer key held by an agent must never move real funds.
    check_network(chain.chain_id(), label)
    acct = Account.from_key(key)
    call = {"from": acct.address, "to": to, "data": hex0x(data)}
    try:
        gas = to_int(chain.rpc("eth_estimateGas", [call]))
    except BuyerError as exc:
        raise BuyerError(f"{label} would revert: {exc}") from None
    latest = chain.rpc("eth_getBlockByNumber", ["latest", False]) or {}
    base_fee = to_int(latest.get("baseFeePerGas") or 0)
    try:
        tip = to_int(chain.rpc("eth_maxPriorityFeePerGas", []))
    except BuyerError:
        tip = 0
    max_fee = base_fee * 2 + tip + 1
    gas_limit = gas * 13 // 10 + 10_000
    if chain.eth_balance(acct.address) < gas_limit * max_fee:
        raise BuyerError(f"{acct.address} has too little ETH for gas; bridge test ETH to Robinhood Chain testnet")
    print(f"{label}: gas estimate {gas}")
    if not send:
        print(f"{label}: dry run only; add --yes to send")
        return {"sent": False}
    tx = {"chainId": chain.chain_id(), "nonce": to_int(chain.rpc("eth_getTransactionCount", [acct.address, "pending"])),
          "to": to, "value": 0, "data": data, "gas": gas_limit, "maxFeePerGas": max_fee,
          "maxPriorityFeePerGas": tip, "type": 2}
    signed = Account.sign_transaction(tx, key)
    raw = getattr(signed, "raw_transaction", None) or getattr(signed, "rawTransaction")
    tx_hash = str(chain.rpc("eth_sendRawTransaction", [hex0x(raw)])).lower()
    print(f"{label}: sent {chain.tx_link(tx_hash)}")
    for _ in range(60):
        receipt = chain.rpc("eth_getTransactionReceipt", [tx_hash])
        if receipt:
            if to_int(receipt.get("status", 0)) != 1:
                raise BuyerError(f"{label} reverted: {chain.tx_link(tx_hash)}")
            print(f"{label}: mined in block {to_int(receipt['blockNumber'])}")
            return {"sent": True, "tx_hash": tx_hash}
        time.sleep(2)
    print(f"{label}: no receipt yet; check {chain.tx_link(tx_hash)}")
    return {"sent": True, "tx_hash": tx_hash, "pending": True}


# ------------------------------------------------------------------ commands


def cmd_status(chain: Chain, buyer: str) -> None:
    token = chain.token()
    dec = chain.decimals(token)
    print(json.dumps({
        "buyer": buyer,
        "chain_id": chain.chain_id(),
        "escrow": chain.escrow,
        "token": token,
        "eth_for_gas": f"{Decimal(chain.eth_balance(buyer)) / Decimal(10**18):f}",
        "usdg": fmt(chain.erc20_balance(token, buyer), dec),
        "claimable_in_escrow": fmt(chain.claimable(buyer), dec),
    }, indent=2))


def cmd_pay(chain: Chain, key: str, offer_doc: dict[str, Any], send: bool) -> None:
    buyer = Account.from_key(key).address
    checked = verify_offer(chain, unwrap_offer(offer_doc), buyer)
    q, token = checked["q"], checked["token"]
    dec = chain.decimals(token)
    check_spend_limit(chain.chain_id(), q["amount"], dec)
    balance = chain.erc20_balance(token, buyer)
    print(json.dumps({
        "order_id": hex0x(checked["order_id"]),
        "amount": fmt(q["amount"], dec),
        "research_fee": fmt(q["researchAmount"], dec),
        "min_coverage_bps": q["minCoverageBps"],
        "quote_signed_by": checked["signer"],
        "valid_until": q["validUntil"],
        "delivery_deadline": q["deliveryDeadline"],
        "buyer_usdg": fmt(balance, dec),
    }, indent=2))
    if balance < q["amount"]:
        raise BuyerError(f"buyer holds {fmt(balance, dec)} USDG, quote needs {fmt(q['amount'], dec)}; run `mint`")
    if chain.order(checked["order_id"])["state_name"] != "None":
        raise BuyerError("this order is already funded")
    auth = sign_authorization(checked["typed"], key)
    send_tx(chain, key, chain.escrow, fund_calldata(checked["quote"], checked["signature"], auth), send,
            "fundWithAuthorization")


def cmd_mint(chain: Chain, key: str, amount: str, send: bool) -> None:
    if chain.chain_id() not in TESTNET_CHAIN_IDS:
        raise BuyerError("mint is only for the testnet mock token")
    token = chain.token()
    buyer = Account.from_key(key).address
    data = encode_call("mint(address,uint256)", ["address", "uint256"], [buyer, units(amount, chain.decimals(token))])
    send_tx(chain, key, token, data, send, f"mint {amount} USDG")


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                epilog="RPC blocked locally? ssh -f -N -D 11080 <host> and pass "
                                       "--proxy socks5h://127.0.0.1:11080 (needs pysocks).")
    p.add_argument("--rpc-url", default=os.environ.get("ESCROW_RPC_URL", DEFAULT_RPC_URL))
    p.add_argument("--proxy", default=os.environ.get("ESCROW_RPC_PROXY"))
    p.add_argument("--escrow", default=os.environ.get("ESCROW_CONTRACT", DEFAULT_ESCROW))
    p.add_argument("--explorer", default=os.environ.get("ESCROW_EXPLORER_URL", DEFAULT_EXPLORER))
    p.add_argument("--key-file", default=os.environ.get("WAYAN_BUYER_KEY_FILE") or os.environ.get("HERMES_BUYER_KEY_FILE")
                   or default_key_file())
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("new-wallet")
    sub.add_parser("import-key", help="store an existing key (MetaMask: Account details > Show private key)")
    sub.add_parser("address")
    sub.add_parser("status")
    m = sub.add_parser("mint")
    m.add_argument("--amount", default="1000")
    pay = sub.add_parser("pay")
    pay.add_argument("--offer", required=True, help="offer JSON file from /api/a2a/payments/escrow/offer, or -")
    for name in ("order", "confirm", "dispute"):
        sp = sub.add_parser(name)
        sp.add_argument("--order-id", required=True)
        if name == "dispute":
            sp.add_argument("--reason", required=True)
    sub.add_parser("withdraw")
    for sp in sub.choices.values():
        if sp.prog.split()[-1] in {"mint", "pay", "confirm", "dispute", "withdraw"}:
            sp.add_argument("--yes", action="store_true", help="send the transaction (default: dry run)")
    args = p.parse_args(argv)
    key_file = Path(args.key_file).expanduser()

    try:
        if args.cmd == "new-wallet":
            print(f"buyer address: {create_wallet(key_file)}\nkey stored in {key_file} (mode 600)")
            return 0
        if args.cmd == "import-key":
            address_ = write_wallet(key_file, read_secret("private key (hidden): "))
            print(f"buyer address: {address_}\nkey stored in {key_file} (mode 600)")
            return 0
        key = load_key(key_file)
        buyer = Account.from_key(key).address
        if args.cmd == "address":
            print(buyer)
            return 0
        chain = Chain(make_rpc(args.rpc_url, args.proxy), args.escrow, args.explorer)
        if args.cmd == "status":
            cmd_status(chain, buyer)
        elif args.cmd == "mint":
            cmd_mint(chain, key, args.amount, args.yes)
        elif args.cmd == "pay":
            text = sys.stdin.read() if args.offer == "-" else Path(args.offer).read_text()
            cmd_pay(chain, key, json.loads(text), args.yes)
        elif args.cmd == "order":
            print(json.dumps(chain.order(b32(args.order_id)), indent=2, default=str))
        elif args.cmd == "confirm":
            send_tx(chain, key, chain.escrow, encode_call("confirmRelease(bytes32)", ["bytes32"], [b32(args.order_id)]),
                    args.yes, "confirmRelease")
        elif args.cmd == "dispute":
            data = encode_call("openDispute(bytes32,bytes32)", ["bytes32", "bytes32"],
                               [b32(args.order_id), keccak(text=args.reason)])
            send_tx(chain, key, chain.escrow, data, args.yes, "openDispute")
        elif args.cmd == "withdraw":
            send_tx(chain, key, chain.escrow, selector("withdraw()"), args.yes, "withdraw")
    except BuyerError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
