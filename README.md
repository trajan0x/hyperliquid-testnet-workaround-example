# HyperCore testnet deposit workaround

Site with diagrams: https://trajan0x.github.io/hyperliquid-testnet-workaround-example/

This is a small, crude example for one testnet problem. On HyperEVM testnet, `CoreDepositWallet.depositFor`
to a fresh address succeeds on the EVM side, but HyperCore never credits the USDC.

It was written in reply to this Discord question:
https://discord.com/channels/1029781241702129716/1262879465503981672/1555492643230720081

## The problem

Circle documents two testnet limits for USDC bridged into HyperCore
([CCTP on HyperCore, testnet recipient address limitations](https://developers.circle.com/cctp/concepts/cctp-on-hypercore#testnet-recipient-address-limitations)).
The recipient must already exist on HyperCore mainnet. Even then, it can receive at most 1,000 testnet USDC.
Deposits to other addresses fail silently. The EVM transaction succeeds and the USDC is burned, but nothing
arrives on Core. See [hyperliquid-dex/node#138](https://github.com/hyperliquid-dex/node/issues/138) and
[this comment](https://github.com/hyperliquid-dex/node/issues/138#issuecomment-5947357512).

A per-user deposit contract deployed on testnet has no mainnet history, so bridge deposits to it are lost.
Mainnet does not have this problem.

## What this repo does

It skips the bridge on testnet. Each user gets a deposit contract at a CREATE2 address (salt = user). USDC is
sent to that address on HyperCore with a Core-side `spotSend`, for example from a faucet-funded wallet. The
address can receive funds before any code is deployed there.

The contract never trusts EVM events. It reads its own Core balance from the `spotBalance` precompile
(`0x...0801`) and only acts when the funds are there. CoreWriter actions run after the EVM block, so every
check that an action worked happens in a later block.

Before its first real action, the contract must be activated. A small amount is sent in through the exchange
API. The contract sends it back out through CoreWriter, and a later block confirms that it left. Until then the
contract refuses to act.

The example action places a HYPE limit buy through CoreWriter. It is there to show the pattern and nothing more.
There is also a `sweep()` that moves the balance to a main contract. The user is only credited when a later
precompile read shows the funds left. User actions are blocked between the two steps.

The production contract (`MainnetContract`) contains none of this. All testnet code sits in `src/testnet/` and
plugs into two hooks in the abstract base. If your mainnet and testnet contracts already share a Solidity
abstraction, put the testnet pieces behind it the same way.

## What did not work: making the address a "mainnet user"

Circle's rule says the recipient must exist on HyperCore mainnet. We tried three ways to satisfy it, and none
made testnet `depositFor` work for an address that did not already qualify.

1. Core-side seed. We sent the deposit address 2 USDC on mainnet Core, deployed the same factory and deposit
   contract at the same address on mainnet, added an operator API wallet from the replica's initializer, and had
   that API wallet sign an L1 action. Testnet deposits were still not credited.
2. Mainnet bridge history. We bridged 5 USDC with mainnet `CoreDepositWallet.depositFor` to the deposit address
   and to a brand-new EOA. Both landed on mainnet Core. Testnet deposits to them were not credited 5 minutes,
   40 minutes, or about 24 hours later.
3. Bridge history plus a testnet Core account. We also gave the new EOA a testnet Core account with a small
   Core send. Still not credited.

Over the same period our older wallet, which has long mainnet history, was credited within seconds every time.
None of the failed deposits ever showed up later, and nothing appears in the recipients' testnet ledgers. So
the testnet check needs something we could not create: maybe account age, maybe a snapshot taken less often
than daily, maybe an allowlist. We do not know which.

The practical answer for USDC on testnet is therefore the workaround above. Fund addresses with Core-side
sends from a wallet that already works, and do not rely on testnet `depositFor` for new addresses.

The mainnet pieces do work on their own. The factory lands at the same address on both chains, the replica's
initializer adds an API wallet, and that wallet can sign gasless L1 actions. They just do not unlock testnet
deposits.

## What does work for EOAs: native HYPE

The limit is specific to USDC through `CoreDepositWallet`. We took a brand-new testnet EOA with no mainnet
history and no Core account, and sent 0.01 HYPE from HyperEVM to Core through the HYPE system address
`0x2222222222222222222222222222222222222222`. The testnet ledger recorded the transfer right away. The info
API showed the address as `missing` with no balance, though. As soon as another wallet sent the EOA a small
amount of USDC on Core, which created its Core account, the 0.01 HYPE was there. After that, HYPE moved both
ways within seconds: EVM to Core through `0x2222...2222`, and Core to EVM with a `spotSend` to the same address.

So if you have testnet EOAs with assets on HyperEVM that have never touched Core:

1. From any wallet that already has testnet Core USDC, `spotSend` each EOA a small amount on Core. The sender
   pays HyperCore's 1 USDC new-account fee.
2. After that, HYPE moves freely between HyperEVM and Core. We did not test other spot tokens.
3. USDC through testnet `depositFor` still does not work for these EOAs. Move USDC with Core-side sends instead.

## Live results

All runs used the same factory address on both chains:
`0x3A1dfE1132646A32A6D68326cA5baC226Bd5514e`. Owner and test user is the wallet
`0x76198E1AC0e47c046Ed233f66B6033CBB4f82F6D`. Its deposit address is
`0xD4808d726a073292c2B4AF2C454586DabFa9b160` on both chains.

Testnet (chain 998). EVM links go to testnet.purrsec.com. Core links go to the Hyperliquid testnet explorer.

| Step | Transaction |
|---|---|
| Deploy factory through `0x4e59...956C` (big block) | [0x7ef61d82](https://testnet.purrsec.com/tx/0x7ef61d82c807fd4544b7a9a8853518f6572716579ec9614f9db732fe6b922737) |
| `setConfig` (HYPE asset 11035, 1 USDC activation) | [0x5f63859f](https://testnet.purrsec.com/tx/0x5f63859ffa49d391508c206bb6a8ae7971baef5b5a22230753126180ba693e16) |
| Core send 15 USDC to the address before it had code. The sender paid a 1 USDC new-account fee. | [Core 0xa026d047](https://app.hyperliquid-testnet.xyz/explorer/tx/0xa026d0473385fba7a1a0042ab7aa83010100e82cce891a7943ef7b99f289d592) |
| `factory.deploy(user)` | [0x71f8b5b9](https://testnet.purrsec.com/tx/0x71f8b5b9ac3a3527db84e6fdd9224fad82e6fc8f5caccfccbce3e9611578f637) |
| Activation: 1 USDC in | [Core 0xc817426c](https://app.hyperliquid-testnet.xyz/explorer/tx/0xc817426cf2534371c990042ab7ac5a0103005a528d5662436bdfedbfb1571d5c) |
| Activation: `beginActivation()` sends it back out | [0x8ff1f509](https://testnet.purrsec.com/tx/0x8ff1f509dcb4ce39f40bad70f65704591c2a0d027d436e9b5ebfa5c33f306410), [Core 0xca9d518b](https://app.hyperliquid-testnet.xyz/explorer/tx/0xca9d518b676e4c9ecc17042ab7aca60000d8697102616b706e65fcde26622689) |
| Activation: `confirmActivation()` | [0x1b800c2a](https://testnet.purrsec.com/tx/0x1b800c2ab7ba86959f64b3fa453b8c6ef5ffdc5781a8b7cfc7b7e7c145b97875) |
| `buyHype(32, 0.4)`, filled 0.4 HYPE at 31.658 | [0x774e5359](https://testnet.purrsec.com/tx/0x774e53595619a091784f283ad2833ac681d247853116cedcea53d1a2ba7741cf), [Core fill 0x0d036d7c](https://app.hyperliquid-testnet.xyz/explorer/tx/0x0d036d7c846f6d9d0e7d042ab7bab600003e85621f628c6fb0cc18cf43634787) |
| `sweep()` 2.3368 USDC to the factory | [0x7ccd37b8](https://testnet.purrsec.com/tx/0x7ccd37b8d3ba6d29398d36ed7426ab2e32b93d18cba80e4c4d9a81588a6965b9), [Core 0xea311837](https://app.hyperliquid-testnet.xyz/explorer/tx/0xea311837fdee369aebaa042ab7be2e00006c301d98e1556c8df9c38abce21085) |
| `confirmSweep()`, `credited(user)` = 2.3368 | [0x1bd05ed7](https://testnet.purrsec.com/tx/0x1bd05ed7e43a90e4b5819ed466dc6082de7e554402db832fb7f5a9e4bf8f9d05) |

Mainnet (chain 999). Total spend was 3 USDC in new-account fees plus about 0.0005 HYPE of gas. All principal
was sent back.

| Step | Transaction |
|---|---|
| Core send 2 USDC to the deposit address (seed). The sender paid a 1 USDC new-account fee. | [Core 0x50773ed7](https://app.hyperliquid.xyz/explorer/tx/0x50773ed7e30786a951f00445aaff3802017000bd7e0aa57bf43fea2aa20b6093) |
| Deploy the same factory, same address | [0x382c79ae](https://hyperevmscan.io/tx/0x382c79ae8405746d40d8707848fdcd21cf34354a1775216a872689eafcacea68) |
| `setConfig` (HYPE asset 10107, API wallet) | [0xe2d83bd0](https://hyperevmscan.io/tx/0xe2d83bd0eb0febdfb19077bb620a7acdbfb6a6d856c3315d1399acb40ab9a95f) |
| `factory.deploy(user)`, which runs `initializeReplica()`. API wallet `0x5438b9fE9d6819102C59e7c7E66cf8766180F164` shows up in `extraAgents`. | [0xe83eb434](https://hyperevmscan.io/tx/0xe83eb43437807cd40db583e0b468415ada8fcfa25c93f00baa2a1a3f0cfe6d64) |
| API wallet signs a gasless `noop` for the address (`nRequestsUsed` went from 0 to 1) | exchange API, no tx |
| `returnSeed()` sends the 2 USDC back | [0x1e5c4a08](https://hyperevmscan.io/tx/0x1e5c4a083715431badb58e68f6da2624731a16937fcbf5905d9234b864216f8e), [Core 0xaad69a44](https://app.hyperliquid.xyz/explorer/tx/0xaad69a443ab881eaac500445ab2f7f000011b229d5bba0bc4e9f4596f9bc5bd5) |
| Bridge 5 USDC with `depositFor` to the deposit address. Credited 5.0. | [0x53be4b44](https://hyperevmscan.io/tx/0x53be4b4430bb784e3e1220b0b6f214332edf66456aae77ddf3c1ac58449be761) |
| Bridge 5 USDC with `depositFor` to new EOA `0x5b9f...03f7`. Credited 4.0, because the bridge charges 1 USDC `accountActivationGas` for a new account. | [0x05c04cfe](https://hyperevmscan.io/tx/0x05c04cfec87097c69e2fffa2e9d180c5dde37d087a5d64cac14ef24873d98070) |
| `returnSeed()` sends the 5 USDC back | [0xf8e2a7e5](https://hyperevmscan.io/tx/0xf8e2a7e5eaf099e6d67e2b2cbe64c08e98b85f0a5d27878733808ac04c55147c) |
| New EOA sends its 4 USDC back on Core | [Core 0xd1c1b11e](https://app.hyperliquid.xyz/explorer/tx/0xd1c1b11e7baa3b07d33b0445bf69710202ad000416ad59d9758a5c713aae14f2) |

Testnet `depositFor` experiment. Each run bridged 0.25 to 1 testnet USDC to the spot dex and watched the
recipient's balance through the precompile. Times are measured from the mainnet bridge deposits.

| Recipient | Mainnet state | Testnet Core account | Result | depositFor tx |
|---|---|---|---|---|
| Deposit address | none | yes | not credited | [0xcaf91390](https://testnet.purrsec.com/tx/0xcaf9139016f2ae5fa301963c49306bfa8ccddbc440b1c515ed4f6573c28c9099) |
| Deposit address | Core seed, replica, API wallet | yes | not credited | [0xb6befae4](https://testnet.purrsec.com/tx/0xb6befae42b8b6d9d7f5ba4ebc05fb0ed9f48ec8868430fb6d20f162569b1c6b0) |
| Deposit address | same, plus an API wallet L1 action | yes | not credited | [0xcca6dab2](https://testnet.purrsec.com/tx/0xcca6dab2853869bd4023f87fba2524e4ba1a6a4c4bb24a9288f7c58defebfd65) |
| New EOA `0x3d77...4EF3` | 1 USDC Core send minutes earlier | no | not credited | [0x4e1f3b8a](https://testnet.purrsec.com/tx/0x4e1f3b8af3b1132187bc6ad0dfc83cf0d67f5f7ecb37baae19ca201b7a22bc2d) |
| Deposit address | plus mainnet bridge deposit, +5 min | yes | not credited | [0xb535c63c](https://testnet.purrsec.com/tx/0xb535c63c123f45bcaae07b08e652d4d2d1f8939d06dad26bcc0cb4688b548839) |
| New EOA `0x5b9f...03f7` | mainnet bridge deposit, +5 min | no | not credited | [0xabe5688b](https://testnet.purrsec.com/tx/0xabe5688bb51f376984a92a3c32b55366ce3cc89a7567ec24a330a9104d7bdace) |
| New EOA `0x5b9f...03f7` | mainnet bridge deposit, +16 min | yes | not credited | [0x160b946e](https://testnet.purrsec.com/tx/0x160b946ea804bf461886c8093404c3000a4a4b2ddbdde23266687c8445338a8c) |
| HYPE EOA `0x3928...e156` | none | yes | not credited | [0xa0543561](https://testnet.purrsec.com/tx/0xa0543561d909a740303c6035f7f54c3b3d7cf4fbfb4a243c388aa60caf1cecb2) |
| Deposit address | mainnet bridge deposit, +40 min | yes | not credited | [0xb395f3e8](https://testnet.purrsec.com/tx/0xb395f3e81f32e2f60a86c666f4e705a363c7f984a8a7cee7b6da471487dc11ad) |
| New EOA `0x5b9f...03f7` | mainnet bridge deposit, about +24 h | yes | not credited in 10 min | [0x782b3f20](https://testnet.purrsec.com/tx/0x782b3f2027efa0891a85733ff84a14eea6da3c5767e421e88ebdf8369911bbc3) |
| Deposit address | mainnet bridge deposit, about +24 h | yes | not credited in 11 min | [0xb95604ee](https://testnet.purrsec.com/tx/0xb95604ee29e28cc5c2582dddbfc436da6fdbbc6e75fec3af0eae473c8434786f) |
| Our wallet | long mainnet history | yes | credited within seconds | [0x7f99e74e](https://testnet.purrsec.com/tx/0x7f99e74e9c21d4a1db133d1773c714fe42e8030c14ea022034ab3aff6189eaa1) |

None of the failed deposits were credited later. A day after the first attempts, all of the recipients still
showed only what they had received through Core-side sends.

Testnet native HYPE with brand-new EOA `0x3928Dbc6C315ef26c077BDb0739cce4dD173e156`:

| Step | Result | Transaction |
|---|---|---|
| EVM to Core, 0.01 HYPE to `0x2222...2222`, no Core account yet | in the ledger right away, but the info API showed `missing` and 0 | [0x099c7f00](https://testnet.purrsec.com/tx/0x099c7f00c20628e660394f0f9977f8efbbf639f74282ca5bc468dd3ee3d6542b) |
| Core send of 0.5 USDC from our wallet creates the account (we paid the 1 USDC fee) | 0.01 HYPE now visible | [Core 0x1deeec6f](https://app.hyperliquid-testnet.xyz/explorer/tx/0x1deeec6f55b729421f68042ab9a3c80103000454f0ba4814c1b797c214bb032c) |
| EVM to Core, 0.005 HYPE | credited within seconds | [0x0101c4a5](https://testnet.purrsec.com/tx/0x0101c4a54983f2d58ab8b30bd6de2c47eced45382740b90da8e1e0e86286b9e1) |
| Core to EVM, `spotSend` 0.01 HYPE to `0x2222...2222` | on HyperEVM within about 1 second | exchange API |

## Layout

```
src/lib/HyperCore.sol              precompile and CoreWriter helpers
src/HyperCoreFunding.sol           abstract base: buyHype() and two hooks
src/MainnetContract.sol            production contract, no workaround code
src/testnet/TestnetFunding.sol     testnet-only mixin: activation, balance checks, sweep, replica
src/testnet/TestnetContract.sol    MainnetContract + TestnetFunding
src/testnet/TestnetDepositFactory.sol  CREATE2 factory (salt = user) and credit ledger
scripts/                           Python scripts for the exchange API and EVM steps
test/                              forge tests with a mocked precompile and CoreWriter
docs/                              the GitHub Pages site
```

## Running it

```
forge build && forge test
python3 -m venv .venv && . .venv/bin/activate
pip install -r scripts/requirements.txt
```

The scripts read a private key from the file named by `KEY_FILE` (default `./key`, must be chmod 600). They
never take keys from the command line or print them. You need testnet USDC on Core (the faucet) and a little
testnet HYPE on HyperEVM for gas.

```
# 1. Deploy the factory. Turns on big blocks, since the deploy is about 2.4M gas.
python scripts/deploy_factory.py --network testnet --salt 0x01 --hype-asset 11035

# 2. Fund the user's deposit address on Core, then deploy it.
python scripts/deposit.py --factory 0xFACTORY fund --amount 15
python scripts/deposit.py --factory 0xFACTORY deploy

# 3. Activate: 1 USDC in, the contract bounces it out, confirm in a later block.
python scripts/deposit.py --factory 0xFACTORY activate

# 4. Example action only: limit buy 0.4 HYPE at 32 USDC. Or sweep and credit.
python scripts/deposit.py --factory 0xFACTORY buy --px 32 --sz 0.4
python scripts/deposit.py --factory 0xFACTORY sweep

# Experiment: bridge 1 testnet USDC with depositFor and watch whether Core credits it.
python scripts/deposit_for.py --to 0xRECIPIENT --amount 1
# Same on mainnet (real USDC). Dry run unless --execute and CONFIRM_MAINNET=yes.
python scripts/deposit_for.py --network mainnet --to 0xRECIPIENT --amount 5
```

`scripts/lookup_spot_asset.py` prints the HYPE/USDC asset id per network (spot asset = 10000 + pair index;
testnet `@1035`, mainnet `@107` at time of writing). `scripts/check_address.py` shows `userRole` on both
networks.

The mainnet steps live in `scripts/mainnet_replica_worker.py`. Every write is a dry run unless you pass
`--execute` and set `CONFIRM_MAINNET=yes`. Given the results above, they will not unlock testnet deposits.
They are kept so others can rerun the experiment.

## Reference

The CoreWriter address (`0x3333...3333`), action encoding and action ids (1 limit order, 6 spot send, 9 add
API wallet) come from
[Interacting with HyperCore](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/interacting-with-hypercore).
The same page lists the read precompile addresses. We also cross-checked them against
[hyper-evm-lib](https://github.com/hyperliquid-dev/hyper-evm-lib). The action format is one version byte (1),
three bytes of action id, then the ABI-encoded arguments. Prices and sizes in a limit order are the human value
times 1e8.

The deterministic CREATE2 deployer `0x4e59b44847b379578588920ca78fbf26c0b4956c` exists on both HyperEVM
chains. `foundry.toml` turns off the metadata hash so the bytecode, and so the addresses, match.

## Caveats

This is crude, testnet-only code. It has not been audited.

Every first transfer to a new Core address costs the sender 1 USDC. The sweep target must already exist on
Core. If it does not, the contract cannot pay that fee, Core rejects the sweep, and the deposit address stays
locked. There is no way out of that state in this version.

CoreWriter actions are asynchronous. A rejected action does not revert the EVM transaction. If funds arrive
between `beginActivation` and `confirmActivation`, confirmation can stall. Wait `ACTIVATION_RETRY_BLOCKS` and
begin again.

Accounts in unified-account mode reject `spotSend`. The scripts fall back to `sendAsset` in that case.

API wallets cannot move funds out of an account. `spotSend`, `usdSend` and `withdraw3` are user-signed and move
the signer's own funds, which is why the replica returns its seed through CoreWriter.

## License

MIT. See [LICENSE](LICENSE).
