# Cross-Chain Payment Infrastructure

PoC cross-chain payment infrastructure prepared for **Oak Network**, using **Chainlink CCIP** and **LayerZero v2 + Stargate v2**.

**Disclaimer:** If you intend to adopt or replicate this code in production, you should conduct your own due diligence, including security audits, testing, and compliance review.

---

## Overview

### Core Architecture

- **Source chain**: An authorized agent calls `IntentSender` to initiate a payment intent and bridge funds.
- **Destination chain**: A bridge-specific adapter (`ChainlinkCCIPAdapter` or `LayerZeroStargateAdapter`) validates provenance and forwards funds to `CrossChainExecutor`.
- **CrossChainExecutor**: Enforces idempotency via `intentId`, validates adapter integrity, approves the treasury, and dispatches the intent payload (e.g. `processPayment`).
- **SimpleFundReceiver**: Minimal treasury that receives payments and can request refunds via `requestRefund`.
- **Refunds**: Treasury calls `requestRefund(intentId, amount, recipient)`. An off-chain agent then calls `sendRefundCCIP` or `sendRefundLZStargate` to bridge funds back to the source chain.

### PoC Scope

- **Single destination chain**: The `IntentSender` is configured for one destination (one CCIP adapter, one LayerZero adapter). Multi-destination support would require additional configuration.
- **SimpleFundReceiver**: Minimal treasury that tracks payments and supports refunds. Production deployments would typically use a full treasury contract.

---

## Terminology

### CCIP

- **CCIP chain selector**: Chainlink’s identifier for a chain (not EVM `chainId`).

### LayerZero v2 / Stargate v2

- **EID (endpoint ID)**: LayerZero’s chain identifier (not EVM `chainId`).
- **Peer**: Trusted remote sender identity for a given source EID. In this PoC, the peer is the source-chain `IntentSender` (encoded as `bytes32`).
- **Stargate**: Token-bridging app on LayerZero v2; implements `IOFT` send/quote for bridged assets.

---

## Payment Flow: Chainlink CCIP

### Source Chain

1. **Agent → `IntentSender.sendIntentCCIP(intent, payload, gasLimit)`**
2. `IntentSender._sanitizeIntent(...)`:
   - Sets `intent.account = msg.sender`
   - Sets `intent.sourceChainId = block.chainid`
   - Validates amount, receiver, deadline
3. `IntentSender`:
   - Pulls tokens from the payer
   - Approves the CCIP router
   - Calls `CCIP_ROUTER.ccipSend(...)` with:
     - `data = abi.encode(intent, payload)`
     - `tokenAmounts` = bridged token and amount

### Destination Chain

4. **CCIP router → `ChainlinkCCIPAdapter._ccipReceive(message)`**
5. Adapter decodes `(intent, payload)` from `message.data` and verifies:
   - `executor.getIntentSender(intent.sourceChainId) == abi.decode(message.sender, (address))`
   - `executor.getCcipChainSelector(intent.sourceChainId) == message.sourceChainSelector`
   - Token and amount in the message match the intent
6. Adapter transfers received tokens to the executor and calls:
   - `Executor.executeIntent(keccak256("CCIP"), intent, payload)`

### Destination Execution

7. `Executor.executeIntent(...)` verifies:
   - Intent not already processed
   - Caller is the registered CCIP adapter
   - Intent status (or marks as Failed on validation error)
8. Executor approves the treasury and calls `intent.treasury.call(payload)` (e.g. `processPayment`).
9. Treasury pulls funds from the executor via `transferFrom`.

---

## Payment Flow: LayerZero v2 + Stargate v2 (Compose)

### Source Chain

1. **Agent → `IntentSender.sendIntentLZStargate(params, intent, payload)`**
2. `IntentSender._sanitizeIntent(...)`:
   - Sets `intent.account` and `intent.sourceChainId`
   - Validates amount, receiver, deadline
3. `IntentSender`:
   - Pulls tokens from the payer
   - Calls Stargate `send(...)` with `SendParam`:
     - `dstEid` = destination LayerZero EID
     - `to` = destination adapter address (as `bytes32`)
     - `composeMsg` = `abi.encode(intent, payload)`
     - `oftCmd` = taxi/compose mode
   - Pays `MessagingFee.nativeFee`

### Destination Chain

4. Stargate delivers tokens to the destination adapter and triggers the compose callback.
5. **LayerZero EndpointV2 → `LayerZeroStargateAdapter.lzCompose(from, guid, message, ...)`**
6. Adapter decodes `(intent, payload)` and verifies:
   - Caller is the LayerZero endpoint
   - `composeFrom == bytes32(uint256(uint160(executor.getIntentSender(intent.sourceChainId))))`
   - `executor.getLayerZeroEid(intent.sourceChainId) == srcEid`
   - `from` is the configured Stargate for the delivered token
7. Adapter transfers tokens to the executor and calls:
   - `Executor.executeIntent(keccak256("LAYERZERO"), intent, payload)`
8. Execution matches the CCIP path (same executor and treasury flow).

---

## Refund Flow

### Destination Chain (Initiate)

1. Owner enables refunds; user calls **`SimpleFundReceiver.claimRefund(intentId)`**
2. `SimpleFundReceiver`:
   - Transfers tokens to the executor
   - Calls **`Executor.requestRefund(intentId, amount, recipient)`**
3. Executor stores the refund request (including `sourceChainId` from the original intent).

### Destination Chain (Execute)

4. Agent calls **`Executor.sendRefundCCIP(intentId)`** or **`Executor.sendRefundLZStargate(intentId, stargate)`**
   - The refund bridge can differ from the inbound bridge.
5. Executor:
   - Fetches the adapter for the chosen bridge
   - Quotes fee via `adapter.quoteRefundFee(...)`
   - Approves the adapter and calls `adapter.sendRefund(...)`

### Source Chain (Bridge-Specific)

- **CCIP**: Adapter calls the CCIP router to bridge tokens to the recipient on the source chain.
- **LayerZero/Stargate**: Adapter calls Stargate `send(...)` to bridge tokens back to the recipient.

---

## Usage

### Build

```bash
forge build
```

### Deployment

#### Prerequisites

1. Choose a **source chain** (where the user pays) and a **destination chain** (where funds are received).
   - CCIP: both chains must be supported by CCIP.
   - LayerZero/Stargate: both must be supported by LayerZero v2 and Stargate v2.

2. Obtain native gas tokens on both chains.

3. Obtain a CCIP-transferable ERC20 on the source chain and its destination-chain counterpart.
   - For CCIP test tokens, see the [Chainlink test token docs](https://docs.chain.link/ccip).

4. Look up CCIP router addresses and chain selectors: [CCIP directory](https://docs.chain.link/ccip/directory)

5. Set environment variables:
   - `SOURCE_RPC_URL`, `DEST_RPC_URL`
   - `PRIVATE_KEY`
   - `AGENT` (authorized address for sending intents and executing refunds)

#### Step 1: Deploy on Destination Chain

```bash
export CCIP_ROUTER=<dest_chain_ccip_router>
export AGENT=<agent_address>

# Optional: configure executor during deployment
export SOURCE_CHAIN_ID=<source_chain_evm_chain_id>
export SOURCE_SENDER=<intent_sender_address>
export CCIP_SOURCE_CHAIN_SELECTOR=<source_chain_ccip_selector>
export LZ_SOURCE_EID=<source_chain_layerzero_eid>
export LZ_ENDPOINT_V2=<dest_chain_layerzero_endpoint>
export LZ_DESTINATION_TOKEN=<dest_token_delivered_by_stargate>
export LZ_DESTINATION_STARGATE=<dest_stargate_pool_for_token>

forge script script/DeployDestination.s.sol \
  --rpc-url $DEST_RPC_URL \
  --broadcast \
  --private-key $PRIVATE_KEY
```

Save: `CrossChainExecutor`, `ChainlinkCCIPAdapter`, `LayerZeroStargateAdapter` (if used), `SimpleFundReceiver`.

#### Step 2: Deploy on Source Chain

```bash
export AGENT=<agent_address>
export CCIP_ROUTER=<source_chain_ccip_router>
export CCIP_DEST_CHAIN_SELECTOR=<dest_chain_ccip_selector>
export CCIP_DEST_ADAPTER=<ccip_adapter_from_step_1>
export LZ_DEST_EID=<dest_chain_layerzero_eid>
export LZ_DEST_ADAPTER=<layerzero_adapter_from_step_1>

forge script script/DeploySource.s.sol \
  --rpc-url $SOURCE_RPC_URL \
  --broadcast \
  --private-key $PRIVATE_KEY
```

Save: `IntentSender`.

#### Step 3: Configure Executor (if not done at deploy)

If the source-chain `IntentSender` was deployed after the destination, configure the executor:

```bash
export EXECUTOR=<executor_address>
export SOURCE_CHAIN_ID=<source_chain_evm_chain_id>
export SOURCE_SENDER=<intent_sender_from_step_2>
export CCIP_SOURCE_CHAIN_SELECTOR=<source_chain_ccip_selector>
export LZ_SOURCE_EID=<source_chain_layerzero_eid>

forge script script/ConfigureExecutor.s.sol \
  --rpc-url $DEST_RPC_URL \
  --broadcast \
  --private-key $PRIVATE_KEY
```

#### Step 4: Send a Cross-Chain Payment

```bash
export SENDER=<intent_sender_address>
export DEST_ADAPTER=<ccip_or_lz_adapter_address>
export AMOUNT=<amount_in_token_decimals>

# CCIP
export BRIDGE=CCIP
export DEST_CHAIN_SELECTOR=<dest_chain_ccip_selector>
# Plus: SOURCE_TOKEN, intent params, etc.

# LayerZero/Stargate
export BRIDGE=LAYERZERO
export STARGATE=<stargate_pool_address>
export DST_EID=<dest_chain_layerzero_eid>
# Plus: MIN_AMOUNT_LD, intent params, etc.

forge script script/SendIntent.s.sol \
  --rpc-url $SOURCE_RPC_URL \
  --broadcast \
  --private-key $PRIVATE_KEY
```

#### Step 5: Track and Verify

1. Track CCIP messages at [ccip.chain.link](https://ccip.chain.link)
2. Verify payment on destination:
   ```bash
   cast call $DEST_RECEIVER "getPayment(bytes32)" $INTENT_ID --rpc-url $DEST_RPC_URL
   ```

### Notes

- `SOURCE_CHAIN_ID` is the EVM `chainId`; `DEST_CHAIN_SELECTOR` is the CCIP chain selector.
- LayerZero uses `EID` (endpoint ID) for chain identification.
- `intent.treasury` is the destination-chain contract that receives the payment (e.g. `SimpleFundReceiver`).
- `payload` is the ABI-encoded calldata for the treasury function (e.g. `processPayment(intentId, sender, token, amount, "")`).

---

## Sample Cross-Chain Transactions

Example testnet transactions:

- **Ethereum Sepolia → Base Sepolia (Payment):** [0xcd5bb85acc91ca6bf76cdce60a2a79974a4037a4ec2f5949a9e58d2c21a6b2a9](https://ccip.chain.link/#/side-drawer/msg/0xcd5bb85acc91ca6bf76cdce60a2a79974a4037a4ec2f5949a9e58d2c21a6b2a9)
- **Base Sepolia → Ethereum Sepolia (Refund):** [0xd6349d3020871e8b6ae64be262732788fd0aeb5a8d2237d830783b58502ad4d1](https://ccip.chain.link/#/side-drawer/msg/0xd6349d3020871e8b6ae64be262732788fd0aeb5a8d2237d830783b58502ad4d1)
