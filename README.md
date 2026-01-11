# Cross-Chain Payment PoC

A proof-of-concept for cross-chain payments using **Chainlink CCIP** and **LayerZero v2 + Stargate v2**.

## Build

```bash
forge build
```

## Deployment

### Prerequisites

1. Pick a **source chain** (where the user pays) and a **destination chain** (where funds are received/executed).
   - For CCIP flows: both must be supported by CCIP.
   - For LayerZero/Stargate flows: both must be supported by LayerZero v2 + Stargate v2.

2. Get native gas tokens on both chains (for deployment + transactions).

3. Get a CCIP-transferable ERC20 on the **source chain** and note the corresponding ERC20 on the **destination chain**.
   - If you use Chainlink CCIP test tokens, see the test token docs and mint on your source chain.

4. Look up the CCIP router addresses + CCIP chain selectors for your chosen chains:
   - https://docs.chain.link/ccip/directory

5. Set up RPC URLs and a private key:
   - `SOURCE_RPC_URL` (source chain)
   - `DEST_RPC_URL` (destination chain)
   - `PRIVATE_KEY`

### Step 1: Deploy on Destination Chain

```bash
export CCIP_ROUTER=<dest_chain_ccip_router>
export SOURCE_CHAIN_SELECTOR=<source_chain_ccip_selector>
# Optional: if you already know the source sender contract (IntentSender), you can set it during deployment:
# export SOURCE_SENDER=<source_chain_intent_sender_address>

# Optional (LayerZero/Stargate): deploy + partially configure the LayerZero adapter during destination deployment
# export LZ_ENDPOINT_V2=<dest_chain_layerzero_endpoint_v2>
# export LZ_SOURCE_EID=<source_chain_layerzero_eid>
# export LZ_DESTINATION_TOKEN=<dest_chain_token_delivered_by_stargate>
# export LZ_DESTINATION_STARGATE=<dest_chain_stargate_v2_for_that_token>

forge script script/DeployDestination.s.sol \
  --rpc-url $DEST_RPC_URL \
  --broadcast \
  --private-key $PRIVATE_KEY
```

Save the output addresses: `Registry`, `Executor`, `ChainlinkCCIPAdapter`, `LayerZeroStargateAdapter` (if enabled), `Receiver`

### Step 2: Deploy on Source Chain

```bash
export CCIP_ROUTER=<source_chain_ccip_router>

forge script script/DeploySource.s.sol \
  --rpc-url $SOURCE_RPC_URL \
  --broadcast \
  --private-key $PRIVATE_KEY
```

Save the output: `IntentSender`

### Step 3: Configure Adapter

Allow the source chain sender (`IntentSender`) on the destination **CCIP** adapter:

```bash
export ADAPTER=<adapter_address_from_step_1>
export SOURCE_CHAIN_SELECTOR=<source_chain_ccip_selector>
export SOURCE_SENDER=<sender_address_from_step_2>

forge script script/ConfigureAdapter.s.sol \
  --rpc-url $DEST_RPC_URL \
  --broadcast \
  --private-key $PRIVATE_KEY
```

### Step 3b (LayerZero/Stargate): Configure LayerZero Adapter

If you deployed the destination chain before knowing the source `IntentSender`, configure the LayerZero adapter now:

```bash
export ADAPTER=<layerzero_adapter_address_from_step_1>
export SOURCE_CHAIN_SELECTOR=<source_chain_selector_used_in_registry>
export LZ_SOURCE_EID=<source_chain_layerzero_eid>
export SOURCE_SENDER=<intent_sender_address_from_step_2>

export LZ_DESTINATION_TOKEN=<dest_chain_token_delivered_by_stargate>
export LZ_DESTINATION_STARGATE=<dest_chain_stargate_v2_for_that_token>

# Optional: if refunds should use a different dstEid than sourceEid:
# export LZ_DST_EID=<source_chain_layerzero_eid>

forge script script/ConfigureLayerZeroAdapter.s.sol \
  --rpc-url $DEST_RPC_URL \
  --broadcast \
  --private-key $PRIVATE_KEY
```

### Step 4: Send a Cross-Chain Payment (CCIP or LayerZero)

```bash
export SOURCE_CHAIN_SELECTOR=<source_chain_ccip_selector>
export SOURCE_TOKEN=<source_chain_token_address>
export DEST_TOKEN=<dest_chain_token_address>      # may differ from SOURCE_TOKEN
export SENDER=<intent_sender_contract_address>
export DEST_ADAPTER=<adapter_address>
export DEST_RECEIVER=<receiver_address>
export AMOUNT=<amount_in_token_decimals>

# Choose bridge:
# - CCIP: BRIDGE=CCIP and set DEST_CHAIN_SELECTOR
# - LayerZero/Stargate: BRIDGE=LAYERZERO and set STARGATE + DST_EID (+ optional MIN_AMOUNT_LD/LZ_EXTRA_OPTIONS)
export BRIDGE=CCIP
export DEST_CHAIN_SELECTOR=<dest_chain_ccip_selector>

forge script script/SendIntent.s.sol \
  --rpc-url $SOURCE_RPC_URL \
  --broadcast \
  --private-key $PRIVATE_KEY
```

### Step 5: Track & Verify

1. Track the CCIP message at https://ccip.chain.link (paste the Message ID)
2. Wait for "Success" status
3. Verify payment on destination:
   ```bash
   cast call $DEST_RECEIVER "getPayment(bytes32)" $INTENT_ID --rpc-url $DEST_RPC_URL
   ```

### Notes

- `SOURCE_CHAIN_SELECTOR` / `DEST_CHAIN_SELECTOR` are **CCIP chain selectors**, not EVM `chainId`.
- LayerZero uses **endpoint IDs** (EIDs): `LZ_SOURCE_EID` / `DST_EID`.
- Destination-side intent semantics:
  - `intent.destinationToken` is the **destination-chain** ERC20 expected to be delivered
  - `SOURCE_TOKEN` is the **source-chain** ERC20 that CCIP or Stargate bridges

Router addresses and chain selectors: https://docs.chain.link/ccip/directory

## Sample Cross-Chain Transactions

Example testnet transactions demonstrating the full payment + refund flow:

- **Ethereum Sepolia → Base Sepolia (Payment):** [0xcd5bb85acc91ca6bf76cdce60a2a79974a4037a4ec2f5949a9e58d2c21a6b2a9](https://ccip.chain.link/#/side-drawer/msg/0xcd5bb85acc91ca6bf76cdce60a2a79974a4037a4ec2f5949a9e58d2c21a6b2a9)

- **Base Sepolia → Ethereum Sepolia (Refund):** [0xd6349d3020871e8b6ae64be262732788fd0aeb5a8d2237d830783b58502ad4d1](https://ccip.chain.link/#/side-drawer/msg/0xd6349d3020871e8b6ae64be262732788fd0aeb5a8d2237d830783b58502ad4d1)
