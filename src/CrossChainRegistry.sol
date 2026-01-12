// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ICrossChainRegistry} from "./interfaces/ICrossChainRegistry.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title CrossChainRegistry
 * @notice Manages cross-chain configuration including supported chains and bridge adapters
 */
contract CrossChainRegistry is ICrossChainRegistry, Ownable(msg.sender) {
    /// @notice Chain configurations
    mapping(uint256 => ChainConfig) private _chainConfigs;

    /// @notice Bridge adapter registry: chainId => bridgeId => (adapter, enabled)
    mapping(uint256 => mapping(bytes32 => AdapterInfo)) private _bridgeAdapters;

    struct AdapterInfo {
        address adapter;
        bool enabled;
    }

    /// @inheritdoc ICrossChainRegistry
    function setChainConfig(uint256 chainId, ChainConfig calldata config) external onlyOwner {
        _chainConfigs[chainId] = config;
        emit ChainConfigSet(chainId, config.isSupported, config.isPaused);
    }

    /// @inheritdoc ICrossChainRegistry
    function getChainConfig(uint256 chainId) external view returns (ChainConfig memory) {
        return _chainConfigs[chainId];
    }

    /// @inheritdoc ICrossChainRegistry
    function isChainSupported(uint256 chainId) external view returns (bool) {
        ChainConfig memory config = _chainConfigs[chainId];
        return config.isSupported && !config.isPaused;
    }

    /// @inheritdoc ICrossChainRegistry
    function setBridgeAdapter(uint256 chainId, bytes32 bridgeId, address adapter, bool enabled)
        external
        onlyOwner
    {
        _bridgeAdapters[chainId][bridgeId] = AdapterInfo({adapter: adapter, enabled: enabled});
        emit BridgeAdapterSet(chainId, bridgeId, adapter, enabled);
    }

    /// @inheritdoc ICrossChainRegistry
    function getBridgeAdapter(uint256 chainId, bytes32 bridgeId)
        external
        view
        returns (address adapter, bool enabled)
    {
        AdapterInfo memory info = _bridgeAdapters[chainId][bridgeId];
        return (info.adapter, info.enabled);
    }

    /// @inheritdoc ICrossChainRegistry
    function pauseChain(uint256 chainId) external onlyOwner {
        _chainConfigs[chainId].isPaused = true;
        emit ChainPaused(chainId);
    }

    /// @inheritdoc ICrossChainRegistry
    function unpauseChain(uint256 chainId) external onlyOwner {
        _chainConfigs[chainId].isPaused = false;
        emit ChainUnpaused(chainId);
    }
}
