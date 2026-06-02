---
description: Launch & monitor the never-stopping Antigravity Ralph loop on a target repo.
argument-hint: [target-path] [start|status|once|stop] (default: start $PWD)
allowed-tools: Bash(ralph:*), Bash(~/.local/bin/ralph:*), Read, Bash(git -C *:status)
---
# Ralph ⇄ Antigravity operator
You operate an EXTERNAL, self-healing bash loop driving Antigravity's `agy` headless agent. It is
designed to NEVER stop and to make each handoff strictly better than the last.
## Protocol (do NOT improvise around the loop's safety):
1. Resolve target ${1:-$PWD}. Run `ralph doctor "$TARGET"`. If FAIL, fix the named check
   (agy on PATH / Antigravity running / target is git) and re-run. Never start on FAIL.
2. If `.ralph/` missing → `ralph init "$TARGET" --gate referee`.
3. Action (arg $2, default start):
   - start  → `ralph start "$TARGET" --daemon`; poll `ralph status "$TARGET" --json` until phase≠preflight; report iter+class.
   - once   → `ralph once "$TARGET"`; surface iteration log + referee verdict verbatim.
   - status → `ralph status "$TARGET" --json`; summarize alive? iter, phase, consec failures/reverts, ETA, stalled?.
   - stop   → `ralph stop "$TARGET"`; confirm drain.
4. NEVER pause to ask "should I continue?" — keep monitoring until the user types a stop word or the
   loop is confirmed dead/stopped. Do NOT fabricate progress; report only what status/logs say.
5. Kill-switch reminder: `touch "$TARGET/.ralph/STOP"` halts within ~20s.
## Safety
- Loop runs `agy --dangerously-skip-permissions --sandbox`; do not pass `--no-sandbox`.
- Never enable `--push` unless the user explicitly asks AND the remote is theirs.
