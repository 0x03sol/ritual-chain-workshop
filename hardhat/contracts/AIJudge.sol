// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "./utils/PrecompileConsumer.sol";

/// @title AIJudge — Commit‑Reveal Bounty Judge
/// @author 0x03sol
/// @notice A sealed-submission bounty system. During the submission phase a
///         participant publishes only a *commitment* (a hash of their answer);
///         the plaintext stays private. After submissions close, participants
///         reveal their answer + salt during a reveal window, and the contract
///         verifies the reveal against the stored commitment. Only correctly
///         revealed answers become eligible for a single, batched AI judging
///         call. The bounty owner then finalizes exactly one winner — the AI
///         only *recommends*; a human makes the final call.
/// @dev    Targets Ritual Chain, where `block.timestamp` is denominated in
///         MILLISECONDS — all deadlines are therefore ms since epoch. Judging
///         performs ONE call to the LLM inference precompile (0x0802) over the
///         whole revealed batch (never one call per answer).
contract AIJudge is PrecompileConsumer {
    // ---------------------------------------------------------------------
    //  Limits
    // ---------------------------------------------------------------------

    /// @notice Maximum number of commitments (and therefore reveals) per bounty.
    /// @dev Bounds the batched LLM input so a single judging call stays within
    ///      the precompile's payload limit.
    uint256 public constant MAX_SUBMISSIONS = 50;

    /// @notice Maximum byte length of a revealed answer.
    uint256 public constant MAX_ANSWER_LENGTH = 2_000;

    // ---------------------------------------------------------------------
    //  Types
    // ---------------------------------------------------------------------

    /// @notice High-level lifecycle stage of a bounty, derived from the clock
    ///         and finalization flags. Purely informational (for UIs/indexers).
    enum Phase {
        None, // bounty does not exist
        Submission, // accepting commitments
        Reveal, // accepting reveals
        Judging, // reveal window closed, awaiting judge/finalize
        Finalized // winner paid (or funds reclaimed)
    }

    /// @notice A successfully revealed answer.
    struct Submission {
        address submitter;
        string answer;
    }

    /// @notice Storage reference tuple returned by the LLM inference precompile.
    /// @dev Mirrors the precompile response shape; unused fields are ignored.
    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    /// @notice Flat, array-free snapshot of a bounty for off-chain reads.
    struct BountyView {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint64 submissionDeadline;
        uint64 revealDeadline;
        uint32 commitmentCount;
        uint256 revealedCount;
        bool judged;
        bool finalized;
        uint256 winnerIndex;
        bytes aiReview;
    }

    struct Bounty {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint64 submissionDeadline; // ms since epoch — commitments accepted strictly before
        uint64 revealDeadline; // ms since epoch — reveals accepted [submissionDeadline, revealDeadline)
        uint32 commitmentCount; // number of commitments taken (cap: MAX_SUBMISSIONS)
        bool judged;
        bool finalized;
        uint256 winnerIndex; // index into `revealed`; type(uint256).max until finalized
        bytes aiReview; // raw completion bytes returned by the LLM judge
        Submission[] revealed; // only correctly-revealed answers, in reveal order
    }

    // ---------------------------------------------------------------------
    //  Storage
    // ---------------------------------------------------------------------

    uint256 public nextBountyId = 1;

    mapping(uint256 => Bounty) private _bounties;

    /// @notice commitment hash for a participant in a bounty (bytes32(0) = none).
    mapping(uint256 => mapping(address => bytes32)) public commitmentOf;

    /// @notice whether a participant has already revealed in a bounty.
    mapping(uint256 => mapping(address => bool)) public hasRevealed;

    uint256 private _locked; // 1 while a value-transferring call is executing

    // ---------------------------------------------------------------------
    //  Events
    // ---------------------------------------------------------------------

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed owner,
        string title,
        uint256 reward,
        uint64 submissionDeadline,
        uint64 revealDeadline
    );
    event CommitmentSubmitted(uint256 indexed bountyId, address indexed participant, bytes32 commitment);
    event AnswerRevealed(uint256 indexed bountyId, uint256 indexed submissionIndex, address indexed submitter);
    event AllAnswersJudged(uint256 indexed bountyId, uint256 submissionCount, bytes aiReview);
    event WinnerFinalized(uint256 indexed bountyId, uint256 indexed winnerIndex, address indexed winner, uint256 reward);
    event BountyReclaimed(uint256 indexed bountyId, address indexed owner, uint256 amount);

    // ---------------------------------------------------------------------
    //  Errors
    // ---------------------------------------------------------------------

    error BountyNotFound();
    error NotBountyOwner();
    error RewardRequired();
    error BadDeadlines();
    error SubmissionClosed();
    error EmptyCommitment();
    error AlreadyCommitted();
    error TooManySubmissions();
    error NotInRevealWindow();
    error NoCommitment();
    error AlreadyRevealed();
    error AnswerTooLong();
    error CommitmentMismatch();
    error RevealNotOver();
    error AlreadyJudged();
    error AlreadyFinalized();
    error NoRevealedAnswers();
    error LLMError(string message);
    error NotJudged();
    error InvalidWinner();
    error PaymentFailed();
    error NothingToReclaim();
    error Reentrancy();

    // ---------------------------------------------------------------------
    //  Modifiers
    // ---------------------------------------------------------------------

    modifier exists(uint256 bountyId) {
        if (_bounties[bountyId].owner == address(0)) revert BountyNotFound();
        _;
    }

    modifier onlyOwner(uint256 bountyId) {
        if (msg.sender != _bounties[bountyId].owner) revert NotBountyOwner();
        _;
    }

    modifier nonReentrant() {
        if (_locked == 1) revert Reentrancy();
        _locked = 1;
        _;
        _locked = 0;
    }

    // ---------------------------------------------------------------------
    //  1. Create
    // ---------------------------------------------------------------------

    /// @notice Create and fund a bounty. The attached value is escrowed and paid
    ///         to the finalized winner.
    /// @param title Human-readable bounty title.
    /// @param rubric Grading rubric the AI judge is instructed to apply.
    /// @param submissionDeadline ms timestamp after which commitments are closed.
    /// @param revealDeadline ms timestamp after which reveals are closed; must be
    ///        strictly greater than `submissionDeadline`.
    function createBounty(
        string calldata title,
        string calldata rubric,
        uint64 submissionDeadline,
        uint64 revealDeadline
    ) external payable returns (uint256 bountyId) {
        if (msg.value == 0) revert RewardRequired();
        // ms-denominated clock: submission must close in the future, and the
        // reveal window must open after submissions close.
        if (submissionDeadline <= block.timestamp || revealDeadline <= submissionDeadline) {
            revert BadDeadlines();
        }

        bountyId = nextBountyId++;
        Bounty storage b = _bounties[bountyId];
        b.owner = msg.sender;
        b.title = title;
        b.rubric = rubric;
        b.reward = msg.value;
        b.submissionDeadline = submissionDeadline;
        b.revealDeadline = revealDeadline;
        b.winnerIndex = type(uint256).max;

        emit BountyCreated(bountyId, msg.sender, title, msg.value, submissionDeadline, revealDeadline);
    }

    // ---------------------------------------------------------------------
    //  2. Commit
    // ---------------------------------------------------------------------

    /// @notice Submit a sealed commitment to an answer. Only the hash is stored;
    ///         the plaintext answer is never put on-chain in this phase.
    /// @dev The commitment must equal
    ///      `keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))`.
    ///      One commitment per address per bounty; allowed only before the
    ///      submission deadline.
    function submitCommitment(uint256 bountyId, bytes32 commitment) external exists(bountyId) {
        Bounty storage b = _bounties[bountyId];
        if (block.timestamp >= b.submissionDeadline) revert SubmissionClosed();
        if (commitment == bytes32(0)) revert EmptyCommitment();
        if (commitmentOf[bountyId][msg.sender] != bytes32(0)) revert AlreadyCommitted();
        if (b.commitmentCount >= MAX_SUBMISSIONS) revert TooManySubmissions();

        commitmentOf[bountyId][msg.sender] = commitment;
        unchecked {
            ++b.commitmentCount;
        }

        emit CommitmentSubmitted(bountyId, msg.sender, commitment);
    }

    // ---------------------------------------------------------------------
    //  3. Reveal
    // ---------------------------------------------------------------------

    /// @notice Reveal a previously committed answer. Succeeds only if the hash of
    ///         (answer, salt, sender, bountyId) matches the stored commitment.
    /// @dev Allowed only within the reveal window
    ///      `[submissionDeadline, revealDeadline)`. Each address may reveal once.
    function revealAnswer(uint256 bountyId, string calldata answer, bytes32 salt) external exists(bountyId) {
        Bounty storage b = _bounties[bountyId];
        if (block.timestamp < b.submissionDeadline || block.timestamp >= b.revealDeadline) {
            revert NotInRevealWindow();
        }

        bytes32 commitment = commitmentOf[bountyId][msg.sender];
        if (commitment == bytes32(0)) revert NoCommitment();
        if (hasRevealed[bountyId][msg.sender]) revert AlreadyRevealed();
        if (bytes(answer).length > MAX_ANSWER_LENGTH) revert AnswerTooLong();
        if (keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId)) != commitment) {
            revert CommitmentMismatch();
        }

        hasRevealed[bountyId][msg.sender] = true;
        b.revealed.push(Submission({submitter: msg.sender, answer: answer}));

        emit AnswerRevealed(bountyId, b.revealed.length - 1, msg.sender);
    }

    // ---------------------------------------------------------------------
    //  4. Judge (single batched LLM call)
    // ---------------------------------------------------------------------

    /// @notice Run the AI judge over every revealed answer in one batched call to
    ///         the LLM inference precompile, and store the recommendation.
    /// @dev Owner-only; allowed only after the reveal deadline so the full set of
    ///      revealed answers is known. `llmInput` is the ABI-encoded inference
    ///      request (rubric + the revealed answers) built off-chain. Unrevealed
    ///      commitments are never part of `revealed`, so they cannot be judged.
    function judgeAll(uint256 bountyId, bytes calldata llmInput) external exists(bountyId) onlyOwner(bountyId) {
        Bounty storage b = _bounties[bountyId];
        if (block.timestamp < b.revealDeadline) revert RevealNotOver();
        if (b.judged) revert AlreadyJudged();
        if (b.finalized) revert AlreadyFinalized();
        if (b.revealed.length == 0) revert NoRevealedAnswers();

        bytes memory output = _executePrecompile(LLM_INFERENCE_PRECOMPILE, llmInput);

        (bool hasError, bytes memory completionData,, string memory errorMessage,) =
            abi.decode(output, (bool, bytes, bytes, string, ConvoHistory));
        if (hasError) revert LLMError(errorMessage);

        b.judged = true;
        b.aiReview = completionData;

        emit AllAnswersJudged(bountyId, b.revealed.length, completionData);
    }

    // ---------------------------------------------------------------------
    //  5. Finalize (human decision) + payout
    // ---------------------------------------------------------------------

    /// @notice Pay the bounty reward to the chosen winner. The AI only recommends;
    ///         the owner makes the binding decision here.
    /// @dev Owner-only; only after judging; `winnerIndex` must reference a
    ///      revealed submission. Pays exactly one winner. Uses
    ///      checks-effects-interactions plus a reentrancy guard.
    function finalizeWinner(uint256 bountyId, uint256 winnerIndex)
        external
        exists(bountyId)
        onlyOwner(bountyId)
        nonReentrant
    {
        Bounty storage b = _bounties[bountyId];
        if (!b.judged) revert NotJudged();
        if (b.finalized) revert AlreadyFinalized();
        if (winnerIndex >= b.revealed.length) revert InvalidWinner();

        b.finalized = true;
        b.winnerIndex = winnerIndex;

        address winner = b.revealed[winnerIndex].submitter;
        uint256 reward = b.reward;
        b.reward = 0;

        (bool ok,) = payable(winner).call{value: reward}("");
        if (!ok) revert PaymentFailed();

        emit WinnerFinalized(bountyId, winnerIndex, winner, reward);
    }

    // ---------------------------------------------------------------------
    //  Safety valve: reclaim if nobody revealed
    // ---------------------------------------------------------------------

    /// @notice Let the owner reclaim the escrow if the reveal window closed with
    ///         zero valid reveals, so funds are never permanently locked.
    /// @dev Only callable after `revealDeadline`, only when there are no revealed
    ///      answers, and only once.
    function reclaimUnawarded(uint256 bountyId) external exists(bountyId) onlyOwner(bountyId) nonReentrant {
        Bounty storage b = _bounties[bountyId];
        if (block.timestamp < b.revealDeadline) revert RevealNotOver();
        if (b.finalized) revert AlreadyFinalized();
        if (b.revealed.length != 0 || b.reward == 0) revert NothingToReclaim();

        uint256 amount = b.reward;
        b.reward = 0;
        b.finalized = true;

        (bool ok,) = payable(b.owner).call{value: amount}("");
        if (!ok) revert PaymentFailed();

        emit BountyReclaimed(bountyId, b.owner, amount);
    }

    // ---------------------------------------------------------------------
    //  Views
    // ---------------------------------------------------------------------

    /// @notice Current lifecycle phase of a bounty.
    function phaseOf(uint256 bountyId) external view exists(bountyId) returns (Phase) {
        Bounty storage b = _bounties[bountyId];
        if (b.finalized) return Phase.Finalized;
        if (block.timestamp < b.submissionDeadline) return Phase.Submission;
        if (block.timestamp < b.revealDeadline) return Phase.Reveal;
        return Phase.Judging;
    }

    /// @notice Helper to compute the canonical commitment off-chain or in tests.
    function computeCommitment(string calldata answer, bytes32 salt, address participant, uint256 bountyId)
        external
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(answer, salt, participant, bountyId));
    }

    function getBounty(uint256 bountyId) external view exists(bountyId) returns (BountyView memory v) {
        Bounty storage b = _bounties[bountyId];
        v = BountyView({
            owner: b.owner,
            title: b.title,
            rubric: b.rubric,
            reward: b.reward,
            submissionDeadline: b.submissionDeadline,
            revealDeadline: b.revealDeadline,
            commitmentCount: b.commitmentCount,
            revealedCount: b.revealed.length,
            judged: b.judged,
            finalized: b.finalized,
            winnerIndex: b.winnerIndex,
            aiReview: b.aiReview
        });
    }

    /// @notice Read a single revealed submission.
    function getSubmission(uint256 bountyId, uint256 index)
        external
        view
        exists(bountyId)
        returns (address submitter, string memory answer)
    {
        Bounty storage b = _bounties[bountyId];
        if (index >= b.revealed.length) revert InvalidWinner();
        Submission storage s = b.revealed[index];
        return (s.submitter, s.answer);
    }

    /// @notice Number of revealed submissions for a bounty.
    function revealedCount(uint256 bountyId) external view exists(bountyId) returns (uint256) {
        return _bounties[bountyId].revealed.length;
    }
}
