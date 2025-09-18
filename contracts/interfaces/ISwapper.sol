// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

/**
 * @title ISwapper
 * @notice Interface for modular swap functionality
 * @dev Allows GovernanceHYBR to use different swap implementations
 */
interface ISwapper {
    /**
     * @notice Swap parameters for aggregator calls
     */
    struct SwapParams {
        address aggregator;     // Aggregator contract address
        address tokenIn;        // Input token address
        uint256 amountIn;       // Input token amount
        uint256 minAmountOut;   // Minimum HYBR expected
        bytes callData;         // Aggregator call data
    }

    /**
     * @notice Event emitted when aggregator whitelist is updated
     */
    event AggregatorWhitelisted(address indexed aggregator, bool whitelisted);

    /**
     * @notice Event emitted when a swap is executed
     */
    event SwappedToHYBR(
        address indexed executor,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 hybrOut
    );

    /**
     * @notice Event emitted when authorized caller is updated
     */
    event AuthorizedCallerUpdated(address indexed oldCaller, address indexed newCaller);

    /**
     * @notice Swap tokens to HYBR via aggregator with slippage protection
     * @param params Swap parameters including aggregator and calldata
     * @return hybrReceived Amount of HYBR received
     */
    function swapToHYBR(SwapParams calldata params) external returns (uint256 hybrReceived);

    /**
     * @notice Set aggregator whitelist status
     * @param aggregator Aggregator contract address
     * @param whitelisted Whether to whitelist or not
     */
    function setAggregatorWhitelist(address aggregator, bool whitelisted) external;

    /**
     * @notice Check if an aggregator is whitelisted
     * @param aggregator Aggregator address to check
     * @return whitelisted Whether the aggregator is whitelisted
     */
    function isWhitelistedAggregator(address aggregator) external view returns (bool whitelisted);

    /**
     * @notice Get the HYBR token address
     * @return hybr The HYBR token address
     */
    function HYBR() external view returns (address hybr);




    /**
     * @notice Emergency withdraw stuck tokens
     * @param token Token address to withdraw
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(address token, address to, uint256 amount) external;
}