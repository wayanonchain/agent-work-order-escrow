// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AgentWorkOrderEscrow} from "../src/AgentWorkOrderEscrow.sol";
import {MockPaxosToken} from "./mocks/MockPaxosToken.sol";

/// @notice Drives random sequences of every role's actions against the escrow.
contract EscrowHandler is Test {
    AgentWorkOrderEscrow public escrow;
    MockPaxosToken public usdg;
    uint256 internal attesterKey;
    address internal attester;
    address internal arbiter;
    address internal treasury;
    address[] public buyers;
    bytes32[] public orderIds;
    uint256 internal quoteNonce;

    /// @notice Total ever funded and total ever withdrawn, for conservation checks.
    uint256 public ghostFunded;
    uint256 public ghostWithdrawn;

    constructor(
        AgentWorkOrderEscrow escrow_,
        MockPaxosToken usdg_,
        uint256 attesterKey_,
        address arbiter_,
        address treasury_
    ) {
        escrow = escrow_;
        usdg = usdg_;
        attesterKey = attesterKey_;
        attester = vm.addr(attesterKey_);
        arbiter = arbiter_;
        treasury = treasury_;
        for (uint256 i = 1; i <= 3; i++) {
            address b = makeAddr(string(abi.encode("buyer", i)));
            buyers.push(b);
            usdg.mint(b, 1_000_000e6);
            vm.prank(b);
            usdg.approve(address(escrow), type(uint256).max);
        }
    }

    function orderCount() external view returns (uint256) {
        return orderIds.length;
    }

    function fund(uint256 buyerSeed, uint256 amount, uint256 research) external {
        address b = buyers[buyerSeed % buyers.length];
        amount = bound(amount, 1, escrow.perOrderCap());
        research = bound(research, 0, amount);
        if (escrow.totalLocked() + amount > escrow.totalOpenEscrowCap()) return;
        quoteNonce++;
        AgentWorkOrderEscrow.Quote memory q = AgentWorkOrderEscrow.Quote({
            quoteId: keccak256(abi.encode(quoteNonce)),
            buyer: b,
            amount: amount,
            researchAmount: research,
            minCoverageBps: 10_000,
            validUntil: uint64(block.timestamp + 1 hours),
            acceptDeadline: uint64(block.timestamp + 1 hours),
            deliveryDeadline: uint64(block.timestamp + 2 days),
            disputeWindow: uint64(1 days),
            termsHash: bytes32(0)
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attesterKey, escrow.quoteDigest(q));
        vm.prank(b);
        try escrow.fund(q, abi.encodePacked(r, s, v)) returns (bytes32 id) {
            orderIds.push(id);
            ghostFunded += amount;
        } catch {}
    }

    function progress(uint256 seed, uint16 coverage) external {
        if (orderIds.length == 0) return;
        bytes32 id = orderIds[seed % orderIds.length];
        AgentWorkOrderEscrow.State s = escrow.getOrder(id).state;
        vm.startPrank(attester);
        if (s == AgentWorkOrderEscrow.State.Funded) {
            try escrow.acceptOrder(id) {} catch {}
        } else if (s == AgentWorkOrderEscrow.State.Accepted) {
            try escrow.commitEvidence(id, keccak256("root"), uint16(bound(coverage, 9_000, 10_000)), 1, 0) {} catch {}
        } else if (s == AgentWorkOrderEscrow.State.EvidenceCommitted) {
            try escrow.deliver(id, keccak256("a"), keccak256("p")) {} catch {}
        }
        vm.stopPrank();
    }

    function settle(uint256 seed, uint256 action, uint256 split) external {
        if (orderIds.length == 0) return;
        bytes32 id = orderIds[seed % orderIds.length];
        AgentWorkOrderEscrow.Order memory o = escrow.getOrder(id);
        action = action % 6;
        if (action == 0) {
            vm.prank(o.buyer);
            try escrow.confirmRelease(id) {} catch {}
        } else if (action == 1) {
            try escrow.releaseAfterDisputeWindow(id) {} catch {}
        } else if (action == 2) {
            vm.prank(o.buyer);
            try escrow.openDispute(id, 0) {} catch {}
        } else if (action == 3) {
            uint256 remainder = o.amount - o.settled;
            uint256 toBuyer = bound(split, 0, remainder);
            vm.prank(arbiter);
            try escrow.resolveDispute(id, toBuyer, remainder - toBuyer, 0) {} catch {}
        } else if (action == 4) {
            try escrow.refundExpired(id) {} catch {}
        } else {
            vm.prank(attester);
            try escrow.providerRefund(id, 0) {} catch {}
        }
    }

    function withdraw(uint256 seed) external {
        address who = seed % 4 == 3 ? treasury : buyers[seed % buyers.length];
        vm.prank(who);
        try escrow.withdraw() returns (uint256 amount) {
            ghostWithdrawn += amount;
        } catch {}
    }

    function warp(uint256 secondsForward) external {
        vm.warp(block.timestamp + bound(secondsForward, 1, 3 days));
    }
}

contract EscrowInvariantTest is Test {
    AgentWorkOrderEscrow internal escrow;
    MockPaxosToken internal usdg;
    EscrowHandler internal handler;

    function setUp() public {
        vm.warp(1_790_000_000);
        uint256 attesterKey = 0xA11CE;
        address arbiter = makeAddr("arbiter");
        address treasury = makeAddr("treasury");
        usdg = new MockPaxosToken();
        escrow = new AgentWorkOrderEscrow(
            usdg, makeAddr("admin"), vm.addr(attesterKey), arbiter, makeAddr("pauser"), treasury, 1_000e6, 5_000e6
        );
        handler = new EscrowHandler(escrow, usdg, attesterKey, arbiter, treasury);
        targetContract(address(handler));
    }

    /// Balance covers every obligation: locked in open orders plus credited but not withdrawn.
    function invariant_solvent() public view {
        (uint256 balance, uint256 locked, uint256 owed) = escrow.solvency();
        assertEq(balance, locked + owed);
    }

    /// Nothing is created or lost: funded in = withdrawn out + still held.
    function invariant_conservation() public view {
        assertEq(handler.ghostFunded(), handler.ghostWithdrawn() + usdg.balanceOf(address(escrow)));
    }

    /// No order ever settles more than it was funded with; terminal orders are fully settled.
    function invariant_perOrderAccounting() public view {
        uint256 n = handler.orderCount();
        for (uint256 i = 0; i < n; i++) {
            AgentWorkOrderEscrow.Order memory o = escrow.getOrder(handler.orderIds(i));
            assertLe(o.settled, o.amount);
            if (
                o.state == AgentWorkOrderEscrow.State.Released || o.state == AgentWorkOrderEscrow.State.Refunded
                    || o.state == AgentWorkOrderEscrow.State.Resolved
            ) assertEq(o.settled, o.amount);
        }
    }

    function invariant_openEscrowWithinCap() public view {
        assertLe(escrow.totalLocked(), escrow.totalOpenEscrowCap());
    }
}
