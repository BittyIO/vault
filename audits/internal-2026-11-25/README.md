# Internal security review, 2026-11-25

Scope: vault `feat/bridge_better` (23f2696, vault 1.2.1) and protocol-store `feat/across-bridge-to`
(d756a53, Across adapter 1.2.2). Three independent reviews (bridge path; limits, payees and locks;
vault core and access), each finding re-checked against the code. Nothing here is fixed yet.

PoC tests are in `poc/`. They were written against throwaway copies of the repos and pass there;
to run one, copy it into the matching repo's `test/local/` (PocBridge, RelayerCharge: vault;
PocAcross: protocol-store).

Threat model throughout: the vault's limits, security delay and locks exist to cap what a thief
holding the **owner key** can take.

## Critical / High

### 1. Critical: `bridge()` takes everything past every limit (live on all 5 EVM chains)
- `src/logic/BridgeLogic.sol:75-93`: the bridge is on by default (unset switch reads as on,
  `:37-40`), the amount is never metered; only the bridge cost is charged to the loss allowance.
- The money lands at the vault's CREATE2 address on the destination chain, which depends only on
  the owner key (`src/BittyV1VaultFactory.sol:130`).
- Where the owner never activated a vault, the thief calls `activateVault` there with the stolen key.
  A new vault starts open: no send limit, zero timelock (`src/logic/RiskLogic.sol:98-108`). Then sends
  everything. The send allowance, delay and lock on the original chain change nothing.
- Same after a recovery: ownership is per chain, so a later `bridge()` to an unactivated chain pays
  the old (stolen) key's address.
- Predates `bridgeTo`. Evidence: existing tests `test_onByDefault`, `test_noAmountLimit`.
- Fix: `bridge()` only to chains the owner registered behind the security delay (like a payee,
  voided by a lock); anywhere else meter it against the send allowance. New vaults: bridge off.

### 2. High: payee bridges drain the vault through bridge cost, even under a lock (PoC)
- `src/logic/BridgeLogic.sol:128-143`: `bridgeToWhitelistedRecipient` charges no loss.
- protocol-store `src/protocols/AcrossBridgeProtocol.sol:360-375`: with a flat cost, a deposit at or
  below it floors the minimum to 0, so `outputAmount = 1` passes (`test_flatCostLargerThanTheTransfer`).
- Live: USDT→TRON has an 8 USDT flat cost on Ethereum, Base, Arbitrum, BSC. With any matured TRON
  payee, the thief repeats 8-USDT bridges with output 1 and their own `exclusiveRelayer`, keeping
  ~8 USDT each, also under an emergency or forever lock. Without a flat cost, still up to the
  route cost per crossing, unmetered.
- PoC: `poc/PocBridge.t.sol` `test_poc_unmeteredCostDrainUnderLock` (loss allowance 0, locked,
  200 calls lose 2,000 USDC; the same through `bridge()` reverts).
- Fix: charge `amount - received` to the loss allowance; adapter refuses when the floor is 0, and
  caps the flat cost relative to the deposit. Stopgap via guard only: set the TRON routes' flat cost
  to 0 (small bridges under ~25 USDT stop working again).

### 3. High, latent: `bridge()` to self on Solana burns the funds (PoC)
- `AcrossBridgeProtocol.sol:221-223`: with no origin owner, `recipientFor` returns the vault's 20
  bytes for any non-TRON chain. On Solana nobody holds that key; same on chains with different
  CREATE2 derivation (e.g. zkSync) or where the factory isn't deployed.
- Not live: no Solana route exists. Becomes live the moment one is added.
- PoC: `poc/PocAcross.t.sol` `test_poc_bridgeToSelfOnSolana`.
- Fix: `bridge()` accepts only guard-marked EVM chains (`bitty.chain.evm`) or TRON.

## Medium

### 4. A relayer charges any vault's gas budget with no owner signature (PoC)
- `src/BittyV1VaultForwarder.sol:201-219`: `executeWithFee` never checks the signer is the vault's
  owner/manager/keeper; fee and fee token are not signed.
- Up to the $100/day system budget per vault, under an emergency lock too. Goes to
  `BITTY_FEE_COLLECTOR`, not the relayer, but unauthorized.
- PoC: `poc/RelayerCharge.t.sol` `test_relayerChargesVaultWithoutOwnerSignature`.
- Fix: charge only when the signer is the owner, an active manager or the keeper signer; bind a
  max fee and token into the signed data.

### 5. Deprecating a buggy adapter doesn't stop vaults that already cloned it (PoC)
- `BridgeLogic.sol:170-190`, `DeFiLogic.sol:494-501`: guard flags are checked on the `protocol`
  argument, but the vault's existing clone runs, whatever version it is.
- PoC: `poc/PocBridge.t.sol` `test_poc_deprecatedImplKeepsRunning`.
- Fix: require the clone's ERC-1967 implementation to be registered and not deprecated (or equal
  `protocol`), or upgrade the clone to `protocol` when it is newer.

### 6. A thief can freeze a vault forever when it has no matured payee
- Tightening applies at once and cancels a pending loosening (`TimelockLib.sol:36-41`); unmatured
  payees can be removed at once; a forever lock needs a matured payee.
- Inherent to two holders of one key. Defence: the app requires an escape payee as soon as a delay
  is set.

### 7. A market-trade manager has full custody while the loss allowance is NO_LIMIT
- `MarketTradeLogic.sol:208`: under NO_LIMIT nothing is priced; the route is caller-chosen and can
  name any recipient (Universal Router commands).
- Fix: refuse *manager* market trades under NO_LIMIT (or price them anyway); the owner's own trades
  can stay unpriced (see "Design note" below).

## Low / Info
- **ANY_EVM payees** (`WhitelistLogic.sol:244-256`) assume one address = one holder on every chain;
  wrong for a Safe or exchange deposit contract. Restrict to addresses with no code, or per chain.
  On a TRON vault they are treated as local, contradicting `Constants.sol:56-60`.
- **PERM_INTENT** managers can sell yield receipts (aTokens, stETH): `DeFiLogic.sol:454-460`.
- **Free `execute` front-run** of a paid relay burns the nonce; relayer pays gas, no fee.
- **Vault bootstrap** checks OZ's Ownable slot, never written (`BittyV1VaultBootstrap.sol:32-46`);
  harmless while it is only used inside the factory's one transaction.
- **Docs**: `MarketTradeLogic.sol` header says every trade is priced and only fed assets trade; under
  NO_LIMIT neither holds (the code and `test_aNewVaultThatSetNothingTradesUnpriced` agree it isn't).

## Unverified suspicions
- CoW intent orders are not priced unless the loss allowance is 0; safety rests on solver competition.
- Across `speedUpDeposit` accepts the depositor's ERC-1271 signature; harmless today (the vault only
  signs CoW digests) but any future adapter that validates plain owner signatures would let a thief
  redirect in-flight deposits.
- On a new chain, check the factory/guard addresses cannot be taken by someone else before routes to
  it are added.

## Checked and sound
ERC-2771 suffix spoofing; forwarder replay/nonces/malleability; factory activation and front-running;
upgrade rules; facet/ERC-7201 layout (incl. the two new payee mappings); clone ownership; `data`
cannot redirect the recipient; route output token and chain binding; decimals (incl. 18-dec BSC
USDT); allowances cleared; exact-amount check; refunds to the vault; `bridgeTo` metering; payee
delay, id reuse, lock epochs; one-network payees never paid locally.

## Design note: market trading with NO_LIMIT
A vault whose loss allowance is NO_LIMIT (the default for new vaults since 1.1.1) already trades
without the 5% oracle bound and without a Chainlink feed: `_settleMarketTrade` returns before any
pricing, and the guard returns an empty feed rather than reverting. What is still required: both
tokens carry `ASSET_AMM_LIQUID` in the guard, the bought token is registered, the protocol is a live
market-trade protocol, and the allowance is not 0. The owner's only price protection is then the
`buyAmountMin` / `sellAmountMax` the app sets from its quote.
