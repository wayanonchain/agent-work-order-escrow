// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AgentWorkOrderEscrow} from "../src/AgentWorkOrderEscrow.sol";
import {MockPaxosToken} from "./mocks/MockPaxosToken.sol";
import {EscrowBase} from "./EscrowBase.t.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract AgentWorkOrderEscrowTest is EscrowBase {
    // ------------------------------------------------------------ happy path

    function test_happyPath_authorization_release_withdraw() public {
        AgentWorkOrderEscrow.Quote memory q = _quote();
        bytes32 id = _deliverFlow(q);
        assertEq(escrow.claimable(treasury), RESEARCH, "research fee earned at evidence");

        vm.prank(buyer);
        escrow.confirmRelease(id);

        assertEq(uint8(escrow.getOrder(id).state), uint8(AgentWorkOrderEscrow.State.Released));
        assertEq(escrow.claimable(treasury), PRICE);
        assertEq(escrow.totalLocked(), 0);

        vm.prank(treasury);
        escrow.withdraw();
        assertEq(usdg.balanceOf(treasury), PRICE);
        assertEq(usdg.balanceOf(address(escrow)), 0);
        _assertSolvent();
    }

    function test_fund_withApprove() public {
        AgentWorkOrderEscrow.Quote memory q = _quote();
        bytes32 id = _fundWithApprove(q);
        assertEq(id, escrow.orderIdFor(q.quoteId));
        assertEq(usdg.balanceOf(address(escrow)), PRICE);
        assertEq(escrow.totalLocked(), PRICE);
        AgentWorkOrderEscrow.Order memory o = escrow.getOrder(id);
        assertEq(o.buyer, buyer);
        assertEq(o.quoteDigest, escrow.quoteDigest(q));
    }

    function test_releaseAfterDisputeWindow_byAnyone() public {
        bytes32 id = _deliverFlow(_quote());
        vm.expectRevert(AgentWorkOrderEscrow.DeadlineNotPassed.selector);
        escrow.releaseAfterDisputeWindow(id);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(stranger);
        escrow.releaseAfterDisputeWindow(id);
        assertEq(escrow.claimable(treasury), PRICE);
    }

    // ------------------------------------------------------------ quote binding

    function test_fund_rejectsQuoteNotSignedByAttester() public {
        AgentWorkOrderEscrow.Quote memory q = _quote();
        bytes memory forged = _signQuote(q, buyerKey);
        vm.startPrank(buyer);
        usdg.approve(address(escrow), q.amount);
        vm.expectRevert(AgentWorkOrderEscrow.InvalidQuoteSigner.selector);
        escrow.fund(q, forged);
        vm.stopPrank();
    }

    function test_fund_rejectsTamperedPrice() public {
        AgentWorkOrderEscrow.Quote memory q = _quote();
        bytes memory sig = _signQuote(q, attesterKey);
        q.amount = PRICE - 50 * ONE; // buyer tries to pay less than quoted
        vm.startPrank(buyer);
        usdg.approve(address(escrow), PRICE);
        vm.expectRevert(AgentWorkOrderEscrow.InvalidQuoteSigner.selector);
        escrow.fund(q, sig);
        vm.stopPrank();
    }

    function test_fund_rejectsReplayOfSameQuote() public {
        AgentWorkOrderEscrow.Quote memory q = _quote();
        _fundWithApprove(q);
        vm.startPrank(buyer);
        usdg.approve(address(escrow), q.amount);
        bytes memory sig = _signQuote(q, attesterKey);
        vm.expectRevert(AgentWorkOrderEscrow.QuoteAlreadyUsed.selector);
        escrow.fund(q, sig);
        vm.stopPrank();
    }

    function test_fund_rejectsExpiredQuote() public {
        AgentWorkOrderEscrow.Quote memory q = _quote();
        bytes memory sig = _signQuote(q, attesterKey);
        vm.warp(q.validUntil + 1);
        vm.prank(buyer);
        vm.expectRevert(AgentWorkOrderEscrow.QuoteExpired.selector);
        escrow.fund(q, sig);
    }

    function test_fund_onlyBuyerCanSpendAllowance() public {
        AgentWorkOrderEscrow.Quote memory q = _quote();
        vm.prank(buyer);
        usdg.approve(address(escrow), q.amount);
        bytes memory sig = _signQuote(q, attesterKey);
        vm.prank(stranger);
        vm.expectRevert(AgentWorkOrderEscrow.NotBuyer.selector);
        escrow.fund(q, sig);
    }

    function test_fund_rejectsInvalidTerms() public {
        AgentWorkOrderEscrow.Quote memory q = _quote();
        q.researchAmount = q.amount + 1;
        _expectInvalidQuote(q);

        q = _quote();
        q.minCoverageBps = 10_001;
        _expectInvalidQuote(q);

        q = _quote();
        q.deliveryDeadline = q.acceptDeadline;
        _expectInvalidQuote(q);

        q = _quote();
        q.disputeWindow = uint64(31 days);
        _expectInvalidQuote(q);

        q = _quote();
        q.deliveryDeadline = uint64(block.timestamp + 91 days);
        _expectInvalidQuote(q);
    }

    function _expectInvalidQuote(AgentWorkOrderEscrow.Quote memory q) internal {
        bytes memory sig = _signQuote(q, attesterKey);
        vm.prank(buyer);
        vm.expectRevert(AgentWorkOrderEscrow.InvalidQuote.selector);
        escrow.fund(q, sig);
    }

    function test_caps() public {
        AgentWorkOrderEscrow.Quote memory q = _quote();
        q.amount = PER_ORDER_CAP + 1;
        q.researchAmount = 0;
        bytes memory sig = _signQuote(q, attesterKey);
        vm.prank(buyer);
        vm.expectRevert(AgentWorkOrderEscrow.CapExceeded.selector);
        escrow.fund(q, sig);

        for (uint256 i = 0; i < 5; i++) {
            AgentWorkOrderEscrow.Quote memory big = _quote();
            big.amount = PER_ORDER_CAP;
            big.researchAmount = 0;
            _fundWithApprove(big);
        }
        AgentWorkOrderEscrow.Quote memory over = _quote();
        bytes memory overSig = _signQuote(over, attesterKey);
        vm.prank(buyer);
        vm.expectRevert(AgentWorkOrderEscrow.CapExceeded.selector);
        escrow.fund(over, overSig);
    }

    // ------------------------------------------------------------ EIP-3009

    function test_authorization_wrongAmountRejected() public {
        AgentWorkOrderEscrow.Quote memory q = _quote();
        AgentWorkOrderEscrow.Authorization memory a = _authorization(buyerKey, q.amount - 1, bytes32("n"));
        bytes memory sig = _signQuote(q, attesterKey);
        vm.expectRevert(MockPaxosToken.InvalidSignature.selector);
        vm.prank(buyer);
        escrow.fundWithAuthorization(q, sig, a);
    }

    function test_authorization_fromOtherAccountRejected() public {
        AgentWorkOrderEscrow.Quote memory q = _quote();
        AgentWorkOrderEscrow.Authorization memory a = _authorization(0xBAD, q.amount, bytes32("n"));
        bytes memory sig = _signQuote(q, attesterKey);
        vm.expectRevert(MockPaxosToken.InvalidSignature.selector);
        vm.prank(buyer);
        escrow.fundWithAuthorization(q, sig, a);
    }

    function test_authorization_cannotBeReusedForAnotherQuote() public {
        AgentWorkOrderEscrow.Quote memory q1 = _quote();
        AgentWorkOrderEscrow.Authorization memory a = _authorization(buyerKey, q1.amount, bytes32("same"));
        bytes memory sig1 = _signQuote(q1, attesterKey);
        vm.prank(buyer);
        escrow.fundWithAuthorization(q1, sig1, a);
        AgentWorkOrderEscrow.Quote memory q2 = _quote();
        bytes memory sig2 = _signQuote(q2, attesterKey);
        vm.prank(buyer);
        vm.expectRevert(MockPaxosToken.AuthorizationUsed.selector);
        escrow.fundWithAuthorization(q2, sig2, a);
    }

    function test_authorization_expiredRejected() public {
        AgentWorkOrderEscrow.Quote memory q = _quote();
        AgentWorkOrderEscrow.Authorization memory a = _authorization(buyerKey, q.amount, bytes32("n"));
        bytes memory sig = _signQuote(q, attesterKey);
        vm.warp(a.validBefore);
        vm.expectRevert(MockPaxosToken.AuthorizationExpired.selector);
        vm.prank(buyer);
        escrow.fundWithAuthorization(q, sig, a);
    }

    function test_authorization_onlyBuyerCanSubmit() public {
        AgentWorkOrderEscrow.Quote memory q = _quote();
        AgentWorkOrderEscrow.Authorization memory a = _authorization(buyerKey, q.amount, bytes32("n"));
        bytes memory sig = _signQuote(q, attesterKey);
        vm.prank(stranger);
        vm.expectRevert(AgentWorkOrderEscrow.NotBuyer.selector);
        escrow.fundWithAuthorization(q, sig, a);
        vm.prank(buyer);
        bytes32 id = escrow.fundWithAuthorization(q, sig, a);
        assertEq(escrow.getOrder(id).buyer, buyer);
        assertEq(usdg.balanceOf(address(escrow)), PRICE);
    }

    function test_treasuryIsSnapshottedPerOrder() public {
        bytes32 id = _deliverFlow(_quote());
        address newTreasury = makeAddr("newTreasury");
        vm.prank(admin);
        escrow.setProviderTreasury(newTreasury);
        vm.prank(buyer);
        escrow.confirmRelease(id);
        assertEq(escrow.claimable(treasury), PRICE, "open order pays the treasury it was funded with");
        assertEq(escrow.claimable(newTreasury), 0);
        bytes32 next = _fundWithAuth(_quote());
        assertEq(escrow.getOrder(next).providerTreasury, newTreasury);
    }

    function test_feeOnTransferRejected() public {
        usdg.setFeeBps(10); // a token upgrade that starts charging a fee
        AgentWorkOrderEscrow.Quote memory q = _quote();
        vm.startPrank(buyer);
        usdg.approve(address(escrow), q.amount);
        bytes memory sig = _signQuote(q, attesterKey);
        vm.expectRevert(AgentWorkOrderEscrow.AmountMismatch.selector);
        escrow.fund(q, sig);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ milestones

    function test_milestones_onlyAttester() public {
        bytes32 id = _fundWithAuth(_quote());
        bytes32 role = escrow.ATTESTER_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role)
        );
        escrow.acceptOrder(id);
    }

    function test_milestones_mustFollowOrder() public {
        bytes32 id = _fundWithAuth(_quote());
        vm.startPrank(attester);
        vm.expectRevert(
            abi.encodeWithSelector(AgentWorkOrderEscrow.WrongState.selector, AgentWorkOrderEscrow.State.Funded)
        );
        escrow.deliver(id, keccak256("a"), keccak256("p"));
        vm.expectRevert(
            abi.encodeWithSelector(AgentWorkOrderEscrow.WrongState.selector, AgentWorkOrderEscrow.State.Funded)
        );
        escrow.commitEvidence(id, keccak256("r"), 10_000, 1, 0);
        escrow.acceptOrder(id);
        vm.expectRevert(
            abi.encodeWithSelector(AgentWorkOrderEscrow.WrongState.selector, AgentWorkOrderEscrow.State.Accepted)
        );
        escrow.acceptOrder(id);
        vm.stopPrank();
    }

    function test_acceptAfterDeadlineRejected() public {
        AgentWorkOrderEscrow.Quote memory q = _quote();
        bytes32 id = _fundWithAuth(q);
        vm.warp(q.acceptDeadline + 1);
        vm.prank(attester);
        vm.expectRevert(AgentWorkOrderEscrow.DeadlinePassed.selector);
        escrow.acceptOrder(id);
    }

    function test_lowCoverageCannotBeDelivered_andRefundsRemainder() public {
        AgentWorkOrderEscrow.Quote memory q = _quote();
        bytes32 id = _fundWithAuth(q);
        vm.startPrank(attester);
        escrow.acceptOrder(id);
        escrow.commitEvidence(id, keccak256("root"), 7_000, 7, 0);
        vm.expectRevert(AgentWorkOrderEscrow.CoverageBelowMinimum.selector);
        escrow.deliver(id, keccak256("a"), keccak256("p"));
        escrow.providerRefund(id, keccak256("transcript gate failed"));
        vm.stopPrank();
        assertEq(escrow.claimable(treasury), RESEARCH);
        assertEq(escrow.claimable(buyer), PRICE - RESEARCH);
        _assertSolvent();
    }

    function test_commitEvidence_rejectsBadInput() public {
        bytes32 id = _fundWithAuth(_quote());
        vm.startPrank(attester);
        escrow.acceptOrder(id);
        vm.expectRevert(AgentWorkOrderEscrow.ZeroHash.selector);
        escrow.commitEvidence(id, 0, 10_000, 1, 0);
        vm.expectRevert(AgentWorkOrderEscrow.InvalidCoverage.selector);
        escrow.commitEvidence(id, keccak256("r"), 10_001, 1, 0);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ refunds

    function test_refundExpired_notAccepted() public {
        AgentWorkOrderEscrow.Quote memory q = _quote();
        bytes32 id = _fundWithAuth(q);
        vm.expectRevert(AgentWorkOrderEscrow.DeadlineNotPassed.selector);
        escrow.refundExpired(id);
        vm.warp(q.acceptDeadline + 1);
        vm.prank(stranger);
        escrow.refundExpired(id);
        assertEq(escrow.claimable(buyer), PRICE);
        vm.prank(buyer);
        escrow.withdraw();
        assertEq(usdg.balanceOf(buyer), 10_000 * ONE);
    }

    function test_refundExpired_afterEvidenceKeepsResearchFee() public {
        AgentWorkOrderEscrow.Quote memory q = _quote();
        bytes32 id = _fundWithAuth(q);
        vm.startPrank(attester);
        escrow.acceptOrder(id);
        escrow.commitEvidence(id, keccak256("root"), 10_000, 10, 0);
        vm.stopPrank();
        vm.warp(q.deliveryDeadline + 1);
        escrow.refundExpired(id);
        assertEq(escrow.claimable(buyer), PRICE - RESEARCH);
        assertEq(escrow.claimable(treasury), RESEARCH);
        vm.prank(attester);
        vm.expectRevert(
            abi.encodeWithSelector(AgentWorkOrderEscrow.WrongState.selector, AgentWorkOrderEscrow.State.Refunded)
        );
        escrow.deliver(id, keccak256("a"), keccak256("p"));
    }

    function test_refundExpired_notAfterDelivery() public {
        bytes32 id = _deliverFlow(_quote());
        vm.warp(block.timestamp + 10 days);
        vm.expectRevert(
            abi.encodeWithSelector(AgentWorkOrderEscrow.WrongState.selector, AgentWorkOrderEscrow.State.Delivered)
        );
        escrow.refundExpired(id);
    }

    function test_providerRefund_beforeWork() public {
        bytes32 id = _fundWithAuth(_quote());
        vm.prank(attester);
        escrow.providerRefund(id, keccak256("failed before paid providers"));
        assertEq(escrow.claimable(buyer), PRICE);
        assertEq(escrow.totalLocked(), 0);
    }

    function test_providerRefund_notAfterDelivery() public {
        bytes32 id = _deliverFlow(_quote());
        vm.prank(attester);
        vm.expectRevert(
            abi.encodeWithSelector(AgentWorkOrderEscrow.WrongState.selector, AgentWorkOrderEscrow.State.Delivered)
        );
        escrow.providerRefund(id, 0);
    }

    // ------------------------------------------------------------ disputes

    function test_dispute_resolvedBySplit() public {
        bytes32 id = _deliverFlow(_quote());
        vm.prank(buyer);
        escrow.openDispute(id, keccak256("evidence looks fabricated"));
        uint256 remainder = PRICE - RESEARCH;

        vm.prank(arbiter);
        vm.expectRevert(AgentWorkOrderEscrow.InvalidSplit.selector);
        escrow.resolveDispute(id, remainder, 1, 0);

        vm.prank(arbiter);
        escrow.resolveDispute(id, 100 * ONE, remainder - 100 * ONE, keccak256("half"));
        assertEq(escrow.claimable(buyer), 100 * ONE);
        assertEq(escrow.claimable(treasury), PRICE - 100 * ONE);
        _assertSolvent();
    }

    function test_dispute_onlyBuyer_onlyInWindow() public {
        bytes32 id = _deliverFlow(_quote());
        vm.prank(stranger);
        vm.expectRevert(AgentWorkOrderEscrow.NotBuyer.selector);
        escrow.openDispute(id, 0);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(buyer);
        vm.expectRevert(AgentWorkOrderEscrow.DeadlinePassed.selector);
        escrow.openDispute(id, 0);
    }

    function test_dispute_notBeforeDelivery() public {
        bytes32 id = _fundWithAuth(_quote());
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(AgentWorkOrderEscrow.WrongState.selector, AgentWorkOrderEscrow.State.Funded)
        );
        escrow.openDispute(id, 0);
    }

    function test_dispute_blocksRelease() public {
        bytes32 id = _deliverFlow(_quote());
        vm.prank(buyer);
        escrow.openDispute(id, 0);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(
            abi.encodeWithSelector(AgentWorkOrderEscrow.WrongState.selector, AgentWorkOrderEscrow.State.Disputed)
        );
        escrow.releaseAfterDisputeWindow(id);
    }

    function test_dispute_arbiterSilenceRefundsBuyer() public {
        bytes32 id = _deliverFlow(_quote());
        vm.prank(buyer);
        escrow.openDispute(id, 0);
        vm.expectRevert(AgentWorkOrderEscrow.DeadlineNotPassed.selector);
        escrow.refundExpired(id);
        vm.warp(block.timestamp + 30 days + 1);
        escrow.refundExpired(id);
        assertEq(escrow.claimable(buyer), PRICE - RESEARCH);
    }

    // ------------------------------------------------------------ pause

    function test_pause_blocksNewWork_allowsExits() public {
        AgentWorkOrderEscrow.Quote memory q = _quote();
        bytes32 delivered = _deliverFlow(q);
        AgentWorkOrderEscrow.Quote memory q2 = _quote();
        bytes32 funded = _fundWithAuth(q2);

        vm.prank(pauser);
        escrow.pause();

        AgentWorkOrderEscrow.Quote memory q3 = _quote();
        bytes memory sig3 = _signQuote(q3, attesterKey);
        vm.prank(buyer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        escrow.fund(q3, sig3);

        vm.prank(attester);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        escrow.acceptOrder(funded);

        vm.prank(buyer);
        escrow.confirmRelease(delivered);
        vm.prank(attester);
        escrow.providerRefund(funded, 0);
        vm.prank(buyer);
        escrow.withdraw();
        vm.prank(treasury);
        escrow.withdraw();
        assertEq(usdg.balanceOf(address(escrow)), 0);
    }

    // ------------------------------------------------------------ issuer controls (USDG)

    function test_frozenBuyer_doesNotBlockProviderPayout() public {
        bytes32 id = _deliverFlow(_quote());
        usdg.freeze(buyer);
        vm.prank(buyer);
        escrow.confirmRelease(id);
        vm.prank(treasury);
        escrow.withdraw();
        assertEq(usdg.balanceOf(treasury), PRICE);
    }

    function test_frozenTreasury_doesNotBlockBuyerRefund() public {
        AgentWorkOrderEscrow.Quote memory q = _quote();
        bytes32 id = _fundWithAuth(q);
        vm.startPrank(attester);
        escrow.acceptOrder(id);
        escrow.commitEvidence(id, keccak256("root"), 10_000, 10, 0);
        escrow.providerRefund(id, 0);
        vm.stopPrank();
        usdg.freeze(treasury);

        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(MockPaxosToken.Frozen.selector, treasury));
        escrow.withdraw();
        assertEq(escrow.claimable(treasury), RESEARCH, "frozen funds stay claimable");

        vm.prank(buyer);
        escrow.withdraw();
        assertEq(usdg.balanceOf(buyer), 10_000 * ONE - RESEARCH);

        usdg.unfreeze(treasury);
        vm.prank(treasury);
        escrow.withdraw();
        assertEq(usdg.balanceOf(treasury), RESEARCH);
    }

    function test_tokenPause_withdrawRetriesLater() public {
        bytes32 id = _deliverFlow(_quote());
        vm.prank(buyer);
        escrow.confirmRelease(id);
        usdg.setPaused(true);
        vm.prank(treasury);
        vm.expectRevert(MockPaxosToken.TransfersPaused.selector);
        escrow.withdraw();
        usdg.setPaused(false);
        vm.prank(treasury);
        escrow.withdraw();
        assertEq(usdg.balanceOf(treasury), PRICE);
    }

    function test_issuerWipeOfEscrow_isVisibleInSolvency() public {
        _fundWithAuth(_quote());
        usdg.freeze(address(escrow));
        usdg.wipeFrozenAddress(address(escrow));
        (uint256 balance, uint256 locked,) = escrow.solvency();
        assertEq(balance, 0);
        assertEq(locked, PRICE, "obligations stay recorded for off-chain recovery");
    }

    // ------------------------------------------------------------ admin

    function test_admin_setTreasury_and_caps() public {
        address newTreasury = makeAddr("newTreasury");
        bytes32 role = escrow.DEFAULT_ADMIN_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role)
        );
        escrow.setProviderTreasury(newTreasury);
        vm.startPrank(admin);
        escrow.setProviderTreasury(newTreasury);
        escrow.setCaps(1, 2);
        vm.stopPrank();
        assertEq(escrow.providerTreasury(), newTreasury);
        assertEq(escrow.perOrderCap(), 1);
    }

    function test_withdraw_nothing() public {
        vm.expectRevert(AgentWorkOrderEscrow.NothingToWithdraw.selector);
        escrow.withdraw();
    }

    function test_orderId_bindsChainAndContract() public {
        bytes32 quoteId = keccak256("q");
        bytes32 here = escrow.orderIdFor(quoteId);
        vm.chainId(4663);
        assertTrue(escrow.orderIdFor(quoteId) != here);
    }

    // ------------------------------------------------------------ fuzz

    function testFuzz_disputeSplitNeverExceedsRemainder(uint256 buyerAmount) public {
        bytes32 id = _deliverFlow(_quote());
        vm.prank(buyer);
        escrow.openDispute(id, 0);
        uint256 remainder = PRICE - RESEARCH;
        buyerAmount = bound(buyerAmount, 0, remainder);
        vm.prank(arbiter);
        escrow.resolveDispute(id, buyerAmount, remainder - buyerAmount, 0);
        assertEq(escrow.claimable(buyer) + escrow.claimable(treasury), PRICE);
        assertEq(escrow.totalLocked(), 0);
        _assertSolvent();
    }

    function testFuzz_fundAnyValidAmount(uint256 amount, uint256 research) public {
        amount = bound(amount, 1, PER_ORDER_CAP);
        research = bound(research, 0, amount);
        AgentWorkOrderEscrow.Quote memory q = _quote();
        q.amount = amount;
        q.researchAmount = research;
        bytes32 id = _fundWithAuth(q);
        vm.startPrank(attester);
        escrow.acceptOrder(id);
        escrow.commitEvidence(id, keccak256("root"), 10_000, 1, 0);
        escrow.providerRefund(id, 0);
        vm.stopPrank();
        assertEq(escrow.claimable(buyer) + escrow.claimable(treasury), amount);
        _assertSolvent();
    }
}
