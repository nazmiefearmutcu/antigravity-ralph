# antigravity-ralph

**A never-stopping, always-improving Ralph loop for Google Antigravity, driving the `agy` headless
agent CLI.**

`antigravity-ralph` runs an autonomous self-improvement loop over a git repo. Each iteration spawns a
fresh, memoryless `agy -p` agent that reads its entire state from files on disk, does **exactly one**
unit of work, and hands off. An external, trusted **harness** then independently re-measures the
result and accepts the change only if the repo got *strictly better* — otherwise it reverts. The loop
is supervised so it survives quota outages, crashes, IDE death, and reboots.

> **It drives `agy` headless — it is NOT the abhishekbhakat VS Code extension.**
> This tool calls the official Antigravity headless CLI (`agy -p "<prompt>"
> --dangerously-skip-permissions --add-dir <target>`) as a disposable subprocess. It does **not**
> reverse-engineer the local gRPC-Web API, scrape the `language_server` CSRF token, or hook into a
> VS Code editor. The `agy` CLI is the entire control surface (see
> [docs/TECH_GROUNDING.md](docs/TECH_GROUNDING.md)). Antigravity must be installed, running, and
> authenticated, because `agy` shares its running `language_server`.

---

## The two guarantees

1. **NEVER STOPS.** The supervising process and the iteration loop both run forever. The only ways
   out are an explicit human kill-switch (`.ralph/STOP`), `SIGTERM` via `ralph stop`, or an explicit
   `--max-iterations N`. No code path inside the loop body calls `exit`; errors `return` and the
   outer `while true` re-enters. Quota and transient crashes back off and retry. Even when explicit
   goals are met, the loop does not stop — it descends a tier ladder (correctness → coverage →
   hardening → perf → docs → DX → novel-probe) and keeps improving.

2. **STRICTLY BETTER EVERY HANDOFF.** After any completed iteration, the committed `HEAD` is measured
   to be ≥ the best state ever recorded on every ratcheted metric, with ≥1 non-frozen metric strictly
   improved on each ADVANCE. **"Better" is a harness-computed fact, never an agent assertion** — the
   harness owns `git` and owns the scoreboard, re-runs the verify command itself, and re-derives every
   metric from the actual committed tree. The agent's self-reported numbers are advisory only.

---

## Quickstart

```sh
# 0. Prereqs: macOS, Antigravity installed/running/authenticated, `agy` on PATH, git, jq, python3,
#    /usr/bin/perl. (A bash >= 4 via `brew install bash` is preferred but NOT required — every lib is
#    bash-3.2-safe and runs under the system /bin/bash too.) Sanity check the agent itself:
agy -p "Reply with exactly one word: PONG" --dangerously-skip-permissions   # → PONG, exit 0

# 1. INSTALL — put the CLI on your PATH (symlink bin/ralph → ~/.local/bin/ralph):
mkdir -p ~/.local/bin                        # create it if it doesn't exist yet
ln -sf "$PWD/bin/ralph" ~/.local/bin/ralph
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo '  (add ~/.local/bin to PATH: export PATH="$HOME/.local/bin:$PATH")' ;; esac
ralph version

# 2. INIT — scaffold the runtime dir for a target repo (auto-detects verify cmd + metrics,
#    seeds MISSION.md / RATCHET.json / config.env / allow.txt, registers the target):
ralph init /abs/path/to/repo --gate referee
ralph doctor /abs/path/to/repo          # PASS/FAIL preflight; fix any FAIL before starting

# 3. START — launch the supervisor (foreground in a TTY by default):
ralph start /abs/path/to/repo --daemon  # --daemon survives terminal close (NOT reboot)
#   For true reboot-survival, install the launchd agent instead:
ralph install-daemon /abs/path/to/repo

# 4. STATUS — watch it work:
ralph status /abs/path/to/repo --watch  # alive? iter, phase, last_class, reverts, ETA, stalled?
ralph tail   /abs/path/to/repo          # follow the supervisor + current iteration log

# 5. STOP — drain cleanly (resumes on reboot unless --permanent):
ralph stop /abs/path/to/repo            # or: touch /abs/path/to/repo/.ralph/STOP
```

`ralph status` exit codes: `0` alive · `1` dead/error · `2` paused · `3` already-running · `4`
misconfig. See [docs/RUNBOOK.md](docs/RUNBOOK.md) for recovery procedures.

---

## The three command surfaces

The same loop is reachable three ways; all share the safety model:

1. **CLI** (`bin/ralph` → `~/.local/bin/ralph`). The primary surface and the source of truth.
   Subcommands: `init · start · once · status · tail · pause · resume · stop · doctor ·
   install-daemon · list · logs · metrics · version · help`. `ralph install-daemon` renders
   [`integrations/launchd/com.ralph.TEMPLATE.plist`](integrations/launchd/com.ralph.TEMPLATE.plist)
   into a per-target launchd agent for reboot-survival.

2. **Claude Code slash command** — drop
   [`integrations/claude-code/ralph-antigravity.md`](integrations/claude-code/ralph-antigravity.md)
   into `~/.claude/commands/`. It teaches Claude Code to operate the loop (doctor → init → start →
   monitor) and never pause to ask "should I continue?".

3. **Antigravity in-IDE** — two pieces:
   - [`integrations/antigravity/never-stop-ralph.md`](integrations/antigravity/never-stop-ralph.md)
     → `~/.gemini/antigravity/global_workflows/`: a `/ralph` workflow that runs the Ralph discipline
     interactively in the IDE (read disk state → one strictly-better unit → verify → append PROGRESS
     → never summarize).
   - [`integrations/antigravity/GEMINI.snippet.md`](integrations/antigravity/GEMINI.snippet.md)
     → appended to `~/.gemini/GEMINI.md`: a global rule that makes any agent in a `.ralph/` workspace
     behave as one iteration of the never-stop loop.

---

## Architecture

Two layers of immortality wrap a disposable agent. **launchd** keeps the bash **supervisor** alive
across reboots/crashes; the supervisor keeps the **iteration** alive across quota/timeouts; each
iteration runs **one bounded `agy`** whose output is judged by the **ratchet gate**.

```
                        ┌─────────────────────────────────────────────────┐
   reboot / crash  ───► │ launchd  (Layer 2: process immortality)          │
                        │   com.ralph.<name>.plist                         │
                        │   RunAtLoad=true · KeepAlive · ThrottleInterval  │
                        └───────────────────────┬─────────────────────────┘
                                                 │ exec
                        ┌────────────────────────▼─────────────────────────┐
                        │ ralph-supervisor.sh  (Layer 1: iteration          │
                        │ immortality — no terminal state by default)       │
                        │                                                    │
                        │  while true:                                       │
                        │   STOP/PAUSE/max-iter checks ──► (only ways out)   │
                        │   PREFLIGHT (agy reachable? relaunch IDE)          │
                        │   render_prompt  ◄── reads .ralph/ files           │
                        │        │                                           │
                        │   ┌────▼──── bounded_run (group-kill watchdog) ──┐ │
                        │   │   agy -p "<prompt>" --add-dir <target>       │ │   one DISPOSABLE,
                        │   │       --dangerously-skip-permissions         │ │   memoryless agent
                        │   │       --sandbox --print-timeout              │ │   (fresh conversation)
                        │   └────┬─────────────────────────────────────────┘ │
                        │   CLASSIFY rc+transcript:                          │
                        │     success │ rate_limit │ timeout │               │
                        │     transient_crash │ fatal_misconfig              │
                        │        │ success                                   │
                        │   ┌────▼─────── THE RATCHET GATE (trusted) ──────┐ │
                        │   │  measure_verify(HEAD)   ← harness runs verify │ │
                        │   │  measure_metrics(HEAD)  ← harness derives #s  │ │
                        │   │  no floor crossed AND ≥1 metric improves?     │ │
                        │   │     yes → ADVANCE: click floors, refs/best,   │ │
                        │   │              write HANDOFF, (periodic referee)│ │
                        │   │     no  → REVERT: git reset --hard <base>     │ │
                        │   │              -e .ralph  (history survives)    │ │
                        │   └────┬───────────────────────────────────────────┘ │
                        │   PERSIST state.json + heartbeat + logs ──► loop   │
                        └────────────────────────┬───────────────────────────┘
                                                 │ reads / writes (git-ignored)
                        ┌────────────────────────▼───────────────────────────┐
                        │ <target>/.ralph/   (durable memory; never in git)    │
                        │  MISSION.md  RATCHET.json  HANDOFF.md  LEDGER.md     │
                        │  PROGRESS.md  state.json  heartbeat.json  allow.txt  │
                        │  iter/NNNNNN/…  iterations/*.json  progress.ndjson   │
                        │  metrics/  refs/best  logs/  STOP  PAUSE  ralph.lock │
                        └──────────────────────────────────────────────────────┘
```

**The Ralph principle:** the `agy` conversation is discarded after each turn, so all durable state
lives on disk under `.ralph/`. A fresh agent reading `MISSION.md` + `HANDOFF.md` + `RATCHET.json` +
`LEDGER.md` (OPEN) + the last 3 `PROGRESS.md` blocks has the goal, the baton, the floors, the
do-not-repeat list, and the recent trajectory — everything the thrown-away conversation held.

---

## The ratchet (how "strictly better" is enforced)

The asymmetry that makes infinite running safe: **the agent is an untrusted optimizer; the harness is
the trusted referee that owns `git` and owns the scoreboard.** "Strictly better" is enforced at the
gate, never merely requested in the prompt.

- **The scoreboard** is `RATCHET.json` — a multi-metric monotone gate. Each metric has a direction
  (`up`/`down`), a current **floor**, and a `frozen` flag. The floors are the `best.metrics` ever
  *independently verified*. A single-axis "just a score" loop is the special case of one metric named
  `score`.
- **Independent re-measurement (anti-fabrication).** After the agent commits, the harness runs the
  verify command itself and re-derives every metric from the committed tree. The trailer's claimed
  `metrics_after` is **never** fed to the gate — only logged for an integrity audit. Claimed ≫
  measured raises an integrity flag that warns future iterations.
- **The pawl (the gate rule).** ADVANCE iff: verify passes (when required) AND the diff is non-trivial
  AND **no metric crosses its floor in the wrong direction** AND **≥1 non-frozen metric strictly
  improves** vs `best`. Otherwise REVERT.
- **The click.** On ADVANCE, each floor tightens to the achieved value — and **never loosens**
  (floors are monotone; nothing lowers a floor). The floor is always `best`, not the previous
  iteration's baseline, so a run of "each a little better than the last bad one" can never walk a
  metric downhill.
- **REVERT is safe.** `git reset --hard <baseline>` + `git clean -fdx -e .ralph` returns HEAD to the
  last good state. Because the *entire* `.ralph/` audit trail is git-ignored and excluded from clean,
  the reset literally cannot touch the loop's memory — history survives by construction.
- **Anti-thrash.** A reverted approach is recorded in `LEDGER.REJECTED` with the independent finding;
  the next prompt carries a verbatim regression notice so the agent doesn't repeat it without new
  evidence. Shipped work is in `LEDGER.DONE`; the append-only `PROGRESS.md` makes "already done"
  durable across fresh contexts.
- **Honest completion (three witnesses).** `goals_done` requires MISSION success criteria met AND
  `LEDGER.OPEN` empty for tiers T1–T6 AND a referee verdict of READY. The agent alone can never set
  it — and even when true, the loop does not stop; it enters the perpetual novel-probe tier.

---

## Safety & footguns (summary)

`agy --dangerously-skip-permissions` runs unattended — the most dangerous flag here. Containment is
layered (full table in [SPEC.md §12](SPEC.md)):

| Footgun | Guard |
|---|---|
| Auto-approved destructive command | `agy --sandbox` on by default; `.ralph/allow.txt` is the only sanctioned command set, injected into the prompt; HARD LIMITS block (no financial txns, no broad `rm -rf`, no force-push main, no DB drop) embedded verbatim; referee sees the diff before any push. |
| Metric fabrication / fake completion | Gate uses only the harness's own `measure_metrics()` on the committed tree; trailer numbers are advisory; `done_with_explicit_goals` is one of three required witnesses. |
| Thrash (A→B→A undo) | The vector ratchet reverts any change that lowers a previously-raised metric; `LEDGER.REJECTED` + regression notice block repeats without new evidence. |
| Push to a foreign remote | `RALPH_PUSH=0` by default = never push. When enabled, `guard_no_push` checks `origin` is under the user's GitHub org and refuses otherwise; force-push is never issued. |
| Kill-switch ignored | `.ralph/STOP` / `.ralph/PAUSE` checked at the top of every iteration AND inside every backoff sleep; `launchctl bootout` on a STOP-drain prevents KeepAlive resurrection. |
| Two supervisors on one target | `mkdir .ralph/ralph.lock` mutex with stale-PID steal. |
| Tight crash-loop torches CPU/credits | `enforce_min_interval` floor + crash-loop window cooldown + launchd `ThrottleInterval=30`. |
| Wedged worker ignores its timeout | External `bounded_run` group-kill at `AGY_TIMEOUT_S + 60` → rc 124 → `timeout` → unit abandoned, loop advances. |
| Silent zombie (rc 0, no work) | Classifier greps quota even on rc 0; `handle_noop` on unchanged sha; `stalled` heartbeat flag → `ralph status` shows "alive but not progressing", never false-green. |

**Default-safe posture:** sandboxed, never pushes, never force-pushes, never deletes the audit trail,
never lowers a floor, and refuses to start on a `doctor` FAIL (use `--force` only if you know better).

---

## Documentation

- **[SPEC.md](SPEC.md)** — the authoritative build specification (state schemas, the ratchet
  algorithm, the supervisor state machine, the CLI contract, the test plan, footguns).
- **[docs/TECH_GROUNDING.md](docs/TECH_GROUNDING.md)** — empirically-verified facts about `agy`,
  `agentapi`, the `language_server`, and Antigravity artifact locations on macOS.
- **[docs/RUNBOOK.md](docs/RUNBOOK.md)** — operational recovery: quota outage, stale lock, "alive but
  not progressing" triage, reading heartbeat/state, STOP/PAUSE, reboot-survival, adding a target.
