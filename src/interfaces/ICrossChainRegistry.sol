// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title ICrossChainRegistry
 * @notice Interface for managing cross-chain configuration
 */
interface ICrossChainRegistry {
    /// @notice Configuration for a supported chain
    struct ChainConfig {
        bool isSupported;
        bool isPaused;
    }

    /// @notice Register or update a source chain configuration
    /// @param chainId The EVM chainId
    /// @param config The chain configuration
    function setChainConfig(uint256 chainId, ChainConfig calldata config) external;

    /// @notice Get the configuration for a chain
    /// @param chainId The EVM chainId
    /// @return config The chain configuration
    function getChainConfig(uint256 chainId) external view returns (ChainConfig memory config);

    /// @notice Check if a chain is supported
    /// @param chainId The EVM chainId
    /// @return supported True if supported
    function isChainSupported(uint256 chainId) external view returns (bool supported);

    /// @notice Register a bridge adapter for a (chainId, bridgeId) pair
    /// @param chainId The EVM chainId
    /// @param bridgeId The bridge identifier (e.g., keccak256("CCIP"))
    /// @param adapter The adapter contract address
    /// @param enabled Whether the adapter is enabled
    function setBridgeAdapter(uint256 chainId, bytes32 bridgeId, address adapter, bool enabled) external;

    /// @notice Get the bridge adapter for a (chainId, bridgeId) pair
    /// @param chainId The EVM chainId
    /// @param bridgeId The bridge identifier
    /// @return adapter The adapter address
    /// @return enabled Whether it's enabled
    function getBridgeAdapter(uint256 chainId, bytes32 bridgeId)
        external
        view
        returns (address adapter, bool enabled);

    /// @notice Pause a chain
    /// @param chainId The EVM chainId
    function pauseChain(uint256 chainId) external;

    /// @notice Unpause a chain
    /// @param chainId The EVM chainId
    function unpauseChain(uint256 chainId) external;

    // Events
    event ChainConfigSet(uint256 indexed chainId, bool isSupported, bool isPaused);
    event BridgeAdapterSet(uint256 indexed chainId, bytes32 indexed bridgeId, address adapter, bool enabled);
    event ChainPaused(uint256 indexed chainId);
    event ChainUnpaused(uint256 indexed chainId);
}

