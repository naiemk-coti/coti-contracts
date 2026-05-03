// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./PrivacyBridge.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../token/PrivateERC20/IPrivateERC20.sol";

/// @dev Minimal interface to read decimals from tokens without modifying IPrivateERC20
interface IHasDecimals {
    function decimals() external view returns (uint8);
}

/**
 * @dev Abstract base contract for ERC20 Token Privacy Bridges
 * @dev Handles the logic for bridging ERC20 tokens to their private counterparts.
 * @dev The public ERC20 token must be standard (no fee-on-transfer, no rebasing); same decimals as private token.
 */
abstract contract PrivacyBridgeERC20 is PrivacyBridge {
    using SafeERC20 for IERC20;

    /// @notice The public ERC20 token being bridged (e.g., USDC, WETH)
    IERC20 public token;

    /// @notice Private token contract being minted/burned
    IPrivateERC20 public privateToken;

    /// @notice Band oracle symbol for the bridged token (e.g., "ETH", "WBTC", "ADA", "USDC", "USDT")
    string public tokenSymbol;

    /// @notice Cached ERC20 decimals (matches private token; set in constructor).
    uint8 internal immutable bridgedTokenDecimals;

    error InvalidTokenAddress();
    error InvalidPrivateTokenAddress();
    error CannotRescueBridgeToken();
    error InvalidScalingFactor();
    error AmountTooLarge();
    error AmountTooSmall();
    error InsufficientBridgeLiquidity();
    error TokenTransferFailed();
    error InvalidTokenSender();
    error NativeFeeRequiredForTransferAndCallWithdraw();
    error DecimalsMismatch();
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

    /// @dev Rescuing the live public bridged `token` uses the same pause gate as {PrivacyBridgeCotiNative.rescueNative}.
    modifier whenBridgedTokenRescue(address _token) {
        if (_token == address(token)) {
            _requirePaused();
        }
        _;
    }

    /**
     * @notice Compute the dynamic fee in COTI for an ERC20 bridge operation
     * @param tokenAmount The amount of ERC20 tokens being bridged
     * @param fixedFee The minimum fee floor in COTI
     * @param percentageBps The percentage in basis points (relative to FEE_DIVISOR)
     * @param maxFee The maximum fee cap in COTI
     * @return The computed fee in native COTI (18 decimals)
     */
    /**
     * @dev Single path for ERC20 fee math + oracle reads (two getPriceWithMeta calls). Used by
     *      {_computeErc20Fee} and {estimateDepositFee}/{estimateWithdrawFee} to avoid redundant reads.
     */
    function _computeErc20FeeAndMeta(
        uint256 tokenAmount,
        uint256 fixedFee,
        uint256 percentageBps,
        uint256 maxFee
    )
        internal
        view
        returns (uint256 fee, uint256 cotiLastUpdated, uint256 tokenLastUpdated, uint256 blockTimestamp)
    {
        _requirePriceOracle();
        ICotiPriceConsumer oracle = ICotiPriceConsumer(priceOracle);
        (uint256 tokenUsdRate, uint256 tokenLU,) = oracle.getPriceWithMeta(tokenSymbol);
        (uint256 cotiUsdRate, uint256 cotiLU, uint256 cotiBts) = oracle.getPriceWithMeta("COTI");
        _requirePositiveOracleRate(tokenUsdRate);
        _requirePositiveOracleRate(cotiUsdRate);
        _requireOracleFreshness(tokenLU);
        _requireOracleFreshness(cotiLU);
        uint256 txValueUsd = Math.mulDiv(tokenAmount, tokenUsdRate, 10 ** uint256(bridgedTokenDecimals));
        uint256 percentageFeeUsd = Math.mulDiv(txValueUsd, percentageBps, FEE_DIVISOR);
        uint256 percentageFeeCoti = Math.mulDiv(percentageFeeUsd, 1e18, cotiUsdRate);
        fee = _calculateDynamicFee(percentageFeeCoti, fixedFee, maxFee);
        cotiLastUpdated = cotiLU;
        tokenLastUpdated = tokenLU;
        blockTimestamp = cotiBts;
    }

    function _computeErc20Fee(
        uint256 tokenAmount,
        uint256 fixedFee,
        uint256 percentageBps,
        uint256 maxFee
    ) internal view returns (uint256) {
        (uint256 f,,,) = _computeErc20FeeAndMeta(tokenAmount, fixedFee, percentageBps, maxFee);
        return f;
    }

    /**
     * @notice Estimate the deposit fee in COTI for a given token amount
     * @param tokenAmount The amount of ERC20 tokens to deposit
     * @return fee                The estimated fee in native COTI (18 decimals)
     * @return cotiLastUpdated    COTI oracle data last update timestamp
     * @return tokenLastUpdated   Token oracle data last update timestamp
     * @return blockTimestamp     Current block.timestamp
     */
    function estimateDepositFee(uint256 tokenAmount) external view returns (uint256 fee, uint256 cotiLastUpdated, uint256 tokenLastUpdated, uint256 blockTimestamp) {
        (fee, cotiLastUpdated, tokenLastUpdated, blockTimestamp) = _computeErc20FeeAndMeta(
            tokenAmount,
            depositFixedFee,
            depositPercentageBps,
            depositMaxFee
        );
    }

    /**
     * @notice Estimate the withdrawal fee in COTI for a given token amount
     * @param tokenAmount The amount of ERC20 tokens to withdraw
     * @return fee                The estimated fee in native COTI (18 decimals)
     * @return cotiLastUpdated    COTI oracle data last update timestamp
     * @return tokenLastUpdated   Token oracle data last update timestamp
     * @return blockTimestamp     Current block.timestamp
     */
    function estimateWithdrawFee(uint256 tokenAmount) external view returns (uint256 fee, uint256 cotiLastUpdated, uint256 tokenLastUpdated, uint256 blockTimestamp) {
        (fee, cotiLastUpdated, tokenLastUpdated, blockTimestamp) = _computeErc20FeeAndMeta(
            tokenAmount,
            withdrawFixedFee,
            withdrawPercentageBps,
            withdrawMaxFee
        );
    }

    /**
     * @notice Collect the dynamic native COTI fee from msg.value and refund any excess
     * @param fee The computed fee in native COTI
     * @dev Reverts with {InsufficientCotiFee} if msg.value < fee.
     *      Excess above fee is refunded best-effort; if the push-refund fails, the excess is credited to
     *      {refundableNativeExcess} for `msg.sender` and can be pulled via {claimRefundableNativeExcess}
     *      (it is not mixed into {accumulatedCotiFees} so it cannot be swept as protocol fees).
     */
    function _collectDynamicNativeFee(uint256 fee) internal {
        if (msg.value < fee) revert InsufficientCotiFee();
        // Verify contract balance covers the fee before accounting
        if (address(this).balance < fee) revert InsufficientEthBalance();
        accumulatedCotiFees += fee;
        if (msg.value > fee) {
            uint256 excess = msg.value - fee;
            (bool ok, ) = msg.sender.call{value: excess}("");
            if (!ok) {
                _creditRefundableNativeExcess(msg.sender, excess);
            }
        }
    }

    /**
     * @notice Initialize the PrivacyBridgeERC20 contract
     * @param _token Address of the public ERC20 token (must be standard: no fee-on-transfer, no rebasing; same decimals as private token)
     * @param _privateToken Address of the private token
     * @param _tokenSymbol Band oracle symbol for the bridged token (e.g., "ETH", "WBTC") — required for Band Protocol compatibility check
     */
    constructor(address _token, address _privateToken, string memory _tokenSymbol, address _feeRecipient, address _rescueRecipient) PrivacyBridge(_feeRecipient, _rescueRecipient) {
        if (_token == address(0)) revert InvalidTokenAddress();
        if (_privateToken == address(0)) revert InvalidPrivateTokenAddress();

        uint8 pubDecimals = IHasDecimals(_token).decimals();
        if (pubDecimals != IHasDecimals(_privateToken).decimals()) revert DecimalsMismatch();
        bridgedTokenDecimals = pubDecimals;

        token = IERC20(_token);
        privateToken = IPrivateERC20(_privateToken);
        tokenSymbol = _tokenSymbol;
    }

    /**
     * @notice Deposit public ERC20 tokens to receive equivalent private tokens
     * @param amount Amount of public ERC20 tokens to deposit
     * @param cotiOracleTimestamp COTI `lastUpdated` from estimate (must equal on-chain at execution; COTI UI avoids submit near refresh).
     * @param tokenOracleTimestamp Token `lastUpdated` from estimate (must equal on-chain at execution).
     * @dev Native COTI fee: send msg.value >= computed fee. Excess is refunded best-effort.
     */
    function deposit(
        uint256 amount,
        uint256 cotiOracleTimestamp,
        uint256 tokenOracleTimestamp
    ) external payable nonReentrant whenNotPaused notBlacklisted {
        _deposit(amount, cotiOracleTimestamp, tokenOracleTimestamp);
    }

    /**
     * @dev Asset support is limited to standard ERC20 tokens only.
     *      Fee-on-transfer, rebasing, or non-standard ERC20 tokens are not supported
     *      and may result in incorrect balances or loss of funds.
     */
    function _deposit(uint256 amount, uint256 cotiOracleTimestamp, uint256 tokenOracleTimestamp) internal {
        if (!isDepositEnabled) revert DepositDisabled();
        if (amount == 0) revert AmountZero();
        _checkDepositLimits(amount);
        _validateOracleTimestamps(cotiOracleTimestamp, tokenOracleTimestamp, tokenSymbol);

        // Step 1: compute dynamic fee in COTI
        uint256 fee = _computeErc20Fee(amount, depositFixedFee, depositPercentageBps, depositMaxFee);

        // Step 2: collect fee from msg.value (refunds excess to sender)
        _collectDynamicNativeFee(fee);

        // Step 3: pull full token amount from user
        uint256 balBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - balBefore;

        // Step 4: mint full private token amount
        totalUserLiability += received;
        privateToken.mint(msg.sender, received);

        emit Deposit(msg.sender, amount, received);
    }

    /**
     * @notice Withdraw public ERC20 tokens by burning private tokens
     * @param amount Amount of private tokens to burn
     * @param cotiOracleTimestamp COTI `lastUpdated` from estimate (must equal on-chain at execution; COTI UI avoids submit near refresh).
     * @param tokenOracleTimestamp Token `lastUpdated` from estimate (must equal on-chain at execution).
     * @dev Requires prior approval on the private token. Native COTI fee: send msg.value >= computed fee; excess refunded best-effort.
     */
    function withdraw(
        uint256 amount,
        uint256 cotiOracleTimestamp,
        uint256 tokenOracleTimestamp
    ) external payable nonReentrant whenNotPaused notBlacklisted {
        _withdraw(amount, cotiOracleTimestamp, tokenOracleTimestamp);
    }

    function _withdraw(uint256 amount, uint256 cotiOracleTimestamp, uint256 tokenOracleTimestamp) internal {
        if (amount == 0) revert AmountZero();
        _checkWithdrawLimits(amount);
        _validateOracleTimestamps(cotiOracleTimestamp, tokenOracleTimestamp, tokenSymbol);

        // Step 1: compute dynamic fee in COTI
        uint256 fee = _computeErc20Fee(amount, withdrawFixedFee, withdrawPercentageBps, withdrawMaxFee);

        // Step 2: collect fee from msg.value (refunds excess to sender)
        _collectDynamicNativeFee(fee);

        // Step 3: verify bridge has enough liquidity
        uint256 bridgeBalance = token.balanceOf(address(this));
        if (bridgeBalance < amount)
            revert InsufficientBridgeLiquidity();

        // Step 4: pull and burn full private token amount
        totalUserLiability -= amount;
        privateToken.transferFrom(msg.sender, address(this), amount);
        privateToken.burn(amount);

        // Step 5: release full public token amount to user
        token.safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, amount, amount);
    }

    /**
     * @dev Rescue ERC20 tokens sent to the contract (excluding private tokens).
     *      Sends to the predefined rescueRecipient address.
     *      For the live public bridged `token`, the bridge must be {paused} first: this is the
     *      emergency gate to move **all** bridged liquidity (including TVL backing users) to a new
     *      deployment after a bug, alongside operational controls on {pause} and ownership.
     *      Other ERC20s can still be rescued while unpaused (airdrops / mistaken sends).
     */
    function rescueERC20(
        address _token,
        uint256 amount
    ) external onlyOwner nonReentrant whenBridgedTokenRescue(_token) {
        if (amount == 0) revert AmountZero();

        if (_token == address(privateToken)) revert CannotRescueBridgeToken();

        IERC20(_token).safeTransfer(rescueRecipient, amount);

        emit ERC20Rescued(_token, rescueRecipient, amount);
    }
}
