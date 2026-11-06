# Bitty on TRON

The `tron` branches of `vault`, `guard` and `protocol-store` are the TRON build. forge still builds
and tests everything; this directory deploys it, because forge cannot broadcast to TRON (its
JSON-RPC accepts no transactions).

## What is different on TRON

| | EVM | TRON |
| --- | --- | --- |
| CREATE2 address | `keccak256(0xff ‖ deployer ‖ salt ‖ hash)` | `keccak256(0x41 ‖ …)` |
| Canonical CREATE2 deployer | `0x4e59…956C` on every chain | none; we deploy `BittyTronCreate2Deployer` |
| Address of a plain deployment | from the sender's nonce | from the transaction id, so **different on Nile and mainnet** |
| Native coin | ETH, 18 decimals | TRX, 6 decimals (sun) |
| Fixed addresses | identical on every chain | identical given the CREATE2 deployer, so one set per network |

Consequences in the contracts (all on these branches):

- `BittyV1VaultFactory.vaultAddress` predicts with the TVM prefix on TRON
  (`src/logic/Create2Address.sol`). With OpenZeppelin's `Create2` it named an address the vault never
  lands at, and counterfactual addresses are funded before activation.
- `PriceLib` and the guard price native TRX at 6 decimals.
- `Constants.sol`, the forwarder and factory bootstraps and the factory's proxy hash hold **TRON
  addresses, written by `cli.mjs plan`**. They are not hand-edited.
- TRON USDT's `transfer` returns `false` on success, so OpenZeppelin `safeTransfer` reverts on it.
  Every payout (`PaymentCore`, `TokenAsGasLogic`, the SunSwap adapter) goes through
  `protocol-store`'s `TRC20Transfer`, which accepts `false` only when the balance fell by exactly
  the amount. `transferFrom` and `approve` return `true` and keep using SafeERC20.
- The market-trade venue is SunSwap V3 (`protocol-store`'s `SunSwapV3TradeProtocol`). There is no
  Uniswap, Aave, CoW, Lido or Sky on TRON.

## Order

```shell
cd tron && npm ci
export TRON_PRIVATE_KEY=…   # the DEPLOYER key (0x12EE…9823); the bootstraps gate on tx.origin
export TRON_PRO_API_KEY=…   # optional, TronGrid rate limits

node cli.mjs probe    --network nile   # no key: TVM opcodes, chain id, CREATE2 formula; after plan,
                                       # also simulates every planned deployment (energy per piece)
node cli.mjs deployer --network nile   # once per network; recorded in deployments/nile.json
node cli.mjs plan     --network nile   # writes TRON constants into the sources, builds all three repos
git diff                               # review the constants, then commit them
node cli.mjs deploy   --network nile --dry-run
node cli.mjs deploy   --network nile
```

`plan` must be run from a tree where the guard and protocol-store `tron` branches sit next to this
repo (`../../guard`, `../../protocol-store`), or pass `--guard` / `--protocol-store`.

`deploy` is re-runnable: every piece already at its planned address is skipped, every proxy is
upgraded only when its ERC-1967 slot is stale, and every setting is written only when it differs.

### One set of constants per network

Nile and mainnet get different CREATE2 deployers, so every fixed address differs between them. The
branch holds **mainnet's** constants once mainnet is deployed. Rehearse on Nile from a local working
copy (or a short-lived `tron-nile` branch), then run `plan --network mainnet` and commit that.

After `plan`, treat `src/` as frozen until `deploy` finishes: any source edit, comments included,
changes the init code and so every address after it.

### What has been checked live (2026-11-07, Nile and mainnet)

- `probe`: PUSH0, TSTORE/TLOAD and MCOPY run; CHAINID is 3448148188 / 728126428; CREATE2 lands at
  the `0x41` formula's address. Hence `[profile.tron] evm_version = "cancun"` in all three repos.
- `tx.origin` and `msg.sender` compare equal to the DEPLOYER's 20-byte address, so the bootstraps'
  `tx.origin == DEPLOYER` gate works.
- Every planned contract's init code (built with placeholder addresses) runs as a simulated
  deployment. Largest is the vault implementation at about 4.7M energy; the whole set is about 28M
  energy, about 2,800 TRX at 100 sun/energy without staked energy. There is no 24 KB code limit.
- Not yet run on a chain: an actual deploy, a vault activation, a SunSwap trade, TIP-712 signing
  from TronLink against the factory and forwarder.

## Network config

`networks/<network>.json` holds what varies per network: the node, chain id, DEPLOYER, relayer, fee
collector, token and SunSwap addresses, and the guard's initial registry and price feeds. Fields
marked `TODO` must be filled before `plan` / `deploy`; both refuse to run past a missing one.

## Tests

```shell
npm test                    # address math (CREATE2 under both prefixes, base58check)
cd .. && forge test         # the vault suite, including test/local/TronSemantics.t.sol
```
