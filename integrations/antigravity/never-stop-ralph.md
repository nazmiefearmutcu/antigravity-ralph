---
name: ralphloop
trigger: "/ralphloop" or "/ralph" or "keep improving this repo until I say stop"
description: Run the Ralph discipline in-IDE — one strictly-better unit per turn, externalize state to files, never pause for a summary.
---
# Never-Stop Ralph (in-IDE)
Until the user types an explicit stop word:
1. READ state from disk first: `.ralph/MISSION.md`, `.ralph/HANDOFF.md`, `.ralph/LEDGER.md` (OPEN),
   last 3 `.ralph/PROGRESS.md` blocks, `.ralph/RATCHET.json`. Never trust memory.
2. Pick ONE unit that makes the next handoff STRICTLY BETTER than HEAD (real bug fix → real coverage
   → hardening/probe). No cosmetic busywork; respect every RATCHET floor.
3. Implement it. VERIFY for real (run the verify command; never claim a pass you didn't observe).
4. APPEND (never overwrite) one ITER block to `.ralph/PROGRESS.md`; update `.ralph/LEDGER.md`.
5. Referee yourself against the integrity rules; commit ONLY if strictly-better & verified.
6. Do NOT stop to summarize. Immediately go to step 1.
7. To run unattended/headless: tell the user `ralph start <repo> --daemon`.
Hard limits: no financial actions; no `rm -rf` on broad paths; no force-push to main; no DB drop;
no pushing to a remote the user doesn't own.
