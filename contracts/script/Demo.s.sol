// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {AgentWorkOrderEscrow} from "../src/AgentWorkOrderEscrow.sol";
import {MockPaxosToken} from "../test/mocks/MockPaxosToken.sol";

/// @notice End-to-end demo of agent-to-agent paid work with three outcomes: delivered and released, provider
/// refund after a failed transcript gate, and a dispute settled by the arbiter. The buyer agent pays with a single
/// EIP-3009 signature and pays its own gas. Runs against a local anvil (default keys) or a testnet (env keys):
///   anvil &
///   forge script script/Demo.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
contract Demo is Script {
    // anvil's default mnemonic; accounts 0..3 are pre-funded on a local node
    string constant ANVIL_MNEMONIC = "test test test test test test test test test test test junk";

    uint256 attesterKey;
    uint256 buyerKey;
    uint256 arbiterKey;
    AgentWorkOrderEscrow escrow;
    MockPaxosToken usdg;
    uint256 counter;

    function run() external {
        uint256 deployerKey = vm.envOr("DEPLOYER_KEY", vm.deriveKey(ANVIL_MNEMONIC, 0));
        attesterKey = vm.envOr("ATTESTER_KEY", vm.deriveKey(ANVIL_MNEMONIC, 1));
        buyerKey = vm.envOr("BUYER_KEY", vm.deriveKey(ANVIL_MNEMONIC, 2));
        arbiterKey = vm.envOr("ARBITER_KEY", vm.deriveKey(ANVIL_MNEMONIC, 3));
        address deployer = vm.addr(deployerKey);
        address treasury;

        address existing = vm.envOr("ESCROW", address(0));
        if (existing == address(0)) {
            // Local run: deploy a fresh mock token and escrow.
            treasury = vm.envOr("TREASURY", deployer);
            vm.startBroadcast(deployerKey);
            usdg = new MockPaxosToken();
            escrow = new AgentWorkOrderEscrow(
                usdg, deployer, vm.addr(attesterKey), vm.addr(arbiterKey), deployer, treasury, 1_000e6, 10_000e6
            );
            vm.stopBroadcast();
        } else {
            // Testnet run: attach to the deployed escrow; its token must be the mock (anyone can mint test USDG).
            escrow = AgentWorkOrderEscrow(existing);
            usdg = MockPaxosToken(address(escrow.token()));
            treasury = escrow.providerTreasury();
        }
        vm.broadcast(buyerKey);
        usdg.mint(vm.addr(buyerKey), 1_000e6);
        console.log("escrow", address(escrow));
        console.log("mock USDG", address(usdg));

        // 1. Delivered: evidence with 100% transcript coverage, artifacts + provenance, buyer confirms.
        bytes32 a = _buyerFunds(250e6, 100e6);
        _attester(a, 10_000, true);
        vm.broadcast(buyerKey);
        escrow.confirmRelease(a);
        console.log("1. released to provider:", escrow.claimable(treasury));

        // 2. Transcript gate failed (70% coverage): research fee kept, the rest refunded at once.
        bytes32 b = _buyerFunds(250e6, 100e6);
        _attester(b, 7_000, false);
        vm.broadcast(attesterKey);
        escrow.providerRefund(b, keccak256("transcript coverage 70% < 100%"));
        console.log("2. refunded to buyer:", escrow.claimable(vm.addr(buyerKey)));

        // 3. Buyer disputes the delivery; arbiter splits the remainder.
        bytes32 c = _buyerFunds(250e6, 100e6);
        _attester(c, 10_000, true);
        vm.broadcast(buyerKey);
        escrow.openDispute(c, keccak256("one script off-brief"));
        vm.broadcast(arbiterKey);
        escrow.resolveDispute(c, 50e6, 100e6, keccak256("partial refund"));

        vm.broadcast(buyerKey);
        escrow.withdraw();
        if (treasury == deployer) {
            vm.broadcast(deployerKey);
            escrow.withdraw();
        } else {
            console.log("treasury withdraws its own balance:", escrow.claimable(treasury));
        }
        (uint256 balance, uint256 locked, uint256 owed) = escrow.solvency();
        console.log("buyer USDG after:", usdg.balanceOf(vm.addr(buyerKey)));
        console.log("escrow balance / locked / owed:", balance, locked, owed);
    }

    function _buyerFunds(uint256 amount, uint256 research) internal returns (bytes32) {
        counter++;
        AgentWorkOrderEscrow.Quote memory q = AgentWorkOrderEscrow.Quote({
            quoteId: keccak256(abi.encode("wayan-demo", block.timestamp, counter)),
            buyer: vm.addr(buyerKey),
            amount: amount,
            researchAmount: research,
            minCoverageBps: 10_000,
            validUntil: uint64(block.timestamp + 1 hours),
            acceptDeadline: uint64(block.timestamp + 1 hours),
            deliveryDeadline: uint64(block.timestamp + 2 days),
            disputeWindow: uint64(1 days),
            termsHash: keccak256("analyze + 3 scripts")
        });
        // The provider's backend signs the quote; the buyer agent signs one EIP-3009 authorization.
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attesterKey, escrow.quoteDigest(q));
        AgentWorkOrderEscrow.Authorization memory auth;
        auth.validAfter = 0;
        auth.validBefore = block.timestamp + 10 minutes;
        auth.nonce = keccak256(abi.encode(q.quoteId));
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                usdg.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        usdg.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(),
                        q.buyer,
                        address(escrow),
                        amount,
                        auth.validAfter,
                        auth.validBefore,
                        auth.nonce
                    )
                )
            )
        );
        (auth.v, auth.r, auth.s) = vm.sign(buyerKey, digest);
        vm.broadcast(buyerKey);
        return escrow.fundWithAuthorization(q, abi.encodePacked(r, s, v), auth);
    }

    function _attester(bytes32 id, uint16 coverageBps, bool deliverIt) internal {
        vm.startBroadcast(attesterKey);
        escrow.acceptOrder(id);
        escrow.commitEvidence(id, keccak256(abi.encode("evidence merkle root", id)), coverageBps, 10, 0);
        if (deliverIt) escrow.deliver(id, keccak256("artifact bundle"), keccak256("provenance_json"));
        vm.stopBroadcast();
    }
}
