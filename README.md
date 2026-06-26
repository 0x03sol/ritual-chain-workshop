<div align="center">

# 🔒 AIJudge — Privacy-Preserving Commit-Reveal Bounty Judge

**Sealed bounty submissions on any EVM chain, judged in a single batched TEE-backed LLM call.**

Ritual Academy · *Proof of Building* · Commit-Reveal Track

[![Solidity](https://img.shields.io/badge/Solidity-0.8.24-363636?logo=solidity)](hardhat/contracts/AIJudge.sol)
[![Tests](https://img.shields.io/badge/forge%20test-29%20passing-2ea44f)](hardhat/test/AIJudge.t.sol)
[![Chain](https://img.shields.io/badge/Ritual-chain%201979-7c3aed)](https://explorer.ritualfoundation.org/address/0x115165D3BE0C35C92eb6561aFFFe418071de9FBC)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

</div>

---

## The problem

The original workshop contract let anyone read submissions while the bounty was still open:

```solidity
function submitAnswer(uint256 bountyId, string calldata answer) external { ... }
// ❌ the answer sits in PUBLIC calldata — late entrants copy it and submit a tweaked, "better" version
```

That quietly destroys fairness: the best private idea loses to whoever submits last.

## The solution

**Commit-reveal.** Nobody can read an answer until *everyone* has locked theirs in.

```
Phase 1  commit   → on-chain you publish ONLY  keccak256(answer, salt, you, bountyId)
Phase 2  reveal   → after submissions close, you reveal (answer, salt); the contract re-hashes and checks
Phase 3  judge    → ONE batched LLM call (precompile 0x0802) scores every revealed answer together
Phase 4  finalize → the human owner picks the winner (AI only recommends) and the escrow pays out
```

A 32-byte hash leaks nothing about the answer, so copying during submission is impossible. Binding
`msg.sender` + `bountyId` into the hash makes each commitment **non-transferable and non-replayable**.

> ⏱ **Ritual detail:** `block.timestamp` is in **milliseconds** on Ritual, so all deadlines in this contract are ms.

---

## 🚀 Deployed on Ritual (chain 1979)

| | |
|---|---|
| **Contract** | [`0x115165D3BE0C35C92eb6561aFFFe418071de9FBC`](https://explorer.ritualfoundation.org/address/0x115165D3BE0C35C92eb6561aFFFe418071de9FBC) |
| **Deploy tx** | [`0x747f36c25b53c63f7dacafabb0aa0514244ae9260d0edbe4e2ccaa28f0596dde`](https://explorer.ritualfoundation.org/tx/0x747f36c25b53c63f7dacafabb0aa0514244ae9260d0edbe4e2ccaa28f0596dde) |
| **Deployer** | `0x9Ce516790c3afC712EaC37897765A7A38af68f75` |

---

## Lifecycle

```
                  createBounty                 submitCommitment            revealAnswer              judgeAll              finalizeWinner
 owner ──escrow R──────►●        participants ─────►●  (hash only)   ─────►●  (verify hash)   owner ─►●  1 LLM call   owner ─►●  pay winner
                        │                            │                      │                        │                       │
                  set 2 deadlines            now < submissionDeadline   subDL ≤ now < revDL      now ≥ revDL              AI recommends,
                  (ms timestamps)            one per wallet             hash must match          batched 0x0802          human decides
 ──────────────────────┼────────────────────────────┼──────────────────────┼────────────────────────┼───────────────────────┼─────────►
        SUBMISSION                    REVEAL                    JUDGING                 FINALIZED                              time
```

| # | Function | Who | Window | Effect |
|---|----------|-----|--------|--------|
| 1 | `createBounty(title, rubric, submissionDeadline, revealDeadline)` | anyone | — | escrows `msg.value`, sets two ms deadlines |
| 2 | `submitCommitment(bountyId, commitment)` | participant | `now < submissionDeadline` | stores **only** the hash; one per wallet |
| 3 | `revealAnswer(bountyId, answer, salt)` | participant | `[submissionDeadline, revealDeadline)` | verifies hash, stores the plaintext answer |
| 4 | `judgeAll(bountyId, llmInput)` | owner | `now ≥ revealDeadline` | **one** batched `0x0802` call over all reveals |
| 5 | `finalizeWinner(bountyId, winnerIndex)` | owner | after judging | human picks winner, pays the escrow |
| ↩ | `reclaimUnawarded(bountyId)` | owner | after reveal, 0 reveals | refunds escrow so funds never lock |

**The commitment:** `keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))`

---

## Rules enforced

| Invariant | Guard (custom error) |
|-----------|----------------------|
| Commit only before submission deadline | `SubmissionClosed` |
| One commitment per address | `AlreadyCommitted` / `EmptyCommitment` |
| Reveal only inside the window | `NotInRevealWindow` |
| Reveal must match the commitment | `CommitmentMismatch` |
| A wallet can't reveal another's answer | sender ∈ hash → `CommitmentMismatch` / `NoCommitment` |
| Unrevealed answers can't be judged or win | only reveals enter `revealed[]`; `NoRevealedAnswers` / `InvalidWinner` |
| Judge only after reveal deadline | `RevealNotOver` |
| Exactly one batched LLM call | single `0x0802` call in `judgeAll` |
| Finalize only after judging, once | `NotJudged` / `AlreadyFinalized` |
| Owner-only judge & finalize | `NotBountyOwner` |

---

## Architecture — on-chain vs off-chain, and the batched TEE judge

| Data | Where | When visible |
|------|-------|--------------|
| title, rubric, reward, deadlines | on-chain | always (public) |
| **commitment hash** | on-chain | always — but leaks nothing about the answer |
| plaintext answers | on-chain | **only after** the reveal window opens |
| AI recommendation, winner | on-chain | after judge / finalize |
| `llmInput` prompt (rubric + revealed answers) | built off-chain | passed into `judgeAll` |

**How judging works:** the owner builds one ABI-encoded prompt off-chain (rubric + every revealed answer)
and passes it to `judgeAll`, which calls the LLM inference precompile **`0x0802` exactly once**. Ritual's
TEE executor runs the model and returns `(bool hasError, bytes completion, …)`; the contract stores
`completion` as the on-chain recommendation. Batching is deliberate — one inference with full comparative
context, one async round-trip, instead of N calls.

**Ritual-native extension (advanced track):** to keep answers encrypted *through* judging, a participant
would ECIES-encrypt their answer to the executor's TEE key and commit to the ciphertext; the plaintext
then exists *only inside the enclave* during the single batched call, never in public calldata. The
commit-reveal flow here is the EVM-portable version of the same principle — hide first, reveal minimally,
judge once.

---

## 🛡 Security considerations

- **Hiding guarantee** relies on a high-entropy `salt`; a 32-byte commitment is otherwise infeasible to brute-force.
- **Non-transferable commitments:** `msg.sender` and `bountyId` are inside the hash, so reveals can't be stolen or replayed across bounties.
- **Reentrancy:** payout uses checks-effects-interactions (`reward = 0` before transfer) *and* a `nonReentrant` guard.
- **Funds safety:** `reclaimUnawarded` prevents permanently-locked escrow when nobody reveals.
- **DoS bounds:** `MAX_SUBMISSIONS = 50` and `MAX_ANSWER_LENGTH = 2000` keep the batched LLM input within precompile limits.
- **Trust model:** the AI only *recommends*; the human owner makes the binding, accountable `finalizeWinner` call — models can be biased or prompt-injected by submissions, so no payout is automated.

---

## ✅ Tests — `forge test` (29 passing)

| Group | Cases |
|-------|-------|
| Happy path | full create→commit→reveal→judge→finalize, winner paid, escrow drained |
| **Invalid reveals** | wrong salt · wrong answer · wrong wallet (no commitment) · wrong wallet (mismatch) · double reveal · no commitment · answer too long · before/after window |
| Commit gating | after deadline · empty hash · double commit · unknown bounty |
| Judge gating | before reveal deadline · non-owner · no reveals · LLM-error path · double judge |
| Finalize gating | before judging · non-owner · invalid index · double finalize |
| Properties | only-revealed are judged & payable · `reclaimUnawarded` refund · commitment helper parity |

The `0x0802` precompile is mocked with `vm.mockCall` reproducing the async
`abi.encode(bytes simInput, bytes actualOutput)` envelope, so judging is tested deterministically off-chain.

---

## Run it

```bash
cd hardhat
pnpm install            # installs forge-std (pinned v1.9.4)
forge test -vv          # 29 passing

# Deploy to Ritual (chain 1979)
forge create --rpc-url https://rpc.ritualfoundation.org \
  --private-key 0xYOURKEY contracts/AIJudge.sol:AIJudge --broadcast
```

---

## Reflection — public vs hidden, AI vs human

In a bounty system the **rules and outcomes** should be public — rubric, deadlines, escrow, who
committed, and (after judging) the revealed answers and the winner — so the process is auditable and the
result verifiable by anyone. What must stay **hidden** is the *content of submissions until the
submission window closes*; otherwise late entrants copy and marginally improve earlier work, which is the
exact flaw this contract removes. Commit-reveal (or TEE-encrypted inputs) delivers that: a binding,
information-free commitment first, plaintext only once copying can no longer help. The **AI** is ideal
for the scalable, comparative work — reading every revealed answer against the rubric in one batched pass
and producing a structured recommendation with reasons. But the AI should **decide nothing binding**:
models can be biased, prompt-injected by a submission, or simply wrong, and real money is at stake. So a
**human** owner holds the final, accountable decision and calls `finalizeWinner`. In short: make the
*rules and results* transparent, keep *submissions secret until reveal*, let *AI recommend at scale*, and
let a *human own the payout*.

---

## Repo layout

```
hardhat/
├── contracts/
│   ├── AIJudge.sol            ← commit-reveal bounty judge (this submission)
│   └── utils/PrecompileConsumer.sol
├── test/AIJudge.t.sol         ← 29 Foundry tests
├── foundry.toml               ← forge config (src=contracts, forge-std remap)
└── README.md                  ← developer quickstart
web/                            ← starter Next.js frontend (unchanged)
```

<div align="center"><sub>Built for Ritual Chain · ID 1979 · precompile <code>0x0802</code></sub></div>
