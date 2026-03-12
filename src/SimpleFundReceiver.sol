// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ICrossChainExecutor} from "./interfaces/ICrossChainExecutor.sol";
import {ISimpleFundReceiver} from "./interfaces/ISimpleFundReceiver.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title SimpleFundReceiver
 * @author 0x4dnanH (https://github.com/adnanhq)
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
    }

    /// @notice Payments by intentId
    mapping(bytes32 => Payment) private _payments;

    /// @notice Total received per token
    mapping(address => uint256) public totalReceived;

    // Errors
    error SimpleFundReceiver__Unauthorized();
    error SimpleFundReceiver__PaymentNotFound();
    error SimpleFundReceiver__InsufficientBalance();

    // Events
    event PaymentReceived(
        bytes32 indexed intentId, address indexed sender, address token, uint256 amount, uint256 timestamp
    );
    event RefundInitiated(bytes32 indexed intentId, address token, uint256 amount, address recipient);

    constructor(address _executor) Ownable(msg.sender) {
        executor = _executor;
    }

    /**
     * @inheritdoc ISimpleFundReceiver
     * @notice Process an incoming cross-chain payment
     * @dev Called by Executor after validating the intent
     */
    function processPayment(bytes32 intentId, address sender, address token, uint256 amount, bytes calldata) external {
        if (msg.sender != executor) revert SimpleFundReceiver__Unauthorized();

        // Pull the settled funds from the executor using the allowance granted for this payment.
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Record the payment
        _payments[intentId] = Payment({
            intentId: intentId, 
            sender: sender, 
            token: token, 
            amount: amount
        });

        // Track totals
        totalReceived[token] += amount;

        emit PaymentReceived(intentId, sender, token, amount, block.timestamp);
    }

    /**
     * @notice Initiate a refund for a payment
     * @dev Approves tokens for the executor which will pull them and request a cross-chain refund
     * @param intentId The payment to refund
     */
    function initiateRefund(bytes32 intentId) external onlyOwner {
        Payment memory payment = _payments[intentId];

        // Verify payment exists (amount == 0 means not found or already refunded/deleted)
        if (payment.amount == 0) revert SimpleFundReceiver__PaymentNotFound();

        // Check we have enough balance
        uint256 balance = IERC20(payment.token).balanceOf(address(this));
        if (balance < payment.amount) revert SimpleFundReceiver__InsufficientBalance();

        // Delete payment record (prevents double-refund)
        delete _payments[intentId];

        // Update totals
        totalReceived[payment.token] -= payment.amount;

        // Approve tokens for executor to pull
        IERC20(payment.token).forceApprove(executor, payment.amount);

        // Create refund intent via executor - refund goes to original sender
        ICrossChainExecutor(executor).createRefundIntent(intentId, payment.amount, payment.sender);

        emit RefundInitiated(intentId, payment.token, payment.amount, payment.sender);
    }

    /**
     * @notice Get payment details
     * @param intentId The payment ID
     * @return payment The payment details
     */
    function getPayment(bytes32 intentId) external view returns (Payment memory) {
        return _payments[intentId];
    }

    /// @notice Update the executor address
    function setExecutor(address _executor) external onlyOwner {
        executor = _executor;
    }
}
