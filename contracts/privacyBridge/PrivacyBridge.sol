// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";
import "../oracle/ICotiPriceConsumer.sol";

/**
 * @title PrivacyBridge
 * @notice Base contract for Privacy Bridge contracts containing common logic
 * @dev Trust assumptions: (1) MPC precompile at expected address is correct and non-malicious.
 *      (2) Private token implementation is trusted and only authorized minters can mint.
 *      (3) Owner operations (limits, fees, pause, withdraw fees, rescue) are centralized; {pause} plus
 *          rescue on derived bridges is the intentional emergency gate to move **full** balances
 *          (including TVL) to a replacement deployment after a bug — mitigate with multisig/timelock on owner. 
 *      (4) Oracle prices are trusted; {maxOracleAge} bounds staleness of `lastUpdated` when set (does not remove oracle trust).
 *      (5) {totalUserLiability} is bridge bookkeeping for transparency: it tracks net user obligations from mint/burn
 *          paths in this contract. It helps depositors/observers reason about exposure on-chain; it is not a
 *          cryptographic proof of MPC/private-token balances and can diverge if the token layer misbehaves.
 *      (6) For COTI-operated deployments, residual trust in MPC/private-token behavior beyond (2) and (5), and in oracle
 *          *market* correctness beyond (4), is an accepted operational assumption; the on-chain mitigations above
 *          are the intended scope for those concerns in this module.
 */
abstract contract PrivacyBridge is ReentrancyGuard, Pausable, Ownable, AccessControlEnumerable {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    event OperatorAdded(address indexed account, address indexed by);
    event OperatorRemoved(address indexed account, address indexed by);
    event DepositEnabledUpdated(bool enabled, address indexed by);
    event DynamicFeeUpdated(string feeType, uint256 fixedFee, uint256 percentageBps, uint256 maxFee);
    event PriceOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event MaxOracleAgeUpdated(uint256 maxOracleAge, address indexed by);

    /// @notice Maximum amount that can be deposited in a single transaction
    uint256 public maxDepositAmount;

    /// @notice Maximum amount that can be withdrawn in a single transaction
    uint256 public maxWithdrawAmount;

    /// @notice Minimum amount required for a deposit
    uint256 public minDepositAmount;

    /// @notice Minimum amount required for a withdrawal
    uint256 public minWithdrawAmount;

    /// @notice Booked native COTI fees not yet swept: both {PrivacyBridgeCotiNative} (deposit/withdraw fees)
    ///         and ERC20 bridges (per-operation dynamic native fee via {_collectDynamicNativeFee}) credit this counter.
    ///         Native bridge: {PrivacyBridgeCotiNative.withdrawFees}; ERC20 deployments: {withdrawCotiFees}.
    uint256 public accumulatedCotiFees;

    /// @notice On-chain aggregate of bridge-issued user obligations from deposit/withdraw mint and burn paths
    ///         (native: net private minted; native withdraw: private burned; ERC20: public received in / amount out).
    ///         Intended for transparency so depositors and tooling can read how much liability the bridge tracks
    ///         in its own accounting. This does not attest to MPC correctness or encrypted token balances.
    uint256 public totalUserLiability;

    /// @notice Fee divisor (1,000,000). Fee math uses {Math.mulDiv}; pathological combinations of
    ///         amount × oracle rate can still cause reverts (panic) on overflow—operators should set
    ///         deposit/withdraw limits accordingly.
    uint256 public constant FEE_DIVISOR = 1000000;

    /// @notice Maximum fee allowed (10% = 100,000 units)
    uint256 public constant MAX_FEE_UNITS = 100000;

    /// @notice Flag to enable/disable deposits
    bool public isDepositEnabled = true;

    // Privacy Bridge defines default Fees
    // those fees can be overwritten using
    // setDepositDynamicFee available for OPERATORS and ADMIN

    /// @notice Deposit fee floor in COTI wei
    uint256 public depositFixedFee = 10 ether;

    /// @notice Deposit percentage (500/1,000,000 = 0.05%)
    uint256 public depositPercentageBps = 500;

    /// @notice Deposit fee cap in COTI wei
    uint256 public depositMaxFee = 3000 ether;

    /// @notice Withdraw fee floor in COTI wei
    uint256 public withdrawFixedFee = 3 ether;

    /// @notice Withdraw percentage (250/1,000,000 = 0.025%)
    uint256 public withdrawPercentageBps = 250;

    /// @notice Withdraw fee cap in COTI wei
    uint256 public withdrawMaxFee = 1500 ether;

    // --- END OF DEFAULT FEES

    /// @notice CotiPriceConsumer contract address
    address public priceOracle;

    /// @notice Default max oracle age: nominal ~30 minute feed cadence plus a 5 minute buffer so slightly delayed
    ///         updates or inclusion lag do not spuriously revert with {OraclePriceStale}.
    uint256 public constant DEFAULT_MAX_ORACLE_AGE = 30 minutes + 5 minutes;

    /// @notice Maximum allowed `block.timestamp - oracle lastUpdated` (seconds). Initialized to {DEFAULT_MAX_ORACLE_AGE}; set to 0 to disable.
    uint256 public maxOracleAge;

    /// @notice Address where collected fees are sent
    address public feeRecipient;

    /// @notice Address where rescued funds are sent
    address public rescueRecipient;

    error AmountZero();
    error InsufficientEthBalance();
    error EthTransferFailed();
    error InvalidAddress();
    error DepositDisabled();
    error InsufficientCotiFee();
    error BridgePaused();
    error OracleTimestampMismatch(uint256 expected, uint256 actual);
    error PriceOracleNotSet();
    error InvalidOraclePrice();
    error OraclePriceStale(uint256 oracleLastUpdated, uint256 blockTimestamp, uint256 maxOracleAge);
    error OracleLastUpdatedInFuture(uint256 lastUpdated);
    error FeeRecipientNotSet();
    error AddressBlacklisted(address account);

    /// @notice Addresses blocked from depositing or withdrawing
    mapping(address => bool) public blacklisted;

    /// @notice Native COTI excess from `msg.value` after dynamic fees when the push-refund to `msg.sender` failed (ERC20 bridges).
    mapping(address => uint256) public refundableNativeExcess;

    event Blacklisted(address indexed account, address indexed by);
    event UnBlacklisted(address indexed account, address indexed by);
    event NativeRefundExcessPushFailed(address indexed user, uint256 amount);
    event RefundableNativeExcessClaimed(address indexed user, uint256 amount);

    // Limits errors
    error InvalidLimitConfiguration();
    error DepositBelowMinimum();
    error DepositExceedsMaximum();
    error WithdrawBelowMinimum();
    error WithdrawExceedsMaximum();
    error InvalidFee();
    error InvalidFeeConfiguration();
    error InsufficientAccumulatedFees();

    /// @notice Emitted when a user deposits tokens
    /// @param user        Address of the user
    /// @param grossAmount Total amount provided by the user before fees
    /// @param netAmount   Net amount credited to the user after fees
    event Deposit(address indexed user, uint256 grossAmount, uint256 netAmount);

    /// @notice Emitted when a user withdraws tokens
    /// @param user        Address of the user
    /// @param grossAmount Total amount of private tokens burned / requested
    /// @param netAmount   Net public/native amount sent to the user after fees
    event Withdraw(address indexed user, uint256 grossAmount, uint256 netAmount);

    /// @notice Emitted when deposit/withdrawal limits are updated
    event LimitsUpdated(
        uint256 minDeposit,
        uint256 maxDeposit,
        uint256 minWithdraw,
        uint256 maxWithdraw
    );

    /// @notice Emitted when accumulated fees are withdrawn
    event FeesWithdrawn(address indexed to, uint256 amount);

    constructor(address _feeRecipient, address _rescueRecipient) Ownable() {
        if (_feeRecipient == address(0)) revert InvalidAddress();
        if (_rescueRecipient == address(0)) revert InvalidAddress();
        maxDepositAmount = type(uint256).max;
        maxWithdrawAmount = type(uint256).max;
        minDepositAmount = 1;
        minWithdrawAmount = 1;
        feeRecipient = _feeRecipient;
        rescueRecipient = _rescueRecipient;
        maxOracleAge = DEFAULT_MAX_ORACLE_AGE;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    modifier onlyOperator() {
        _checkRole(OPERATOR_ROLE, msg.sender);
        _;
    }

    function addOperator(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (account == address(0)) revert InvalidAddress();
        _grantRole(OPERATOR_ROLE, account);
        emit OperatorAdded(account, msg.sender);
    }

    function removeOperator(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (account == address(0)) revert InvalidAddress();
        _revokeRole(OPERATOR_ROLE, account);
        emit OperatorRemoved(account, msg.sender);
    }

    function isOperator(address account) external view returns (bool) {
        return hasRole(OPERATOR_ROLE, account);
    }

    /**
     * @dev Overrides Ownable's transferOwnership to automatically grant roles to new owner
     *      and revoke all existing operators to prevent hidden privileged actors.
     */
    function transferOwnership(address newOwner) public override onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();

        // Revoke all existing operators before transferring
        uint256 operatorCount = getRoleMemberCount(OPERATOR_ROLE);
        for (uint256 i = operatorCount; i > 0; i--) {
            address op = getRoleMember(OPERATOR_ROLE, i - 1);
            _revokeRole(OPERATOR_ROLE, op);
        }

        // Revoke all existing admins
        uint256 adminCount = getRoleMemberCount(DEFAULT_ADMIN_ROLE);
        for (uint256 i = adminCount; i > 0; i--) {
            address admin = getRoleMember(DEFAULT_ADMIN_ROLE, i - 1);
            _revokeRole(DEFAULT_ADMIN_ROLE, admin);
        }

        super.transferOwnership(newOwner);
        _grantRole(DEFAULT_ADMIN_ROLE, newOwner);
        _grantRole(OPERATOR_ROLE, newOwner);
    }

    /**
     * @dev Disabled to prevent split-brain state between Ownable and AccessControl.
     *      Use transferOwnership instead.
     */
    function renounceOwnership() public override onlyOwner {
        revert("renounceOwnership disabled");
    }

    /**
     * @notice Add an address to the blacklist, preventing deposits and withdrawals.
     * @param account The address to blacklist
     * @dev Only the owner can call this function.
     */
    function addToBlacklist(address account) external onlyOwner {
        if (account == address(0)) revert InvalidAddress();
        blacklisted[account] = true;
        emit Blacklisted(account, msg.sender);
    }

    /**
     * @notice Remove an address from the blacklist.
     * @param account The address to remove
     * @dev Only the owner can call this function.
     */
    function removeFromBlacklist(address account) external onlyOwner {
        if (account == address(0)) revert InvalidAddress();
        blacklisted[account] = false;
        emit UnBlacklisted(account, msg.sender);
    }

    /**
     * @dev Reverts if the caller is blacklisted.
     */
    modifier notBlacklisted() {
        if (blacklisted[msg.sender]) revert AddressBlacklisted(msg.sender);
        _;
    }

    /**
     * @notice Update deposit and withdrawal limits
     * @dev Ensures min values are less than or equal to max values.
     *      Setting _maxDeposit or _maxWithdraw to 0 effectively disables deposits or withdrawals.
     *      Note: cross-parameter coherence (e.g. minDeposit after fee >= minWithdraw) cannot be
     *      validated on-chain because fees are dynamic and depend on the oracle price at transaction
     *      time, not at the time limits are set. The operator is responsible for ensuring that the
     *      smallest valid deposit mints at least the smallest valid withdrawal amount.
     * @param _minDeposit New minimum deposit amount
     * @param _maxDeposit New maximum deposit amount
     * @param _minWithdraw New minimum withdrawal amount
     * @param _maxWithdraw New maximum withdrawal amount
     */
    function setLimits(
        uint256 _minDeposit,
        uint256 _maxDeposit,
        uint256 _minWithdraw,
        uint256 _maxWithdraw
    ) external onlyOwner {
        if (_minDeposit > _maxDeposit) revert InvalidLimitConfiguration();
        if (_minWithdraw > _maxWithdraw) revert InvalidLimitConfiguration();
        minDepositAmount = _minDeposit;
        maxDepositAmount = _maxDeposit;
        minWithdrawAmount = _minWithdraw;
        maxWithdrawAmount = _maxWithdraw;

        emit LimitsUpdated(
            _minDeposit,
            _maxDeposit,
            _minWithdraw,
            _maxWithdraw
        );
    }

    /**
     * @notice Emergency stop — pause the bridge, preventing all deposits and withdrawals.
     * @dev Only the owner can call this function.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the bridge, allowing deposits and withdrawals again
     * @dev Only the owner can call this function
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Check if a deposit amount is within configured limits
     * @param amount The amount to check
     * @dev Reverts if amount is below minimum or above maximum
     */
    function _checkDepositLimits(uint256 amount) internal view {
        if (amount < minDepositAmount) revert DepositBelowMinimum();
        if (amount > maxDepositAmount) revert DepositExceedsMaximum();
    }

    /**
     * @notice Check if a withdrawal amount is within configured limits
     * @param amount The amount to check
     * @dev Reverts if amount is below minimum or exceeds maximum withdrawal limit
     */
    function _checkWithdrawLimits(uint256 amount) internal view {
        if (amount < minWithdrawAmount) revert WithdrawBelowMinimum();
        if (amount > maxWithdrawAmount) revert WithdrawExceedsMaximum();
    }

    /**
     * @notice Toggle deposit functionality
     * @param _enabled True to enable, false to disable
     * @dev Only the operator can call this function
     */
    function setIsDepositEnabled(bool _enabled) external onlyOperator {
        isDepositEnabled = _enabled;
        emit DepositEnabledUpdated(_enabled, msg.sender);
    }

    function _requirePriceOracle() internal view {
        if (priceOracle == address(0)) revert PriceOracleNotSet();
    }

    function _requirePositiveOracleRate(uint256 rate) internal pure {
        if (rate == 0) revert InvalidOraclePrice();
    }

    /**
     * @dev Credits a user when a push-style native refund failed (e.g. smart wallet rejects ETH).
     *      Funds stay in the contract until {claimRefundableNativeExcess}.
     */
    function _creditRefundableNativeExcess(address user, uint256 amount) internal {
        refundableNativeExcess[user] += amount;
        emit NativeRefundExcessPushFailed(user, amount);
    }

    /**
     * @notice Pull native COTI previously credited after a failed excess refund during ERC20 bridge fee collection.
     * @dev Not gated by {whenPaused} so users can recover; still {notBlacklisted}. Restores credit if the send fails.
     */
    function claimRefundableNativeExcess() external nonReentrant notBlacklisted {
        uint256 amount = refundableNativeExcess[msg.sender];
        if (amount == 0) revert AmountZero();
        refundableNativeExcess[msg.sender] = 0;
        if (address(this).balance < amount) revert InsufficientEthBalance();
        (bool success, ) = msg.sender.call{value: amount}("");
        if (!success) {
            refundableNativeExcess[msg.sender] = amount;
            revert EthTransferFailed();
        }
        emit RefundableNativeExcessClaimed(msg.sender, amount);
    }

    /**
     * @notice Reject oracle rows that are too old vs `block.timestamp` when {maxOracleAge} is set.
     * @dev `maxOracleAge == 0` disables this check (e.g. for tests). Default is {DEFAULT_MAX_ORACLE_AGE} from the constructor.
     */
    function _requireOracleFreshness(uint256 lastUpdated) internal view {
        uint256 maxAge = maxOracleAge;
        if (maxAge == 0) return;
        if (lastUpdated > block.timestamp) revert OracleLastUpdatedInFuture(lastUpdated);
        uint256 nowTs = block.timestamp;
        if (nowTs - lastUpdated > maxAge) revert OraclePriceStale(lastUpdated, nowTs, maxAge);
    }

    /**
     * @notice Validate oracle timestamps for both COTI and a bridged token.
     * @dev Requires `lastUpdated == expected*` so execution uses the same oracle row the user saw when
     *      quoting (otherwise a refresh between estimate and inclusion could change price without the user
     *      having agreed to it on-screen). Production oracle cadence is ~30 minutes; the COTI UI blocks
     *      submission for ~10 seconds before a scheduled refresh to reduce races inside that window.
     *      Third-party integrators should mirror that pattern. {_requireOracleFreshness} still caps row age.
     * @param expectedCotiTimestamp COTI `lastUpdated` from the user's estimate (must match on-chain).
     * @param expectedTokenTimestamp Token `lastUpdated` from the user's estimate (must match on-chain).
     * @param tokenSymbol The Band oracle symbol for the bridged token.
     */
    function _validateOracleTimestamps(
        uint256 expectedCotiTimestamp,
        uint256 expectedTokenTimestamp,
        string memory tokenSymbol
    ) internal view {
        _requirePriceOracle();
        (, uint256 cotiLastUpdated,) = ICotiPriceConsumer(priceOracle).getPriceWithMeta("COTI");
        if (cotiLastUpdated != expectedCotiTimestamp) revert OracleTimestampMismatch(expectedCotiTimestamp, cotiLastUpdated);
        _requireOracleFreshness(cotiLastUpdated);
        (, uint256 tokenLastUpdated,) = ICotiPriceConsumer(priceOracle).getPriceWithMeta(tokenSymbol);
        if (tokenLastUpdated != expectedTokenTimestamp) revert OracleTimestampMismatch(expectedTokenTimestamp, tokenLastUpdated);
        _requireOracleFreshness(tokenLastUpdated);
    }

    /**
     * @notice Calculate the dynamic fee using the floor/cap formula
     * @param percentageFeeCoti The percentage-based fee component in COTI
     * @param fixedFee The minimum fee floor in COTI
     * @param maxFee The maximum fee cap in COTI
     * @return The computed fee: min(max(fixedFee, percentageFeeCoti), maxFee)
     */
    function _calculateDynamicFee(
        uint256 percentageFeeCoti,
        uint256 fixedFee,
        uint256 maxFee
    ) internal pure returns (uint256) {
        uint256 fee = percentageFeeCoti > fixedFee ? percentageFeeCoti : fixedFee;
        return fee > maxFee ? maxFee : fee;
    }

    /**
     * @notice Estimate functions are declared in derived contracts (Native and ERC20 bridges)
     *         with different return signatures:
     *         - Native: returns (fee, lastUpdated, blockTimestamp)
     *         - ERC20:  returns (fee, cotiLastUpdated, tokenLastUpdated, blockTimestamp)
     */

    /**
     * @notice Set the deposit dynamic fee parameters
     * @param _fixedFee New deposit fee floor in COTI wei
     * @param _percentageBps New deposit percentage (max MAX_FEE_UNITS = 10%)
     * @param _maxFee New deposit fee cap in COTI wei
     * @dev Only the operator can call this function
     */
    function setDepositDynamicFee(
        uint256 _fixedFee,
        uint256 _percentageBps,
        uint256 _maxFee
    ) external onlyOperator {
        if (_maxFee == 0) revert InvalidFeeConfiguration();
        if (_fixedFee > _maxFee) revert InvalidFeeConfiguration();
        if (_percentageBps > MAX_FEE_UNITS) revert InvalidFee();
        depositFixedFee = _fixedFee;
        depositPercentageBps = _percentageBps;
        depositMaxFee = _maxFee;
        emit DynamicFeeUpdated("deposit", _fixedFee, _percentageBps, _maxFee);
    }

    /**
     * @notice Set the withdraw dynamic fee parameters
     * @param _fixedFee New withdraw fee floor in COTI wei
     * @param _percentageBps New withdraw percentage (max MAX_FEE_UNITS = 10%)
     * @param _maxFee New withdraw fee cap in COTI wei
     * @dev Only the operator can call this function
     */
    function setWithdrawDynamicFee(
        uint256 _fixedFee,
        uint256 _percentageBps,
        uint256 _maxFee
    ) external onlyOperator {
        if (_maxFee == 0) revert InvalidFeeConfiguration();
        if (_fixedFee > _maxFee) revert InvalidFeeConfiguration();
        if (_percentageBps > MAX_FEE_UNITS) revert InvalidFee();
        withdrawFixedFee = _fixedFee;
        withdrawPercentageBps = _percentageBps;
        withdrawMaxFee = _maxFee;
        emit DynamicFeeUpdated("withdraw", _fixedFee, _percentageBps, _maxFee);
    }

    /**
     * @notice Set the price oracle address
     * @param _oracle Address of the CotiPriceConsumer contract
     * @dev Only the owner can call this function
     */
    function setPriceOracle(address _oracle) external onlyOwner {
        if (_oracle == address(0)) revert InvalidAddress();
        address oldOracle = priceOracle;
        priceOracle = _oracle;
        emit PriceOracleUpdated(oldOracle, _oracle);
    }

    /**
     * @notice Set the maximum allowed age of oracle `lastUpdated` (seconds) relative to `block.timestamp`.
     * @param _maxOracleAge Use 0 to disable staleness checks; default after deploy is {DEFAULT_MAX_ORACLE_AGE} (30 min cadence + 5 min buffer).
     */
    function setMaxOracleAge(uint256 _maxOracleAge) external onlyOwner {
        maxOracleAge = _maxOracleAge;
        emit MaxOracleAgeUpdated(_maxOracleAge, msg.sender);
    }

    event CotiFeesWithdrawn(address indexed feeRecipient, uint256 amount);

    /**
     * @notice Withdraw accumulated native COTI fees to the predefined feeRecipient
     * @param amount Amount of native COTI fees to withdraw
     * @dev Only the owner can call this function.
     */
    function withdrawCotiFees(uint256 amount) external onlyOwner nonReentrant {
        if (feeRecipient == address(0)) revert FeeRecipientNotSet();
        if (amount == 0) revert AmountZero();
        if (amount > accumulatedCotiFees) revert InsufficientAccumulatedFees();
        if (amount > address(this).balance) revert InsufficientEthBalance();

        accumulatedCotiFees -= amount;

        (bool success, ) = feeRecipient.call{value: amount}("");
        if (!success) revert EthTransferFailed();

        emit CotiFeesWithdrawn(feeRecipient, amount);
    }
}
