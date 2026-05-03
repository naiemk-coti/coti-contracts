// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./PrivacyBridge.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../token/PrivateERC20/tokens/PrivateCOTI.sol";

/**
 * @title PrivacyBridgeCotiNative
 * @notice Bridge contract for converting between native COTI and privacy-preserving COTI.p tokens
 */
contract PrivacyBridgeCotiNative is PrivacyBridge {
    PrivateCOTI public privateCoti;

    event NativeRescued(address indexed to, uint256 amount);

    // Scaling factor removed (using native 18 decimals due to uint256 upgrade)

    /**
     * @notice Initialize the Native Bridge
     * @param _privateCoti Address of the PrivateCoti token contract
     * @param _priceOracle Non-zero price oracle (see {PrivacyBridge}'s constructor)
     */
    constructor(address _privateCoti, address _feeRecipient, address _rescueRecipient, address _priceOracle) PrivacyBridge(_feeRecipient, _rescueRecipient, _priceOracle) {
        if (_privateCoti == address(0)) revert InvalidAddress();
        privateCoti = PrivateCOTI(_privateCoti);
    }

    /**
     * @notice Compute the dynamic fee in native COTI
     * @param cotiAmount The COTI amount to compute fee for
     * @param fixedFee The minimum fee floor in COTI wei
     * @param percentageBps The percentage in basis points (relative to FEE_DIVISOR)
     * @param maxFee The maximum fee cap in COTI wei
     * @return The computed fee in COTI wei
     */
    /**
     * @dev Native COTI fee math + one {getPriceWithMeta("COTI")} read. Used by {_computeCotiFee} and
     *      {estimateDepositFee}/{estimateWithdrawFee}. Extreme `cotiAmount`×`cotiUsdRate` values can make
     *      {Math.mulDiv} revert—keep amounts within configured max deposit/withdraw limits.
     */
    function _computeCotiFeeAndMeta(
        uint256 cotiAmount,
        uint256 fixedFee,
        uint256 percentageBps,
        uint256 maxFee
    ) internal view returns (uint256 fee, uint256 cotiLastUpdated, uint256 blockTimestamp) {
        _requirePriceOracle();
        (uint256 cotiUsdRate, uint256 cotiLU, uint256 cotiBts) = ICotiPriceConsumer(priceOracle).getPriceWithMeta("COTI");
        _requirePositiveOracleRate(cotiUsdRate);
        _requireOracleFreshness(cotiLU);
        uint256 txValueUsd = Math.mulDiv(cotiAmount, cotiUsdRate, 1e18);
        uint256 percentageFeeUsd = Math.mulDiv(txValueUsd, percentageBps, FEE_DIVISOR);
        uint256 percentageFeeCoti = Math.mulDiv(percentageFeeUsd, 1e18, cotiUsdRate);
        fee = _calculateDynamicFee(percentageFeeCoti, fixedFee, maxFee);
        cotiLastUpdated = cotiLU;
        blockTimestamp = cotiBts;
    }

    function _computeCotiFee(
        uint256 cotiAmount,
        uint256 fixedFee,
        uint256 percentageBps,
        uint256 maxFee
    ) internal view returns (uint256) {
        (uint256 f,,) = _computeCotiFeeAndMeta(cotiAmount, fixedFee, percentageBps, maxFee);
        return f;
    }

    /**
     * @notice Estimate the deposit fee in COTI for a given COTI amount
     * @param cotiAmount The amount of native COTI to deposit (wei; very large values can revert in fee math)
     * @return fee                The estimated fee in COTI wei
     * @return cotiLastUpdated    COTI oracle data last update timestamp
     * @return blockTimestamp     Third field from the COTI oracle row (same as pre-refactor behavior)
     * @dev Use `cotiLastUpdated` for **both** `cotiOracleTimestamp` and `tokenOracleTimestamp` on {deposit}/{withdraw}
     *      (native bridge validates `"COTI"` twice). See {PrivacyBridge._validateOracleTimestamps}.
     */
    function estimateDepositFee(uint256 cotiAmount) external view returns (uint256 fee, uint256 cotiLastUpdated, uint256 blockTimestamp) {
        (fee, cotiLastUpdated, blockTimestamp) = _computeCotiFeeAndMeta(
            cotiAmount,
            depositFixedFee,
            depositPercentageBps,
            depositMaxFee
        );
    }

    /**
     * @notice Estimate the withdrawal fee in COTI for a given COTI amount
     * @param cotiAmount The amount of native COTI to withdraw (wei; very large values can revert in fee math)
     * @return fee                The estimated fee in COTI wei
     * @return cotiLastUpdated    COTI oracle data last update timestamp
     * @return blockTimestamp     Third field from the COTI oracle row (same as pre-refactor behavior)
     * @dev Same timestamp usage as {estimateDepositFee} for the subsequent {withdraw}.
     */
    function estimateWithdrawFee(uint256 cotiAmount) external view returns (uint256 fee, uint256 cotiLastUpdated, uint256 blockTimestamp) {
        (fee, cotiLastUpdated, blockTimestamp) = _computeCotiFeeAndMeta(
            cotiAmount,
            withdrawFixedFee,
            withdrawPercentageBps,
            withdrawMaxFee
        );
    }

    /**
     * @notice Internal function to handle deposits
     * @param sender Address of the depositor
     */
    function _deposit(address sender, uint256 cotiOracleTimestamp, uint256 tokenOracleTimestamp) internal {
        if (!isDepositEnabled) revert DepositDisabled();
        if (msg.value == 0) revert AmountZero();

        _checkDepositLimits(msg.value);
        _validateOracleTimestamps(cotiOracleTimestamp, tokenOracleTimestamp, "COTI");

        // Compute dynamic fee in COTI
        uint256 fee = _computeCotiFee(msg.value, depositFixedFee, depositPercentageBps, depositMaxFee);
        uint256 netAmount = msg.value - fee;
        if (netAmount == 0) revert AmountZero();

        accumulatedCotiFees += fee;

        totalUserLiability += netAmount;
        privateCoti.mint(sender, netAmount);

        // Emit gross deposit amount and net private tokens minted
        emit Deposit(sender, msg.value, netAmount);
    }

    /**
     * @notice Deposit native COTI to receive private COTI (COTI.p)
     * @param cotiOracleTimestamp COTI `lastUpdated` from the latest `estimateDepositFee` (must still equal on-chain at execution).
     * @param tokenOracleTimestamp Same value as `cotiOracleTimestamp` for this bridge (both checks use `"COTI"`).
     * @dev User sends native COTI with the transaction. Oracle races: {OracleTimestampMismatch} — re-estimate; see {_validateOracleTimestamps}.
     */
    function deposit(uint256 cotiOracleTimestamp, uint256 tokenOracleTimestamp) external payable nonReentrant whenNotPaused notBlacklisted {
        _deposit(msg.sender, cotiOracleTimestamp, tokenOracleTimestamp);
    }

    /**
     * @notice Withdraw native COTI by burning private COTI
     * @param amount Amount of private COTI to burn
     * @param cotiOracleTimestamp COTI `lastUpdated` from the latest `estimateWithdrawFee` (must still equal on-chain at execution).
     * @param tokenOracleTimestamp Same value as `cotiOracleTimestamp` for this bridge.
     * @dev User must have approved the bridge to spend their private tokens. Oracle rules: {_validateOracleTimestamps}.
     */
    function withdraw(uint256 amount, uint256 cotiOracleTimestamp, uint256 tokenOracleTimestamp) external nonReentrant whenNotPaused notBlacklisted {
        _withdraw(msg.sender, amount, cotiOracleTimestamp, tokenOracleTimestamp);
    }

    function _withdraw(
        address to,
        uint256 amount,
        uint256 cotiOracleTimestamp,
        uint256 tokenOracleTimestamp
    ) internal {
        if (amount == 0) revert AmountZero();
        _checkWithdrawLimits(amount);
        _validateOracleTimestamps(cotiOracleTimestamp, tokenOracleTimestamp, "COTI");

        // Compute dynamic withdrawal fee in COTI
        uint256 fee = _computeCotiFee(amount, withdrawFixedFee, withdrawPercentageBps, withdrawMaxFee);
        uint256 publicAmount = amount - fee;
        if (publicAmount == 0) revert AmountZero();

        accumulatedCotiFees += fee;

        if (address(this).balance < publicAmount)
            revert InsufficientEthBalance();

        // Extinguish liability for the full private amount burned (fee stays with bridge as native revenue).
        totalUserLiability -= amount;

        // Pull and burn private tokens
        IPrivateERC20(address(privateCoti)).transferFrom(
            msg.sender,
            address(this),
            amount
        );
        privateCoti.burn(amount);

        (bool success, ) = to.call{value: publicAmount}("");
        if (!success) revert EthTransferFailed();

        emit Withdraw(to, amount, publicAmount);
    }

    /**
     * @notice Internal deposit without binding to a prior estimate’s oracle `lastUpdated` snapshot.
     * @dev Used by {receive}. Fee uses {_computeCotiFee}, which still enforces: oracle configured
     *      ({PriceOracleNotSet}), non-zero COTI/USD rate ({InvalidOraclePrice}), and max age of
     *      `lastUpdated` when {PrivacyBridge.maxOracleAge} is set ({OraclePriceStale} /
     *      {OracleLastUpdatedInFuture}). What plain sends do **not** do is equality to timestamps
     *      passed into {deposit} from an off-chain estimate—users who need that binding should call {deposit}.
     */
    function _directDeposit(address sender) internal {
        if (!isDepositEnabled) revert DepositDisabled();
        if (msg.value == 0) revert AmountZero();

        _checkDepositLimits(msg.value);

        uint256 fee = _computeCotiFee(msg.value, depositFixedFee, depositPercentageBps, depositMaxFee);
        uint256 netAmount = msg.value - fee;
        if (netAmount == 0) revert AmountZero();

        accumulatedCotiFees += fee;

        totalUserLiability += netAmount;
        privateCoti.mint(sender, netAmount);

        emit Deposit(sender, msg.value, netAmount);
    }

    /**
     * @notice Fallback for plain native transfers: same fee path as {_directDeposit}.
     * @dev See {_directDeposit}: zero/stale oracle rates are rejected via {_computeCotiFee}; use {deposit}
     *      when you must match `lastUpdated` from {estimateDepositFee} to the on-chain row (see {_validateOracleTimestamps}).
     */
    receive() external payable nonReentrant whenNotPaused notBlacklisted {
        _directDeposit(msg.sender);
    }

    /**
     * @notice Get the native COTI balance held by the bridge
     * @return The contract's balance in native units (wei-equivalent)
     */
    function getBridgeBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @notice Withdraw accumulated fees to feeRecipient (Native implementation)
     * @param amount Amount of fees to withdraw
     * @dev Only the owner can call this function
     */
    function withdrawFees(
        uint256 amount
    ) external onlyOwner nonReentrant {
        if (feeRecipient == address(0)) revert FeeRecipientNotSet();
        if (amount == 0) revert AmountZero();
        if (amount > accumulatedCotiFees) revert InsufficientAccumulatedFees();
        if (amount > address(this).balance) revert InsufficientEthBalance();

        accumulatedCotiFees -= amount;

        // Transfer native COTI tokens to feeRecipient
        (bool success, ) = feeRecipient.call{value: amount}("");
        if (!success) revert EthTransferFailed();

        emit FeesWithdrawn(feeRecipient, amount);
    }

    /**
     * @notice Move native COTI from this bridge to {rescueRecipient} while the bridge is paused.
     * @dev Emergency / migration path: sends up to `amount` (typically the full {address(this).balance}) to
     *      {rescueRecipient}. That balance can include all user-deposited native liquidity and unswept fee
     *      float—there is no on-chain carve-out that keeps “user principal” behind. Intended for bug recovery
     *      or handover to a new bridge; a malicious or compromised owner who has paused can drain TVL to
     *      {rescueRecipient} in one or more calls. See {PrivacyBridge} contract-level @dev (3) for governance
     *      mitigations (multisig, timelock, monitoring). After a partial rescue, {accumulatedCotiFees} is capped
     *      to the remaining balance so fee accounting cannot exceed what is still on the contract.
     * @param amount Amount of native currency to send (often the full balance for migration).
     */
    function rescueNative(uint256 amount) external onlyOwner nonReentrant whenPaused {
        if (amount == 0) revert AmountZero();
        if (amount > address(this).balance) revert InsufficientEthBalance();

        (bool success, ) = rescueRecipient.call{value: amount}("");
        if (!success) revert EthTransferFailed();

        uint256 remaining = address(this).balance;
        if (accumulatedCotiFees > remaining) {
            accumulatedCotiFees = remaining;
        }

        emit NativeRescued(rescueRecipient, amount);
    }

}
