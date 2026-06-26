// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AIJudge} from "../contracts/AIJudge.sol";

/// @title AIJudge commit-reveal test suite
/// @notice Covers the full lifecycle plus every invalid-reveal and gating case
///         the assignment calls out: wrong salt, wrong answer, wrong wallet,
///         double reveal, deadline violations, and judge/finalize ordering.
/// @dev Timestamps are plain numbers here; on Ritual they are milliseconds, but
///      the contract only ever *compares* them so units are irrelevant to logic.
contract AIJudgeTest is Test {
    AIJudge internal judge;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    // ms-style clock
    uint64 internal constant T0 = 1_000_000; // "now" at setup
    uint64 internal constant SUB_DEADLINE = 2_000_000; // submissions close
    uint64 internal constant REV_DEADLINE = 3_000_000; // reveals close

    uint256 internal constant REWARD = 1 ether;

    address internal constant LLM = address(0x0802);

    function setUp() public {
        judge = new AIJudge();
        vm.warp(T0);
        vm.deal(owner, 10 ether);
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
        vm.deal(carol, 1 ether);
    }

    // ----------------------------------------------------------------- helpers

    function _create() internal returns (uint256 id) {
        vm.prank(owner);
        id = judge.createBounty{value: REWARD}("Best haiku", "Most evocative wins", SUB_DEADLINE, REV_DEADLINE);
    }

    function _commitment(string memory answer, bytes32 salt, address who, uint256 id) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(answer, salt, who, id));
    }

    function _commit(uint256 id, address who, string memory answer, bytes32 salt) internal {
        vm.prank(who);
        judge.submitCommitment(id, _commitment(answer, salt, who, id));
    }

    function _reveal(uint256 id, address who, string memory answer, bytes32 salt) internal {
        vm.prank(who);
        judge.revealAnswer(id, answer, salt);
    }

    /// @dev Mock the LLM inference precompile (0x0802). The async precompile
    ///      returns abi.encode(bytes simInput, bytes actualOutput); the inner
    ///      actualOutput is the inference tuple the contract decodes.
    function _mockLLM(bytes memory llmInput, bool hasError, bytes memory completion, string memory err) internal {
        AIJudge.ConvoHistory memory ch = AIJudge.ConvoHistory("", "", "");
        bytes memory actual = abi.encode(hasError, completion, bytes(""), err, ch);
        bytes memory raw = abi.encode(bytes(""), actual);
        vm.mockCall(LLM, llmInput, raw);
    }

    // -------------------------------------------------------------- happy path

    function test_FullLifecycle_PaysWinner() public {
        uint256 id = _create();

        // commit phase
        _commit(id, alice, "frost on the pane", bytes32(uint256(0xA11CE)));
        _commit(id, bob, "a crow takes flight", bytes32(uint256(0xB0B)));

        AIJudge.BountyView memory cv = judge.getBounty(id);
        assertEq(cv.commitmentCount, 2, "2 commitments");
        assertEq(cv.revealedCount, 0, "no reveals yet");
        assertEq(uint256(judge.phaseOf(id)), uint256(AIJudge.Phase.Submission));

        // reveal phase
        vm.warp(SUB_DEADLINE + 1);
        assertEq(uint256(judge.phaseOf(id)), uint256(AIJudge.Phase.Reveal));
        _reveal(id, alice, "frost on the pane", bytes32(uint256(0xA11CE)));
        _reveal(id, bob, "a crow takes flight", bytes32(uint256(0xB0B)));
        assertEq(judge.revealedCount(id), 2, "both revealed");

        // judge (single batched call)
        vm.warp(REV_DEADLINE + 1);
        assertEq(uint256(judge.phaseOf(id)), uint256(AIJudge.Phase.Judging));
        bytes memory llmInput = bytes("BATCH_JUDGE_REQUEST");
        _mockLLM(llmInput, false, bytes("AI recommends submission #0"), "");
        vm.prank(owner);
        judge.judgeAll(id, llmInput);

        AIJudge.BountyView memory jv = judge.getBounty(id);
        assertTrue(jv.judged, "judged flag set");
        assertEq(string(jv.aiReview), "AI recommends submission #0");

        // finalize: human picks the winner (here, alice at index 0)
        uint256 before = alice.balance;
        vm.prank(owner);
        judge.finalizeWinner(id, 0);

        assertEq(alice.balance, before + REWARD, "winner paid");
        assertEq(uint256(judge.phaseOf(id)), uint256(AIJudge.Phase.Finalized));
        AIJudge.BountyView memory fv = judge.getBounty(id);
        assertTrue(fv.finalized);
        assertEq(fv.winnerIndex, 0);
        assertEq(address(judge).balance, 0, "escrow drained");
    }

    // --------------------------------------------------------------- creation

    function test_Create_RevertsWithoutReward() public {
        vm.prank(owner);
        vm.expectRevert(AIJudge.RewardRequired.selector);
        judge.createBounty("t", "r", SUB_DEADLINE, REV_DEADLINE);
    }

    function test_Create_RevertsBadDeadlines() public {
        vm.startPrank(owner);
        // submission deadline in the past
        vm.expectRevert(AIJudge.BadDeadlines.selector);
        judge.createBounty{value: REWARD}("t", "r", uint64(T0 - 1), REV_DEADLINE);
        // reveal not after submission
        vm.expectRevert(AIJudge.BadDeadlines.selector);
        judge.createBounty{value: REWARD}("t", "r", SUB_DEADLINE, SUB_DEADLINE);
        vm.stopPrank();
    }

    // --------------------------------------------------------------- commit

    function test_Commit_RevertsAfterDeadline() public {
        uint256 id = _create();
        vm.warp(SUB_DEADLINE);
        vm.prank(alice);
        vm.expectRevert(AIJudge.SubmissionClosed.selector);
        judge.submitCommitment(id, _commitment("x", bytes32(uint256(1)), alice, id));
    }

    function test_Commit_RevertsEmpty() public {
        uint256 id = _create();
        vm.prank(alice);
        vm.expectRevert(AIJudge.EmptyCommitment.selector);
        judge.submitCommitment(id, bytes32(0));
    }

    function test_Commit_RevertsDouble() public {
        uint256 id = _create();
        _commit(id, alice, "x", bytes32(uint256(1)));
        vm.prank(alice);
        vm.expectRevert(AIJudge.AlreadyCommitted.selector);
        judge.submitCommitment(id, _commitment("y", bytes32(uint256(2)), alice, id));
    }

    function test_Commit_RevertsUnknownBounty() public {
        vm.prank(alice);
        vm.expectRevert(AIJudge.BountyNotFound.selector);
        judge.submitCommitment(999, _commitment("x", bytes32(uint256(1)), alice, 999));
    }

    // --------------------------------------------------------------- reveal

    function test_Reveal_RevertsBeforeWindow() public {
        uint256 id = _create();
        _commit(id, alice, "x", bytes32(uint256(1)));
        // still in submission phase
        vm.prank(alice);
        vm.expectRevert(AIJudge.NotInRevealWindow.selector);
        judge.revealAnswer(id, "x", bytes32(uint256(1)));
    }

    function test_Reveal_RevertsAfterWindow() public {
        uint256 id = _create();
        _commit(id, alice, "x", bytes32(uint256(1)));
        vm.warp(REV_DEADLINE); // reveal closed
        vm.prank(alice);
        vm.expectRevert(AIJudge.NotInRevealWindow.selector);
        judge.revealAnswer(id, "x", bytes32(uint256(1)));
    }

    function test_Reveal_RevertsWrongSalt() public {
        uint256 id = _create();
        _commit(id, alice, "secret", bytes32(uint256(0xAAAA)));
        vm.warp(SUB_DEADLINE + 1);
        vm.prank(alice);
        vm.expectRevert(AIJudge.CommitmentMismatch.selector);
        judge.revealAnswer(id, "secret", bytes32(uint256(0xBBBB))); // wrong salt
    }

    function test_Reveal_RevertsWrongAnswer() public {
        uint256 id = _create();
        _commit(id, alice, "secret", bytes32(uint256(0xAAAA)));
        vm.warp(SUB_DEADLINE + 1);
        vm.prank(alice);
        vm.expectRevert(AIJudge.CommitmentMismatch.selector);
        judge.revealAnswer(id, "not-the-secret", bytes32(uint256(0xAAAA))); // wrong answer
    }

    function test_Reveal_RevertsWrongWallet_NoCommitment() public {
        uint256 id = _create();
        _commit(id, alice, "secret", bytes32(uint256(0xAAAA)));
        vm.warp(SUB_DEADLINE + 1);
        // bob never committed; he cannot reveal alice's answer
        vm.prank(bob);
        vm.expectRevert(AIJudge.NoCommitment.selector);
        judge.revealAnswer(id, "secret", bytes32(uint256(0xAAAA)));
    }

    function test_Reveal_RevertsWrongWallet_Mismatch() public {
        uint256 id = _create();
        _commit(id, alice, "secret", bytes32(uint256(0xAAAA)));
        // bob commits his own, then tries to reveal alice's plaintext: the hash
        // binds msg.sender, so it cannot match bob's commitment.
        _commit(id, bob, "bob-answer", bytes32(uint256(0xBBBB)));
        vm.warp(SUB_DEADLINE + 1);
        vm.prank(bob);
        vm.expectRevert(AIJudge.CommitmentMismatch.selector);
        judge.revealAnswer(id, "secret", bytes32(uint256(0xAAAA)));
    }

    function test_Reveal_RevertsDouble() public {
        uint256 id = _create();
        _commit(id, alice, "secret", bytes32(uint256(0xAAAA)));
        vm.warp(SUB_DEADLINE + 1);
        _reveal(id, alice, "secret", bytes32(uint256(0xAAAA)));
        vm.prank(alice);
        vm.expectRevert(AIJudge.AlreadyRevealed.selector);
        judge.revealAnswer(id, "secret", bytes32(uint256(0xAAAA)));
    }

    function test_Reveal_RevertsWithoutCommit() public {
        uint256 id = _create();
        vm.warp(SUB_DEADLINE + 1);
        vm.prank(carol);
        vm.expectRevert(AIJudge.NoCommitment.selector);
        judge.revealAnswer(id, "anything", bytes32(uint256(1)));
    }

    function test_Reveal_RevertsAnswerTooLong() public {
        uint256 id = _create();
        string memory big = new string(2_001);
        bytes32 salt = bytes32(uint256(7));
        vm.prank(alice);
        judge.submitCommitment(id, _commitment(big, salt, alice, id));
        vm.warp(SUB_DEADLINE + 1);
        vm.prank(alice);
        vm.expectRevert(AIJudge.AnswerTooLong.selector);
        judge.revealAnswer(id, big, salt);
    }

    // --------------------------------------------------------------- judge

    function test_Judge_RevertsBeforeRevealDeadline() public {
        uint256 id = _create();
        _commit(id, alice, "x", bytes32(uint256(1)));
        vm.warp(SUB_DEADLINE + 1);
        _reveal(id, alice, "x", bytes32(uint256(1)));
        // still inside reveal window
        bytes memory llmInput = bytes("J");
        _mockLLM(llmInput, false, bytes("ok"), "");
        vm.prank(owner);
        vm.expectRevert(AIJudge.RevealNotOver.selector);
        judge.judgeAll(id, llmInput);
    }

    function test_Judge_RevertsNotOwner() public {
        uint256 id = _create();
        _commit(id, alice, "x", bytes32(uint256(1)));
        vm.warp(SUB_DEADLINE + 1);
        _reveal(id, alice, "x", bytes32(uint256(1)));
        vm.warp(REV_DEADLINE + 1);
        vm.prank(alice);
        vm.expectRevert(AIJudge.NotBountyOwner.selector);
        judge.judgeAll(id, bytes("J"));
    }

    function test_Judge_RevertsNoReveals() public {
        uint256 id = _create();
        _commit(id, alice, "x", bytes32(uint256(1))); // committed but never revealed
        vm.warp(REV_DEADLINE + 1);
        vm.prank(owner);
        vm.expectRevert(AIJudge.NoRevealedAnswers.selector);
        judge.judgeAll(id, bytes("J"));
    }

    function test_Judge_RevertsOnLLMError() public {
        uint256 id = _create();
        _commit(id, alice, "x", bytes32(uint256(1)));
        vm.warp(SUB_DEADLINE + 1);
        _reveal(id, alice, "x", bytes32(uint256(1)));
        vm.warp(REV_DEADLINE + 1);
        bytes memory llmInput = bytes("J");
        _mockLLM(llmInput, true, bytes(""), "model unavailable");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AIJudge.LLMError.selector, "model unavailable"));
        judge.judgeAll(id, llmInput);
    }

    function test_Judge_RevertsDouble() public {
        uint256 id = _judgedBounty();
        vm.prank(owner);
        vm.expectRevert(AIJudge.AlreadyJudged.selector);
        judge.judgeAll(id, bytes("BATCH_JUDGE_REQUEST"));
    }

    // --------------------------------------------------------------- finalize

    function test_Finalize_RevertsBeforeJudge() public {
        uint256 id = _create();
        _commit(id, alice, "x", bytes32(uint256(1)));
        vm.warp(SUB_DEADLINE + 1);
        _reveal(id, alice, "x", bytes32(uint256(1)));
        vm.warp(REV_DEADLINE + 1);
        vm.prank(owner);
        vm.expectRevert(AIJudge.NotJudged.selector);
        judge.finalizeWinner(id, 0);
    }

    function test_Finalize_RevertsNotOwner() public {
        uint256 id = _judgedBounty();
        vm.prank(alice);
        vm.expectRevert(AIJudge.NotBountyOwner.selector);
        judge.finalizeWinner(id, 0);
    }

    function test_Finalize_RevertsInvalidWinner() public {
        uint256 id = _judgedBounty(); // exactly 1 revealed (alice)
        vm.prank(owner);
        vm.expectRevert(AIJudge.InvalidWinner.selector);
        judge.finalizeWinner(id, 1); // out of range
    }

    function test_Finalize_RevertsDouble() public {
        uint256 id = _judgedBounty();
        vm.prank(owner);
        judge.finalizeWinner(id, 0);
        vm.prank(owner);
        vm.expectRevert(AIJudge.AlreadyFinalized.selector);
        judge.finalizeWinner(id, 0);
    }

    // ---------------------------------------- only-revealed-are-eligible

    function test_OnlyRevealedAnswersAreJudgedAndPayable() public {
        uint256 id = _create();
        _commit(id, alice, "alice-ans", bytes32(uint256(0xA)));
        _commit(id, bob, "bob-ans", bytes32(uint256(0xB)));
        vm.warp(SUB_DEADLINE + 1);
        _reveal(id, alice, "alice-ans", bytes32(uint256(0xA))); // only alice reveals
        vm.warp(REV_DEADLINE + 1);

        assertEq(judge.revealedCount(id), 1, "only one revealed");
        bytes memory llmInput = bytes("B");
        _mockLLM(llmInput, false, bytes("pick 0"), "");
        vm.prank(owner);
        judge.judgeAll(id, llmInput);

        // index 1 would be bob, but he never revealed -> not payable
        vm.prank(owner);
        vm.expectRevert(AIJudge.InvalidWinner.selector);
        judge.finalizeWinner(id, 1);

        uint256 before = alice.balance;
        vm.prank(owner);
        judge.finalizeWinner(id, 0);
        assertEq(alice.balance, before + REWARD);
    }

    // ----------------------------------------------------- reclaim safety valve

    function test_ReclaimUnawarded_WhenNobodyReveals() public {
        uint256 id = _create();
        _commit(id, alice, "x", bytes32(uint256(1))); // committed, never revealed
        vm.warp(REV_DEADLINE + 1);

        uint256 before = owner.balance;
        vm.prank(owner);
        judge.reclaimUnawarded(id);
        assertEq(owner.balance, before + REWARD, "owner refunded");
        assertEq(uint256(judge.phaseOf(id)), uint256(AIJudge.Phase.Finalized));
    }

    function test_Reclaim_RevertsIfRevealsExist() public {
        uint256 id = _judgedBounty();
        vm.prank(owner);
        vm.expectRevert(AIJudge.NothingToReclaim.selector);
        judge.reclaimUnawarded(id);
    }

    // --------------------------------------------------------------- misc

    function test_ComputeCommitment_MatchesReveal() public {
        uint256 id = _create();
        bytes32 onchain = judge.computeCommitment("answer", bytes32(uint256(42)), alice, id);
        bytes32 local = _commitment("answer", bytes32(uint256(42)), alice, id);
        assertEq(onchain, local);
    }

    // --------------------------------------------------------------- fixtures

    /// @dev Returns a bounty that has been judged with a single revealed answer
    ///      from `alice`, ready for finalize tests.
    function _judgedBounty() internal returns (uint256 id) {
        id = _create();
        _commit(id, alice, "alice-answer", bytes32(uint256(0xA11CE)));
        vm.warp(SUB_DEADLINE + 1);
        _reveal(id, alice, "alice-answer", bytes32(uint256(0xA11CE)));
        vm.warp(REV_DEADLINE + 1);
        bytes memory llmInput = bytes("BATCH_JUDGE_REQUEST");
        _mockLLM(llmInput, false, bytes("AI recommends submission #0"), "");
        vm.prank(owner);
        judge.judgeAll(id, llmInput);
    }
}
