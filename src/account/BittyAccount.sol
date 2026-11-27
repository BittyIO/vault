// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IPriceFeed {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IRelayerSource {
    function relayer() external view returns (address);
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
}

/**
 * @title BittyAccount
 * @notice A smart contract account for one user's USDT, with the protections a leaked key needs:
 *
 *          - **Payees.** Addresses the owner adds, which become payable once the timelock has passed.
 *            A payee can be paid any amount, at any time, even while the account is locked: it is the
 *            owner's way out after a key leaks. Removing one that is already payable waits out the
 *            timelock too, so a thief cannot strip the way out first.
 *          - **A daily limit**, in USDT, on sends to anyone who is not a payee (UTC days).
 *          - **The relayer's fee.** USDT to the relayer (the factory's, which its owner can change:
 *            {relayer}) skips the payee, lock and daily-limit rules, so a relayed send always pays for
 *            itself, locked or not. It has its own cap instead, {RELAYER_DAILY_CAP} a UTC day, which is
 *            all a leaked key can push there.
 *          - **TRX goes to payees only** ({sendTrx}), any amount, locked or not, outside the daily
 *            limit. TRX to anyone else is a queued call like any other.
 *          - **Staking TRX for energy** ({stakeTrx}, {unstakeTrx}, {withdrawUnstaked}): the TRX stays
 *            in the account, frozen, and comes back to it. Its energy is delegated ({delegateEnergy})
 *            to the owner key or a payee at once, to anyone else (a relayer) only after the timelock:
 *            the account itself never sends a transaction, so energy left on it is wasted.
 *          - **Swaps between TRX and USDT** on SunSwap ({swapTrxForUsdt}, {swapUsdtForTrx}), into
 *            the account only, for a {SWAP_FEE_BPS} fee paid in TRX. What a swap gets below the TRX/USD
 *            price feed counts toward the daily limit, so a thief cannot drain the account through a
 *            bad-price swap either.
 *          - **A lock**, instant. While locked only payees can be paid; nothing waiting to happen
 *            (a payee being added or removed, a queued call) ever happens; unlocking waits out the
 *            timelock, and locking again cancels that wait.
 *          - **A timelock** on everything that loosens any of the above: a raised limit, a shorter
 *            timelock, a new owner key, and any call other than a USDT send (an approval, any other
 *            contract, TRX). Those are queued and run only after the timelock, if no lock lands first.
 *            Tightening (a lower limit, a longer timelock, a lock) is instant.
 *
 *         Sends are made by the owner key itself ({execute}) or signed by it and sent by anyone, a
 *         relayer ({executeSigned}), so the key never needs TRX. Both run a batch of calls: a USDT send
 *         is the call `sendUsdt` on the account itself; any call to another address is the "other
 *         call" above and needs the timelock (none is needed while the timelock is 0).
 *
 *         What it cannot stop: a thief holding the key can send up to the daily limit each day, and
 *         can lock the account (the owner can still pay payees). The owner's answer is the same as in
 *         the Bitty vault: lock, then move the money to a payee.
 *
 *         A new account starts with no protection: timelock 0, no limit, no payees, which behaves like
 *         a normal account. The owner turns it on (add payees, set a limit, raise the timelock), all
 *         instant from there.
 *
 * @dev An EIP-1167 clone made by {BittyAccountFactory}, which creates and initializes it in the same
 *      transaction. USDT is fixed per factory (an immutable of the implementation).
 *
 *      Locks are counted by {lockEpoch}; {lockedAt} records when each began. Anything queued records the
 *      epoch it was queued in, and counts only if it came due before the next lock began. So a lock
 *      cancels everything still waiting, and nothing already due.
 */
contract BittyAccount is EIP712 {
    struct Call {
        address to;
        uint256 value;
        bytes data;
    }

    struct Payee {
        uint64 readyAt; // payable from then; 0 = not a payee
        uint64 removeAt; // stops being one then; 0 = no removal queued
        uint32 addEpoch;
        uint32 removeEpoch;
    }

    struct Queued {
        uint64 readyAt;
        uint32 epoch;
    }

    bytes32 private constant CALL_TYPEHASH = keccak256("Call(address to,uint256 value,bytes data)");
    bytes32 private constant EXECUTE_TYPEHASH =
        keccak256("Execute(Call[] calls,uint256 nonce,uint256 deadline)Call(address to,uint256 value,bytes data)");
    /// TRON's resource code for energy.
    uint256 private constant ENERGY = 1;
    /// USDT the relayer can be paid per UTC day (6 decimals: 1,000 USDT).
    uint256 public constant RELAYER_DAILY_CAP = 1_000e6;
    /// Bitty's swap fee, 0.2%, to the relayer, always in TRX (a TRX transfer costs no USDT energy): from the TRX sold,
    /// or from the TRX bought.
    uint256 public constant SWAP_FEE_BPS = 20;
    /// How a route arrives (as the Bitty API builds it for the vault's SunSwap adapter):
    /// TAG ‖ abi.encode(commands, inputs, deadline).
    bytes4 private constant ROUTE_TAG = bytes4(keccak256("bitty.uniswap.universal-route"));

    /// What one factory's accounts are built against, fixed for all of them.
    struct Config {
        address usdt; // 6 decimals
        address stakeOps; // TronStakeOps: TRON's Stake 2.0 opcodes, delegatecalled
        address router; // SunSwap's Universal Router
        address permit2; // SunSwap's Permit2, how the router pulls USDT
        address trxUsdFeed; // a Chainlink-style TRX/USD feed (WINkLink on TRON)
        uint32 feedMaxAge; // seconds; an older price stops swaps (never sends)
        uint8 feedDecimals;
        // TRON's USDT (mainnet and Nile) returns false from `transfer` even when it succeeds, and reverts
        // on every failure, so there its return value says nothing. True: a transfer that did not revert
        // succeeded. False: a false return is a failure (the ERC-20 rule, for any other token).
        bool usdtFalseIsSuccess;
    }

    /// The one token this account sends without a timelock.
    address public immutable usdt;
    /// The factory that made this implementation; it names the relayer.
    address public immutable factory;
    address public immutable stakeOps;
    address public immutable router;
    address public immutable permit2;
    address public immutable trxUsdFeed;
    uint32 public immutable feedMaxAge;
    uint8 public immutable feedDecimals;
    bool public immutable usdtFalseIsSuccess;

    // slot 0
    address public owner;
    bool public locked;
    uint32 public timelock; // seconds
    uint32 public relayerPaidToday; // USDT to the relayer on relayerPaidDay
    uint24 public relayerPaidDay; // UTC day
    // slot 1: the daily limit, packed so a send reads and writes one slot
    uint96 private _limit; // limit + 1; 0 = no limit
    uint96 public spentToday;
    uint32 public spentDay; // UTC day of spentToday
    uint32 public lockEpoch;
    // slot 2
    address public pendingOwner;
    uint64 public unlockAt;
    /// The next signed batch's number; each one is used once, in order.
    uint256 public nonce;

    mapping(uint32 epoch => uint64) public lockedAt;
    mapping(address => Payee) private _payees;
    mapping(bytes32 => Queued) private _queued;
    bool private transient _inQueued;

    event Executed(uint256 indexed nonce, uint256 calls);
    event SentUsdt(address indexed to, uint256 amount, bool toPayee);
    event SentTrx(address indexed to, uint256 amount);
    event PayeeAdded(address indexed payee, uint256 readyAt);
    event PayeeRemoved(address indexed payee, uint256 removeAt);
    event Locked(uint32 epoch);
    event UnlockRequested(uint256 unlockAt);
    event Unlocked();
    event CallsQueued(bytes32 indexed id, uint256 readyAt);
    event QueuedCancelled(bytes32 indexed id);
    event QueuedExecuted(bytes32 indexed id);
    event DailyLimitSet(uint256 limit, bool unlimited);
    event TimelockSet(uint256 timelock);
    event Staked(uint256 amount);
    event Unstaked(uint256 amount);
    event UnstakedWithdrawn(uint256 amount);
    event EnergyDelegated(address indexed receiver, uint256 stake);
    event EnergyUndelegated(address indexed receiver, uint256 stake);
    /// `loss`: USDT below the feed price, counted toward the daily limit (0 with no limit).
    event Swapped(bool trxToUsdt, uint256 spent, uint256 received, uint256 fee, uint256 loss);
    event OwnershipProposed(address indexed current, address indexed proposed);
    event OwnershipTransferred(address indexed previous, address indexed current);

    error AlreadyInitialized();
    error NotOwner();
    error NotPendingOwner();
    error InvalidAddress();
    error InvalidLimit();
    error Expired();
    error BadSignature();
    error CallFailed(uint256 index, bytes reason);
    error UsdtTransferFailed(bytes reason);
    error AccountLocked();
    error NotLocked();
    error OverDailyLimit(uint256 left);
    error OverRelayerCap(uint256 left);
    /// Loosening a protection, or a call other than a USDT send: queue it ({queue}) and run it after the timelock.
    error NeedsTimelock();
    error NotReady();
    error AlreadyPayee();
    error NotAPayee();
    error TrxTransferFailed(bytes reason);
    error StakeOpFailed();
    error NotARoute();
    error InsufficientOutput(uint256 received);
    error PriceStale();
    error SwapWentWrong();

    constructor(Config memory c) EIP712("Bitty Account", "1") {
        usdt = c.usdt;
        factory = msg.sender;
        stakeOps = c.stakeOps;
        router = c.router;
        permit2 = c.permit2;
        trxUsdFeed = c.trxUsdFeed;
        feedMaxAge = c.feedMaxAge;
        feedDecimals = c.feedDecimals;
        usdtFalseIsSuccess = c.usdtFalseIsSuccess;
        owner = address(this); // the implementation can never be initialized
    }

    /// The owner itself, or the account calling itself from a batch the owner sent or signed.
    modifier onlyOwnerOrSelf() {
        if (msg.sender != owner && msg.sender != address(this)) revert NotOwner();
        _;
    }

    function initialize(address owner_) external {
        if (owner != address(0)) revert AlreadyInitialized();
        if (owner_ == address(0)) revert InvalidAddress();
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

    receive() external payable {}

    // ------------------------------------------------------------------ running batches

    /// The owner sends it: run `calls` in order, all or nothing.
    function execute(Call[] calldata calls) external onlyOwnerOrSelf returns (bytes[] memory results) {
        results = _run(calls);
        emit Executed(type(uint256).max, calls.length);
    }

    /**
     * Anyone sends it; the owner signed it (EIP-712 over the calls, this account's {nonce} and
     * `deadline`, under this account's address and chain), so it works once, here, before `deadline`.
     */
    function executeSigned(Call[] calldata calls, uint256 deadline, bytes calldata signature)
        external
        returns (bytes[] memory results)
    {
        if (block.timestamp > deadline) revert Expired();
        uint256 n = nonce;
        if (ECDSA.recover(_hashTypedDataV4(_executeHash(calls, n, deadline)), signature) != owner) {
            revert BadSignature();
        }
        nonce = n + 1;
        results = _run(calls);
        emit Executed(n, calls.length);
    }

    function executeDigest(Call[] calldata calls, uint256 nonce_, uint256 deadline) external view returns (bytes32) {
        return _hashTypedDataV4(_executeHash(calls, nonce_, deadline));
    }

    // ------------------------------------------------------------------ USDT

    /**
     * Send USDT. To a payable payee: any amount, locked or not. To anyone else: only unlocked, and
     * within what is left of today's limit.
     */
    function sendUsdt(address to, uint256 amount) external onlyOwnerOrSelf {
        bool toPayee;
        uint96 limit = _limit;
        if (locked || limit != 0) {
            toPayee = _isPayee(to);
            if (!toPayee) {
                // Only a send the rules would hold back asks the factory who the relayer is.
                if (to == relayer()) return _payRelayer(to, amount);
                if (locked) revert AccountLocked();
                _spend(limit, amount);
            }
        }
        _transferUsdt(to, amount);
        emit SentUsdt(to, amount, toPayee);
    }

    /// The relayer's fee: no payee, lock or daily-limit check, only its own cap per UTC day.
    function _payRelayer(address to, uint256 amount) private {
        uint24 today = uint24(_today());
        uint256 paid = relayerPaidDay == today ? relayerPaidToday : 0;
        if (paid + amount > RELAYER_DAILY_CAP) revert OverRelayerCap(RELAYER_DAILY_CAP - paid);
        relayerPaidToday = uint32(paid + amount);
        relayerPaidDay = today;
        _transferUsdt(to, amount);
        emit SentUsdt(to, amount, false);
    }

    /// Who relayed batches pay, and who gets the swap fee: the factory owner's choice.
    function relayer() public view returns (address) {
        return IRelayerSource(factory).relayer();
    }

    /// Send TRX (in sun) to a payable payee: any amount, locked or not. Never to anyone else.
    function sendTrx(address payable to, uint256 amount) external onlyOwnerOrSelf {
        if (!_isPayee(to)) revert NotAPayee();
        (bool ok, bytes memory ret) = to.call{value: amount}("");
        if (!ok) revert TrxTransferFailed(ret);
        emit SentTrx(to, amount);
    }

    /// What can still go to non-payees today; type(uint256).max with no limit.
    function leftToday() external view returns (uint256) {
        uint96 stored = _limit;
        if (stored == 0) return type(uint256).max;
        uint256 spent = spentDay == _today() ? spentToday : 0;
        return stored - 1 > spent ? stored - 1 - spent : 0;
    }

    function dailyLimit() external view returns (uint256 limit, bool unlimited) {
        uint96 stored = _limit;
        return stored == 0 ? (0, true) : (stored - 1, false);
    }

    /// Lower the limit at once; raise it, or remove it, only through a queued call.
    function setDailyLimit(uint256 limit, bool unlimited) external onlyOwnerOrSelf {
        uint96 current = _limit;
        if (!unlimited && limit >= type(uint96).max) revert InvalidLimit();
        bool looser = unlimited ? current != 0 : (current != 0 && limit > current - 1);
        if (looser) _requireTimelockPassed();
        _limit = unlimited ? 0 : uint96(limit) + 1;
        emit DailyLimitSet(limit, unlimited);
    }

    // ------------------------------------------------------------------ payees

    /// Becomes payable after the timelock in force now, unless a lock lands first.
    function addPayee(address payee) external onlyOwnerOrSelf {
        if (locked) revert AccountLocked();
        if (payee == address(0) || payee == address(this)) revert InvalidAddress();
        if (_isPayee(payee)) revert AlreadyPayee();
        uint64 readyAt = uint64(block.timestamp) + timelock;
        _payees[payee] = Payee({readyAt: readyAt, removeAt: 0, addEpoch: lockEpoch, removeEpoch: 0});
        emit PayeeAdded(payee, readyAt);
    }

    /**
     * A payee that is payable stays so until the timelock passes (a lock cancels the removal); one
     * not payable yet goes at once.
     */
    function removePayee(address payee) external onlyOwnerOrSelf {
        if (locked) revert AccountLocked();
        uint32 t = timelock;
        if (!_isPayee(payee) || t == 0) {
            delete _payees[payee];
            emit PayeeRemoved(payee, block.timestamp);
            return;
        }
        Payee storage p = _payees[payee];
        uint64 removeAt = uint64(block.timestamp) + t;
        p.removeAt = removeAt;
        p.removeEpoch = lockEpoch;
        emit PayeeRemoved(payee, removeAt);
    }

    function isPayee(address payee) external view returns (bool) {
        return _isPayee(payee);
    }

    function payee(address p) external view returns (Payee memory) {
        return _payees[p];
    }

    // ------------------------------------------------------------------ lock

    /// Instant. Cancels everything waiting, and any unlock in progress.
    function lock() external onlyOwnerOrSelf {
        if (!locked) {
            uint32 epoch = lockEpoch + 1;
            lockEpoch = epoch;
            lockedAt[epoch] = uint64(block.timestamp);
            locked = true;
            emit Locked(epoch);
        }
        unlockAt = 0;
    }

    function requestUnlock() external onlyOwnerOrSelf {
        if (!locked) revert NotLocked();
        uint64 at = uint64(block.timestamp) + timelock;
        unlockAt = at;
        emit UnlockRequested(at);
    }

    function unlock() external onlyOwnerOrSelf {
        uint64 at = unlockAt;
        if (!locked || at == 0 || at > block.timestamp) revert NotReady();
        locked = false;
        unlockAt = 0;
        emit Unlocked();
    }

    // ------------------------------------------------------------------ timelock

    /// Longer at once; shorter only through a queued call.
    function setTimelock(uint32 seconds_) external onlyOwnerOrSelf {
        if (seconds_ < timelock) _requireTimelockPassed();
        timelock = seconds_;
        emit TimelockSet(seconds_);
    }

    /// The id a batch is queued under.
    function queuedId(Call[] calldata calls) public pure returns (bytes32) {
        return keccak256(abi.encode(calls));
    }

    function queued(bytes32 id) external view returns (Queued memory) {
        return _queued[id];
    }

    /// Queue `id` (= {queuedId} of a batch) to run after the timelock, unless a lock lands first.
    function queue(bytes32 id) external onlyOwnerOrSelf {
        if (locked) revert AccountLocked();
        uint64 readyAt = uint64(block.timestamp) + timelock;
        _queued[id] = Queued({readyAt: readyAt, epoch: lockEpoch});
        emit CallsQueued(id, readyAt);
    }

    function cancelQueued(bytes32 id) external onlyOwnerOrSelf {
        delete _queued[id];
        emit QueuedCancelled(id);
    }

    /// Run a queued batch whose timelock has passed. Anything it does counts as having waited.
    function executeQueued(Call[] calldata calls) external onlyOwnerOrSelf returns (bytes[] memory results) {
        if (locked) revert AccountLocked();
        bytes32 id = queuedId(calls);
        Queued memory q = _queued[id];
        if (q.readyAt == 0 || !_due(q.readyAt, q.epoch)) revert NotReady();
        delete _queued[id];
        _inQueued = true;
        results = _run(calls);
        _inQueued = false;
        emit QueuedExecuted(id);
    }

    // ------------------------------------------------------------------ the key

    /// Replacing the key is a loosening: queued, unless the timelock is 0.
    function proposeOwner(address proposed) external onlyOwnerOrSelf {
        _requireTimelockPassed();
        pendingOwner = proposed;
        emit OwnershipProposed(owner, proposed);
    }

    function acceptOwner() external {
        if (msg.sender != pendingOwner || msg.sender == address(0)) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    // ------------------------------------------------------------------ staking TRX for energy
    //
    // TRON keeps the books (frozen balance, delegations, unstakes in progress); the account keeps none,
    // so nothing here touches the storage a send uses. Every one is allowed while locked: none of them
    // moves TRX out of the account, and delegating to anyone but the owner or a payee still waits.

    /// Freeze `amount` sun of the account's TRX for energy.
    function stakeTrx(uint256 amount) external onlyOwnerOrSelf {
        if (_op(abi.encodeWithSelector(0x08bee6c4, amount, ENERGY)) != 1) revert StakeOpFailed();
        emit Staked(amount);
    }

    /// Start unfreezing `amount` sun (undelegate it first). It returns after TRON's unstake delay.
    function unstakeTrx(uint256 amount) external onlyOwnerOrSelf {
        if (_op(abi.encodeWithSelector(0x2fe36be5, amount, ENERGY)) != 1) revert StakeOpFailed();
        emit Unstaked(amount);
    }

    /// Take back into the account every unstake whose delay has passed.
    function withdrawUnstaked() external onlyOwnerOrSelf returns (uint256 released) {
        released = _op(abi.encodeWithSelector(0xa465bb19));
        emit UnstakedWithdrawn(released);
    }

    /// Lend the energy of `amount` sun of stake to `receiver`: the owner key or a payee at once,
    /// anyone else only after the timelock (and never while locked).
    function delegateEnergy(address receiver, uint256 amount) external onlyOwnerOrSelf {
        if (receiver != owner && !_isPayee(receiver)) {
            if (locked) revert AccountLocked();
            _requireTimelockPassed();
        }
        if (_op(abi.encodeWithSelector(0xf09cbeba, receiver, amount, ENERGY)) != 1) revert StakeOpFailed();
        emit EnergyDelegated(receiver, amount);
    }

    function undelegateEnergy(address receiver, uint256 amount) external onlyOwnerOrSelf {
        if (_op(abi.encodeWithSelector(0x11865b15, receiver, amount, ENERGY)) != 1) revert StakeOpFailed();
        emit EnergyUndelegated(receiver, amount);
    }

    function _op(bytes memory data) private returns (uint256) {
        (bool ok, bytes memory ret) = stakeOps.delegatecall(data);
        if (!ok || ret.length != 32) revert StakeOpFailed();
        return abi.decode(ret, (uint256));
    }

    // ------------------------------------------------------------------ swaps

    /// Swap `trxIn` sun for USDT on SunSwap, into this account; at least `minOut` USDT. The fee is
    /// {SWAP_FEE_BPS} of `trxIn`, so the route must sell `trxIn` less the fee.
    function swapTrxForUsdt(uint256 trxIn, uint256 minOut, bytes calldata route)
        external
        onlyOwnerOrSelf
        returns (uint256 received)
    {
        return _swap(true, trxIn, minOut, route);
    }

    /// Swap `usdtIn` USDT for TRX on SunSwap, into this account; at least `minOut` sun after the
    /// fee, which is {SWAP_FEE_BPS} of the TRX bought.
    function swapUsdtForTrx(uint256 usdtIn, uint256 minOut, bytes calldata route)
        external
        onlyOwnerOrSelf
        returns (uint256 received)
    {
        return _swap(false, usdtIn, minOut, route);
    }

    /**
     * @dev Judged by what the account's balances did, never by what the route says: the TRX and USDT
     *      that left, and what came in. Neither side may move the wrong way. With a daily limit, the
     *      value given up below the feed price (USDT terms) is spent from it, so even a route that
     *      sends the output elsewhere loses no more than the limit. The fee is not part of that
     *      count: it is measured on the swap itself, and goes only to the {relayer}.
     */
    function _swap(bool fromTrx, uint256 amountIn, uint256 minOut, bytes calldata route)
        private
        returns (uint256 received)
    {
        if (locked) revert AccountLocked();
        if (route.length < 4 || bytes4(route[:4]) != ROUTE_TAG) revert NotARoute();
        (bytes memory commands, bytes[] memory inputs, uint256 deadline) =
            abi.decode(route[4:], (bytes, bytes[], uint256));

        uint256 fee;
        if (fromTrx) {
            fee = amountIn * SWAP_FEE_BPS / 10_000;
            amountIn -= fee;
        }
        uint256 trxBefore = address(this).balance;
        uint256 usdtBefore = _usdtBalance();
        if (fromTrx) {
            IUniversalRouter(router).execute{value: amountIn}(commands, inputs, deadline);
        } else {
            _permit2Grant(amountIn);
            IUniversalRouter(router).execute(commands, inputs, deadline);
        }
        uint256 trxAfter = address(this).balance;
        uint256 usdtAfter = _usdtBalance();

        uint256 spent;
        uint256 worth;
        if (fromTrx) {
            if (usdtAfter < usdtBefore || trxAfter > trxBefore) revert SwapWentWrong();
            spent = trxBefore - trxAfter;
            received = usdtAfter - usdtBefore;
        } else {
            if (trxAfter < trxBefore || usdtAfter > usdtBefore) revert SwapWentWrong();
            spent = usdtBefore - usdtAfter;
            received = trxAfter - trxBefore;
        }

        uint256 loss;
        uint96 limit = _limit;
        if (limit != 0) {
            uint256 price = _trxPrice();
            if (fromTrx) {
                worth = spent * price / 10 ** feedDecimals;
                loss = worth > received ? worth - received : 0;
            } else {
                worth = received * price / 10 ** feedDecimals;
                loss = spent > worth ? spent - worth : 0;
            }
            if (loss != 0) _spend(limit, loss);
        }

        if (!fromTrx) {
            fee = received * SWAP_FEE_BPS / 10_000;
            received -= fee;
        }
        if (received < minOut) revert InsufficientOutput(received);
        if (fee != 0) {
            (bool ok, bytes memory ret) = relayer().call{value: fee}("");
            if (!ok) revert TrxTransferFailed(ret);
        }
        emit Swapped(fromTrx, spent, received, fee, loss);
    }

    /// USD per TRX from the feed, fresh or reverting: a stale price stops swaps, nothing else.
    function _trxPrice() private view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = IPriceFeed(trxUsdFeed).latestRoundData();
        if (answer <= 0 || block.timestamp > updatedAt + feedMaxAge) revert PriceStale();
        return uint256(answer);
    }

    /// The router pulls USDT through Permit2: a standing USDT allowance to Permit2 (once), then
    /// exactly this swap's amount to the router, for this block only.
    function _permit2Grant(uint256 amount) private {
        if (_usdtAllowance(permit2) < amount) {
            (bool ok, bytes memory ret) = usdt.call(abi.encodeWithSelector(0x095ea7b3, permit2, type(uint256).max));
            if (!ok) revert UsdtTransferFailed(ret);
        }
        IPermit2(permit2).approve(usdt, router, uint160(amount), 0);
    }

    function _usdtBalance() private view returns (uint256) {
        return IERC20Min(usdt).balanceOf(address(this));
    }

    function _usdtAllowance(address spender) private view returns (uint256) {
        return IERC20Min(usdt).allowance(address(this), spender);
    }

    // ------------------------------------------------------------------ internals

    /**
     * Calls to the account itself are its own functions, each checking its own rule. A call to any
     * other address can do anything (approve USDT, move another token, send TRX), so it needs the
     * timelock: only inside a queued batch, or while the timelock is 0, and never while locked.
     */
    function _run(Call[] calldata calls) private returns (bytes[] memory results) {
        results = new bytes[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            address to = calls[i].to;
            if (to != address(this)) {
                if (locked) revert AccountLocked();
                if (!_inQueued && timelock != 0) revert NeedsTimelock();
            }
            (bool ok, bytes memory ret) = to.call{value: calls[i].value}(calls[i].data);
            if (!ok) revert CallFailed(i, ret);
            results[i] = ret;
        }
    }

    function _requireTimelockPassed() private view {
        if (!_inQueued && timelock != 0) revert NeedsTimelock();
    }

    function _today() private view returns (uint32) {
        return uint32(block.timestamp / 1 days);
    }

    function _spend(uint96 stored, uint256 amount) private {
        uint32 today = _today();
        uint256 spent = spentDay == today ? spentToday : 0;
        uint256 limit = stored - 1;
        if (spent + amount > limit) revert OverDailyLimit(limit > spent ? limit - spent : 0);
        spentToday = uint96(spent + amount);
        spentDay = today;
    }

    /// `at` has come, and came before any lock begun since `epoch`.
    function _due(uint64 at, uint32 epoch) private view returns (bool) {
        if (at > block.timestamp) return false;
        return epoch == lockEpoch || at <= lockedAt[epoch + 1];
    }

    function _isPayee(address p) private view returns (bool) {
        Payee memory x = _payees[p];
        if (x.readyAt == 0 || !_due(x.readyAt, x.addEpoch)) return false;
        return x.removeAt == 0 || !_due(x.removeAt, x.removeEpoch);
    }

    /**
     * @dev USDT on TRON mainnet declares `transfer` as returning bool but returns false on success;
     *      every way it fails reverts. Elsewhere a false return is a failure.
     */
    function _transferUsdt(address to, uint256 amount) private {
        (bool ok, bytes memory ret) = usdt.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        if (!ok) revert UsdtTransferFailed(ret);
        if (!usdtFalseIsSuccess && ret.length >= 32 && !abi.decode(ret, (bool))) {
            revert UsdtTransferFailed(ret);
        }
    }

    function _executeHash(Call[] calldata calls, uint256 nonce_, uint256 deadline) private pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            hashes[i] = keccak256(abi.encode(CALL_TYPEHASH, calls[i].to, calls[i].value, keccak256(calls[i].data)));
        }
        return keccak256(abi.encode(EXECUTE_TYPEHASH, keccak256(abi.encodePacked(hashes)), nonce_, deadline));
    }
}
