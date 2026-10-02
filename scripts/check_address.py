#!/usr/bin/env python3
"""Show what HyperCore knows about an address on both networks. No keys needed.

Circle: testnet recipients must already exist on HyperCore MAINNET; mainnet userRole == "missing" means it does not.
"""

import sys

from common import spot_balance, user_role

addr = sys.argv[1]
for net in ("mainnet", "testnet"):
    print(f"{net:8s} userRole={user_role(net, addr):10s} spot USDC={spot_balance(net, addr)}")
