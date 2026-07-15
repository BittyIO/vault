.PHONY: build test size

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
