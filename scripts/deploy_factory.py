#!/usr/bin/env python3
"""Deploy TestnetDepositFactory through the deterministic CREATE2 deployer, then set its per-chain config.

Same owner + salt + compiler settings gives the same factory address on testnet and mainnet. The factory deploy
is about 2.4M gas, above HyperEVM's 2M small-block limit, so the deployer is switched to big blocks first.

  KEY_FILE=./key python deploy_factory.py --network testnet --salt 0x01 --hype-asset 11035
  KEY_FILE=./key python deploy_factory.py --network mainnet --salt 0x01 --hype-asset 10107 \
      --replica-api-wallet 0xAPI --execute-mainnet
"""

import argparse
import sys

from common import (
    CREATE2_DEPLOYER,
    calldata,
    check_ok,
    code_at,
    create2_address,
    exchange,
    factory_initcode,
    load_account,
    rpc,
    send_tx,
    wait_for,
)

p = argparse.ArgumentParser()
p.add_argument("--network", choices=["testnet", "mainnet"], required=True)
p.add_argument("--salt", default="0x00")
p.add_argument("--hype-asset", type=int, required=True, help="10000 + HYPE/USDC spot index (lookup_spot_asset.py)")
p.add_argument("--activation-wei", type=int, default=100_000_000, help="Core USDC wei bounced on activation")
p.add_argument("--replica-api-wallet", default="0x" + "00" * 20)
p.add_argument("--execute-mainnet", action="store_true")
a = p.parse_args()

acct = load_account()
salt = int(a.salt, 16).to_bytes(32, "big")
initcode = factory_initcode(acct.address)
factory = create2_address(CREATE2_DEPLOYER, salt, initcode)
print(f"owner {acct.address}\nfactory {factory} (chain-independent)")

if a.network == "mainnet" and not a.execute_mainnet:
    sys.exit("mainnet: dry run only. Pass --execute-mainnet to deploy.")
if code_at(a.network, CREATE2_DEPLOYER) == "0x":
    sys.exit("deterministic deployer missing on this chain")

if code_at(a.network, factory) == "0x":
    ex = exchange(a.network, acct)
    check_ok(ex.use_big_blocks(True), "evmUserModify usingBigBlocks=true")
    wait_for(lambda: rpc(a.network, "eth_usingBigBlocks", [acct.address]), "big blocks enabled")
    send_tx(a.network, acct, CREATE2_DEPLOYER, "0x" + (salt + initcode).hex(), gas=3_000_000)
    check_ok(ex.use_big_blocks(False), "evmUserModify usingBigBlocks=false")
    assert code_at(a.network, factory) != "0x", "factory not deployed"
else:
    print("factory already deployed")

# DepositConfig(activationAmountWei, activationReturn, sweepTarget, hypeSpotAsset, replicaApiWallet)
cfg = (a.activation_wei, acct.address, factory, a.hype_asset, a.replica_api_wallet)
send_tx(a.network, acct, factory, calldata("setConfig((uint64,address,address,uint32,address))",
                                           ["(uint64,address,address,uint32,address)"], [cfg]))
print("config set:", cfg)
