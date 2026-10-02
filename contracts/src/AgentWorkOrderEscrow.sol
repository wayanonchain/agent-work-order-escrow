// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC3009} from "./interfaces/IERC3009.sol";

/// @title AgentWorkOrderEscrow
/// @notice Escrow for paid AI work between agents. A buyer (a person or an agent) locks a stablecoin under a quote
/// signed by the provider's attester. The provider records milestones on-chain as hashes: the order is accepted,
/// the evidence set is committed (Merkle root + transcript coverage), the deliverable is handed over (artifact hash +
/// provenance hash). Money moves only by these rules:
///  - the research fee is earned when evidence is committed;
///  - the rest is earned after delivery once the buyer confirms or the dispute window passes;
///  - missed deadlines refund everything not yet earned to the buyer; the provider can refund voluntarily;
///  - a dispute after delivery is settled by the arbiter; an arbiter that never acts refunds the buyer.
/// Payouts are pull-based: settlements credit balances and each party withdraws its own, so a token-level freeze of
/// one party (USDG issuer controls) never blocks the other.
/// Trust model: the attester is the provider's backend and is trusted to report milestones honestly (evidence is
/// committed as hashes, not verified on-chain); a compromised attester can at most earn the research fee of funded
/// orders and mark fake deliveries, which the buyer can dispute. Revoke its role at once on compromise — old quote
/// signatures stay valid only while the signer holds ATTESTER_ROLE and until `validUntil`.
/// @dev One deployment serves one token (immutable). No proxy: a new version is a new deployment.
contract AgentWorkOrderEscrow is AccessControl, Pausable, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    bytes32 public constant ATTESTER_ROLE = keccak256("ATTESTER_ROLE");
    bytes32 public constant ARBITER_ROLE = keccak256("ARBITER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint16 public constant MAX_BPS = 10_000;
    uint64 public constant MAX_DISPUTE_WINDOW = 30 days;
    uint64 public constant MAX_ORDER_DURATION = 90 days;
    /// @notice How long the arbiter has to settle a dispute before anyone can refund the buyer.
    uint64 public constant ARBITRATION_PERIOD = 30 days;

    bytes32 public constant QUOTE_TYPEHASH = keccak256(
        "Quote(bytes32 quoteId,address buyer,uint256 amount,uint256 researchAmount,uint16 minCoverageBps,"
        "uint64 validUntil,uint64 acceptDeadline,uint64 deliveryDeadline,uint64 disputeWindow,bytes32 termsHash)"
    );

    enum State {
        None,
        Funded,
        Accepted,
        EvidenceCommitted,
        Delivered,
        Disputed,
        Released,
        Refunded,
        Resolved
    }

    /// @notice Terms the provider's attester signs off-chain (EIP-712). `termsHash` binds the off-chain quote
    /// document (package, deliverables, refund terms); the chain id and this contract are bound by the domain.
    struct Quote {
        bytes32 quoteId;
        address buyer;
        uint256 amount;
        uint256 researchAmount;
        uint16 minCoverageBps;
        uint64 validUntil;
        uint64 acceptDeadline;
        uint64 deliveryDeadline;
        uint64 disputeWindow;
        bytes32 termsHash;
    }

    /// @notice An EIP-3009 authorization signed by the buyer for a transfer of exactly `amount` to this contract.
    struct Authorization {
        uint256 validAfter;
        uint256 validBefore;
        bytes32 nonce;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct Order {
        address buyer;
        address providerTreasury;
        State state;
        uint16 minCoverageBps;
        uint16 coverageBps;
        uint64 acceptDeadline;
        uint64 deliveryDeadline;
        uint64 disputeWindow;
        uint64 deliveredAt;
        uint64 disputedAt;
        uint256 amount;
        uint256 researchAmount;
        uint256 settled;
        bytes32 quoteDigest;
        bytes32 evidenceRoot;
        bytes32 deliverableHash;
        bytes32 provenanceHash;
    }

    IERC20 public immutable token;
    address public providerTreasury;
    uint256 public perOrderCap;
    uint256 public totalOpenEscrowCap;

    /// @notice Sum of amounts still locked in open orders (not yet credited to anyone).
    uint256 public totalLocked;
    /// @notice Sum of credited balances not yet withdrawn.
    uint256 public totalClaimable;

    mapping(bytes32 orderId => Order) private _orders;
    mapping(address account => uint256) public claimable;

    event OrderFunded(
        bytes32 indexed orderId,
        bytes32 indexed quoteId,
        address indexed buyer,
        uint256 amount,
        uint256 researchAmount,
        bytes32 quoteDigest,
        bytes32 termsHash
    );
    event OrderAccepted(bytes32 indexed orderId);
    event EvidenceCommitted(
        bytes32 indexed orderId, bytes32 evidenceRoot, uint16 coverageBps, uint32 evidenceCount, bytes32 metadataHash
    );
    event OrderDelivered(bytes32 indexed orderId, bytes32 deliverableHash, bytes32 provenanceHash);
    event DisputeOpened(bytes32 indexed orderId, bytes32 reasonHash);
    event DisputeResolved(bytes32 indexed orderId, uint256 buyerAmount, uint256 providerAmount, bytes32 resolutionHash);
    event OrderReleased(bytes32 indexed orderId, uint256 providerAmount);
    event OrderRefunded(bytes32 indexed orderId, uint256 buyerAmount);
    event ProviderRefunded(bytes32 indexed orderId, uint256 buyerAmount, bytes32 reasonHash);
    event Credited(bytes32 indexed orderId, address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event ProviderTreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);
    event CapsUpdated(uint256 perOrderCap, uint256 totalOpenEscrowCap);

    error ZeroAddress();
    error InvalidQuote();
    error QuoteExpired();
    error InvalidQuoteSigner();
    error QuoteAlreadyUsed();
    error CapExceeded();
    error NotBuyer();
    error WrongState(State current);
    error DeadlinePassed();
    error DeadlineNotPassed();
    error InvalidCoverage();
    error CoverageBelowMinimum();
    error ZeroHash();
    error AmountMismatch();
    error InvalidSplit();
    error NothingToWithdraw();

    constructor(
        IERC20 token_,
        address admin,
        address attester,
        address arbiter,
        address pauser,
        address treasury,
        uint256 perOrderCap_,
        uint256 totalOpenEscrowCap_
    ) EIP712("WayanAgentEscrow", "1") {
        if (
            address(token_) == address(0) || admin == address(0) || attester == address(0) || arbiter == address(0)
                || pauser == address(0) || treasury == address(0)
        ) revert ZeroAddress();
        token = token_;
        providerTreasury = treasury;
        perOrderCap = perOrderCap_;
        totalOpenEscrowCap = totalOpenEscrowCap_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ATTESTER_ROLE, attester);
        _grantRole(ARBITER_ROLE, arbiter);
        _grantRole(PAUSER_ROLE, pauser);
        emit ProviderTreasuryUpdated(address(0), treasury);
        emit CapsUpdated(perOrderCap_, totalOpenEscrowCap_);
    }

    // ---------------------------------------------------------------- funding

    /// @notice Fund an order with an allowance (`approve` or EIP-2612 `permit` done beforehand). Only the buyer
    /// named in the quote can fund it, so nobody can spend a buyer's allowance on the buyer's behalf.
    function fund(Quote calldata q, bytes calldata quoteSignature)
        external
        nonReentrant
        whenNotPaused
        returns (bytes32 orderId)
    {
        if (msg.sender != q.buyer) revert NotBuyer();
        orderId = _open(q, quoteSignature);
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), q.amount);
        _checkReceived(before, q.amount);
    }

    /// @notice Fund an order in one transaction from an EIP-3009 authorization signed by the buyer, without a separate
    /// `approve`. Only the buyer can submit it and pays its own gas, so an authorization seen in the mempool cannot be
    /// executed by someone else to force the order open. Terms are bound by the attester's quote signature; payer,
    /// amount and recipient by the buyer's authorization.
    function fundWithAuthorization(Quote calldata q, bytes calldata quoteSignature, Authorization calldata auth)
        external
        nonReentrant
        whenNotPaused
        returns (bytes32 orderId)
    {
        if (msg.sender != q.buyer) revert NotBuyer();
        orderId = _open(q, quoteSignature);
        uint256 before = token.balanceOf(address(this));
        IERC3009(address(token))
            .receiveWithAuthorization(
                q.buyer, address(this), q.amount, auth.validAfter, auth.validBefore, auth.nonce, auth.v, auth.r, auth.s
            );
        _checkReceived(before, q.amount);
    }

    // ---------------------------------------------------------------- milestones (attester)

    function acceptOrder(bytes32 orderId) external onlyRole(ATTESTER_ROLE) whenNotPaused {
        Order storage o = _orders[orderId];
        _requireState(o, State.Funded);
        if (block.timestamp > o.acceptDeadline) revert DeadlinePassed();
        o.state = State.Accepted;
        emit OrderAccepted(orderId);
    }

    /// @notice Record the evidence set behind the work and earn the research fee. Coverage below the order minimum
    /// can be recorded honestly, but such an order can never be delivered: it ends in a refund of the remainder.
    function commitEvidence(
        bytes32 orderId,
        bytes32 evidenceRoot,
        uint16 coverageBps,
        uint32 evidenceCount,
        bytes32 metadataHash
    ) external onlyRole(ATTESTER_ROLE) whenNotPaused {
        Order storage o = _orders[orderId];
        _requireState(o, State.Accepted);
        if (block.timestamp > o.deliveryDeadline) revert DeadlinePassed();
        if (evidenceRoot == bytes32(0)) revert ZeroHash();
        if (coverageBps > MAX_BPS) revert InvalidCoverage();
        o.state = State.EvidenceCommitted;
        o.evidenceRoot = evidenceRoot;
        o.coverageBps = coverageBps;
        emit EvidenceCommitted(orderId, evidenceRoot, coverageBps, evidenceCount, metadataHash);
        if (o.researchAmount > 0) _credit(orderId, o, o.providerTreasury, o.researchAmount);
    }

    function deliver(bytes32 orderId, bytes32 deliverableHash, bytes32 provenanceHash)
        external
        onlyRole(ATTESTER_ROLE)
        whenNotPaused
    {
        Order storage o = _orders[orderId];
        _requireState(o, State.EvidenceCommitted);
        if (block.timestamp > o.deliveryDeadline) revert DeadlinePassed();
        if (o.coverageBps < o.minCoverageBps) revert CoverageBelowMinimum();
        if (deliverableHash == bytes32(0) || provenanceHash == bytes32(0)) revert ZeroHash();
        o.state = State.Delivered;
        o.deliveredAt = uint64(block.timestamp);
        o.deliverableHash = deliverableHash;
        o.provenanceHash = provenanceHash;
        emit OrderDelivered(orderId, deliverableHash, provenanceHash);
    }

    // ---------------------------------------------------------------- settlement (allowed while paused)

    function confirmRelease(bytes32 orderId) external {
        Order storage o = _orders[orderId];
        if (msg.sender != o.buyer) revert NotBuyer();
        _requireState(o, State.Delivered);
        _release(orderId, o);
    }

    function releaseAfterDisputeWindow(bytes32 orderId) external {
        Order storage o = _orders[orderId];
        _requireState(o, State.Delivered);
        if (block.timestamp <= uint256(o.deliveredAt) + o.disputeWindow) revert DeadlineNotPassed();
        _release(orderId, o);
    }

    function openDispute(bytes32 orderId, bytes32 reasonHash) external {
        Order storage o = _orders[orderId];
        if (msg.sender != o.buyer) revert NotBuyer();
        _requireState(o, State.Delivered);
        if (block.timestamp > uint256(o.deliveredAt) + o.disputeWindow) revert DeadlinePassed();
        o.state = State.Disputed;
        o.disputedAt = uint64(block.timestamp);
        emit DisputeOpened(orderId, reasonHash);
    }

    /// @notice Split what is left of a disputed order. The split must account for exactly the remainder.
    function resolveDispute(bytes32 orderId, uint256 buyerAmount, uint256 providerAmount, bytes32 resolutionHash)
        external
        onlyRole(ARBITER_ROLE)
    {
        Order storage o = _orders[orderId];
        _requireState(o, State.Disputed);
        if (buyerAmount + providerAmount != o.amount - o.settled) revert InvalidSplit();
        o.state = State.Resolved;
        emit DisputeResolved(orderId, buyerAmount, providerAmount, resolutionHash);
        if (buyerAmount > 0) _credit(orderId, o, o.buyer, buyerAmount);
        if (providerAmount > 0) _credit(orderId, o, o.providerTreasury, providerAmount);
    }

    /// @notice Refund the unearned remainder when a deadline was missed: not accepted in time, not delivered in
    /// time, or a dispute the arbiter never settled. Anyone can call it.
    function refundExpired(bytes32 orderId) external {
        Order storage o = _orders[orderId];
        State s = o.state;
        bool expired = false;
        if (s == State.Funded) {
            expired = block.timestamp > o.acceptDeadline;
        } else if (s == State.Accepted || s == State.EvidenceCommitted) {
            expired = block.timestamp > o.deliveryDeadline;
        } else if (s == State.Disputed) {
            expired = block.timestamp > uint256(o.disputedAt) + ARBITRATION_PERIOD;
        } else {
            revert WrongState(s);
        }
        if (!expired) revert DeadlineNotPassed();
        uint256 remainder = o.amount - o.settled;
        o.state = State.Refunded;
        emit OrderRefunded(orderId, remainder);
        if (remainder > 0) _credit(orderId, o, o.buyer, remainder);
    }

    /// @notice The provider gives up before delivery (e.g. it failed before calling any paid provider) and refunds
    /// the unearned remainder at once instead of making the buyer wait for the deadline.
    function providerRefund(bytes32 orderId, bytes32 reasonHash) external onlyRole(ATTESTER_ROLE) {
        Order storage o = _orders[orderId];
        State s = o.state;
        if (s != State.Funded && s != State.Accepted && s != State.EvidenceCommitted) revert WrongState(s);
        uint256 remainder = o.amount - o.settled;
        o.state = State.Refunded;
        emit ProviderRefunded(orderId, remainder, reasonHash);
        if (remainder > 0) _credit(orderId, o, o.buyer, remainder);
    }

    /// @notice Withdraw everything credited to the caller. Deliberately no `withdrawTo`: funds of an address frozen by
    /// the token issuer stay claimable until the freeze is lifted rather than being routed around it.
    function withdraw() external nonReentrant returns (uint256 amount) {
        amount = claimable[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        claimable[msg.sender] = 0;
        totalClaimable -= amount;
        emit Withdrawn(msg.sender, amount);
        token.safeTransfer(msg.sender, amount);
    }

    // ---------------------------------------------------------------- admin

    /// @notice Applies to orders funded from now on; every open order keeps the treasury it was funded with.
    function setProviderTreasury(address treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (treasury == address(0)) revert ZeroAddress();
        emit ProviderTreasuryUpdated(providerTreasury, treasury);
        providerTreasury = treasury;
    }

    function setCaps(uint256 perOrderCap_, uint256 totalOpenEscrowCap_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        perOrderCap = perOrderCap_;
        totalOpenEscrowCap = totalOpenEscrowCap_;
        emit CapsUpdated(perOrderCap_, totalOpenEscrowCap_);
    }

    /// @notice Pausing stops new orders and forward milestones; every exit (release, refund, dispute, withdraw) stays open.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ---------------------------------------------------------------- views

    function getOrder(bytes32 orderId) external view returns (Order memory) {
        return _orders[orderId];
    }

    function orderIdFor(bytes32 quoteId) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), quoteId));
    }

    function quoteDigest(Quote calldata q) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    QUOTE_TYPEHASH,
                    q.quoteId,
                    q.buyer,
                    q.amount,
                    q.researchAmount,
                    q.minCoverageBps,
                    q.validUntil,
                    q.acceptDeadline,
                    q.deliveryDeadline,
                    q.disputeWindow,
                    q.termsHash
                )
            )
        );
    }

    /// @notice Solvency check for monitoring: `balance >= totalLocked + totalClaimable` unless the issuer seized funds.
    function solvency() external view returns (uint256 balance, uint256 locked, uint256 owed) {
        return (token.balanceOf(address(this)), totalLocked, totalClaimable);
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ---------------------------------------------------------------- internal

    function _open(Quote calldata q, bytes calldata quoteSignature) internal returns (bytes32 orderId) {
        if (block.timestamp > q.validUntil) revert QuoteExpired();
        if (
            q.buyer == address(0) || q.amount == 0 || q.researchAmount > q.amount || q.minCoverageBps > MAX_BPS
                || q.acceptDeadline <= block.timestamp || q.deliveryDeadline <= q.acceptDeadline
                || q.deliveryDeadline > block.timestamp + MAX_ORDER_DURATION || q.disputeWindow == 0
                || q.disputeWindow > MAX_DISPUTE_WINDOW
        ) revert InvalidQuote();
        if (q.amount > perOrderCap || totalLocked + q.amount > totalOpenEscrowCap) revert CapExceeded();

        bytes32 digest = quoteDigest(q);
        if (!hasRole(ATTESTER_ROLE, ECDSA.recover(digest, quoteSignature))) revert InvalidQuoteSigner();

        orderId = orderIdFor(q.quoteId);
        Order storage o = _orders[orderId];
        if (o.state != State.None) revert QuoteAlreadyUsed();

        o.buyer = q.buyer;
        o.providerTreasury = providerTreasury;
        o.state = State.Funded;
        o.minCoverageBps = q.minCoverageBps;
        o.acceptDeadline = q.acceptDeadline;
        o.deliveryDeadline = q.deliveryDeadline;
        o.disputeWindow = q.disputeWindow;
        o.amount = q.amount;
        o.researchAmount = q.researchAmount;
        o.quoteDigest = digest;
        totalLocked += q.amount;

        emit OrderFunded(orderId, q.quoteId, q.buyer, q.amount, q.researchAmount, digest, q.termsHash);
    }

    function _checkReceived(uint256 before, uint256 amount) internal view {
        if (token.balanceOf(address(this)) - before != amount) revert AmountMismatch();
    }

    function _release(bytes32 orderId, Order storage o) internal {
        uint256 remainder = o.amount - o.settled;
        o.state = State.Released;
        emit OrderReleased(orderId, remainder);
        if (remainder > 0) _credit(orderId, o, o.providerTreasury, remainder);
    }

    function _credit(bytes32 orderId, Order storage o, address account, uint256 amount) internal {
        o.settled += amount;
        totalLocked -= amount;
        claimable[account] += amount;
        totalClaimable += amount;
        emit Credited(orderId, account, amount);
    }

    function _requireState(Order storage o, State expected) internal view {
        if (o.state != expected) revert WrongState(o.state);
    }
}
