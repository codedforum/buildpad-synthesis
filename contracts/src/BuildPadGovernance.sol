// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title BuildPadGovernance
/// @notice Lightweight on-chain governance for tokens launched on BuildPad.
/// @dev Uses block.number snapshots for vote-weight calculation.
///      Proposals pass with >50% support AND ≥10% quorum (of total supply at snapshot).
contract BuildPadGovernance is ReentrancyGuard {
    // ──────────────────────────────────────────────
    //  Types
    // ──────────────────────────────────────────────

    enum ProposalState {
        Active,
        Canceled,
        Defeated,
        Succeeded,
        Executed
    }

    struct Proposal {
        uint256 id;
        address token;
        address proposer;
        string title;
        string description;
        uint256 snapshotBlock;
        uint256 snapshotSupply;
        uint64 startTime;
        uint64 endTime;
        uint256 forVotes;
        uint256 againstVotes;
        bytes executionData;
        ProposalState state;
    }

    struct VoteInfo {
        bool hasVoted;
        bool support;
        uint256 weight;
    }

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    event ProposalCreated(
        uint256 indexed id,
        address indexed token,
        address proposer,
        string title,
        uint64 endTime
    );

    event Voted(
        uint256 indexed proposalId,
        address indexed voter,
        bool support,
        uint256 weight
    );

    event ProposalExecuted(uint256 indexed proposalId);

    event ProposalCanceled(uint256 indexed proposalId);

    // ──────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────

    error InvalidToken();
    error InsufficientTokens();
    error VotingPeriodTooShort();
    error VotingPeriodTooLong();
    error ProposalNotFound();
    error ProposalNotActive();
    error VotingNotEnded();
    error VotingEnded();
    error AlreadyVoted();
    error ProposalNotPassed();
    error ExecutionFailed();
    error NotAuthorizedToCancel();
    error ZeroWeight();

    // ──────────────────────────────────────────────
    //  Constants
    // ──────────────────────────────────────────────

    /// @dev Minimum proposal threshold: 1% of total supply.
    uint256 public constant PROPOSAL_THRESHOLD_BPS = 100; // 1% = 100 bps

    /// @dev Quorum: 10% of total supply must participate.
    uint256 public constant QUORUM_BPS = 1000; // 10% = 1000 bps

    uint64 public constant MIN_VOTING_PERIOD = 1 days;
    uint64 public constant MAX_VOTING_PERIOD = 30 days;

    // ──────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────

    uint256 private _nextProposalId;

    /// @dev proposalId → Proposal
    mapping(uint256 => Proposal) private _proposals;

    /// @dev proposalId → voter → VoteInfo
    mapping(uint256 => mapping(address => VoteInfo)) private _votes;

    /// @dev token → proposal IDs
    mapping(address => uint256[]) private _tokenProposals;

    /// @dev snapshotBlock → account → balance (cached on first vote)
    mapping(uint256 => mapping(address => uint256)) private _snapshotBalances;
    mapping(uint256 => mapping(address => bool)) private _snapshotCached;

    // ──────────────────────────────────────────────
    //  Proposal Lifecycle
    // ──────────────────────────────────────────────

    /// @notice Create a new governance proposal.
    /// @param token The BuildPad token this proposal governs.
    /// @param title Short title for the proposal.
    /// @param description Full description of the proposal.
    /// @param votingPeriod Duration in seconds (1 day – 30 days).
    /// @param executionData Calldata to execute on the token contract if proposal passes.
    /// @return id The new proposal ID.
    function createProposal(
        address token,
        string calldata title,
        string calldata description,
        uint64 votingPeriod,
        bytes calldata executionData
    ) external returns (uint256 id) {
        if (token == address(0)) revert InvalidToken();
        if (votingPeriod < MIN_VOTING_PERIOD) revert VotingPeriodTooShort();
        if (votingPeriod > MAX_VOTING_PERIOD) revert VotingPeriodTooLong();

        uint256 supply = IERC20(token).totalSupply();
        uint256 threshold = (supply * PROPOSAL_THRESHOLD_BPS) / 10_000;
        if (IERC20(token).balanceOf(msg.sender) < threshold) revert InsufficientTokens();

        id = _nextProposalId++;
        uint64 endTime = uint64(block.timestamp) + votingPeriod;

        _proposals[id] = Proposal({
            id: id,
            token: token,
            proposer: msg.sender,
            title: title,
            description: description,
            snapshotBlock: block.number,
            snapshotSupply: supply,
            startTime: uint64(block.timestamp),
            endTime: endTime,
            forVotes: 0,
            againstVotes: 0,
            executionData: executionData,
            state: ProposalState.Active
        });

        _tokenProposals[token].push(id);

        emit ProposalCreated(id, token, msg.sender, title, endTime);
    }

    /// @notice Cast a vote on an active proposal.
    /// @dev Vote weight is the voter's token balance at the snapshot block.
    ///      Uses current balance as proxy since historical balance queries
    ///      require ERC20Votes — this is the lightweight version.
    /// @param proposalId The proposal to vote on.
    /// @param support True for yes, false for no.
    function vote(uint256 proposalId, bool support) external {
        Proposal storage p = _proposals[proposalId];
        if (p.token == address(0)) revert ProposalNotFound();
        if (p.state != ProposalState.Active) revert ProposalNotActive();
        if (block.timestamp > p.endTime) revert VotingEnded();

        VoteInfo storage vi = _votes[proposalId][msg.sender];
        if (vi.hasVoted) revert AlreadyVoted();

        // Cache balance at first interaction as snapshot proxy.
        // For full historical snapshots, tokens should implement ERC20Votes.
        uint256 weight;
        if (_snapshotCached[p.snapshotBlock][msg.sender]) {
            weight = _snapshotBalances[p.snapshotBlock][msg.sender];
        } else {
            weight = IERC20(p.token).balanceOf(msg.sender);
            _snapshotBalances[p.snapshotBlock][msg.sender] = weight;
            _snapshotCached[p.snapshotBlock][msg.sender] = true;
        }

        if (weight == 0) revert ZeroWeight();

        vi.hasVoted = true;
        vi.support = support;
        vi.weight = weight;

        if (support) {
            p.forVotes += weight;
        } else {
            p.againstVotes += weight;
        }

        emit Voted(proposalId, msg.sender, support, weight);
    }

    /// @notice Execute a passed proposal after voting ends.
    /// @dev Requires >50% for-votes AND ≥10% quorum of total supply.
    /// @param proposalId The proposal to execute.
    function execute(uint256 proposalId) external nonReentrant {
        Proposal storage p = _proposals[proposalId];
        if (p.token == address(0)) revert ProposalNotFound();
        if (p.state != ProposalState.Active) revert ProposalNotActive();
        if (block.timestamp <= p.endTime) revert VotingNotEnded();

        uint256 totalVotes = p.forVotes + p.againstVotes;
        uint256 quorum = (p.snapshotSupply * QUORUM_BPS) / 10_000;

        // Must meet quorum AND majority
        bool passed = totalVotes >= quorum && p.forVotes > p.againstVotes;

        if (!passed) {
            p.state = ProposalState.Defeated;
            revert ProposalNotPassed();
        }

        p.state = ProposalState.Executed;

        // Execute calldata on the token contract
        if (p.executionData.length > 0) {
            (bool success,) = p.token.call(p.executionData);
            if (!success) revert ExecutionFailed();
        }

        emit ProposalExecuted(proposalId);
    }

    /// @notice Cancel an active proposal. Only the proposer or the token owner can cancel.
    /// @param proposalId The proposal to cancel.
    function cancel(uint256 proposalId) external {
        Proposal storage p = _proposals[proposalId];
        if (p.token == address(0)) revert ProposalNotFound();
        if (p.state != ProposalState.Active) revert ProposalNotActive();

        // Allow proposer or token owner (via Ownable) to cancel
        bool isProposer = msg.sender == p.proposer;
        bool isTokenOwner = _isOwner(p.token, msg.sender);

        if (!isProposer && !isTokenOwner) revert NotAuthorizedToCancel();

        p.state = ProposalState.Canceled;

        emit ProposalCanceled(proposalId);
    }

    // ──────────────────────────────────────────────
    //  View Functions
    // ──────────────────────────────────────────────

    /// @notice Get full proposal data.
    function getProposal(uint256 id) external view returns (Proposal memory) {
        return _proposals[id];
    }

    /// @notice Get all proposal IDs for a given token.
    function getProposals(address token) external view returns (uint256[] memory) {
        return _tokenProposals[token];
    }

    /// @notice Get a voter's vote info for a proposal.
    function getVote(
        uint256 proposalId,
        address voter
    ) external view returns (bool hasVoted, bool support, uint256 weight) {
        VoteInfo storage vi = _votes[proposalId][voter];
        return (vi.hasVoted, vi.support, vi.weight);
    }

    /// @notice Get the current state of a proposal (resolves Active → Defeated/Succeeded if ended).
    function getProposalState(uint256 proposalId) external view returns (ProposalState) {
        Proposal storage p = _proposals[proposalId];
        if (p.token == address(0)) revert ProposalNotFound();

        if (p.state != ProposalState.Active) return p.state;

        // Still in voting period
        if (block.timestamp <= p.endTime) return ProposalState.Active;

        // Voting ended — determine outcome
        uint256 totalVotes = p.forVotes + p.againstVotes;
        uint256 quorum = (p.snapshotSupply * QUORUM_BPS) / 10_000;

        if (totalVotes >= quorum && p.forVotes > p.againstVotes) {
            return ProposalState.Succeeded;
        }
        return ProposalState.Defeated;
    }

    // ──────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────

    /// @dev Try to call `owner()` on the token contract to check ownership.
    function _isOwner(address token, address account) internal view returns (bool) {
        (bool success, bytes memory data) = token.staticcall(
            abi.encodeWithSignature("owner()")
        );
        if (success && data.length == 32) {
            return abi.decode(data, (address)) == account;
        }
        return false;
    }
}
