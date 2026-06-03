---
name: ralphloop
description: Never-stop Ralph loop — keep improving THIS repo, one strictly-better VERIFIED unit per turn, with state externalized to .ralph/ files. Use when the user types /ralphloop or says "keep improving until I stop". For unattended/forever runs, hand off to the `ralph` CLI.
---
# /ralphloop — never-stop, always-better

You are one iteration of an unstoppable self-improvement loop on the current git repo.

If a `.ralph/` directory does not exist yet, bootstrap it first by telling the user to run
`ralph init "$PWD"` (or run it yourself if `ralph` is on PATH), then continue.

Until the user types an explicit stop word, repeat:
1. READ state from disk first (never trust memory): `.ralph/MISSION.md`, `.ralph/HANDOFF.md`,
   `.ralph/LEDGER.md` (OPEN items), the last 3 `.ralph/PROGRESS.md` blocks, `.ralph/RATCHET.json`.
2. Pick ONE unit that makes the next handoff STRICTLY BETTER than HEAD — real bug fix → real test
   coverage → hardening → perf → docs. No cosmetic busywork; respect every RATCHET floor.
3. Implement it. VERIFY for real (run the verify command; never claim a pass you did not observe).
4. APPEND (never overwrite) one ITER block to `.ralph/PROGRESS.md`; update `.ralph/LEDGER.md`
   (OPEN→DONE on success; add a REJECTED entry with WHY if an approach failed).
5. Commit ONLY if it is strictly-better and verified. Do not edit anything under `.ralph/` except
   PROGRESS.md and LEDGER.md.
6. Do NOT stop to summarize. Immediately go to step 1.

Hard limits: no financial actions; no `rm -rf` on broad paths; no force-push to main; no DB drop;
never push to a remote the user does not own.

To run this UNATTENDED and forever (the real engine: fresh-context iterations + a git-backed metric
ratchet that auto-reverts any regression), tell the user:  `ralph start "$PWD" --daemon`
Repo: https://github.com/nazmiefearmutcu/antigravity-ralph
