[![codecov](https://codecov.io/github/bittyio/vault-contracts/graph/badge.svg?token=HYIKKNAA1I)](https://codecov.io/github/bittyio/vault-contracts)
## Trust

### Build

```shell
$ forge build
```

### Update env

rename `.env.sample` to `.env`, and config as below

```shell
ALCHEMY_KEY=your_key

```

### Deploy

#### seploia

update `.env`, add `SEPOLIA_PRIVATE_KEY`

```shell
forge script ${deploy_script}  --broadcast --slow --verify --rpc-url ${sepolia_rpc_url} 
```

### mainnet

update `.env`, add `MAINNET_PRIVATE_KEY`

```shell
forge script ${deploy_script}  --broadcast --slow --verify --rpc-url ${mainnet_rpc_url} 
```

### Test

```shell
$ forge test
```

### License
```AGPL-3.0-only```
