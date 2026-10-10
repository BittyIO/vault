// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {ERC2771Forwarder} from "openzeppelin-contracts/contracts/metatx/ERC2771Forwarder.sol";
import {ERC2771Context} from "openzeppelin-contracts/contracts/metatx/ERC2771Context.sol";
import {Address} from "openzeppelin-contracts/contracts/utils/Address.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {SignatureChecker} from "openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IBittyV1Vault} from "./interfaces/IBittyV1Vault.sol";
import {IBittyV1Guard} from "guard-contracts/src/interfaces/IBittyV1Guard.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {BITTY_GUARD, CFG_OWNER} from "./logic/Constants.sol";

/**
 * @dev The forwarder must have no constructor arguments — they would be appended to the init code and
 *      give it a different address on every chain, the one property the whole deployment depends on. Its
 *      admin (who may approve relayers and authorize upgrades) is therefore not stored or set at init;
 *      {owner} reads it from the guard config, so there is no per-forwarder owner to squat on a fresh
 *      chain and rotating it is one guard config change, fleet-wide.
 */
contract BittyV1VaultForwarder is ERC2771Forwarder, UUPSUpgradeable {
    error FeeExceedsVaultBudget();
    error NotApprovedRelayer();
    error EmptyBatch();
    error BatchTargetMismatch();
    error NotOwner();
    error BatchNotSupported();
    error PayRelayerFeeNotRelayable();
    event RelayerApprovalSet(address indexed relayer, bool approved);

    /**
     * @dev Plain {execute} stays permissionless, as ERC-2771 intends: anyone may relay a signed request
     *      at their own expense. Charging one, however, is restricted — otherwise a bystander could
     *      lift a signed request out of the mempool, submit it themselves with the maximum allowed fee,
     *      and burn the owner's daily budget for no reason.
     */
    mapping(address relayer => bool approved) public approvedRelayers;

    /**
     * @dev The EIP-712 domain name. A literal, so it contributes to the bytecode rather than the init
     *      code arguments — and so it is identical everywhere, since changing it would invalidate
     *      every signature ever made for this forwarder.
     */
    constructor() ERC2771Forwarder("BittyV1VaultForwarder") {
        _disableInitializers();
    }

    /**
     * @dev The relayer-allowlist owner is the Bitty owner from the guard config — the only authority this
     *      contract has. Deliberately not a separate upgrade admin: an owner that can already decide who
     *      may charge a vault's gas budget is not made more powerful by also deciding the code.
     */
    function owner() public view returns (address) {
        return IBittyV1Guard(BITTY_GUARD).getAddress(CFG_OWNER);
    }

    modifier onlyOwner() {
        if (msg.sender != owner()) revert NotOwner();
        _;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /**
     * @dev Per-(signer, target) nonce sequences, replacing OpenZeppelin's single sequence per signer.
     *
     *      One flat sequence per signer is fine for a vault owner, who only ever signs for their own
     *      vault. It is not fine for the auto-yield keeper, which signs for every vault: all its sweeps
     *      would share one sequence, so they could not be relayed concurrently, and a single failing
     *      sweep would block every later-nonced one behind it — the nonce is rolled back on failure, so
     *      the queue stalls rather than skips.
     *
     *      Keying the lane on `request.to` gives one independent sequence per vault. It needs no change
     *      to the signed payload: the typehash and its fields are untouched, only the value substituted
     *      for `nonce` differs, so wallets and viem keep working. Callers read {nonceFor} instead of
     *      OpenZeppelin's `nonces`.
     */
    mapping(address signer => mapping(address target => uint64 seq)) private _laneNonce;

    /**
     * @dev OpenZeppelin consumes the nonce inside {_execute}, which only receives the signer — so the
     *      target is handed over in transient storage by {_execute} itself, from the request it is about
     *      to run, right before it calls {_useNonce}. Transient because it is meaningful for exactly the
     *      length of one call and must never survive it.
     */
    bytes32 private constant _NONCE_TARGET_SLOT = 0x8df4084eac8b84d2f835fdd215c47aed36ec12bae0062c9cfc227df184580f00; // keccak256("bitty.v1.forwarder.nonceTarget")

    /**
     * @notice The next nonce `signer` must sign for a request targeting `target`.
     */
    function nonceFor(address signer, address target) public view returns (uint64) {
        return _laneNonce[signer][target];
    }

    /**
     * @dev The CHARGE WINDOW: the vault this forwarder is settling a fee for, for the length of that
     *      one call and no longer.
     *
     *      It exists because `msg.sender == trustedForwarder()` cannot tell a settlement from a
     *      relayed user op — the forwarder is the caller for both. So the account could not
     *      distinguish "the forwarder is charging me" from "the forwarder is relaying something that
     *      calls me", and anything a relayed request could reach could reach the charge. Blocking the
     *      `payRelayerFee` selector, at the top level here and at every {multicall} layer in the
     *      account, closes the paths that are known; the window closes the question.
     *
     *      Transient, like {_NONCE_TARGET_SLOT}: it is meaningful for exactly the length of one call
     *      and must never survive it. Opened AFTER the relayed work has run and closed before the
     *      settlement returns, so no relayed calldata ever executes with it open — and even if an
     *      ERC-20 callback inside the charge re-entered {execute}, a relayed `payRelayerFee` is still
     *      refused by the selector guards, so the two defences do not depend on each other.
     */
    bytes32 private constant _CHARGING_SLOT = 0x118462e6d7d9c109e6aaaa07552c6f72e83745f9f6921f9ba4a142b4ad0e06a1; // keccak256("bitty.v1.forwarder.charging")

    /**
     * @notice The vault this forwarder is charging in this call, or the zero address.
     * @dev Read by the account from inside {IBittyV1Vault-payRelayerFee} — see {IBittyV1Forwarder}.
     */
    function chargingVault() external view returns (address vault) {
        assembly ("memory-safe") {
            vault := tload(_CHARGING_SLOT)
        }
    }

    /**
     * @dev Collect the fee with the window open for this vault, and shut it again. The only path to
     *      `payRelayerFee` in this contract: both settlement entry points go through here, so there
     *      is no second place that could charge with the window shut — which the account would
     *      refuse — or forget to shut it.
     */
    function _charge(address vault, address stableCoinAddress, uint256 fee) private {
        assembly ("memory-safe") {
            tstore(_CHARGING_SLOT, vault)
        }
        IBittyV1Vault(vault).payRelayerFee(stableCoinAddress, fee);
        assembly ("memory-safe") {
            tstore(_CHARGING_SLOT, 0)
        }
    }

    function _setNonceTarget(address target) private {
        assembly ("memory-safe") {
            tstore(_NONCE_TARGET_SLOT, target)
        }
    }

    /**
     * @dev Bumps the lane rather than the flat sequence. Reverts if {_execute} did not declare a target,
     *      so a path that forgets to declare one fails loudly instead of quietly sharing lane zero.
     */
    function _useNonce(address signer) internal virtual override returns (uint256) {
        address target;
        assembly ("memory-safe") {
            target := tload(_NONCE_TARGET_SLOT)
        }
        if (target == address(0)) revert BatchNotSupported();
        unchecked {
            return _laneNonce[signer][target]++;
        }
    }

    /**
     * @dev The inherited {execute} stays permissionless, as ERC-2771 intends: anyone may relay a signed
     *      request at their own expense. It needs no override — it routes through {_execute} below like
     *      every other entry point, so the nonce target and the `payRelayerFee` guard both still apply.
     *
     *      `payRelayerFee` is charged by the forwarder directly during a settlement, never relayed as a
     *      user op — relaying it would let anyone drain a vault's gas budget through {execute}. This
     *      selector check is now one of three layers, and the shallowest: the account rejects the same
     *      selector at every {multicall} layer, and the charge window (see {_CHARGING_SLOT}) refuses a
     *      charge that did not come from a settlement at all, whatever path found it.
     *
     *      The nonce target is bound here, from this request's own `to`, immediately before {_useNonce}
     *      consumes it inside `super._execute`. Doing it per request rather than once per entry point
     *      means a batch iteration can never inherit a target left behind by a reentrant call.
     */
    function _execute(ForwardRequestData calldata request, bool requireValidRequest)
        internal
        virtual
        override
        returns (bool)
    {
        if (request.data.length >= 4 && bytes4(request.data[:4]) == IBittyV1Vault.payRelayerFee.selector) {
            revert PayRelayerFeeNotRelayable();
        }
        _setNonceTarget(request.to);
        return super._execute(request, requireValidRequest);
    }

    /**
     * @notice Not supported — use {executeBatchWithFee}.
     * @dev OpenZeppelin's batch is non-atomic, so a partial failure would leave some requests executed
     *      and others not. {executeBatchWithFee} is atomic and single-target, which is also what lets it
     *      declare a nonce target per request.
     */
    function executeBatch(ForwardRequestData[] calldata, address payable) public payable virtual override {
        revert BatchNotSupported();
    }

    function setRelayerApproval(address relayer, bool approved) external onlyOwner {
        approvedRelayers[relayer] = approved;
        emit RelayerApprovalSet(relayer, approved);
    }

    /**
     * @notice Relay a signed request and reclaim `fee` of `stableCoinAddress` from the target vault.
     * @dev Charging AFTER the call, so a request that reverts costs the vault nothing. The budget is
     *      checked BEFORE it, so a relay that could never be paid for fails while it is still cheap
     *      instead of after the work is done.
     * @param request The owner- or asset-manager-signed ForwardRequest.
     * @param stableCoinAddress A stablecoin registered on the target vault.
     * @param fee Amount to reclaim, in `stableCoinAddress` units. 0 relays without charging.
     */
    function executeWithFee(ForwardRequestData calldata request, address stableCoinAddress, uint256 fee)
        external
        payable
        virtual
    {
        if (!approvedRelayers[msg.sender]) revert NotApprovedRelayer();
        if (msg.value != request.value) {
            revert ERC2771ForwarderMismatchedValue(request.value, msg.value);
        }
        if (fee != 0) _checkVaultBudget(request.to, stableCoinAddress, fee);

        if (!_execute(request, true)) {
            revert Address.FailedInnerCall();
        }

        if (fee != 0) {
            _charge(request.to, stableCoinAddress, fee);
        }
    }

    /**
     * @notice Relay several signed requests for ONE vault and charge a single fee for the lot.
     * @dev The reason to prefer this over repeated {executeWithFee}: each separate relay pays the
     *      21,000-gas transaction floor, the signature machinery and — the big one — a fresh ERC-20
     *      transfer plus budget write to collect its fee. Batching pays the floor once and collects
     *      once, so three settings changes cost far less than three relays of one change each.
     *
     *      Every request must target the same `vault`, since the fee is charged there and the budget
     *      is per-vault. They need not share a signer: an owner's change and a sub owner's trade can
     *      ride together, each proven by its own signature.
     *
     *      Atomic. OZ's non-atomic mode exists to refund unspent ETH on partial failure, which cannot
     *      arise here — these requests carry no value — and partial success would leave the owner
     *      charged for work that did not happen.
     * @param requests Signed requests, all with `to` equal to `vault`.
     * @param vault The target vault, charged once for the whole batch.
     * @param stableCoinAddress A stable coin the vault's owner listed for gas.
     * @param fee Total to reclaim for the batch. 0 relays without charging.
     */
    function executeBatchWithFee(
        ForwardRequestData[] calldata requests,
        address vault,
        address stableCoinAddress,
        uint256 fee
    ) external virtual {
        if (!approvedRelayers[msg.sender]) revert NotApprovedRelayer();
        if (requests.length == 0) revert EmptyBatch();

        for (uint256 i; i < requests.length; ++i) {
            if (requests[i].to != vault) revert BatchTargetMismatch();
            if (requests[i].value != 0) revert ERC2771ForwarderMismatchedValue(requests[i].value, 0);
        }

        if (fee != 0) _checkVaultBudget(vault, stableCoinAddress, fee);

        for (uint256 i; i < requests.length; ++i) {
            if (!_execute(requests[i], true)) {
                revert Address.FailedInnerCall();
            }
        }

        if (fee != 0) {
            _charge(vault, stableCoinAddress, fee);
        }
    }

    /**
     * @dev The vault reports its remaining allowance as an 18-decimal whole-token value, so the raw
     *      amount is normalised the same way the vault normalises it. Ceil to match, otherwise a fee
     *      could pass here and be rejected a few thousand gas later.
     */
    function _checkVaultBudget(address vault, address stableCoinAddress, uint256 fee) private view {
        uint256 normalised =
            Math.mulDiv(fee, 1e18, 10 ** IERC20Metadata(stableCoinAddress).decimals(), Math.Rounding.Ceil);
        if (normalised > IBittyV1Vault(vault).gasBudgetRemaining()) revert FeeExceedsVaultBudget();
    }

    /**
     * @dev Accept ERC-1271 signatures as well as ECDSA ones, so a vault owned by a contract wallet can
     *      actually be relayed.
     *
     *      OpenZeppelin's version RECOVERS an address from the signature and compares it to
     *      `request.from`. That can only ever work for an EOA: a Safe's signature is a concatenation of
     *      its owners' signatures, and there is no single address to recover from it — `tryRecover`
     *      returns a length error and the request is rejected as {ERC2771ForwarderInvalidSigner}.
     *      {BittyV1VaultFactory} already onboards contract-wallet owners through {SignatureChecker}, so
     *      without this a Safe-owned vault is activated gaslessly and then can never be relayed again.
     *
     *      The formulation inverts: `request.from` is ASSERTED and the signature is checked against it,
     *      rather than derived from the signature. {SignatureChecker} is therefore the only thing binding
     *      the two together — treat its result as load-bearing. It tries ECDSA first, so the EOA path is
     *      unchanged, and falls back to a staticcall of `isValidSignature`; against an address with no
     *      code that returns empty data and fails the magic-value check, so a bad EOA signature cannot
     *      slip through the ERC-1271 branch.
     *
     *      Everything downstream is untouched: {_execute} still burns `_useNonce(request.from)` — the
     *      same nonce that went into the digest — and still appends `request.from` as the ERC-2771
     *      suffix, which is what the vault reads as `_msgSender()`.
     *
     *      NOTE: contract signatures are revocable, so validity can change between a relayer simulating
     *      a request and it landing (a Safe rotating owners, say). That surfaces as a reverted relay,
     *      which the relayer pays for — re-simulate close to submission.
     *
     *      NOTE: the `signer` returned is `request.from` rather than a recovered address, so a rejected
     *      request reports {ERC2771ForwarderInvalidSigner} with both arguments equal. There is nothing
     *      more informative to report when nothing was recovered.
     */
    function _validate(ForwardRequestData calldata request)
        internal
        view
        virtual
        override
        returns (bool isTrustedForwarder, bool active, bool signerMatch, address signer)
    {
        return (
            _targetTrustsThisForwarder(request.to),
            request.deadline >= block.timestamp,
            SignatureChecker.isValidSignatureNow(request.from, _forwardRequestDigest(request), request.signature),
            request.from
        );
    }

    /**
     * @dev The EIP-712 digest OpenZeppelin's {_recoverForwardRequestSigner} builds, extracted so the
     *      override above can hash without recovering. Must stay byte-identical to it — including
     *      reading the CURRENT `nonces(request.from)` — or every signature ever produced for this
     *      forwarder stops verifying.
     */
    function _forwardRequestDigest(ForwardRequestData calldata request) private view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    _FORWARD_REQUEST_TYPEHASH,
                    request.from,
                    request.to,
                    request.value,
                    request.gas,
                    _laneNonce[request.from][request.to],
                    request.deadline,
                    keccak256(request.data)
                )
            )
        );
    }

    /**
     * @dev OpenZeppelin's `_isTrustedByTarget` is private, so it is reproduced here with the same
     *      tolerant semantics: a raw staticcall, and any non-zero word counts as true. Targets without
     *      code return empty data and read as false rather than reverting.
     */
    function _targetTrustsThisForwarder(address target) private view returns (bool) {
        (bool success, bytes memory returnData) =
            target.staticcall(abi.encodeCall(ERC2771Context.isTrustedForwarder, (address(this))));
        return success && returnData.length >= 32 && abi.decode(returnData, (uint256)) != 0;
    }
}
