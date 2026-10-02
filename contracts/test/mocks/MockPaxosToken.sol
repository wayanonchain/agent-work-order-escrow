// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @notice Test stand-in for USDG: 6 decimals, EIP-3009 receiveWithAuthorization, and the issuer controls the escrow
/// has to survive — freeze, wipe of a frozen balance, global pause, and a transfer fee to mimic a token upgrade.
contract MockPaxosToken is ERC20, EIP712 {
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    mapping(address => bool) public frozen;
    mapping(address => mapping(bytes32 => bool)) public authorizationState;
    bool public paused;
    uint256 public feeBps;

    error Frozen(address account);
    error TransfersPaused();
    error CallerMustBePayee();
    error AuthorizationNotYetValid();
    error AuthorizationExpired();
    error AuthorizationUsed();
    error InvalidSignature();

    constructor() ERC20("Global Dollar (mock)", "USDG") EIP712("Global Dollar (mock)", "1") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function freeze(address account) external {
        frozen[account] = true;
    }

    function unfreeze(address account) external {
        frozen[account] = false;
    }

    function wipeFrozenAddress(address account) external {
        require(frozen[account], "not frozen");
        _burn(account, balanceOf(account));
    }

    function setPaused(bool value) external {
        paused = value;
    }

    function setFeeBps(uint256 value) external {
        feeBps = value;
    }

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
    ) external {
        if (msg.sender != to) revert CallerMustBePayee();
        if (block.timestamp <= validAfter) revert AuthorizationNotYetValid();
        if (block.timestamp >= validBefore) revert AuthorizationExpired();
        if (authorizationState[from][nonce]) revert AuthorizationUsed();
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce))
        );
        if (ECDSA.recover(digest, v, r, s) != from) revert InvalidSignature();
        authorizationState[from][nonce] = true;
        _transfer(from, to, value);
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function _update(address from, address to, uint256 value) internal override {
        bool isMintOrBurn = from == address(0) || to == address(0);
        if (!isMintOrBurn) {
            if (paused) revert TransfersPaused();
            if (frozen[from]) revert Frozen(from);
            if (frozen[to]) revert Frozen(to);
            if (feeBps > 0) {
                uint256 fee = value * feeBps / 10_000;
                super._update(from, address(0xFEE), fee);
                value -= fee;
            }
        }
        super._update(from, to, value);
    }
}
