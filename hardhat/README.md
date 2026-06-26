# AIJudge — Privacy-Preserving Commit-Reveal Bounty Judge

A sealed-submission bounty system for Ritual Chain. It fixes the flaw from the
original workshop contract — where `submitAnswer` stored answers in **public**
calldata, letting late participants read and copy earlier submissions before
judging. Here, answers stay hidden until everyone has committed, and only
correctly-revealed answers are eligible for a single batched AI judging call.

- **Contract:** [`hardhat/contracts/AIJudge.sol`](contracts/AIJudge.sol)
- **Tests:** [`hardhat/test/AIJudge.t.sol`](test/AIJudge.t.sol) — 29 passing
- **Track:** Required (Commit-Reveal) + an architecture note for the Ritual-native angle
- **Chain:** Ritual testnet (chain id `1979`)

> **Ritual note:** on Ritual `block.timestamp` is in **milliseconds**, so every
> deadline in this contract is a millisecond timestamp.

---

## Lifecycle

```
createBounty ──► submitCommitment ──►  (submissionDeadline)  ──► revealAnswer ──► (revealDeadline) ──► judgeAll ──► finalizeWinner
  escrow R        store ONLY hash                                verify hash          batched LLM         human picks
                  (answer hidden)                                reveal → stored       (one call)          winner, pays R
```

| Phase | Window | Who | What |
|-------|--------|-----|------|
| **Create** | — | anyone | `createBounty(title, rubric, submissionDeadline, revealDeadline)` escrows the reward (`msg.value`) and sets the two ms deadlines. |
| **Commit** | `now < submissionDeadline` | participants | `submitCommitment(bountyId, commitment)` stores **only** `keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))`. One per wallet. The plaintext answer never touches the chain in this phase. |
| **Reveal** | `submissionDeadline ≤ now < revealDeadline` | participants | `revealAnswer(bountyId, answer, salt)` recomputes the hash and must match the stored commitment. Valid reveals are appended to the bounty's `revealed[]` list. |
| **Judge** | `now ≥ revealDeadline` | owner | `judgeAll(bountyId, llmInput)` makes **one** call to the LLM inference precompile (`0x0802`) over the whole revealed batch and stores the AI's recommendation. |
| **Finalize** | after judging | owner | `finalizeWinner(bountyId, winnerIndex)` — the **human** owner picks the winner (AI only recommends) and the escrow is paid out. Exactly one winner. |

Safety valve: `reclaimUnawarded(bountyId)` lets the owner recover the escrow if
the reveal window closes with **zero** valid reveals, so funds are never locked.

### The commitment binding

```solidity
commitment == keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
```

Binding `msg.sender` and `bountyId` into the hash means a commitment is
**non-transferable**: a different wallet cannot reveal someone else's answer
(the hash won't match), and a commitment can't be replayed across bounties.

---

## Rules enforced (and where)

| Rule | Enforcement |
|------|-------------|
| Commit only before the submission deadline | `submitCommitment`: `now < submissionDeadline` else `SubmissionClosed` |
| One commitment per address | `commitmentOf[id][sender] == 0` else `AlreadyCommitted` |
| Reveal only inside the window | `revealAnswer`: `[submissionDeadline, revealDeadline)` else `NotInRevealWindow` |
| Reveal must match the commitment | hash check else `CommitmentMismatch` |
| Unrevealed answers can't be judged or win | only revealed answers enter `revealed[]`; `judgeAll` needs `revealed.length > 0`; `finalizeWinner` requires `winnerIndex < revealed.length` |
| Judge only after the reveal deadline | `judgeAll`: `now ≥ revealDeadline` else `RevealNotOver` |
| One batched LLM call (not per-answer) | `judgeAll` issues a single `0x0802` call |
| Finalize only after judging | `finalizeWinner`: `judged == true` else `NotJudged` |
| Exactly one winner, paid once | `finalized` flag + checks-effects-interactions + `nonReentrant` |
| Owner-only judge/finalize | `onlyOwner(bountyId)` |

---

## Architecture note

**On-chain (public):** bounty metadata (title, rubric, reward, deadlines),
each participant's **commitment hash**, and — *after* the reveal window — the
revealed plaintext answers, the AI recommendation bytes, and the final winner.

**On-chain (but hidden until reveal):** nothing about the answer except its hash.
A 32-byte commitment leaks no usable information about the answer as long as the
`salt` has enough entropy, so participants cannot copy each other during the
submission phase.

**Off-chain:** the `llmInput` payload for `judgeAll` is ABI-encoded off-chain
(the rubric + the list of revealed answers, formatted as one prompt) and passed
in by the owner. Judging itself runs inside Ritual's TEE-backed LLM executor:
the contract calls precompile `0x0802` **once**, the executor runs the model and
returns `(bool hasError, bytes completion, …)`, and the contract stores
`completion` as the on-chain AI recommendation. Batching matters — it is one
inference over all answers, giving the model comparative context and costing one
async round-trip instead of N.

**Ritual-native extension (advanced track sketch):** to keep answers encrypted
*through* judging, a participant would ECIES-encrypt their answer to the
executor's TEE public key and commit to the ciphertext; the plaintext then exists
only inside the enclave during the single batched `judgeAll` call, and never in
public calldata at all. The commit-reveal flow here is the EVM-portable version
of the same idea: hide first, reveal only what's needed, judge once.

---

## Test plan

`forge test` — **29 tests, all passing.** Coverage:

**Happy path**
- `test_FullLifecycle_PaysWinner` — create → 2 commits → 2 reveals → batched judge (mocked `0x0802`) → finalize → winner paid, escrow drained, phase = `Finalized`.

**Invalid reveals (the core of the assignment)**
- `test_Reveal_RevertsWrongSalt` — right answer, wrong salt → `CommitmentMismatch`
- `test_Reveal_RevertsWrongAnswer` — wrong answer, right salt → `CommitmentMismatch`
- `test_Reveal_RevertsWrongWallet_NoCommitment` — a wallet that never committed can't reveal → `NoCommitment`
- `test_Reveal_RevertsWrongWallet_Mismatch` — another wallet can't reveal someone else's plaintext (sender is in the hash) → `CommitmentMismatch`
- `test_Reveal_RevertsDouble` — second reveal by same wallet → `AlreadyRevealed`
- `test_Reveal_RevertsWithoutCommit` → `NoCommitment`
- `test_Reveal_RevertsBeforeWindow` / `test_Reveal_RevertsAfterWindow` → `NotInRevealWindow`
- `test_Reveal_RevertsAnswerTooLong` → `AnswerTooLong`

**Commit gating**
- after deadline → `SubmissionClosed`; empty hash → `EmptyCommitment`; double commit → `AlreadyCommitted`; unknown bounty → `BountyNotFound`

**Judge / finalize gating**
- judge before reveal deadline → `RevealNotOver`; non-owner → `NotBountyOwner`; no reveals → `NoRevealedAnswers`; LLM error path → `LLMError`; double judge → `AlreadyJudged`
- finalize before judging → `NotJudged`; non-owner → `NotBountyOwner`; out-of-range index → `InvalidWinner`; double finalize → `AlreadyFinalized`
- `test_OnlyRevealedAnswersAreJudgedAndPayable` — committed-but-unrevealed answers are not judgeable/payable
- `test_ReclaimUnawarded_WhenNobodyReveals` — escrow refundable when no one reveals

The LLM precompile is mocked with `vm.mockCall(0x0802, …)` returning the
async `(bytes simInput, bytes actualOutput)` envelope so judging is tested
deterministically off Ritual.

---

## Build, test, deploy

```bash
cd hardhat
pnpm install            # installs forge-std (pinned v1.9.4)
forge test -vv          # 29 passing

# Deploy to Ritual (chain 1979)
forge create --rpc-url https://rpc.ritualfoundation.org \
  --private-key 0xYOURKEY \
  contracts/AIJudge.sol:AIJudge --broadcast
```

### Deployment (Ritual testnet, chain 1979)

| | |
|---|---|
| Contract address | [`0x115165D3BE0C35C92eb6561aFFFe418071de9FBC`](https://explorer.ritualfoundation.org/address/0x115165D3BE0C35C92eb6561aFFFe418071de9FBC) |
| Deploy tx hash | [`0x747f36c25b53c63f7dacafabb0aa0514244ae9260d0edbe4e2ccaa28f0596dde`](https://explorer.ritualfoundation.org/tx/0x747f36c25b53c63f7dacafabb0aa0514244ae9260d0edbe4e2ccaa28f0596dde) |
| Deployer | `0x9Ce516790c3afC712EaC37897765A7A38af68f75` |

---

## Reflection — what should be public, hidden, or AI- vs human-decided?

In a bounty system the **rules and outcomes** should be public: the rubric,
deadlines, escrowed reward, who committed, and — after judging — the revealed
answers and the final winner, so the process is auditable and the result is
verifiable by anyone. What must stay **hidden** is the *content of submissions
until the submission window closes*; otherwise later entrants simply copy and
marginally improve on earlier ones, which destroys fairness. A commit-reveal
scheme (or TEE-encrypted inputs) gives exactly this: a binding, information-free
commitment first, plaintext only once copying can no longer help. The **AI**
is well suited to the scalable, comparative work — reading every revealed answer
against the rubric in one batched pass and producing a structured
*recommendation* with reasons. But the AI should **decide nothing binding**:
models can be biased, gamed by prompt injection in submissions, or simply wrong,
and real money is at stake. So the **human** bounty owner holds the final,
accountable decision — they review the AI's recommendation and call
`finalizeWinner`. In short: make the *rules and results* transparent, keep
*submissions secret until reveal*, let *AI recommend at scale*, and let a
*human own the payout decision*.
