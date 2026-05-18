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

or just export this in shell PATH

### Test

```shell
$ forge test -vvv
```

### Deploy

```shell
forge script --broadcast -vvvv \
    --rpc-url {rpc} \
    --private-key {private-key} \
    --etherscan-api-key {etherscan-api-key} \
    script/Factory.s.sol:Deploy
```

### Verify

```shell
forge verify-contract \
    --chain-id {chain-id} \
    {contract-address} \
    --etherscan-api-key {etherscan-api-key} \
    src/Factory.sol:Factory
```

### License

```AGPL-3.0-only```