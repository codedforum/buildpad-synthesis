// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @title BuildPadLPLock
/// @notice Locks Uniswap V4 LP position NFTs (ERC-721 from PositionManager).
///         Supports time-locked and permanent locks for anti-rug protection.
/// @dev    Accepts NFTs via safeTransferFrom (implements IERC721Receiver).
contract BuildPadLPLock is IERC721Receiver {

    // ──────────────────────────── Constants ────────────────────────

    /// @notice Minimum lock duration: 30 days.
    uint64 public constant MIN_LOCK_DURATION = 30 days;

    /// @notice Sentinel value for permanent locks.
    uint64 public constant PERMANENT = type(uint64).max;

    // ──────────────────────────── Types ────────────────────────────

    /// @notice On-chain record for a locked LP position.
    struct LockRecord {
        address owner;       // Original depositor
        uint64 unlockTime;   // Unix timestamp when unlock is allowed (PERMANENT = forever)
        bool unlocked;       // True after NFT has been withdrawn
    }

    /// @notice Returned by `getLockInfo` for frontend consumption.
    struct LockInfo {
        address owner;
        uint64 unlockTime;
        bool isPermanent;
        bool isUnlocked;
    }

    // ──────────────────────────── Events ───────────────────────────

    /// @notice Emitted when an LP position NFT is locked.
    event LPLocked(uint256 indexed tokenId, address indexed owner, uint64 unlockTime);

    /// @notice Emitted when a lock is extended to a later time.
    event LockExtended(uint256 indexed tokenId, uint64 oldUnlockTime, uint64 newUnlockTime);

    /// @notice Emitted when a position is permanently locked (anti-rug).
    event PermanentlyLocked(uint256 indexed tokenId, address indexed owner);

    /// @notice Emitted when an LP position NFT is unlocked and returned.
    event LPUnlocked(uint256 indexed tokenId, address indexed owner);

    // ──────────────────────────── Storage ──────────────────────────

    /// @notice The Uniswap V4 PositionManager (ERC-721) contract.
    IERC721 public immutable positionManager;

    /// @dev tokenId → lock record
    mapping(uint256 => LockRecord) private _locks;

    /// @dev owner → array of locked tokenIds
    mapping(address => uint256[]) private _lockedByOwner;

    // ──────────────────────────── Errors ───────────────────────────

    error NotOwner();
    error AlreadyUnlocked();
    error LockTooShort(uint64 minUnlockTime);
    error StillLocked(uint64 unlockTime);
    error CannotShortenLock();
    error AlreadyPermanent();
    error TokenNotLocked();
    error PermanentlyLockedToken();

    // ──────────────────────────── Constructor ──────────────────────

    /// @param _positionManager Address of the Uniswap V4 PositionManager (ERC-721).
    constructor(address _positionManager) {
        positionManager = IERC721(_positionManager);
    }

    // ──────────────────────────── External ─────────────────────────

    /// @notice Lock an LP position NFT until `unlockTime`.
    /// @dev    Caller must have approved this contract or called via safeTransferFrom.
    ///         Minimum lock is 30 days from now.
    /// @param tokenId    The LP position NFT token ID.
    /// @param unlockTime Unix timestamp when the position can be withdrawn.
    function lockLP(uint256 tokenId, uint64 unlockTime) external {
        uint64 minUnlock = uint64(block.timestamp) + MIN_LOCK_DURATION;
        if (unlockTime < minUnlock) revert LockTooShort(minUnlock);

        // Transfer NFT from caller to this contract
        positionManager.transferFrom(msg.sender, address(this), tokenId);

        _locks[tokenId] = LockRecord({
            owner: msg.sender,
            unlockTime: unlockTime,
            unlocked: false
        });
        _lockedByOwner[msg.sender].push(tokenId);

        emit LPLocked(tokenId, msg.sender, unlockTime);
    }

    /// @notice Extend the lock to a later unlock time. Cannot shorten.
    /// @param tokenId       The locked LP position NFT token ID.
    /// @param newUnlockTime New unlock timestamp (must be > current unlockTime).
    function extendLock(uint256 tokenId, uint64 newUnlockTime) external {
        LockRecord storage lock = _locks[tokenId];
        if (lock.owner == address(0)) revert TokenNotLocked();
        if (lock.owner != msg.sender) revert NotOwner();
        if (lock.unlocked) revert AlreadyUnlocked();
        if (lock.unlockTime == PERMANENT) revert AlreadyPermanent();
        if (newUnlockTime <= lock.unlockTime) revert CannotShortenLock();

        uint64 oldUnlockTime = lock.unlockTime;
        lock.unlockTime = newUnlockTime;

        emit LockExtended(tokenId, oldUnlockTime, newUnlockTime);
    }

    /// @notice Withdraw the LP position NFT after the lock has expired.
    /// @param tokenId The locked LP position NFT token ID.
    function unlock(uint256 tokenId) external {
        LockRecord storage lock = _locks[tokenId];
        if (lock.owner == address(0)) revert TokenNotLocked();
        if (lock.owner != msg.sender) revert NotOwner();
        if (lock.unlocked) revert AlreadyUnlocked();
        if (lock.unlockTime == PERMANENT) revert PermanentlyLockedToken();
        if (block.timestamp < lock.unlockTime) revert StillLocked(lock.unlockTime);

        lock.unlocked = true;

        // Return NFT to original owner
        positionManager.safeTransferFrom(address(this), msg.sender, tokenId);

        emit LPUnlocked(tokenId, msg.sender);
    }

    /// @notice Permanently lock an LP position (unlockTime = max uint64).
    ///         Used by the graduator for anti-rug protection. Irreversible.
    /// @param tokenId The locked LP position NFT token ID.
    function permanentLock(uint256 tokenId) external {
        LockRecord storage lock = _locks[tokenId];
        if (lock.owner == address(0)) revert TokenNotLocked();
        if (lock.owner != msg.sender) revert NotOwner();
        if (lock.unlocked) revert AlreadyUnlocked();
        if (lock.unlockTime == PERMANENT) revert AlreadyPermanent();

        lock.unlockTime = PERMANENT;

        emit PermanentlyLocked(tokenId, msg.sender);
    }

    // ──────────────────────────── Views ────────────────────────────

    /// @notice Get lock details for a specific LP position.
    /// @param tokenId The LP position NFT token ID.
    /// @return info LockInfo struct with owner, unlockTime, isPermanent, isUnlocked.
    function getLockInfo(uint256 tokenId) external view returns (LockInfo memory info) {
        LockRecord storage lock = _locks[tokenId];
        info = LockInfo({
            owner: lock.owner,
            unlockTime: lock.unlockTime,
            isPermanent: lock.unlockTime == PERMANENT,
            isUnlocked: lock.unlocked
        });
    }

    /// @notice Get all locked position token IDs for an owner.
    /// @param owner The owner address.
    /// @return tokenIds Array of locked token IDs (may include already-unlocked ones).
    function getLockedPositions(address owner) external view returns (uint256[] memory tokenIds) {
        return _lockedByOwner[owner];
    }

    // ──────────────────────────── ERC-721 Receiver ─────────────────

    /// @notice Handle incoming ERC-721 transfers (required for safeTransferFrom).
    /// @dev    Only accepts NFTs from the configured PositionManager.
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external view override returns (bytes4) {
        // Only accept NFTs from the PositionManager
        require(msg.sender == address(positionManager), "BuildPadLPLock: wrong NFT");
        return IERC721Receiver.onERC721Received.selector;
    }
}
