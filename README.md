# Bitty Vault Contracts

Solidity contracts for Bitty vaults: a factory deploys minimal proxy vaults per owner, each vault manages assets through whitelisted lending, staking, and AMM providers.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Git with submodule support

## Setup

Clone the repository and initialize all dependencies as git submodules:

```shell
git clone --recurse-submodules https://github.com/bittyio/vault-contracts.git
cd vault-contracts
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

## Dependencies

All third-party code lives under `lib/` as pinned git submodules. Do not run `forge install` for these packages; use submodules so everyone builds the same commits.

| Submodule | Repository | Used for |
| --- | --- | --- |
| `lib/forge-std` | [foundry-rs/forge-std](https://github.com/foundry-rs/forge-std) | Scripts and tests |
| `lib/openzeppelin-contracts` | [OpenZeppelin/openzeppelin-contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) | Proxies, ERC20, access control |
| `lib/solmate` | [transmissions11/solmate](https://github.com/transmissions11/solmate) | WETH and test mocks |
| `lib/whitelist-contracts` | [Turtum/WhiteList](https://github.com/Turtum/WhiteList) | Asset and provider allowlists |
| `lib/provider-contracts` | [Turtum/Providers](https://github.com/Turtum/Providers) | Aave, Lido, Uniswap V3 integrations |

Import remappings are declared in `foundry.toml`:

```toml
forge-std/=lib/forge-std/src/
openzeppelin-contracts/=lib/openzeppelin-contracts/
whitelist-contracts/=lib/whitelist-contracts/
provider-contracts/=lib/provider-contracts/
solmate/=lib/solmate/src/
```

To update a dependency to a newer commit:

```shell
cd lib/<submodule>
git fetch && git checkout <commit-or-tag>
cd ../..
git add lib/<submodule>
git commit -m "chore: bump <submodule>"
```

## Build

```shell
forge build
```

## Test

Run all tests:

```shell
forge test -vvv
```

Local tests only (Factory and Vault; no RPC required):

```shell
forge test --match-path 'test/local/Factory.t.sol' --match-path 'test/local/Vault.t.sol' -vvv
```

Some suites under `test/local/` (for example `AssetManager.t.sol`) fork mainnet via `ProviderTestSetup` and need `ALCHEMY_KEY` in `.env`.

Fork tests against mainnet state (requires `ALCHEMY_KEY`):

```shell
forge test --match-path 'test/fork/*' -vvv
```

Coverage report:

```shell
forge coverage --ir-minimum --no-match-coverage 'test|node_modules|script|src/libs'
```

## Deploy

Deployment scripts read chain-specific addresses from `deployments/<chain>.toml` via `forge-std` config. Example for Sepolia:

```shell
source .env
forge script script/Factory.s.sol:Deploy \
  --rpc-url sepolia \
  --broadcast \
  --private-key $SEPOLIA_PRIVATE_KEY \
  -vvvv
```

The factory script uses CREATE2 via the immutable factory at `0x0000000000FFe8B47B3e2130213B802212439497`. Deployed addresses are written back to the chain TOML under `deployments/`.

## Verify

```shell
forge verify-contract \
  --chain sepolia \
  <factory-address> \
  src/Factory.sol:Factory \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

## Formatting

```shell
forge fmt
forge fmt --check   # CI uses this
```

## License

AGPL-3.0-only
