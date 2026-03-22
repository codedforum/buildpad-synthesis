// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {VestingWalletCliff} from "@openzeppelin/contracts/finance/VestingWalletCliff.sol";

/// @title BuildPadVestingWallet
/// @notice Concrete VestingWalletCliff — deployed by the factory for each vest.
contract BuildPadVestingWallet is VestingWalletCliff {
    constructor(
        address beneficiary,
        uint64 startTimestamp,
        uint64 durationSeconds,
        uint64 cliffSeconds
    )
        VestingWallet(beneficiary, startTimestamp, durationSeconds)
        VestingWalletCliff(cliffSeconds)
    {}
}

/// @title BuildPadVesting
/// @notice Factory that deploys VestingWalletCliff instances for token teams.
///         Supports single and batch vest creation with on-chain tracking.
/// @dev    Uses OpenZeppelin v5.1+ VestingWalletCliff under the hood.
contract BuildPadVesting {
    using SafeERC20 for IERC20;

    // ──────────────────────────── Types ────────────────────────────

    /// @notice Parameters for a single vest (used in batch creation).
    struct VestParams {
        address beneficiary;
        uint256 amount;
        uint64 startTimestamp;
        uint64 durationSeconds;
        uint64 cliffSeconds;
    }

    /// @notice Stored metadata for each deployed vesting wallet.
    struct VestRecord {
        address token;
        address beneficiary;
        address vestingWallet;
        uint256 amount;
        uint64 start;
        uint64 duration;
        uint64 cliff;
    }

    /// @notice Returned by `getVestInfo` with live on-chain state.
    struct VestInfo {
        address token;
        address beneficiary;
        uint256 amount;
        uint64 start;
        uint64 duration;
        uint64 cliff;
        uint256 released;
        uint256 releasable;
    }

    // ──────────────────────────── Events ───────────────────────────

    /// @notice Emitted when a new vest is created.
    event VestCreated(
        address indexed token,
        address indexed beneficiary,
        address vestingWallet,
        uint256 amount,
        uint64 start,
        uint64 duration,
        uint64 cliff
    );

    // ──────────────────────────── Storage ──────────────────────────

    /// @dev token → array of vesting wallet addresses
    mapping(address => address[]) private _vestsByToken;

    /// @dev beneficiary → array of vesting wallet addresses
    mapping(address => address[]) private _vestsByBeneficiary;

    /// @dev vesting wallet → record
    mapping(address => VestRecord) private _vestRecords;

    // ──────────────────────────── Errors ───────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error ZeroDuration();
    error UnknownVestingWallet();

    // ──────────────────────────── External ─────────────────────────

    /// @notice Deploy a new VestingWalletCliff and fund it with `amount` tokens.
    /// @dev    Caller must have approved this contract to spend `amount` of `token`.
    /// @param token          ERC-20 token to vest.
    /// @param beneficiary    Wallet that will receive vested tokens over time.
    /// @param startTimestamp Unix timestamp when vesting begins.
    /// @param durationSeconds Total vesting duration in seconds.
    /// @param cliffSeconds   Cliff period in seconds (no release before cliff).
    /// @param amount         Number of tokens (in wei) to lock.
    /// @return wallet Address of the newly deployed vesting wallet.
    function createVest(
        address token,
        address beneficiary,
        uint64 startTimestamp,
        uint64 durationSeconds,
        uint64 cliffSeconds,
        uint256 amount
    ) external returns (address wallet) {
        wallet = _createSingleVest(token, beneficiary, startTimestamp, durationSeconds, cliffSeconds, amount);
    }

    /// @notice Batch-create vests for team allocations in a single transaction.
    /// @dev    Caller must have approved this contract to spend the total amount.
    /// @param token  ERC-20 token to vest.
    /// @param vests  Array of VestParams structs.
    function createBatchVest(address token, VestParams[] calldata vests) external {
        if (token == address(0)) revert ZeroAddress();

        for (uint256 i; i < vests.length; ++i) {
            _createSingleVest(
                token,
                vests[i].beneficiary,
                vests[i].startTimestamp,
                vests[i].durationSeconds,
                vests[i].cliffSeconds,
                vests[i].amount
            );
        }
    }

    // ──────────────────────────── Views ────────────────────────────

    /// @notice Get all vesting wallet addresses created for a given token.
    /// @param token The ERC-20 token address.
    /// @return wallets Array of vesting wallet addresses.
    function getVests(address token) external view returns (address[] memory wallets) {
        return _vestsByToken[token];
    }

    /// @notice Get live vest info for a vesting wallet, including released & releasable amounts.
    /// @param vestingWallet Address of the deployed vesting wallet.
    /// @return info Full VestInfo struct with on-chain state.
    function getVestInfo(address vestingWallet) external view returns (VestInfo memory info) {
        VestRecord storage r = _vestRecords[vestingWallet];
        if (r.vestingWallet == address(0)) revert UnknownVestingWallet();

        VestingWallet vw = VestingWallet(payable(vestingWallet));

        info = VestInfo({
            token: r.token,
            beneficiary: r.beneficiary,
            amount: r.amount,
            start: r.start,
            duration: r.duration,
            cliff: r.cliff,
            released: vw.released(r.token),
            releasable: vw.releasable(r.token)
        });
    }

    /// @notice Get all vesting wallet addresses where `beneficiary` is the recipient.
    /// @param beneficiary The beneficiary address.
    /// @return wallets Array of vesting wallet addresses.
    function getVestsByBeneficiary(address beneficiary) external view returns (address[] memory wallets) {
        return _vestsByBeneficiary[beneficiary];
    }

    // ──────────────────────────── Internal ─────────────────────────

    function _createSingleVest(
        address token,
        address beneficiary,
        uint64 startTimestamp,
        uint64 durationSeconds,
        uint64 cliffSeconds,
        uint256 amount
    ) internal returns (address wallet) {
        if (token == address(0) || beneficiary == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (durationSeconds == 0) revert ZeroDuration();

        // Deploy a new VestingWalletCliff instance
        BuildPadVestingWallet vw = new BuildPadVestingWallet(
            beneficiary,
            startTimestamp,
            durationSeconds,
            cliffSeconds
        );
        wallet = address(vw);

        // Transfer tokens from caller into the vesting wallet
        IERC20(token).safeTransferFrom(msg.sender, wallet, amount);

        // Record for frontend queries
        VestRecord memory record = VestRecord({
            token: token,
            beneficiary: beneficiary,
            vestingWallet: wallet,
            amount: amount,
            start: startTimestamp,
            duration: durationSeconds,
            cliff: cliffSeconds
        });

        _vestRecords[wallet] = record;
        _vestsByToken[token].push(wallet);
        _vestsByBeneficiary[beneficiary].push(wallet);

        emit VestCreated(token, beneficiary, wallet, amount, startTimestamp, durationSeconds, cliffSeconds);
    }
}
