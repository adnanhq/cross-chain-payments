// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title Ownable
 * @notice Minimal ownable implementation for PoC deployments.
 * @dev Keeps the PoC self-contained (Chainlink's vendored OZ does not include Ownable).
 */
abstract contract Ownable {
    address public owner;

    error NotOwner();
    error InvalidOwner();

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidOwner();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}

