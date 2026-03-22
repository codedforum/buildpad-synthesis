// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title BuildPadAirdrop
/// @notice Merkle-based and public airdrop distributor for tokens launched on BuildPad.
/// @dev Supports two modes: Merkle-verified airdrops and public first-come-first-served airdrops.
contract BuildPadAirdrop is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────
    //  Types
    // ──────────────────────────────────────────────

    struct AirdropConfig {
        address token;
        address creator;
        bytes32 merkleRoot;
        uint256 totalAmount;
        uint256 claimedAmount;
        uint64 expiresAt;
        bool isPublic;
        uint256 amountPerClaim; // only used for public airdrops
        uint256 maxClaims;      // only used for public airdrops
        uint256 claimCount;     // only used for public airdrops
    }

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    event AirdropCreated(
        uint256 indexed id,
        address indexed token,
        bytes32 merkleRoot,
        uint256 totalAmount,
        uint64 expiresAt
    );

    event PublicAirdropCreated(
        uint256 indexed id,
        address indexed token,
        uint256 amountPerClaim,
        uint256 maxClaims,
        uint64 expiresAt
    );

    event Claimed(uint256 indexed airdropId, address indexed claimer, uint256 amount);

    event Reclaimed(uint256 indexed airdropId, address indexed creator, uint256 amount);

    // ──────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────

    error InvalidToken();
    error InvalidAmount();
    error InvalidExpiry();
    error InvalidProof();
    error AlreadyClaimed();
    error AirdropExpired();
    error AirdropNotExpired();
    error NotCreator();
    error NothingToReclaim();
    error MaxClaimsReached();
    error AirdropNotFound();

    // ──────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────

    uint256 private _nextAirdropId;

    /// @dev airdropId → config
    mapping(uint256 => AirdropConfig) private _airdrops;

    /// @dev airdropId → claimerAddress → claimed flag (bitmap for Merkle, simple bool for public)
    mapping(uint256 => mapping(address => bool)) private _claimed;

    /// @dev token → airdrop IDs
    mapping(address => uint256[]) private _tokenAirdrops;

    // ──────────────────────────────────────────────
    //  Merkle Airdrop
    // ──────────────────────────────────────────────

    /// @notice Create a Merkle-based airdrop.
    /// @param token The ERC-20 token to airdrop.
    /// @param merkleRoot Root of the Merkle tree encoding (address, amount) leaves.
    /// @param totalAmount Total tokens to deposit into this airdrop.
    /// @param expiresAt Unix timestamp after which unclaimed tokens can be reclaimed.
    /// @return id The unique airdrop ID.
    function createAirdrop(
        address token,
        bytes32 merkleRoot,
        uint256 totalAmount,
        uint64 expiresAt
    ) external returns (uint256 id) {
        if (token == address(0)) revert InvalidToken();
        if (totalAmount == 0) revert InvalidAmount();
        if (expiresAt <= block.timestamp) revert InvalidExpiry();

        id = _nextAirdropId++;

        _airdrops[id] = AirdropConfig({
            token: token,
            creator: msg.sender,
            merkleRoot: merkleRoot,
            totalAmount: totalAmount,
            claimedAmount: 0,
            expiresAt: expiresAt,
            isPublic: false,
            amountPerClaim: 0,
            maxClaims: 0,
            claimCount: 0
        });

        _tokenAirdrops[token].push(id);

        IERC20(token).safeTransferFrom(msg.sender, address(this), totalAmount);

        emit AirdropCreated(id, token, merkleRoot, totalAmount, expiresAt);
    }

    /// @notice Claim tokens from a Merkle airdrop.
    /// @param airdropId The airdrop to claim from.
    /// @param amount The amount the caller is entitled to (encoded in the leaf).
    /// @param merkleProof The Merkle proof for the caller's leaf.
    function claim(
        uint256 airdropId,
        uint256 amount,
        bytes32[] calldata merkleProof
    ) external nonReentrant {
        AirdropConfig storage ad = _airdrops[airdropId];
        if (ad.token == address(0)) revert AirdropNotFound();
        if (block.timestamp > ad.expiresAt) revert AirdropExpired();
        if (_claimed[airdropId][msg.sender]) revert AlreadyClaimed();

        if (ad.isPublic) {
            // Public airdrop — ignore proof, use amountPerClaim
            if (ad.claimCount >= ad.maxClaims) revert MaxClaimsReached();
            amount = ad.amountPerClaim;
            ad.claimCount++;
        } else {
            // Merkle airdrop — verify proof
            bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, amount))));
            if (!MerkleProof.verify(merkleProof, ad.merkleRoot, leaf)) revert InvalidProof();
        }

        _claimed[airdropId][msg.sender] = true;
        ad.claimedAmount += amount;

        IERC20(ad.token).safeTransfer(msg.sender, amount);

        emit Claimed(airdropId, msg.sender, amount);
    }

    // ──────────────────────────────────────────────
    //  Public Airdrop
    // ──────────────────────────────────────────────

    /// @notice Create a public (no proof) airdrop — first-come-first-served.
    /// @param token The ERC-20 token to airdrop.
    /// @param amountPerClaim Tokens each claimer receives.
    /// @param maxClaims Maximum number of unique claimers.
    /// @param expiresAt Unix timestamp after which unclaimed tokens can be reclaimed.
    /// @return id The unique airdrop ID.
    function createPublicAirdrop(
        address token,
        uint256 amountPerClaim,
        uint256 maxClaims,
        uint64 expiresAt
    ) external returns (uint256 id) {
        if (token == address(0)) revert InvalidToken();
        if (amountPerClaim == 0 || maxClaims == 0) revert InvalidAmount();
        if (expiresAt <= block.timestamp) revert InvalidExpiry();

        uint256 totalAmount = amountPerClaim * maxClaims;
        id = _nextAirdropId++;

        _airdrops[id] = AirdropConfig({
            token: token,
            creator: msg.sender,
            merkleRoot: bytes32(0),
            totalAmount: totalAmount,
            claimedAmount: 0,
            expiresAt: expiresAt,
            isPublic: true,
            amountPerClaim: amountPerClaim,
            maxClaims: maxClaims,
            claimCount: 0
        });

        _tokenAirdrops[token].push(id);

        IERC20(token).safeTransferFrom(msg.sender, address(this), totalAmount);

        emit PublicAirdropCreated(id, token, amountPerClaim, maxClaims, expiresAt);
    }

    /// @notice Claim from a public airdrop (convenience — calls `claim` with empty proof).
    /// @param airdropId The public airdrop to claim from.
    function claimPublic(uint256 airdropId) external {
        bytes32[] memory emptyProof = new bytes32[](0);
        this.claim(airdropId, 0, emptyProof);
    }

    // ──────────────────────────────────────────────
    //  Reclaim
    // ──────────────────────────────────────────────

    /// @notice Creator reclaims unclaimed tokens after expiry.
    /// @param airdropId The airdrop to reclaim from.
    function reclaimExpired(uint256 airdropId) external nonReentrant {
        AirdropConfig storage ad = _airdrops[airdropId];
        if (ad.token == address(0)) revert AirdropNotFound();
        if (msg.sender != ad.creator) revert NotCreator();
        if (block.timestamp <= ad.expiresAt) revert AirdropNotExpired();

        uint256 remaining = ad.totalAmount - ad.claimedAmount;
        if (remaining == 0) revert NothingToReclaim();

        ad.claimedAmount = ad.totalAmount; // mark fully claimed

        IERC20(ad.token).safeTransfer(ad.creator, remaining);

        emit Reclaimed(airdropId, ad.creator, remaining);
    }

    // ──────────────────────────────────────────────
    //  View Functions
    // ──────────────────────────────────────────────

    /// @notice Get full info for an airdrop.
    function getAirdropInfo(uint256 id)
        external
        view
        returns (
            address token,
            address creator,
            bytes32 merkleRoot,
            uint256 totalAmount,
            uint256 claimed,
            uint256 remaining,
            uint64 expiresAt,
            bool isPublic
        )
    {
        AirdropConfig storage ad = _airdrops[id];
        token = ad.token;
        creator = ad.creator;
        merkleRoot = ad.merkleRoot;
        totalAmount = ad.totalAmount;
        claimed = ad.claimedAmount;
        remaining = ad.totalAmount - ad.claimedAmount;
        expiresAt = ad.expiresAt;
        isPublic = ad.isPublic;
    }

    /// @notice Check if an account has claimed from an airdrop.
    function hasClaimed(uint256 id, address account) external view returns (bool) {
        return _claimed[id][account];
    }

    /// @notice Get all airdrop IDs for a given token.
    function getAirdropsByToken(address token) external view returns (uint256[] memory) {
        return _tokenAirdrops[token];
    }
}
