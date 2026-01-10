# Cross-Chain Payment PoC

A proof-of-concept for cross-chain payments using Chainlink CCIP.

## Build

```bash
forge build
```

## Deployment

### Prerequisites

1. Pick a **source chain** (where the user pays) and a **destination chain** (where funds are received/executed). Both must be supported by CCIP.

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
# Optional: if you already know the source sender contract, you can set it during deployment:
# export SOURCE_SENDER=<source_chain_ccip_sender_contract_address>

forge script script/DeployDestination.s.sol \
  --rpc-url $DEST_RPC_URL \
  --broadcast \
  --private-key $PRIVATE_KEY
```

Save the output addresses: `Registry`, `Executor`, `Adapter`, `Receiver`

### Step 2: Deploy on Source Chain

```bash
export CCIP_ROUTER=<source_chain_ccip_router>

forge script script/DeploySource.s.sol \
  --rpc-url $SOURCE_RPC_URL \
  --broadcast \
  --private-key $PRIVATE_KEY
```

Save the output: `CCIPSender`

### Step 3: Configure Adapter

Allow the source chain sender on the destination adapter:

```bash
export ADAPTER=<adapter_address_from_step_1>
export SOURCE_CHAIN_SELECTOR=<source_chain_ccip_selector>
export SOURCE_SENDER=<sender_address_from_step_2>

forge script script/ConfigureAdapter.s.sol \
  --rpc-url $DEST_RPC_URL \
  --broadcast \
  --private-key $PRIVATE_KEY
```

### Step 4: Send a Cross-Chain Payment

```bash
export SOURCE_CHAIN_SELECTOR=<source_chain_ccip_selector>
export SOURCE_TOKEN=<source_chain_token_address>
export DEST_TOKEN=<dest_chain_token_address>      # may differ from SOURCE_TOKEN
export SENDER=<ccip_sender_contract_address>
export DEST_ADAPTER=<adapter_address>
export DEST_RECEIVER=<receiver_address>
export DEST_CHAIN_SELECTOR=<dest_chain_ccip_selector>
export AMOUNT=<amount_in_token_decimals>

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
- Destination-side intent semantics:
  - `intent.destinationToken` is the **destination-chain** ERC20 expected to be delivered
  - `SOURCE_TOKEN` is the **source-chain** ERC20 that CCIP bridges

Router addresses and chain selectors: https://docs.chain.link/ccip/directory

## Sample Cross-Chain Transactions

Example testnet transactions demonstrating the full payment + refund flow:

- **Ethereum Sepolia → Base Sepolia (Payment):** [0xcd5bb85acc91ca6bf76cdce60a2a79974a4037a4ec2f5949a9e58d2c21a6b2a9](https://ccip.chain.link/#/side-drawer/msg/0xcd5bb85acc91ca6bf76cdce60a2a79974a4037a4ec2f5949a9e58d2c21a6b2a9)

- **Base Sepolia → Ethereum Sepolia (Refund):** [0xd6349d3020871e8b6ae64be262732788fd0aeb5a8d2237d830783b58502ad4d1](https://ccip.chain.link/#/side-drawer/msg/0xd6349d3020871e8b6ae64be262732788fd0aeb5a8d2237d830783b58502ad4d1)
