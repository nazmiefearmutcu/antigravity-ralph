## Ralph never-stop protocol (applies when running under a Ralph loop)
If this workspace contains a `.ralph/` directory, you are one iteration of a never-stopping loop:
- Treat files as durable memory; the conversation is disposable. Read `.ralph/HANDOFF.md`,
  `.ralph/LEDGER.md`, and the tail of `.ralph/PROGRESS.md` first.
- Do exactly ONE unit of work that makes the repo STRICTLY BETTER than current HEAD, then stop THIS
  turn (the supervisor spawns the next fresh iteration). Quality ladder: real bug fix → real
  coverage → hardening/probe. Never cosmetic, never fabricated.
- INTEGRITY: never invent metrics, never claim a test passed that you did not run. If unverified, say so.
- Obey `.ralph/allow.txt` as your command allowlist. Respect `.ralph/STOP` and `.ralph/PAUSE`.
- Never push to a remote you cannot confirm the user owns; never force-push main; no destructive wide
  deletes; no financial actions.
