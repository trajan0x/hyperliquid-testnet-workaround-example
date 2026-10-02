#!/usr/bin/env python3
"""MAINNET: give a testnet deposit address mainnet state, using a replica deployed at the same address.

Uses real funds. Every write is a dry run unless --execute is passed AND CONFIRM_MAINNET=yes is set.

  python mainnet_replica_worker.py --factory 0xF --user 0xU check
  KEY_FILE=./key python mainnet_replica_worker.py --factory 0xF --user 0xU seed --amount 2 --execute
  (deploy the factory on mainnet: deploy_factory.py --network mainnet ... --replica-api-wallet 0xAPI)
  KEY_FILE=./key python mainnet_replica_worker.py --factory 0xF --user 0xU deploy --execute
  python mainnet_replica_worker.py --factory 0xF --user 0xU verify --api-wallet 0xAPI
  API_KEY_FILE=./api.key python mainnet_replica_worker.py --factory 0xF --user 0xU api-wallet-noop --execute
  KEY_FILE=./key python mainnet_replica_worker.py --factory 0xF --user 0xU return-seed --execute

seed        : spotSend USDC to the deposit address on mainnet Core (exchange API, no EVM gas). This creates
              its mainnet Core account. The address needs no code on mainnet for this. The sender also pays
              HyperCore's 1 USDC fee for sending to a new account.
deploy      : factory.deploy(user) on mainnet. On chain 999 the factory calls initializeReplica(), which adds
              the configured API wallet through CoreWriter. Trading and sweeps are disabled on the replica.
verify      : check the API wallet shows up in extraAgents for the deposit address.
api-wallet-noop : the API wallet signs a gasless L1 "noop" for the deposit address. It moves no funds; it shows
              the API wallet can act for the address without EVM gas.
return-seed : returnSeed(owner) sends the seed back out through CoreWriter (costs a little HYPE gas). An API
              wallet cannot do this: spotSend/usdSend/withdraw3 are user-signed and move the SIGNER's funds.
"""

import argparse
import os
import sys
import time

from common import (
    artifact_bytecode,
    calldata,
    check_ok,
    code_at,
    exchange,
    info,
    load_account,
    precompile_spot_usdc,
    send_spot_usdc,
    send_tx,
    spot_balance,
    usdc_token_id,
    user_role,
    wait_for,
)
from eth_abi import encode
from eth_utils import keccak, to_checksum_address

NET = "mainnet"
p = argparse.ArgumentParser()
p.add_argument("--factory", required=True, help="factory address (same on both chains)")
p.add_argument("--user", required=True)
p.add_argument("--execute", action="store_true")
sub = p.add_subparsers(dest="cmd", required=True)
sub.add_parser("check")
s = sub.add_parser("seed")
s.add_argument("--amount", type=float, default=2.0)
sub.add_parser("deploy")
v = sub.add_parser("verify")
v.add_argument("--api-wallet", required=True)
sub.add_parser("return-seed")
sub.add_parser("api-wallet-noop")
a = p.parse_args()


def deposit_address() -> str:
    # Same as factory.predict(user); computed locally because the factory may not exist on mainnet yet.
    init = artifact_bytecode("TestnetContract", "TestnetContract.sol") + encode(["address"], [a.user])
    salt = int(a.user, 16).to_bytes(32, "big")
    return to_checksum_address(keccak(b"\xff" + bytes.fromhex(a.factory[2:]) + salt + keccak(init))[12:])


dep = deposit_address()
print(f"deposit address {dep}")
print(f"mainnet userRole={user_role(NET, dep)} spot USDC={spot_balance(NET, dep)} code={'yes' if code_at(NET, dep) != '0x' else 'no'}")
print(f"testnet userRole={user_role('testnet', dep)}")

if a.cmd in ("check", "verify"):
    if a.cmd == "verify":
        agents = info(NET).extra_agents(dep)
        ok = any(x["address"].lower() == a.api_wallet.lower() for x in agents)
        print(f"extraAgents {agents}\nAPI wallet registered: {ok}")
        sys.exit(0 if ok else 1)
    sys.exit(0)

if not a.execute or os.environ.get("CONFIRM_MAINNET") != "yes":
    sys.exit(f"DRY RUN: would run '{a.cmd}' on MAINNET. Pass --execute and set CONFIRM_MAINNET=yes.")

if a.cmd == "api-wallet-noop":
    api = load_account("API_KEY_FILE", "api.key")
    before = info(NET).post("/info", {"type": "userRateLimit", "user": dep})
    check_ok(exchange(NET, api).noop(int(time.time() * 1000)), f"noop signed by API wallet {api.address} for {dep}")
    print(f"userRateLimit before {before}\nuserRateLimit after  {info(NET).post('/info', {'type': 'userRateLimit', 'user': dep})}")
    sys.exit(0)

acct = load_account()
if a.cmd == "seed":
    send_spot_usdc(NET, acct, dep, a.amount)
    wait_for(lambda: user_role(NET, dep) != "missing", "deposit address has mainnet state")
elif a.cmd == "deploy":
    if code_at(NET, a.factory) == "0x":
        sys.exit("factory not deployed on mainnet yet (deploy_factory.py --network mainnet)")
    send_tx(NET, acct, a.factory, calldata("deploy(address)", ["address"], [a.user]))
elif a.cmd == "return-seed":
    free = precompile_spot_usdc(NET, dep)[0]
    send_tx(NET, acct, dep, calldata("returnSeed(address)", ["address"], [acct.address]))
    wait_for(lambda: precompile_spot_usdc(NET, dep)[0] < free, "seed left the deposit address")
