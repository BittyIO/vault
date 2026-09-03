# Bitty Vault — Development

Build, test, deploy, and verify the Bitty Vault contracts. For what the vault is and how it works, see the [README](./README.md).

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Git with submodule support

## Setup

Clone the repository and initialize all dependencies as git submodules:

```shell
git clone --recurse-submodules https://github.com/bittyio/vault.git
cd vault
```

If you already cloned without submodules:

```shell
git submodule update --init --recursive
```

Copy the sample environment file and fill in your keys:

```shell
cp .env.sample .env
```

| Variable | Purpose |
| --- | --- |
| `ALCHEMY_KEY` | RPC access for fork tests and scripted deployments |
| `ETHERSCAN_API_KEY` | Contract verification on Etherscan |
| `SEPOLIA_PRIVATE_KEY` | Broadcasting key for Sepolia deployments |
| `MAINNET_PRIVATE_KEY` | Broadcasting key for mainnet deployments |

Foundry reads `.env` automatically for `${ALCHEMY_KEY}` and `${ETHERSCAN_API_KEY}` in `foundry.toml`.

## Build

```shell
forge build
```

## Test

Run all tests:

```shell
forge test -vvv
```

Local tests only (BittyV1VaultFactory and BittyV1Vault; no RPC required):

```shell
forge test -vvv --no-match-path 'test/fork/*'
```

Coverage report:

```shell
forge coverage --ir-minimum --no-match-coverage 'test|node_modules|script|src/libs'
```

## Deploy

`script/Deploy.s.sol` is the only deploy script. It brings up the whole stack in dependency order and
wires the factory to it:

| # | Contract | Deployer | Salt |
| --- | --- | --- | --- |
| 1 | seven logic libraries | canonical CREATE2 | `0` |
| 2 | `BittyV1ForwarderBootstrap` | canonical CREATE2 | `0` |
| 3 | forwarder proxy → upgraded to `BittyV1VaultForwarder`, then `initialize` | `ImmutableCreate2Factory` | `FORWARDER_SALT` (mined) |
| 4 | `BittyV1AutoYieldKeeper` — re-pointed at the forwarder | canonical CREATE2 | `0` |
| 5 | `BittyV1VaultDeFiFacet` | canonical CREATE2 | `0` |
| 6 | `BittyV1SubVault` implementation | canonical CREATE2 | `0` |
| 7 | `BittyV1Vault` implementation | `ImmutableCreate2Factory` | `IMPLEMENTATION_SALT` (mined) |
| 8 | `BittyV1VaultBootstrap` | canonical CREATE2 | `0` |
| 9 | `BittyV1VaultFactory` → `initialize` | `ImmutableCreate2Factory` | `FACTORY_SALT` (mined) |

Everything at salt `0` goes through the canonical CREATE2 deployer
`0x4e59b44847b379578588920cA78FbF26c0B4956C`, so each address is a pure function of its init code —
constructor arguments included. That is what makes re-running safe: code at the predicted address is
byte-for-byte this build, never a leftover from an older generation.

Chain-specific addresses live in `deployments/<chain>.toml`. The script reads them, and writes the ones
it creates back, through `forge-std`'s `Config`.

The guard, the fee collector and the forwarder are deliberately *not* in the TOML. All three are
compile-time constants in `src/logic/Constants.sol`, identical on every chain, so the TOML carries only
what genuinely varies per chain or is genuinely discovered by the run.

**Before you start**, the chain's TOML must already contain:

| Key | Notes |
| --- | --- |
| `WETH` | |
| `BITTY_FORWARDER_OWNER` | controls the relayer allowlist AND, now that the forwarder is a proxy, its upgrades. A Safe is the right answer; the deployer EOA works but is a hot key sitting on every vault's fee path |
| `BITTY_RELAYER` | optional — approved for `executeWithFee` / `executeBatchWithFee` if present. Without it the forwarder still relays, it just cannot charge |

`BITTY_FORWARDER_OWNER` doubles as the owner of `BittyV1AutoYieldKeeper`. The keeper stores which
forwarder it trusts, so it is redeployed-or-re-pointed on any run where the forwarder address changes;
vaults freeze their trigger, so never deploy a *new* keeper for a live generation — call
`setForwarder(newForwarder, true)` on the existing one, which is what step 4 does.

**The broadcasting key must be the DEPLOYER**, `0x12EE2de7BF086388B1D560eb95e7191Edfab9823`. The two
bootstraps, `BittyV1VaultForwarder.initialize` and `BittyV1VaultFactory.initialize` all gate on
`tx.origin` rather than `msg.sender` — which stops another chain's squatter from claiming these
addresses, and also means those calls cannot be relayed or sent from a multisig.

```shell
source .env

forge script script/Deploy.s.sol:Deploy \
  --rpc-url sepolia \
  --broadcast \
  --verify \
  --private-key $SEPOLIA_PRIVATE_KEY \
  -vvvv
```

The run is idempotent. Anything already at its expected address is skipped, each `initialize` is only
called when it has not run yet, and each proxy is upgraded only when its ERC-1967 slot does not already
name the current build — so a partial deployment can simply be re-run.

Watch the log for two things: seven library deployments near the top, and any `!! … MOVED` line from
`_reportIfMoved`, which means a recorded address changed and the guard registration or the web config
needs updating with it.

> **Simulating.** Drop `--broadcast` for a dry run — but note it still rewrites the TOML, because the
> contracts really are deployed inside the fork, at addresses that will not exist afterwards. Back the
> file up if the current values matter.

### After the deploy

1. Register the implementation on the guard: `setImplementation(<implementation>, IMPLEMENTATION_VAULT)`.
   There is no sub-vault registration — a sub vault is a beacon proxy of its parent, so it runs the
   build that ships with the parent's own guard-approved implementation and the guard has nothing
   separate to bless.
2. Update the web config's factory address and deploy block.

### Addresses that must never move

Three addresses are compiled into other contracts as constants, so moving one is not a redeploy but a
migration of everything downstream:

| Constant | Why it is pinned |
| --- | --- |
| `BITTY_GUARD` | read by every vault on every trade |
| `BITTY_FORWARDER` | a vault stores its trusted forwarder at `initialize` and has no setter |
| `BITTY_FEE_COLLECTOR` | an EOA, so it has no bytecode to drift |

The guard and the forwarder are therefore **proxies born on a bootstrap** — a permanent, do-nothing
implementation with fixed bytecode. A proxy's init code embeds its implementation, so a proxy pointed
straight at the current build moves to a new address on every release of that build, and a second chain
can only match the first by rebuilding the exact implementation the first was born with. Being born on
a constant takes the build out of the hash: the init code, and therefore the address, is identical on
every chain at every version, and a later change is an upgrade rather than a migration.

`BittyV1VaultBootstrap` does the same job one level down, for the vaults themselves — every vault proxy
is born on it, so an owner's vault address depends on their address and nothing else, and shipping a new
vault build does not relocate anyone.

Each bootstrap authorises exactly one upgrade, gated on `tx.origin == DEPLOYER` (or, for vaults, on the
vault being unclaimed), and is never the implementation again afterwards.

### Build profiles

`default`, `ci` and `deploy` compile the **same source to the same bytecode** — identical `solc_version`,
`evm_version`, optimizer settings, `via_ir` and remappings. They differ only in `out` and `test`
directories. There is no longer a profile you must remember to select before mining or deploying.

`foundry.toml` deliberately sets **no `libraries` pin and no `bytecode_hash` / `cbor_metadata`
override**. Both change the init code and therefore every CREATE2 address derived from it, and solc
records the `libraries` setting in each contract's metadata — so pinning shifts even contracts that link
nothing. Forge links the libraries automatically at their salt-0 CREATE2 addresses, which is exactly
where `_deployLogicLibraries` puts them, and `_deployLibrary` asserts the two agree before deploying.

### Deterministic addresses and salt mining

`FORWARDER_SALT`, `IMPLEMENTATION_SALT` and `FACTORY_SALT` in `script/Deploy.s.sol` all go through
`ImmutableCreate2Factory` at `0x0000000000FFe8B47B3e2130213B802212439497`, which requires the salt's
leading 20 bytes to equal the caller. Only the trailing 12 bytes are free to search, and no one but the
DEPLOYER can use these salts on any chain — so a miner has to be told the caller, not just the hash.

The script prints each init code hash as it runs, so a dry run is the way to get them.

#### Mining order

The order is forced, not preferred:

| step | mine | depends on |
| --- | --- | --- |
| 1 | `FORWARDER_SALT` | nothing — the proxy's init code holds only the forwarder bootstrap, which is constant |
| 2 | — | paste the resulting proxy address into `BITTY_FORWARDER` in `Constants.sol` |
| 3 | `IMPLEMENTATION_SALT` and `FACTORY_SALT` | step 2 — both build against `Constants.sol` |

Step 2 is the one that catches people out. `BittyV1Vault`, `BittyV1SubVault` and the DeFi facet all
import `Constants.sol`, so changing `BITTY_FORWARDER` moves the facet, the sub implementation and the
vault implementation — and the factory's metadata references the changed sources, so it moves too. A
salt mined before step 2 lands on an address the deploy can never reach, and the failure is silent: the
numbers all look fine.

**Any source edit invalidates a mined salt — comments and NatSpec included**, because solc appends a
metadata hash covering the sources. Between mining and deploying, treat `src/` as frozen, and do not run
`forge fmt`.

Since the forwarder went behind its bootstrap, a change to the relay logic is an upgrade and no longer
forces any of this. The mining sequence above is needed only when `Constants.sol` itself changes.

## Verify

Requires `ETHERSCAN_API_KEY` in `.env`. `--verify` on the deploy covers most of it; the commands below
are for filling gaps or verifying an older deployment.

Foundry reads the compiler settings from `foundry.toml`, so the `0.8.34` / `optimizer_runs = 10000` /
`via_ir = true` triple is matched automatically. Getting one of those wrong is the usual cause of a
bytecode mismatch.

### Libraries, bootstraps, forwarder build and factory

None of these take constructor arguments or link a library:

```shell
forge verify-contract --chain sepolia --watch {ADDRESS} {PATH}:{NAME}
```

for each of `src/logic/PaymentLogic.sol:PaymentLogic`, `DeFiLogic`, `SubVaultRegistryLogic`,
`GaslessLogic`, `RiskLogic`, `ScheduledPaymentLogic`, `WhitelistLogic`,
`src/BittyV1ForwarderBootstrap.sol:BittyV1ForwarderBootstrap`,
`src/BittyV1VaultBootstrap.sol:BittyV1VaultBootstrap`,
`src/BittyV1VaultForwarder.sol:BittyV1VaultForwarder` and
`src/BittyV1VaultFactory.sol:BittyV1VaultFactory`.

### Contracts that link libraries

The `--libraries` addresses must be the ones the deployed bytecode is **actually linked against** — the
values the deploy script wrote to the chain TOML. Pass each flag separately and **quote it**: collapsing
several into one unquoted shell variable makes forge read them as a single argument and fail with
nothing but `For more information, try '--help'`.

```shell
# DeFi facet — links DeFiLogic only
forge verify-contract --chain sepolia --watch {DEFI_FACET} \
  src/BittyV1VaultDeFiFacet.sol:BittyV1VaultDeFiFacet \
  --libraries "src/logic/DeFiLogic.sol:DeFiLogic:{DEFI_LOGIC}"

# sub-vault implementation — links DeFiLogic, takes the facet
forge verify-contract --chain sepolia --watch {SUB_VAULT_IMPLEMENTATION} \
  src/subvault/BittyV1SubVault.sol:BittyV1SubVault \
  --libraries "src/logic/DeFiLogic.sol:DeFiLogic:{DEFI_LOGIC}" \
  --constructor-args "$(cast abi-encode 'constructor(address)' {DEFI_FACET})"

# vault implementation — links all seven, takes the facet and the sub implementation
forge verify-contract --chain sepolia --watch {VAULT_IMPLEMENTATION} \
  src/BittyV1Vault.sol:BittyV1Vault \
  --libraries "src/logic/DeFiLogic.sol:DeFiLogic:{DEFI_LOGIC}" \
  --libraries "src/logic/GaslessLogic.sol:GaslessLogic:{GASLESS_LOGIC}" \
  --libraries "src/logic/PaymentLogic.sol:PaymentLogic:{PAYMENT_LOGIC}" \
  --libraries "src/logic/RiskLogic.sol:RiskLogic:{RISK_LOGIC}" \
  --libraries "src/logic/ScheduledPaymentLogic.sol:ScheduledPaymentLogic:{SCHEDULED_PAYMENT_LOGIC}" \
  --libraries "src/logic/SubVaultRegistryLogic.sol:SubVaultRegistryLogic:{SUB_VAULT_REGISTRY_LOGIC}" \
  --libraries "src/logic/WhitelistLogic.sol:WhitelistLogic:{WHITELIST_LOGIC}" \
  --constructor-args "$(cast abi-encode 'constructor(address,address)' {DEFI_FACET} {SUB_VAULT_IMPLEMENTATION})"
```

### Keeper

```shell
forge verify-contract --chain sepolia --watch {BITTY_AUTO_YIELD_KEEPER} \
  src/BittyV1AutoYieldKeeper.sol:BittyV1AutoYieldKeeper \
  --constructor-args "$(cast abi-encode 'constructor(address)' {BITTY_FORWARDER_OWNER})"
```

### Forwarder proxy

The constructor argument is the **bootstrap**, not the forwarder build behind it, and it stays the
bootstrap through every future upgrade. Passing the current implementation is the natural mistake and
fails with a bytecode mismatch:

```shell
forge verify-contract --chain sepolia --watch {BITTY_FORWARDER} \
  lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
  --constructor-args "$(cast abi-encode 'constructor(address,bytes)' {FORWARDER_BOOTSTRAP} 0x)"
```

Verification alone does not make Etherscan render the forwarder's functions — the proxy's own ABI has
none. Link it to its implementation as well, and repeat this after every forwarder upgrade:

```shell
curl -X POST "https://api.etherscan.io/v2/api?chainid=11155111" \
  -d "module=contract" -d "action=verifyproxycontract" -d "apikey=$ETHERSCAN_API_KEY" \
  -d "address={BITTY_FORWARDER}" -d "expectedimplementation={FORWARDER_IMPLEMENTATION}"
```

The same control is in the UI under *Contract → More Options → Is this a proxy?*.

Individual **vaults** need no verification of their own: each is an `ERC1967Proxy` whose init code is
the vault bootstrap, so once one is verified Etherscan matches the rest by bytecode.

## Formatting

```shell
forge fmt
forge fmt --check   # CI uses this
```
