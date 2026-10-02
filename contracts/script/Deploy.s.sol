// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentWorkOrderEscrow} from "../src/AgentWorkOrderEscrow.sol";
import {MockPaxosToken} from "../test/mocks/MockPaxosToken.sol";

/// @notice Deploys the escrow. Roles and caps come from the environment:
///   TOKEN (or DEPLOY_MOCK_TOKEN=true on a testnet without USDG), ADMIN, ATTESTER, ARBITER, PAUSER, TREASURY,
///   PER_ORDER_CAP, TOTAL_OPEN_ESCROW_CAP (token base units, 6 decimals).
/// forge script script/Deploy.s.sol --rpc-url robinhood_testnet --account <keystore> --broadcast --verify \
///   --verifier blockscout --verifier-url <explorer>/api/
contract Deploy is Script {
    function run() external returns (AgentWorkOrderEscrow escrow, address token) {
        vm.startBroadcast();
        if (vm.envOr("DEPLOY_MOCK_TOKEN", false)) {
            token = address(new MockPaxosToken());
            console.log("Mock USDG (testnet only, anyone can mint):", token);
        } else {
            token = vm.envAddress("TOKEN");
        }
        escrow = new AgentWorkOrderEscrow(
            IERC20(token),
            vm.envAddress("ADMIN"),
            vm.envAddress("ATTESTER"),
            vm.envAddress("ARBITER"),
            vm.envAddress("PAUSER"),
            vm.envAddress("TREASURY"),
            vm.envUint("PER_ORDER_CAP"),
            vm.envUint("TOTAL_OPEN_ESCROW_CAP")
        );
        vm.stopBroadcast();
        console.log("AgentWorkOrderEscrow:", address(escrow));
        console.log("chain id:", block.chainid);
    }
}
