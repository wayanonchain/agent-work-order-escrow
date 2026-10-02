// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The subset of EIP-3009 the escrow uses. USDG (Paxos) and USDC (Circle) implement it.
/// `receiveWithAuthorization` requires `msg.sender == to`, so a signed transfer to the escrow can only be
/// executed by the escrow itself and cannot be front-run into a plain transfer.
interface IERC3009 {
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}
