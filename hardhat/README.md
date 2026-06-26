# AIJudge — developer quickstart

Smart-contract package for the **Commit-Reveal Bounty Judge**.
📖 Full writeup (lifecycle, architecture, security, tests, reflection) is in the
[**root README**](../README.md).

```bash
pnpm install        # installs forge-std (pinned v1.9.4)
forge test -vv      # 29 passing

# Deploy to Ritual (chain 1979)
forge create --rpc-url https://rpc.ritualfoundation.org \
  --private-key 0xYOURKEY contracts/AIJudge.sol:AIJudge --broadcast
```

| File | Purpose |
|------|---------|
| [`contracts/AIJudge.sol`](contracts/AIJudge.sol) | Commit-reveal bounty judge with batched `0x0802` LLM judging |
| [`contracts/utils/PrecompileConsumer.sol`](contracts/utils/PrecompileConsumer.sol) | Ritual precompile addresses + async return decoding |
| [`test/AIJudge.t.sol`](test/AIJudge.t.sol) | 29 Foundry tests (lifecycle + all invalid-reveal/gating cases) |
| [`foundry.toml`](foundry.toml) | `src=contracts`, `forge-std` remapping, solc 0.8.24 |

**Deployed (Ritual 1979):** [`0x115165D3BE0C35C92eb6561aFFFe418071de9FBC`](https://explorer.ritualfoundation.org/address/0x115165D3BE0C35C92eb6561aFFFe418071de9FBC)
· deploy tx [`0x747f36c2…0596dde`](https://explorer.ritualfoundation.org/tx/0x747f36c25b53c63f7dacafabb0aa0514244ae9260d0edbe4e2ccaa28f0596dde)
