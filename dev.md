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

Deployment scripts read chain-specific addresses from `deployments/<chain>.toml` via `forge-std` config. Deploy in order — each step writes addresses the next step needs.

### Step 1 — Deploy logic libraries

Deploy the three logic libraries via the canonical CREATE2 deployer (`0x4e59b44847b379578588920cA78FbF26c0B4956C`, salt `0x0`). All live in `script/LogicLibraries.s.sol` and must be broadcast separately:

- **`VaultLogic`** — custody + payments (scheduled payments, whitelisted recipients, sends). Standalone.
- **`AssetManagerLogic`** — yield (lending / staking / auto-yield), asset-manager config, and protocol registration. Standalone.
- **`AssetManagerTradeLogic`** — the asset manager's trading surface (market swaps, AMM liquidity, intent limit/TWAP orders). Links against `VaultLogic`.

`AssetManagerLogic` and `AssetManagerTradeLogic` were split so each deployed library stays under the EIP-170 24,576-byte limit; they share the internal-only `AssetManagerShared` helpers, which inline into each and need no separate deployment.

**1a — Deploy VaultLogic** (no `--libraries` flag):

```shell
source .env
forge script script/LogicLibraries.s.sol:VaultLogic \
  --rpc-url sepolia \
  --broadcast \
  --private-key $SEPOLIA_PRIVATE_KEY \
  -vvvv
```

**1b — Deploy AssetManagerLogic** (standalone, no `--libraries` flag):

```shell
forge script script/LogicLibraries.s.sol:AssetManagerLogic \
  --rpc-url sepolia \
  --broadcast \
  --private-key $SEPOLIA_PRIVATE_KEY \
  -vvvv
```

**1c — Deploy AssetManagerTradeLogic** (links against VaultLogic from step 1a):

```shell
forge script script/LogicLibraries.s.sol:AssetManagerTradeLogic \
  --rpc-url sepolia \
  --broadcast \
  --private-key $SEPOLIA_PRIVATE_KEY \
  --libraries src/logic/VaultLogic.sol:VaultLogic:{vaultLogicAddress} \
  -vvvv
```

Writes `VAULT_LOGIC`, `ASSET_MANAGER_LOGIC`, and `ASSET_MANAGER_TRADE_LOGIC` to `deployments/<chain>.toml`.

### Step 2 — Deploy Bitty Vault implementation

Deploy `BittyV1Vault` and its `BittyV1VaultDeFiFacet` via CREATE2. The facet links against all three libraries, so pass every address from step 1:

```shell
forge script script/BittyV1Vault.s.sol:BittyV1Vault \
  --rpc-url sepolia \
  --broadcast \
  --private-key $SEPOLIA_PRIVATE_KEY \
  --libraries src/logic/VaultLogic.sol:VaultLogic:{vaultLogicAddress} \
  --libraries src/logic/AssetManagerLogic.sol:AssetManagerLogic:{assetManagerLogicAddress} \
  --libraries src/logic/AssetManagerTradeLogic.sol:AssetManagerTradeLogic:{assetManagerTradeLogicAddress} \
  -vvvv
```

Writes `VAULT_IMPLEMENTATION` and `DEFI_FACET` to `deployments/<chain>.toml`. (`BittyV1Vault` itself only links `VaultLogic` + `AssetManagerLogic`; the facet adds `AssetManagerTradeLogic`.)

### Step 3 — Deploy Bitty Vault Factory

Deploy `BittyV1VaultFactory` via the immutable factory at `0x0000000000FFe8B47B3e2130213B802212439497`, initialized with `VAULT_IMPLEMENTATION`, `BITTY_GUARD`, and `WETH` from the chain TOML:

```shell
forge script script/BittyV1VaultFactory.s.sol:BittyV1VaultFactory \
  --rpc-url sepolia \
  --broadcast \
  --private-key $SEPOLIA_PRIVATE_KEY \
  -vvvv
```

Writes `BITTY_VAULT_FACTORY` to `deployments/<chain>.toml`.

Each script is idempotent — contracts already present at their expected address are skipped.

## Verify

### Verify logic libraries

`VaultLogic` and `AssetManagerLogic` are standalone; `AssetManagerTradeLogic` links against `VaultLogic`, so pass its deployed address via `--libraries`:

```shell
forge verify-contract \
  --chain sepolia \
  {vaultLogicAddress} \
  src/logic/VaultLogic.sol:VaultLogic \
  --etherscan-api-key $ETHERSCAN_API_KEY

forge verify-contract \
  --chain sepolia \
  {assetManagerLogicAddress} \
  src/logic/AssetManagerLogic.sol:AssetManagerLogic \
  --etherscan-api-key $ETHERSCAN_API_KEY

forge verify-contract \
  --chain sepolia \
  {assetManagerTradeLogicAddress} \
  src/logic/AssetManagerTradeLogic.sol:AssetManagerTradeLogic \
  --libraries src/logic/VaultLogic.sol:VaultLogic:{vaultLogicAddress} \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

### Verify Bitty Vault implementation and DeFi facet

`BittyV1Vault` links against `VaultLogic` + `AssetManagerLogic`; the `BittyV1VaultDeFiFacet` additionally links `AssetManagerTradeLogic`. Pass the deployed addresses via `--libraries`:

```shell
forge verify-contract \
  --chain sepolia \
  {VaultImplementationAddress} \
  src/BittyV1Vault.sol:BittyV1Vault \
  --libraries src/logic/VaultLogic.sol:VaultLogic:{vaultLogicAddress} \
  --libraries src/logic/AssetManagerLogic.sol:AssetManagerLogic:{assetManagerLogicAddress} \
  --etherscan-api-key $ETHERSCAN_API_KEY

forge verify-contract \
  --chain sepolia \
  {DefiFacetAddress} \
  src/BittyV1VaultDeFiFacet.sol:BittyV1VaultDeFiFacet \
  --libraries src/logic/VaultLogic.sol:VaultLogic:{vaultLogicAddress} \
  --libraries src/logic/AssetManagerLogic.sol:AssetManagerLogic:{assetManagerLogicAddress} \
  --libraries src/logic/AssetManagerTradeLogic.sol:AssetManagerTradeLogic:{assetManagerTradeLogicAddress} \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

`VaultImplementationAddress` and `DefiFacetAddress` are the `VAULT_IMPLEMENTATION` and `DEFI_FACET` values recorded in `deployments/<chain>.toml`.

### Verify Bitty Vault Factory

```shell
forge verify-contract \
  --chain sepolia \
  <factory-address> \
  src/BittyV1VaultFactory.sol:BittyV1VaultFactory \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

## Formatting

```shell
forge fmt
forge fmt --check   # CI uses this
```
