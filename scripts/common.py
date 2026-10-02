"""Shared helpers. Exchange-API signing uses the official Hyperliquid Python SDK (pinned in requirements.txt).
EVM transactions are signed locally with eth_account and sent over plain JSON-RPC.

Keys are read from a file (KEY_FILE, default ./key, one hex private key, chmod 600). They are never taken from
argv or printed.
"""

from __future__ import annotations

import json
import os
import stat
import sys
import time
from pathlib import Path

import eth_account
import requests
from eth_account.signers.local import LocalAccount
from hyperliquid.exchange import Exchange
from hyperliquid.info import Info
from hyperliquid.utils import constants

ROOT = Path(__file__).resolve().parent.parent
API_URLS = {"testnet": constants.TESTNET_API_URL, "mainnet": constants.MAINNET_API_URL}
RPC_URLS = {"testnet": "https://rpc.hyperliquid-testnet.xyz/evm", "mainnet": "https://rpc.hyperliquid.xyz/evm"}
CHAIN_IDS = {"testnet": 998, "mainnet": 999}
EXPLORER = {"testnet": "https://testnet.purrsec.com", "mainnet": "https://hyperevmscan.io"}
CREATE2_DEPLOYER = "0x4e59b44847b379578588920cA78FbF26c0B4956C"
SPOT_BALANCE_PRECOMPILE = "0x0000000000000000000000000000000000000801"


# ---------------------------------------------------------------- keys


def load_account(env: str = "KEY_FILE", default: str = "key") -> LocalAccount:
    path = Path(os.environ.get(env, default)).expanduser()
    if not path.exists():
        sys.exit(f"{env}: no key file at {path}")
    if path.stat().st_mode & (stat.S_IRWXG | stat.S_IRWXO):
        sys.exit(f"{path} must not be readable by group/others (chmod 600)")
    return eth_account.Account.from_key(path.read_text().strip())


# ---------------------------------------------------------------- exchange / info API


def info(network: str) -> Info:
    return Info(API_URLS[network], skip_ws=True)


def exchange(network: str, account: LocalAccount) -> Exchange:
    return Exchange(account, API_URLS[network])


def usdc_token_id(network: str) -> str:
    """spotSend token string, e.g. 'USDC:0xeb62eee3685fc4c43992febcd9e75443' on testnet."""
    for t in info(network).spot_meta()["tokens"]:
        if t["index"] == 0:
            return f"{t['name']}:{t['tokenId']}"
    raise RuntimeError("USDC (token index 0) not found in spotMeta")


def send_spot_usdc(network: str, account: LocalAccount, destination: str, amount: float):
    """Core-side USDC transfer to `destination`'s spot balance. Uses spotSend; accounts in unified-account mode
    reject spotSend ("Action disabled when unified account is active"), so those fall back to sendAsset."""
    ex = exchange(network, account)
    token = usdc_token_id(network)
    resp = ex.spot_transfer(amount, destination, token)
    if isinstance(resp, dict) and "unified account" in str(resp.get("response", "")):
        print(f"spotSend refused ({resp['response']}); using sendAsset spot -> spot")
        resp = ex.send_asset(destination, "spot", "spot", token, amount)
    return check_ok(resp, f"{network} send {amount} USDC -> {destination}")


def spot_balance(network: str, address: str, coin: str = "USDC") -> float:
    for b in info(network).spot_user_state(address)["balances"]:
        if b["coin"] == coin:
            return float(b["total"])
    return 0.0


def user_role(network: str, address: str) -> str:
    return info(network).user_role(address)["role"]


def check_ok(resp, what: str):
    print(f"{what}: {json.dumps(resp)}")
    if not isinstance(resp, dict) or resp.get("status") != "ok":
        sys.exit(f"{what} failed")
    statuses = resp.get("response", {}).get("data", {}).get("statuses", [])
    if any("error" in s for s in statuses if isinstance(s, dict)):
        sys.exit(f"{what} rejected")
    return resp


def wait_for(pred, what: str, timeout: float = 180, every: float = 3):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if pred():
            print(f"observed: {what}")
            return
        time.sleep(every)
    sys.exit(f"timed out waiting for: {what}")


# ---------------------------------------------------------------- EVM JSON-RPC


def rpc(network: str, method: str, params: list, retries: int = 8):
    """JSON-RPC call. Retries on rate limits and network errors; reverts are raised as RuntimeError."""
    for attempt in range(retries):
        try:
            r = requests.post(RPC_URLS[network], json={"jsonrpc": "2.0", "id": 1, "method": method, "params": params}, timeout=30)
            r.raise_for_status()
            body = r.json()
        except (requests.RequestException, ValueError):
            time.sleep(2 * (attempt + 1))
            continue
        if "error" in body:
            if "rate limit" in str(body["error"]).lower():
                time.sleep(2 * (attempt + 1))
                continue
            raise RuntimeError(f"{method}: {body['error']}")
        return body["result"]
    raise RuntimeError(f"{method}: gave up after {retries} attempts")


def eth_call(network: str, to: str, data: str, sender: str | None = None) -> str:
    tx = {"to": to, "data": data}
    if sender:
        tx["from"] = sender
    return rpc(network, "eth_call", [tx, "latest"])


def try_call(network: str, to: str, data: str, sender: str) -> bool:
    try:
        eth_call(network, to, data, sender)
        return True
    except RuntimeError:
        return False


def send_tx(network: str, account: LocalAccount, to: str, data: str = "0x", value: int = 0, gas: int | None = None) -> dict:
    """Sign and send a legacy tx, wait for the receipt, exit on revert. Prints an explorer link."""
    tx = {"from": account.address, "to": to, "data": data, "value": hex(value)}
    if gas is None:
        gas = int(int(rpc(network, "eth_estimateGas", [tx]), 16) * 1.3)
    signed = account.sign_transaction(
        {
            "to": to,
            "data": data,
            "value": value,
            "gas": gas,
            "gasPrice": int(rpc(network, "eth_gasPrice", []), 16),
            "nonce": int(rpc(network, "eth_getTransactionCount", [account.address, "pending"]), 16),
            "chainId": CHAIN_IDS[network],
        }
    )
    raw = signed.raw_transaction if hasattr(signed, "raw_transaction") else signed.rawTransaction
    h = rpc(network, "eth_sendRawTransaction", ["0x" + raw.hex().removeprefix("0x")])
    print(f"tx {EXPLORER[network]}/tx/{h}")
    for _ in range(120):
        rcpt = rpc(network, "eth_getTransactionReceipt", [h])
        if rcpt:
            if int(rcpt["status"], 16) != 1:
                sys.exit(f"tx reverted: {h}")
            return rcpt
        time.sleep(2)
    sys.exit(f"no receipt for {h}")


def code_at(network: str, address: str) -> str:
    return rpc(network, "eth_getCode", [address, "latest"])


# ---------------------------------------------------------------- ABI (tiny, only what the scripts use)

from eth_abi import decode, encode  # noqa: E402  (installed with eth_account)
from eth_utils import keccak, to_checksum_address  # noqa: E402


def selector(sig: str) -> bytes:
    return keccak(text=sig)[:4]


def calldata(sig: str, types: list[str] | None = None, args: list | None = None) -> str:
    return "0x" + (selector(sig) + encode(types or [], args or [])).hex()


def call_decode(network: str, to: str, sig: str, types: list, args: list, out: list):
    return decode(out, bytes.fromhex(eth_call(network, to, calldata(sig, types, args))[2:]))


def precompile_spot_usdc(network: str, address: str) -> tuple[int, int]:
    """(total, hold) in Core wei (1e8 = 1 USDC), read from the spotBalance precompile, like the contract does."""
    out = eth_call(network, SPOT_BALANCE_PRECOMPILE, "0x" + encode(["address", "uint64"], [address, 0]).hex())
    total, hold, _ = decode(["uint64", "uint64", "uint64"], bytes.fromhex(out[2:]))
    return total, hold


def artifact_bytecode(name: str, sol: str) -> bytes:
    path = ROOT / "out" / sol / f"{name}.json"
    if not path.exists():
        sys.exit(f"missing {path}; run `forge build` first")
    return bytes.fromhex(json.loads(path.read_text())["bytecode"]["object"].removeprefix("0x"))


def factory_initcode(owner: str) -> bytes:
    return artifact_bytecode("TestnetDepositFactory", "TestnetDepositFactory.sol") + encode(["address"], [owner])


def create2_address(deployer: str, salt: bytes, initcode: bytes) -> str:
    return to_checksum_address(keccak(b"\xff" + bytes.fromhex(deployer[2:]) + salt + keccak(initcode))[12:])


def predict_deposit(network: str, factory: str, user: str) -> str:
    return to_checksum_address(call_decode(network, factory, "predict(address)", ["address"], [user], ["address"])[0])
