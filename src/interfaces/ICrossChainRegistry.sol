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
    /// @param chainSelector The chain selector
    /// @param config The chain configuration
    function setChainConfig(uint64 chainSelector, ChainConfig calldata config) external;

    /// @notice Get the configuration for a chain
    /// @param chainSelector The chain selector
    /// @return config The chain configuration
    function getChainConfig(uint64 chainSelector) external view returns (ChainConfig memory config);

    /// @notice Check if a chain is supported
    /// @param chainSelector The chain selector
    /// @return supported True if supported
    function isChainSupported(uint64 chainSelector) external view returns (bool supported);

    /// @notice Register a bridge adapter for a (chainSelector, bridgeId) pair
    /// @param chainSelector The chain selector
    /// @param bridgeId The bridge identifier (e.g., keccak256("CCIP"))
    /// @param adapter The adapter contract address
    /// @param enabled Whether the adapter is enabled
    function setBridgeAdapter(uint64 chainSelector, bytes32 bridgeId, address adapter, bool enabled) external;

    /// @notice Get the bridge adapter for a (chainSelector, bridgeId) pair
    /// @param chainSelector The chain selector
    /// @param bridgeId The bridge identifier
    /// @return adapter The adapter address
    /// @return enabled Whether it's enabled
    function getBridgeAdapter(uint64 chainSelector, bytes32 bridgeId)
        external
        view
        returns (address adapter, bool enabled);

    /// @notice Pause a chain
    /// @param chainSelector The chain selector
    function pauseChain(uint64 chainSelector) external;

    /// @notice Unpause a chain
    /// @param chainSelector The chain selector
    function unpauseChain(uint64 chainSelector) external;

    // Events
    event ChainConfigSet(uint64 indexed chainSelector, bool isSupported, bool isPaused);
    event BridgeAdapterSet(uint64 indexed chainSelector, bytes32 indexed bridgeId, address adapter, bool enabled);
    event ChainPaused(uint64 indexed chainSelector);
    event ChainUnpaused(uint64 indexed chainSelector);
}

