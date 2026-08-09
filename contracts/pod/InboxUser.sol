// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "./IInbox.sol";

/// @title InboxUser
/// @notice Mixin that binds a contract to an {IInbox} and provides callback auth helpers.
/// @dev Prefer {onlyInboxPeer} for inbound peer delivery and {onlyInboxReturnLeg} for linked
///      respond/raise/system-error callbacks. {onlyInbox} is transport-only (not origin auth).
abstract contract InboxUser {
    /// @notice Cross-chain inbox used for messaging.
    IInbox public inbox;

    /// @notice Registered remote peer per source chain id (`inboxMsgSender` remote contract).
    mapping(uint256 => address) public trustedRemote;

    /// @notice Caller is not the configured inbox.
    error OnlyInbox(address caller);

    /// @notice Inbox delivery peer does not match {trustedRemote} for the source chain.
    error UntrustedPeer(uint256 chainId, address peer);

    /// @notice Call is not a linked return leg (`inboxSourceRequestId` is zero).
    error NotLinkedReturnLeg();

    /// @notice Zero address is not a valid inbox.
    error ZeroInbox();

    /// @notice Restrict a function to the configured inbox (transport only).
    /// @dev Does **not** authenticate the remote origin. Prefer {onlyInboxPeer} or
    ///      {onlyInboxReturnLeg} for state-changing handlers unless you deliberately want
    ///      any remote that can reach this inbox to invoke the entrypoint.
    modifier onlyInbox() {
        if (msg.sender != address(inbox)) {
            revert OnlyInbox(msg.sender);
        }
        _;
    }

    /// @notice Restrict to inbox delivery from a registered {trustedRemote} peer.
    /// @dev Use for inbound entrypoints that must originate from a known remote contract.
    modifier onlyInboxPeer() {
        if (msg.sender != address(inbox)) {
            revert OnlyInbox(msg.sender);
        }
        (uint256 srcChain, address srcContract) = inbox.inboxMsgSender();
        address expected = trustedRemote[srcChain];
        if (expected == address(0) || srcContract != expected) {
            revert UntrustedPeer(srcChain, srcContract);
        }
        _;
    }

    /// @notice Restrict to inbox delivery of a linked return leg (callback / raise / system error).
    /// @dev Peer equality is intentionally not required: system-error legs are attributed to
    ///      {IInbox} `SYSTEM_SENDER`. Always combine with app-level pending/status checks when
    ///      settling value.
    modifier onlyInboxReturnLeg() {
        if (msg.sender != address(inbox)) {
            revert OnlyInbox(msg.sender);
        }
        if (inbox.inboxSourceRequestId() == bytes32(0)) {
            revert NotLinkedReturnLeg();
        }
        _;
    }

    /// @notice Set the inbox contract (typically once from a constructor or initializer).
    /// @param _inbox Inbox address; must be non-zero.
    function setInbox(address _inbox) internal {
        if (_inbox == address(0)) {
            revert ZeroInbox();
        }
        inbox = IInbox(_inbox);
    }

    /// @notice Register the expected remote peer for `chainId_`.
    /// @param chainId_ Source chain id reported by {IInbox.inboxMsgSender}.
    /// @param peer Remote contract address expected on that chain.
    function _setTrustedRemote(uint256 chainId_, address peer) internal {
        trustedRemote[chainId_] = peer;
    }
}
