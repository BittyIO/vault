.PHONY: ci ci-submodules build test size fmt build-deploy lib-addr sync-libs sync-constants predict initcode initcodehash deploy verify mine-salt

CHAIN            ?= sepolia
CONSTANTS        := src/logic/Constants.sol
DEPLOY           := script/Deploy.s.sol
TOML             := deployments/$(CHAIN).toml
CREATE2_FACTORY  := 0x0000000000FFe8B47B3e2130213B802212439497

# Compile everything (src, test, script) — catches all errors.
build:
	forge build

# Run the local + fork test suites.
test:
	forge test -vvv

# EIP-170 deploy-size gate. The test-only BittyV1VaultHarness is `abstract`, so it is
# excluded automatically (abstract contracts have no standalone bytecode). Every
# deployable contract is size-checked.
size:
	forge build --sizes

fmt:
	forge fmt --check

# ---------------------------------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------------------------------

# The bytecode a deploy actually ships. The `deploy` profile pins the logic library addresses and
# drops metadata; the default profile does neither, so the same source builds to different bytecode
# and therefore different CREATE2 addresses. Everything below this line uses out-deploy/ for that
# reason - mixing the two is how a salt gets mined against bytecode nobody deploys.
#
# Build chatter goes to stderr so `make initcode` stays pipeable into a miner.
build-deploy:
	@FOUNDRY_PROFILE=deploy forge build 1>&2

# Re-pin the logic library addresses in foundry.toml [profile.deploy] to what their own init code
# gives, resolving VaultLogic before AssetManagerLogic because the latter links the former. Run after
# ANY change to either library - a stale pin silently invalidates every implementation salt.
sync-libs:
	@script/sync-libs.sh

# The same addresses derived independently, in Solidity, as a cross-check on the above.
lib-addr: build-deploy
	FOUNDRY_PROFILE=deploy forge test --match-path test/local/LibAddr.t.sol -vv


# The vault hardcodes BITTY_FORWARDER, but that address is DERIVED — CREATE2 over the forwarder's
# bytecode and salt — so it must never be maintained by hand. This recomputes it and rewrites the
# constant if it has drifted, then rebuilds.
#
# The salt is read from the deploy script, which is where deploy-time data belongs; Constants.sol only
# holds addresses the production contracts actually read.
#
# There is no circularity to worry about: the forwarder imports nothing from Constants.sol, so editing
# the constant cannot change the forwarder's bytecode, and the value converges in one pass. The
# rebuild only changes the vault side, which is what needs to see the new address.
sync-constants: sync-libs build-deploy
	@set -e; \
	salt=$$(grep -oE 'FORWARDER_SALT = 0x[0-9a-fA-F]{64}' $(DEPLOY) | grep -oE '0x[0-9a-fA-F]{64}'); \
	init=$$(jq -r '.bytecode.object' out-deploy/BittyV1VaultForwarder.sol/BittyV1VaultForwarder.json); \
	hashed=$$(cast keccak $$init); \
	preimage=$$(cast concat-hex 0xff $(CREATE2_FACTORY) $$salt $$hashed); \
	want=$$(cast to-check-sum-address 0x$$(cast keccak $$preimage | cut -c27-)); \
	have=$$(grep -oE 'BITTY_FORWARDER = 0x[0-9a-fA-F]{40}' $(CONSTANTS) | grep -oE '0x[0-9a-fA-F]{40}'); \
	if [ "$$want" = "$$have" ]; then \
		echo "BITTY_FORWARDER up to date: $$want"; \
	else \
		echo "BITTY_FORWARDER $$have -> $$want"; \
		sed "s/$$have/$$want/" $(CONSTANTS) > $(CONSTANTS).tmp && mv $(CONSTANTS).tmp $(CONSTANTS); \
		FOUNDRY_PROFILE=deploy forge build 1>&2; \
	fi

# Every CREATE2 address the next deploy will produce, computed from build artifacts.
#
# Not a forge test: only the `deploy` profile produces the bytecode a broadcast actually deploys, and
# `forge test` under that profile still cannot show the whole picture, because the implementation's
# constructor arguments are the facet and keeper ADDRESSES - which are themselves CREATE2 results.
# This resolves the chain in order and reports the whole stack.
#   make predict CHAIN=sepolia               addresses, init code lengths and hashes, drift checks
#   make predict CHAIN=sepolia INITCODE=1    the same, plus the raw implementation init code hex
predict: build-deploy
	@script/predict.sh $(CHAIN) $(if $(INITCODE),--init-code,)

# Just the init code hex for one contract, nothing else - pipe it straight into a salt miner.
#   make initcode                              # BittyV1Vault, i.e. the implementation
#   make initcode CONTRACT=BittyV1VaultFactory
CONTRACT ?= BittyV1Vault
initcode: build-deploy
	@script/predict.sh $(CHAIN) --only $(CONTRACT)

# The same thing hashed, which is what a CREATE2 miner actually takes.
#   make initcodehash                              # BittyV1Vault, i.e. the implementation
#   make initcodehash CONTRACT=BittyV1VaultForwarder
initcodehash: build-deploy
	@script/predict.sh $(CHAIN) --hash $(CONTRACT)

# Whole stack, in dependency order, with the constant synced first. Broadcasting key must be the
# DEPLOYER — both forwarder.initialize and factory.initialize gate on tx.origin.
#   make deploy CHAIN=sepolia
deploy: sync-constants
	FOUNDRY_PROFILE=deploy forge script script/Deploy.s.sol:Deploy \
		--rpc-url $(CHAIN) \
		--broadcast \
		--private-key $$SEPOLIA_PRIVATE_KEY \
		-vvvv

# Verify every deployed contract, reading addresses back from the chain TOML the deploy just wrote —
# except the forwarder, which is not in the TOML because it is a compile-time constant, so it comes
# from Constants.sol.
#
# The libraries are passed explicitly because linked library addresses are part of the bytecode.
#
# Under the `deploy` profile, since that is what produced the deployed bytecode. It does NOT drop
# metadata: the deployed contracts carry the trailer, and the CREATE2 addresses were derived from
# init code that includes it (see the note in foundry.toml).
#
# FOUNDRY_PROFILE is exported rather than prefixed onto $$V: an assignment written inside a variable
# is not treated as an assignment once the variable is expanded, so `sh` looked for a command
# literally named "FOUNDRY_PROFILE=deploy" and failed with 127.
verify:
	@set -e; \
	addr() { grep -oE "^$$1 = \"0x[0-9a-fA-F]{40}\"" $(TOML) | grep -oE '0x[0-9a-fA-F]{40}'; }; \
	VL=$$(addr VAULT_LOGIC); AML=$$(addr ASSET_MANAGER_LOGIC); \
	IMPL=$$(addr VAULT_IMPLEMENTATION); FACET=$$(addr DEFI_FACET); \
	FACTORY=$$(addr BITTY_VAULT_FACTORY); \
	FWD=$$(grep -oE 'BITTY_FORWARDER = 0x[0-9a-fA-F]{40}' $(CONSTANTS) | grep -oE '0x[0-9a-fA-F]{40}'); \
	KEEPER=$$(addr BITTY_AUTO_YIELD_KEEPER); OWNER=$$(addr BITTY_FORWARDER_OWNER); \
	LIBS="--libraries src/logic/VaultLogic.sol:VaultLogic:$$VL --libraries src/logic/AssetManagerLogic.sol:AssetManagerLogic:$$AML"; \
	export FOUNDRY_PROFILE=deploy; \
	V="forge verify-contract --chain $(CHAIN) --etherscan-api-key $$ETHERSCAN_API_KEY --watch"; \
	$$V $$VL      src/logic/VaultLogic.sol:VaultLogic; \
	$$V $$AML     src/logic/AssetManagerLogic.sol:AssetManagerLogic --libraries src/logic/VaultLogic.sol:VaultLogic:$$VL; \
	$$V $$FACET   src/BittyV1VaultDeFiFacet.sol:BittyV1VaultDeFiFacet $$LIBS; \
	$$V $$IMPL    src/BittyV1Vault.sol:BittyV1Vault $$LIBS \
		--constructor-args $$(cast abi-encode "constructor(address,address)" $$FACET $$KEEPER); \
	$$V $$FACTORY src/BittyV1VaultFactory.sol:BittyV1VaultFactory; \
	$$V $$FWD     src/BittyV1VaultForwarder.sol:BittyV1VaultForwarder; \
	$$V $$KEEPER  src/BittyV1AutoYieldKeeper.sol:BittyV1AutoYieldKeeper \
		--constructor-args $$(cast abi-encode "constructor(address)" $$OWNER)

# ---------------------------------------------------------------------------------------------------
# CI parity
# ---------------------------------------------------------------------------------------------------

# Run exactly what .github/workflows/test.yml runs, in the same order, under the same profile.
#
# `forge test` on the default profile is only ONE of four gates, which is how a red CI can follow a
# green local run. Coverage especially: it compiles with the optimizer OFF, a different compilation
# from every other target here, and the only one that surfaces stack-too-deep.
#
# Keep in step with the workflow - if a step is added there, add it here.
ci: ci-submodules
	@set -e; \
	echo "==> forge fmt --check";   FOUNDRY_PROFILE=ci forge fmt --check; \
	echo "==> forge build --sizes"; FOUNDRY_PROFILE=ci forge build --sizes >/dev/null; \
	echo "==> forge test";          FOUNDRY_PROFILE=ci forge test | tail -2; \
	echo "==> forge coverage";      FOUNDRY_PROFILE=ci forge coverage --ir-minimum \
		--no-match-coverage 'test|node_modules|script|src/libs' --report lcov >/dev/null; \
	echo "==> all CI gates passed"

# What CI will actually check out, which is NOT your working tree.
#
# CI clones the submodule commit RECORDED IN GIT and fetches it from the remote, so local edits inside
# a submodule are invisible to it and a commit that exists only here fails the checkout outright
# ("not our ref"). Both have cost a red build: uncommitted interface edits the recorded commit lacked,
# and a pointer bumped to an unpushed commit.
#
# --ignore-submodules=dirty: a NESTED submodule with a scruffy work tree is not a reproducibility
# problem, because only its recorded commit is ever checked out. Flagging it would cry wolf on a
# state CI cannot observe.
ci-submodules:
	@set -e; \
	fail=0; \
	for m in $$(git config -f .gitmodules --get-regexp path | awk '{print $$2}'); do \
		dirty=$$(git -C $$m status --porcelain --ignore-submodules=dirty 2>/dev/null | wc -l | tr -d ' '); \
		want=$$(git ls-tree HEAD $$m | awk '{print $$3}'); \
		have=$$(git -C $$m rev-parse HEAD 2>/dev/null); \
		url=$$(git config -f .gitmodules --get submodule.$$m.url); \
		if [ "$$dirty" != "0" ]; then \
			echo "  DIRTY     $$m ($$dirty file(s)) - CI will not see these edits"; fail=1; \
		elif [ "$$want" != "$$have" ]; then \
			echo "  DRIFTED   $$m - recorded $$want, checked out $$have"; fail=1; \
		elif [ -z "$$(git ls-remote $$url 2>/dev/null | grep $$want)" ]; then \
			echo "  UNPUSHED  $$m@$$want not on $$url - CI cannot fetch it"; fail=1; \
		else echo "  ok        $$m@$$(echo $$want | cut -c1-8)"; fi; \
	done; \
	[ $$fail -eq 0 ] || { echo "==> submodules would not reproduce on CI"; exit 1; }
