// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AgentWorkOrderEscrow} from "../src/AgentWorkOrderEscrow.sol";
import {MockPaxosToken} from "./mocks/MockPaxosToken.sol";

abstract contract EscrowBase is Test {
    AgentWorkOrderEscrow internal escrow;
    MockPaxosToken internal usdg;

    uint256 internal attesterKey = 0xA11CE;
    uint256 internal buyerKey = 0xB0B;
    address internal attester;
    address internal buyer;
    address internal admin = makeAddr("admin");
    address internal arbiter = makeAddr("arbiter");
    address internal pauser = makeAddr("pauser");
    address internal treasury = makeAddr("treasury");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant ONE = 1e6; // USDG has 6 decimals
    uint256 internal constant PRICE = 250 * ONE;
    uint256 internal constant RESEARCH = 100 * ONE;
    uint256 internal constant PER_ORDER_CAP = 1_000 * ONE;
    uint256 internal constant TOTAL_CAP = 5_000 * ONE;

    uint256 private _quoteCounter;

    function setUp() public virtual {
        vm.warp(1_790_000_000);
        attester = vm.addr(attesterKey);
        buyer = vm.addr(buyerKey);
        usdg = new MockPaxosToken();
        escrow = new AgentWorkOrderEscrow(usdg, admin, attester, arbiter, pauser, treasury, PER_ORDER_CAP, TOTAL_CAP);
        usdg.mint(buyer, 10_000 * ONE);
    }

    function _quote() internal returns (AgentWorkOrderEscrow.Quote memory q) {
        _quoteCounter++;
        q = AgentWorkOrderEscrow.Quote({
            quoteId: keccak256(abi.encode("quote", _quoteCounter)),
            buyer: buyer,
            amount: PRICE,
            researchAmount: RESEARCH,
            minCoverageBps: 10_000,
            validUntil: uint64(block.timestamp + 1 hours),
            acceptDeadline: uint64(block.timestamp + 1 hours),
            deliveryDeadline: uint64(block.timestamp + 2 days),
            disputeWindow: uint64(1 days),
            termsHash: keccak256("wayan analyze package: 3 scripts")
        });
    }

    function _signQuote(AgentWorkOrderEscrow.Quote memory q, uint256 key) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, escrow.quoteDigest(q));
        return abi.encodePacked(r, s, v);
    }

    function _authorization(uint256 fromKey, uint256 value, bytes32 nonce)
        internal
        view
        returns (AgentWorkOrderEscrow.Authorization memory a)
    {
        a.validAfter = block.timestamp - 1;
        a.validBefore = block.timestamp + 10 minutes;
        a.nonce = nonce;
        bytes32 structHash = keccak256(
            abi.encode(
                usdg.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(),
                vm.addr(fromKey),
                address(escrow),
                value,
                a.validAfter,
                a.validBefore,
                nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdg.DOMAIN_SEPARATOR(), structHash));
        (a.v, a.r, a.s) = vm.sign(fromKey, digest);
    }

    function _fundWithAuth(AgentWorkOrderEscrow.Quote memory q) internal returns (bytes32) {
        bytes memory quoteSig = _signQuote(q, attesterKey);
        AgentWorkOrderEscrow.Authorization memory auth =
            _authorization(buyerKey, q.amount, keccak256(abi.encode(q.quoteId)));
        vm.prank(q.buyer);
        return escrow.fundWithAuthorization(q, quoteSig, auth);
    }

    function _fundWithApprove(AgentWorkOrderEscrow.Quote memory q) internal returns (bytes32 id) {
        vm.startPrank(buyer);
        usdg.approve(address(escrow), q.amount);
        id = escrow.fund(q, _signQuote(q, attesterKey));
        vm.stopPrank();
    }

    function _deliverFlow(AgentWorkOrderEscrow.Quote memory q) internal returns (bytes32 id) {
        id = _fundWithAuth(q);
        vm.startPrank(attester);
        escrow.acceptOrder(id);
        escrow.commitEvidence(id, keccak256("evidence root"), 10_000, 10, keccak256("meta"));
        escrow.deliver(id, keccak256("artifacts"), keccak256("provenance"));
        vm.stopPrank();
    }

    function _assertSolvent() internal view {
        (uint256 balance, uint256 locked, uint256 owed) = escrow.solvency();
        assertGe(balance, locked + owed, "escrow insolvent");
    }
}
