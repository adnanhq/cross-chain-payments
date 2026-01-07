// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ICrossChainRegistry} from "./interfaces/ICrossChainRegistry.sol";
import {Ownable} from "./utils/Ownable.sol";

/**
 * @title CrossChainRegistry
 * @notice Manages cross-chain configuration including supported chains and bridge adapters
 */
contract CrossChainRegistry is ICrossChainRegistry, Ownable {
    /// @notice Chain configurations
    mapping(uint64 => ChainConfig) private _chainConfigs;

    /// @notice Bridge adapter registry: chainSelector => bridgeId => (adapter, enabled)
    mapping(uint64 => mapping(bytes32 => AdapterInfo)) private _bridgeAdapters;

    struct AdapterInfo {
        address adapter;
        bool enabled;
    }

    /// @inheritdoc ICrossChainRegistry
    function setChainConfig(uint64 chainSelector, ChainConfig calldata config) external onlyOwner {
        _chainConfigs[chainSelector] = config;
        emit ChainConfigSet(chainSelector, config.isSupported, config.isPaused, config.minAmount, config.maxAmount);
    }

    /// @inheritdoc ICrossChainRegistry
    function getChainConfig(uint64 chainSelector) external view returns (ChainConfig memory) {
        return _chainConfigs[chainSelector];
    }

    /// @inheritdoc ICrossChainRegistry
    function isChainSupported(uint64 chainSelector) external view returns (bool) {
        ChainConfig memory config = _chainConfigs[chainSelector];
        return config.isSupported && !config.isPaused;
    }

    /// @inheritdoc ICrossChainRegistry
    function setBridgeAdapter(uint64 chainSelector, bytes32 bridgeId, address adapter, bool enabled)
        external
        onlyOwner
    {
        _bridgeAdapters[chainSelector][bridgeId] = AdapterInfo({adapter: adapter, enabled: enabled});
        emit BridgeAdapterSet(chainSelector, bridgeId, adapter, enabled);
    }

    /// @inheritdoc ICrossChainRegistry
    function getBridgeAdapter(uint64 chainSelector, bytes32 bridgeId)
        external
        view
        returns (address adapter, bool enabled)
    {
        AdapterInfo memory info = _bridgeAdapters[chainSelector][bridgeId];
        return (info.adapter, info.enabled);
    }

    /// @inheritdoc ICrossChainRegistry
    function pauseChain(uint64 chainSelector) external onlyOwner {
        _chainConfigs[chainSelector].isPaused = true;
        emit ChainPaused(chainSelector);
    }

    /// @inheritdoc ICrossChainRegistry
    function unpauseChain(uint64 chainSelector) external onlyOwner {
        _chainConfigs[chainSelector].isPaused = false;
        emit ChainUnpaused(chainSelector);
    }
}
