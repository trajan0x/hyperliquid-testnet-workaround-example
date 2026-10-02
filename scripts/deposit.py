#!/usr/bin/env python3
"""TESTNET: drive one user's deposit address through the whole flow.

  KEY_FILE=./key python deposit.py --factory 0xF status
  KEY_FILE=./key python deposit.py --factory 0xF fund --amount 15        # Core-side spotSend, no bridge
  KEY_FILE=./key python deposit.py --factory 0xF deploy                  # lazy CREATE2 deploy
  KEY_FILE=./key python deposit.py --factory 0xF activate                # 1 USDC in, bounce out, confirm
  KEY_FILE=./key python deposit.py --factory 0xF buy --px 32 --sz 0.5    # example only: HYPE limit buy
  KEY_FILE=./key python deposit.py --factory 0xF sweep                   # sweep + confirmSweep (credit)

The key in KEY_FILE funds the deposit address on Core, pays EVM gas, and is used as the deposit address's
`user` unless --user is given (buy must be sent by the user).
"""

import argparse
import sys
from decimal import Decimal

from common import (
    calldata,
    call_decode,
    check_ok,
    code_at,
    exchange,
    load_account,
    precompile_spot_usdc,
    predict_deposit,
    send_spot_usdc,
    send_tx,
    spot_balance,
    try_call,
    usdc_token_id,
    wait_for,
)

NET = "testnet"
p = argparse.ArgumentParser()
p.add_argument("--factory", required=True)
p.add_argument("--user")
sub = p.add_subparsers(dest="cmd", required=True)
sub.add_parser("status")
f = sub.add_parser("fund")
f.add_argument("--amount", type=float, required=True)
sub.add_parser("deploy")
sub.add_parser("activate")
b = sub.add_parser("buy")
b.add_argument("--px", type=Decimal, required=True, help="USDC per HYPE, <= 5 significant figures")
b.add_argument("--sz", type=Decimal, required=True, help="HYPE, 2 decimals")
sub.add_parser("sweep")
a = p.parse_args()

acct = None if (a.cmd == "status" and a.user) else load_account()
user = a.user or acct.address
dep = predict_deposit(NET, a.factory, user)
STATUS = ["Inactive", "Activating", "Active"]


def status() -> int:
    if code_at(NET, dep) == "0x":
        return -1
    return call_decode(NET, dep, "status()", [], [], ["uint8"])[0]


def show():
    total, hold = precompile_spot_usdc(NET, dep)
    st = status()
    print(f"user {user}\ndeposit {dep}\ncode {'yes' if st >= 0 else 'no'}  status {STATUS[st] if st >= 0 else '-'}")
    print(f"precompile spot USDC total={total / 1e8} hold={hold / 1e8}  api HYPE={spot_balance(NET, dep, 'HYPE')}")
    print(f"credited in factory: {call_decode(NET, a.factory, 'credited(address)', ['address'], [user], ['uint64'])[0] / 1e8}")


def fund(amount: float):
    before = precompile_spot_usdc(NET, dep)[0]
    send_spot_usdc(NET, acct, dep, amount)
    wait_for(lambda: precompile_spot_usdc(NET, dep)[0] >= before + int(amount * 1e8), "precompile sees the funds")


def send(sig: str, types=None, args=None):
    return send_tx(NET, acct, dep, calldata(sig, types, args))


def wait_and_send(sig: str):
    data = calldata(sig)
    wait_for(lambda: try_call(NET, dep, data, acct.address), f"{sig} would succeed")
    send(sig)


if a.cmd == "status":
    show()
elif a.cmd == "fund":
    fund(a.amount)
elif a.cmd == "deploy":
    if code_at(NET, dep) != "0x":
        sys.exit("already deployed")
    send_tx(NET, acct, a.factory, calldata("deploy(address)", ["address"], [user]))
    show()
elif a.cmd == "activate":
    if status() != 0:
        sys.exit("deploy first; activation runs once, from Inactive")
    amount = call_decode(NET, a.factory, "config()", [], [], ["(uint64,address,address,uint32,address)"])[0][0]
    fund(amount / 1e8)  # small amount IN, via the exchange API
    wait_and_send("beginActivation()")  # contract sends it back OUT via CoreWriter
    wait_and_send("confirmActivation()")  # later block: precompile shows it left
    show()
elif a.cmd == "buy":
    px, sz = int(a.px * 10**8), int(a.sz * 10**8)
    send("buyHype(uint64,uint64)", ["uint64", "uint64"], [px, sz])
    wait_for(lambda: spot_balance(NET, dep, "HYPE") > 0 or precompile_spot_usdc(NET, dep)[1] > 0,
             "order filled or resting on Core", timeout=60)
    show()
elif a.cmd == "sweep":
    send("sweep()")
    wait_and_send("confirmSweep()")
    show()
