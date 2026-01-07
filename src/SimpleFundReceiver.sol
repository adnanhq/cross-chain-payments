// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IExecutor} from "./interfaces/IExecutor.sol";
import {ISimpleFundReceiver} from "./interfaces/ISimpleFundReceiver.sol";
import {Ownable} from "./utils/Ownable.sol";
import {
    IERC20
} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title SimpleFundReceiver
 * @notice Minimal treasury-like contract that receives cross-chain payments
 * @dev Simplified PoC - just tracks payments and supports refunds
 */
contract SimpleFundReceiver is ISimpleFundReceiver, Ownable {
    using SafeERC20 for IERC20;

    /// @notice The Executor that can call this contract
    address public executor;

    /// @notice Payment record
    struct Payment {
        bytes32 intentId;
        address sender;
        address token;
        uint256 amount;
        bool refunded;
        uint256 timestamp;
    }

    /// @notice Payments by intentId
    mapping(bytes32 => Payment) public payments;

    /// @notice Total received per token
    mapping(address => uint256) public totalReceived;

    /// @notice Track if refunds are allowed (simulating campaign cancellation)
    bool public refundsEnabled;

    // Errors
    error Unauthorized();
    error PaymentNotFound();
    error AlreadyRefunded();
    error RefundsNotEnabled();
    error InsufficientBalance();

    // Events
    event PaymentReceived(
        bytes32 indexed intentId, address indexed sender, address token, uint256 amount, uint256 timestamp
    );
    event RefundInitiated(bytes32 indexed intentId, address token, uint256 amount, address recipient);

    constructor(address _executor) {
        executor = _executor;
    }

    /**
     * @inheritdoc ISimpleFundReceiver
     * @notice Process an incoming cross-chain payment
     * @dev Called by Executor after validating the intent
     */
    function processPayment(bytes32 intentId, address sender, address token, uint256 amount, bytes calldata) external {
        if (msg.sender != executor) revert Unauthorized();

        // Record the payment
        payments[intentId] = Payment({
            intentId: intentId,
            sender: sender,
            token: token,
            amount: amount,
            refunded: false,
            timestamp: block.timestamp
        });

        // Track totals
        totalReceived[token] += amount;

        emit PaymentReceived(intentId, sender, token, amount, block.timestamp);
    }

    /**
     * @notice Claim a refund for a payment
     * @dev Transfers tokens to executor and requests cross-chain refund
     * @param intentId The payment to refund
     */
    function claimRefund(bytes32 intentId) external {
        Payment memory payment = payments[intentId];

        // Verify payment exists
        if (payment.amount == 0) revert PaymentNotFound();

        // Check not already refunded
        if (payment.refunded) revert AlreadyRefunded();

        // Check refunds are enabled (simulating campaign failure/cancellation)
        if (!refundsEnabled) revert RefundsNotEnabled();

        // Check we have enough balance
        uint256 balance = IERC20(payment.token).balanceOf(address(this));
        if (balance < payment.amount) revert InsufficientBalance();

        // Mark as refunded
        payments[intentId].refunded = true;

        // Update totals
        totalReceived[payment.token] -= payment.amount;

        // Transfer tokens to executor
        IERC20(payment.token).safeTransfer(executor, payment.amount);

        // Request refund via executor - refund goes to original sender
        IExecutor(executor).requestRefund(intentId, payment.token, payment.amount, payment.sender);

        emit RefundInitiated(intentId, payment.token, payment.amount, payment.sender);
    }

    /**
     * @notice Get payment details
     * @param intentId The payment ID
     * @return payment The payment details
     */
    function getPayment(bytes32 intentId) external view returns (Payment memory) {
        return payments[intentId];
    }

    // Admin functions (simplified for PoC - no access control)

    /// @notice Enable refunds (simulating campaign cancellation)
    function enableRefunds() external onlyOwner {
        refundsEnabled = true;
    }

    /// @notice Disable refunds
    function disableRefunds() external onlyOwner {
        refundsEnabled = false;
    }

    /// @notice Update the executor address
    function setExecutor(address _executor) external onlyOwner {
        executor = _executor;
    }
}
