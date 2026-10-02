#!/usr/bin/env python3
"""Print the CoreWriter asset id for a spot pair (default HYPE/USDC). No keys needed.

Spot asset id = 10000 + spotMeta.universe[i].index, where universe[i].tokens == [base token index, 0 (USDC)].
At time of writing: testnet HYPE/USDC is "@1035" -> 11035, mainnet is "@107" -> 10107.
"""

import argparse

from common import info

p = argparse.ArgumentParser()
p.add_argument("--network", choices=["testnet", "mainnet"], default="testnet")
p.add_argument("--base", default="HYPE")
a = p.parse_args()

meta = info(a.network).spot_meta()
tokens = {t["index"]: t for t in meta["tokens"]}
for pair in meta["universe"]:
    base, quote = pair["tokens"]
    if quote == 0 and tokens[base]["name"] == a.base:
        t = tokens[base]
        print(f"{a.network}: {a.base}/USDC pair name={pair['name']} index={pair['index']} "
              f"-> asset id {10000 + pair['index']}  (base token index={base}, szDecimals={t['szDecimals']})")
        break
else:
    raise SystemExit(f"no {a.base}/USDC spot pair on {a.network}")
