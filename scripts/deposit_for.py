#!/usr/bin/env python3
"""Bridge USDC with CoreDepositWallet.depositFor and watch whether HyperCore credits the recipient.

Approves and calls depositFor(recipient, amount, SPOT) from the KEY_FILE account's HyperEVM USDC, then watches
the recipient's spot balance through the precompile. Prints CREDITED or NOT CREDITED.

  KEY_FILE=./key python deposit_for.py --to 0xRECIPIENT --amount 1                     # testnet
  KEY_FILE=./key CONFIRM_MAINNET=yes python deposit_for.py --network mainnet \\
      --to 0xRECIPIENT --amount 5 --execute                                             # mainnet, real USDC
"""

import argparse
import os
import time

from common import calldata, call_decode, load_account, precompile_spot_usdc, send_tx, user_role

# Circle native USDC on HyperEVM (6 decimals) and Circle's CoreDepositWallet, per network.
# Both are listed as USDC's evmContract / linked contracts in each network's spotMeta.
USDC = {"testnet": "0x2B3370eE501B4a559b57D449569354196457D8Ab", "mainnet": "0xb88339CB7199b77E23DB6E890353E22632Ba630f"}
CORE_DEPOSIT_WALLET = {
    "testnet": "0x0B80659a4076E9E93C7DbE0f10675A16a3e5C206",
    "mainnet": "0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24",
}
SPOT_DEX = 2**32 - 1  # destinationDex: 0 = perps, uint32 max = spot

p = argparse.ArgumentParser()
p.add_argument("--network", choices=["testnet", "mainnet"], default="testnet")
p.add_argument("--to", required=True)
p.add_argument("--amount", type=float, required=True, help="USDC")
p.add_argument("--wait", type=int, default=300, help="seconds to watch for the credit")
p.add_argument("--execute", action="store_true", help="required on mainnet, together with CONFIRM_MAINNET=yes")
a = p.parse_args()
net = a.network

print(f"recipient {a.to}: mainnet userRole={user_role('mainnet', a.to)} testnet userRole={user_role('testnet', a.to)}")
if net == "mainnet" and (not a.execute or os.environ.get("CONFIRM_MAINNET") != "yes"):
    raise SystemExit(f"DRY RUN: would bridge {a.amount} mainnet USDC to {a.to}. Pass --execute and CONFIRM_MAINNET=yes.")

acct = load_account()
amount = int(a.amount * 1e6)
have = call_decode(net, USDC[net], "balanceOf(address)", ["address"], [acct.address], ["uint256"])[0]
print(f"sender {net} EVM USDC {have / 1e6}")
if have < amount:
    raise SystemExit(f"not enough {net} EVM USDC")

before = precompile_spot_usdc(net, a.to)[0]
send_tx(net, acct, USDC[net], calldata("approve(address,uint256)", ["address", "uint256"], [CORE_DEPOSIT_WALLET[net], amount]))
send_tx(net, acct, CORE_DEPOSIT_WALLET[net],
        calldata("depositFor(address,uint256,uint32)", ["address", "uint256", "uint32"], [a.to, amount, SPOT_DEX]))

deadline = time.time() + a.wait
while time.time() < deadline:
    now = precompile_spot_usdc(net, a.to)[0]
    if now > before:
        print(f"CREDITED: {net} spot USDC {before / 1e8} -> {now / 1e8}")
        break
    time.sleep(10)
else:
    print(f"NOT CREDITED after {a.wait}s: {net} spot USDC still {before / 1e8}")
