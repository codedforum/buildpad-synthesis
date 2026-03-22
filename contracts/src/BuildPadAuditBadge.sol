// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title BuildPadAuditBadge
/// @notice Soulbound ERC-1155 badges representing audit verifications for BuildPad tokens.
/// @dev Token IDs map to audit firms. Badges are non-transferable (SBT).
///
/// Audit Firm IDs:
///   1 = CertiK
///   2 = Hacken
///   3 = OpenZeppelin
///   4 = Trail of Bits
///   5 = Consensys Diligence
///   6 = Community Audit
contract BuildPadAuditBadge is ERC1155, Ownable {
    // ──────────────────────────────────────────────
    //  Types
    // ──────────────────────────────────────────────

    struct AuditRecord {
        uint256 auditFirmId;
        string reportURI;
        uint64 issuedAt;
    }

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    event BadgeIssued(
        address indexed tokenContract,
        uint256 indexed auditFirmId,
        string reportURI
    );

    event IssuerAdded(address indexed issuer);
    event IssuerRemoved(address indexed issuer);

    // ──────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────

    error NotIssuer();
    error InvalidAuditFirmId();
    error InvalidTokenContract();
    error AlreadyAudited();
    error SoulboundTransferBlocked();

    // ──────────────────────────────────────────────
    //  Constants
    // ──────────────────────────────────────────────

    uint256 public constant CERTIK = 1;
    uint256 public constant HACKEN = 2;
    uint256 public constant OPENZEPPELIN = 3;
    uint256 public constant TRAIL_OF_BITS = 4;
    uint256 public constant CONSENSYS_DILIGENCE = 5;
    uint256 public constant COMMUNITY_AUDIT = 6;

    uint256 public constant MAX_FIRM_ID = 6;

    // ──────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────

    /// @dev Approved badge issuers.
    mapping(address => bool) public isIssuer;

    /// @dev tokenContract → auditFirmId → reportURI
    mapping(address => mapping(uint256 => string)) private _reportURIs;

    /// @dev tokenContract → auditFirmId → issuedAt timestamp
    mapping(address => mapping(uint256 => uint64)) private _issuedAt;

    /// @dev tokenContract → list of audit records
    mapping(address => AuditRecord[]) private _audits;

    // ──────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────

    modifier onlyIssuer() {
        if (!isIssuer[msg.sender]) revert NotIssuer();
        _;
    }

    modifier validFirmId(uint256 firmId) {
        if (firmId == 0 || firmId > MAX_FIRM_ID) revert InvalidAuditFirmId();
        _;
    }

    // ──────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────

    /// @param owner_ The contract owner who can manage issuers.
    constructor(address owner_) ERC1155("") Ownable(owner_) {}

    // ──────────────────────────────────────────────
    //  Issuer Management (Owner only)
    // ──────────────────────────────────────────────

    /// @notice Add an approved badge issuer.
    function addIssuer(address issuer) external onlyOwner {
        isIssuer[issuer] = true;
        emit IssuerAdded(issuer);
    }

    /// @notice Remove an approved badge issuer.
    function removeIssuer(address issuer) external onlyOwner {
        isIssuer[issuer] = false;
        emit IssuerRemoved(issuer);
    }

    // ──────────────────────────────────────────────
    //  Badge Issuance
    // ──────────────────────────────────────────────

    /// @notice Issue an audit badge (SBT) to a token contract address.
    /// @param tokenContract The audited token's contract address.
    /// @param auditFirmId The audit firm ID (1-6).
    /// @param reportURI URI pointing to the audit report.
    function issueBadge(
        address tokenContract,
        uint256 auditFirmId,
        string calldata reportURI
    ) external onlyIssuer validFirmId(auditFirmId) {
        if (tokenContract == address(0)) revert InvalidTokenContract();
        if (balanceOf(tokenContract, auditFirmId) > 0) revert AlreadyAudited();

        // Mint SBT (amount = 1) to the token contract address
        _mint(tokenContract, auditFirmId, 1, "");

        // Store report data
        _reportURIs[tokenContract][auditFirmId] = reportURI;
        uint64 ts = uint64(block.timestamp);
        _issuedAt[tokenContract][auditFirmId] = ts;

        _audits[tokenContract].push(AuditRecord({
            auditFirmId: auditFirmId,
            reportURI: reportURI,
            issuedAt: ts
        }));

        emit BadgeIssued(tokenContract, auditFirmId, reportURI);
    }

    // ──────────────────────────────────────────────
    //  Soulbound Overrides (non-transferable)
    // ──────────────────────────────────────────────

    /// @dev Blocks all single transfers — badges are soulbound.
    function safeTransferFrom(
        address,
        address,
        uint256,
        uint256,
        bytes memory
    ) public pure override {
        revert SoulboundTransferBlocked();
    }

    /// @dev Blocks all batch transfers — badges are soulbound.
    function safeBatchTransferFrom(
        address,
        address,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    ) public pure override {
        revert SoulboundTransferBlocked();
    }

    // ──────────────────────────────────────────────
    //  View Functions
    // ──────────────────────────────────────────────

    /// @notice Check if a token contract has been audited by a specific firm.
    /// @param tokenContract The token contract to check.
    /// @param auditFirmId The audit firm ID.
    /// @return hasAudit True if the badge exists.
    /// @return reportURI The audit report URI (empty if no audit).
    function verifyAudit(
        address tokenContract,
        uint256 auditFirmId
    ) external view returns (bool hasAudit, string memory reportURI) {
        hasAudit = balanceOf(tokenContract, auditFirmId) > 0;
        reportURI = _reportURIs[tokenContract][auditFirmId];
    }

    /// @notice Get all audit records for a token contract.
    /// @param tokenContract The token contract to query.
    /// @return records Array of AuditRecord structs.
    function getAudits(address tokenContract)
        external
        view
        returns (AuditRecord[] memory records)
    {
        return _audits[tokenContract];
    }

    /// @notice Get the human-readable name for an audit firm ID.
    /// @param firmId The audit firm ID (1-6).
    /// @return name The firm name.
    function getAuditFirmName(uint256 firmId) external pure returns (string memory name) {
        if (firmId == 1) return "CertiK";
        if (firmId == 2) return "Hacken";
        if (firmId == 3) return "OpenZeppelin";
        if (firmId == 4) return "Trail of Bits";
        if (firmId == 5) return "Consensys Diligence";
        if (firmId == 6) return "Community Audit";
        revert InvalidAuditFirmId();
    }
}
