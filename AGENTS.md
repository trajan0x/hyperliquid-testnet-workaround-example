# AGENTS.md

Notes for anyone (human or coding agent) changing this repo.

## What this is

A small example of a testnet-only workaround for HyperCore testnet bridge deposits that never credit fresh
addresses. Read README.md first. The site in docs/ explains the same thing with diagrams.

## Layout

- `src/lib/HyperCore.sol`: precompile and CoreWriter helpers. Addresses, action ids and encodings live here only.
- `src/HyperCoreFunding.sol`: abstract base with `buyHype()` and two virtual hooks.
- `src/MainnetContract.sol`: the production contract. It must not contain any workaround code.
- `src/testnet/`: everything that exists only because of the testnet limitation (mixin, contract, factory).
- `test/`: forge tests. The precompile and CoreWriter are mocked with `vm.etch` (`test/mocks/`).
- `scripts/`: Python scripts for the exchange-API and live EVM steps. Official Hyperliquid SDK, pinned.
- `docs/`: static GitHub Pages site (plain HTML, inline SVG). Served from `docs/` on `main`.

## Build and test

```
forge build
forge test
forge fmt --check
python3 -m venv .venv && . .venv/bin/activate && pip install -r scripts/requirements.txt
```

The scripts read compiled bytecode from `out/`, so run `forge build` before them.

## Conventions

- Keep production and testnet code apart. New testnet-only behavior goes in `src/testnet/` behind the hooks in
  `HyperCoreFunding`, never in `MainnetContract`.
- Do not put chain-specific values in constructor arguments or initcode of the factory or `TestnetContract`.
  They belong in `setConfig`. Changing initcode changes every address and breaks the same-address property.
  Any contract change also changes the deployed addresses listed in README.md and docs/.
- Never treat EVM events as proof that Core has funds. Read the precompile, in a later block than the CoreWriter
  action that should have changed it.
- Cite the Hyperliquid docs for any new precompile address, action id or encoding.
- Writing style for README and docs: plain, short sentences. No marketing words, no emoji, no em dashes.

## Safety rules

- Never commit keys, `.env` files, or key files. Scripts read keys from a file named by `KEY_FILE` (chmod 600).
  Never pass a key on the command line or in an environment variable, and never print one.
- Mainnet scripts are dry runs by default. They only write with `--execute` and `CONFIRM_MAINNET=yes`.
- Do not run anything on mainnet without explicit approval from the repo owner, and keep spend small.
