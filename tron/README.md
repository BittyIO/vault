# Bitty on TRON

The vault's `tron-vault` branch and the guard's `tron-guard` branch are the TRON build. forge still
builds and tests everything; this directory deploys the vault stack, because forge cannot broadcast
to TRON (its JSON-RPC accepts no transactions).

No protocol ships with the vault on TRON, and the vault does not depend on protocol-store's TRON
work: it pins the same protocol-store commit as `develop`, for the protocol interfaces only. A
vault on TRON holds, sends, pays payees, locks and pays gas in tokens; market trades and DeFi wait
until a protocol is deployed (from protocol-store) and listed by the guard. Adapters are not
compiled into the vault, so adding one later moves no address here.

## What is different on TRON

| | EVM | TRON |
| --- | --- | --- |
| CREATE2 address | `keccak256(0xff ‖ deployer ‖ salt ‖ hash)` | `keccak256(0x41 ‖ …)` |
| Canonical CREATE2 deployer | `0x4e59…956C` on every chain | none; the guard repo deploys `BittyTronCreate2Deployer` |
| Address of a plain deployment | from the sender's nonce | from the transaction id, so **different on Nile and mainnet** |
| Native coin | ETH, 18 decimals | TRX, 6 decimals (sun) |
| Fixed addresses | identical on every chain | identical given the CREATE2 deployer, so one set per network |

Consequences in the contracts:

- `BittyV1VaultFactory.vaultAddress` predicts with the TVM prefix on TRON
  (`src/logic/Create2Address.sol`). With OpenZeppelin's `Create2` it named an address the vault never
  lands at, and counterfactual addresses are funded before activation.
- `PriceLib` and the guard price native TRX at 6 decimals.
- `Constants.sol`, the forwarder and factory bootstraps and the factory's proxy hash hold **TRON
  addresses, written by `cli.mjs plan`**. They are not hand-edited.
- TRON USDT's `transfer` returns `false` on success, so OpenZeppelin `safeTransfer` reverts on it.
  Every payout (`PaymentCore`, `TokenAsGasLogic`) goes through `src/logic/TRC20Transfer.sol`, which
  accepts `false` only when the balance fell by exactly the amount. `transferFrom` and `approve`
  return `true` and keep using SafeERC20.

## Order

The guard goes first, from the guard repo: its `tron/deploy.mjs` deploys the network's CREATE2
deployer and the guard, and records both in the guard's `deployments/tron-nile.json` /
`deployments/tron.json`. This runner reads them from there (`guardDeployment` in the network
config) and never deploys either; `deploy` refuses a guard that is missing or not yet initialized
and configured.

```shell
cd tron && npm ci
export TRON_PRIVATE_KEY=…   # the DEPLOYER key (0x12EE…9823); the bootstraps gate on tx.origin
export TRON_PRO_API_KEY=…   # optional, TronGrid rate limits

node cli.mjs probe    --network nile   # no key: TVM opcodes, chain id, CREATE2 formula; after plan,
                                       # also simulates every planned deployment (energy per piece)
node cli.mjs plan     --network nile   # writes TRON constants into the sources, builds, plans
git diff                               # review the constants, then commit them
node cli.mjs deploy   --network nile --dry-run
node cli.mjs deploy   --network nile
```

`plan` reads the guard repo at `../../guard` (or `--guard`).

`deploy` is re-runnable: every piece already at its planned address is skipped, every proxy is
upgraded only when its ERC-1967 slot is stale, and every setting is written only when it differs.
It registers the vault implementation with the guard (`setImplementation`) and touches nothing
else there: no protocol is added. Before a deploy from nothing it checks that the
DEPLOYER account exists and holds enough TRX, and prints the address to fund if not.

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
- Every planned contract's init code runs as a simulated deployment. Largest is the vault
  implementation at about 4.8M energy; the vault stack after the guard is about 23.5M energy
  (rehearsed 2026-11-09 against the live Nile guard), about 2,350 TRX at 100 sun/energy without
  staked energy. There is no 24 KB code limit.
- Nile guard (2026-11-09): `TSZjZdPbDToDMZQMzKLhYbJh35rD8C5Em7`, CREATE2 deployer
  `TTcfv6F8mJLtfVZDM3D2V4UA7LQpEkxAgK`.
- Not yet run on a chain: an actual deploy, a vault activation, TIP-712 signing
  from TronLink against the factory and forwarder.

## Network config

`networks/<network>.json` holds what varies per network: the node, chain id, DEPLOYER, relayer, fee
collector, token addresses, and the guard's initial registry and price feeds (kept for reference;
the guard repo deploys and configures the guard). Fields
marked `TODO` must be filled before `plan` / `deploy`; both refuse to run past a missing one.

## Tests

```shell
npm test                    # address math, and the deploy order against an in-memory chain
cd .. && FOUNDRY_PROFILE=tron forge test   # the vault suite against the TRON build and constants
```
