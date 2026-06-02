# SPEC — Ralph Loop for Antigravity

> A never-stopping, always-improving agent loop driving the `agy` headless CLI.
> Authoritative build specification. Merges three lens-designs (A=ratchet, B=protocol,
> C=ops+surfaces) into one internally-consistent contract. Every section is concrete
> enough to implement verbatim.

**Deliverable repo (absolute):** `/Users/nazmi/Desktop/Projeler/proje/antigravity-ralph`
**Primary driver:** `agy -p "<prompt>" --dangerously-skip-permissions --add-dir <target>`
**Target environment:** macOS (APFS), Antigravity IDE 2.0.10, agy CLI 1.0.3, Python 3.14.5,
`/usr/bin/perl` 5.34, git 2.50.1, `jq` present. **Absent (verified):** `timeout`, `gtimeout`, `flock`.

---

## 0. Contradiction resolution (read first)

The three lenses overlap and in several places disagree. This SPEC picks one winner per conflict
and the rest of the document is internally consistent with these rulings. Every later section
assumes these resolutions.

| # | Conflict | Lens positions | RESOLUTION (and why) |
|---|---|---|---|
| R1 | **Runtime state dir name** | A: `.ralph_self/` · B: bare repo files + `state/` · C: `.ralph/` | **`.ralph/` is the single runtime dir** (C). The repo scaffold already shipped `.ralph_self/`, so `.ralph_self/` is **renamed/symlinked to `.ralph/`** at init. One dir, no split brain. All work-memory (A's `state.json`, B's `MISSION.md`/`PROGRESS.md`/`LEDGER.md`/`RATCHET.json`) lives **inside `.ralph/`**, not at repo root, so the loop's bookkeeping never pollutes the target's own tree. |
| R2 | **Who owns the loop process** | A/B: a `while true` bash loop · C: a launchd-supervised supervisor wrapping bounded `agy` | **C's two-layer model wins** (launchd → supervisor → disposable `agy`). A's `run_one_iteration` and B's `run_iteration` are folded into C's `RUN_AGY → CLASSIFY → GATE` states as the *body* the supervisor calls. The supervisor owns liveness; the ratchet owns the verdict. |
| R3 | **The scoreboard: one number (A) vs a metric vector (B)** | A: single `score` + floor · B: `RATCHET.json` multi-metric with per-metric floors | **B's multi-metric `RATCHET.json` is canonical**, and A's single `score` is the special case "one metric named `score`." The gate logic is A's (independent re-measurement, floor compare, ADVANCE/REVERT) generalized to a vector: *no metric may cross its floor in the wrong direction AND ≥1 non-frozen metric must strictly improve*. This is strictly stronger than A's single-axis ratchet and fully implements A's invariants. |
| R4 | **Trailer / handoff format** | A: `===RALPH-HANDOFF===…===END===` JSON · B: `<<<RALPH_HANDOFF … RALPH_HANDOFF` YAML-ish | **One fence, one format:** `<<<RALPH_HANDOFF` … `RALPH_HANDOFF>>>` containing **strict JSON** (A's robustness + B's fence clarity). A's salvage ladder (§5.5) is mandatory. The body schema unions both (§3.4). |
| R5 | **Commit gate** | A: referee every N advances, gates *push* only · B: referee/tests per accept · C: `RALPH_COMMIT_GATE=none\|tests\|referee` per iteration, gates *commit* | **C's per-iteration `RALPH_COMMIT_GATE` knob is the surface**, with A's cadence as the default for the *referee* mode (`RALPH_REFEREE_EVERY`, default 10) and A's rule that **local commits always happen** (they are how we measure) while the **referee gates only the optional push**. Net: tests/verify gate the ratchet ADVANCE every iteration; the referee agent gates push every N advances or on `goals_done`. No contradiction: verify is mechanical+per-iter, referee is judgmental+periodic. |
| R6 | **Revert mechanism** | A: `git reset --hard` + `git clean -fdx -e .ralph` (default) or `git revert` (opt-in) · B: `git reset --hard` · C: implicit | **A wins:** `reset_hard` default with `-e .ralph` exclusion, `revert_commit` opt-in for audited branches. A's progress-log preservation across reset (§5.6) is mandatory. |
| R7 | **Append-only history in git or local-only** | A: `progress.ndjson` committed, `state.json` ignored · B: `PROGRESS.md`/`LEDGER.md` committed · C: `.ralph/iterations/*.json` never deleted, local | **Everything under `.ralph/` is git-IGNORED** (resolves R1's "don't pollute target"). The durable append-only audit trail is `.ralph/iterations/NNNNNN.json` + `.ralph/PROGRESS.md` + `.ralph/progress.ndjson`, preserved across `reset --hard` via the `-e .ralph` exclusion (so they need not be committed to survive — A's stash-and-replay is no longer required because the files live *outside* the reset's reach). This is **better than all three lenses**: A needed a fragile merge step to preserve committed progress across a reset; by keeping `.ralph/` excluded from clean and untracked by git, history survives automatically. |
| R8 | **"agy crash/quota retries SAME iteration" (A) vs "iteration = work attempted" (C)** | A: backoff, re-enter same iteration, floor untouched · C: quota/transient retry same iter, timeout/success advance | **C's classifier is canonical**, aligned with A's intent: `rate_limit` + `transient_crash` → retry SAME iteration (work not done); `timeout` → abandon unit, ADVANCE counter (unit wedged); `success` → gate then ADVANCE counter. The *ratchet floor* never moves on any non-success class (A's guarantee preserved). |
| R9 | **Tier ladder depth** | A: bug→coverage→hardening→probe (4) · B: T1–T7 · C: bug→coverage→hardening→probe | **B's T1–T7 ladder is canonical** (correctness/coverage/hardening/perf/docs/DX/novel-probe) with B's deterministic self-selection + per-tier detectors. A's 4 tiers map onto T1/T2/T3/T7. |
| R10 | **Goals/mission source** | A: `.ralph/goals.md` harness-owned · B: `MISSION.md` seed-owned read-only + `LEDGER.md` OPEN list | **B wins:** `MISSION.md` (north star, read-only to agent) + `LEDGER.md` (OPEN/REJECTED/DONE work memory). A's `goals.md` concept = B's `LEDGER.md` OPEN section. `goals_done` = (MISSION success criteria met) AND (LEDGER.OPEN empty for T1–T6) AND (referee READY) — A's three-witness completion. |
| R11 | **Bounded-exec primitive** | A: perl `fork`+`alarm` · C: subshell-pgroup + perl-sleep watchdog + TERM→KILL to process *group* | **C's group-kill watchdog wins** (`bounded_run`, §6.1) — it reaches `agy`'s hung *children*, which A's single-pid `alarm`+`kill` would miss. Belt-and-suspenders with `agy --print-timeout`. |
| R12 | **Lock** | A: `mkdir` mutex under `.ralph` · C: `mkdir .ralph/ralph.lock` + stale-PID steal | **Identical idea; C's stale-PID reaper is the implementation.** |

**One-line summary of the merged architecture:** launchd keeps a bash **supervisor** immortal; each
iteration the supervisor renders a fresh prompt from `.ralph/` files, runs **one bounded `agy`**,
classifies the result, and—on `success`—hands the candidate to the **ratchet gate** which
*independently re-measures* every `RATCHET.json` metric on the actual committed tree and ADVANCES
only if strictly better, else REVERTS. The agent's self-reported numbers are never trusted.

---

## 1. Overview & invariants (the two guarantees, stated testably)

### 1.1 The mandate, formalized
1. **NEVER STOPS.** The supervising *process* and the iteration loop both run forever; only an
   explicit human kill-switch (`.ralph/STOP`), `SIGTERM` via `ralph stop`, or an explicit
   `--max-iterations N` ends it. No internal code path calls `exit` from the loop body; errors
   `return` and the outer `while true` re-enters.
2. **STRICTLY BETTER EVERY HANDOFF.** After any *completed* iteration, the committed HEAD is
   measured to be ≥ the best state ever recorded, on every ratcheted metric, with ≥1 non-frozen
   metric strictly improved on each ADVANCE. "Better" is a **harness-computed fact**, never an
   agent assertion.

### 1.2 Testable invariants (each maps to a test in §11)
- **INV-1 (HEAD-monotonicity).** ∀ completed iter: for every metric `m` in `RATCHET.json`,
  `measure(HEAD)[m]` is within-floor for `m`; and `verify(HEAD)=pass` when `verify_required`.
  *Test:* T-RATCHET-3, T-RATCHET-4.
- **INV-2 (Floor-immovability-downward).** No code path lowers any `floor`. Floors only tighten on
  ADVANCE. *Test:* T-RATCHET-5.
- **INV-3 (Independence / anti-fabrication).** The scalar/vector feeding the gate is *only* a
  `measure_metrics()` output on the actual committed tree; the trailer's claimed numbers never
  enter the comparison. *Test:* T-RATCHET-2 (claimed≫measured ⇒ revert + integrity flag).
- **INV-4 (Memory-preservation).** No `git reset --hard`/`git clean` deletes any
  `.ralph/iterations/*.json`, `.ralph/PROGRESS.md`, `.ralph/LEDGER.md`, or `.ralph/progress.ndjson`.
  *Test:* T-STATE-4.
- **INV-5 (Liveness).** No path inside the iteration body reaches `exit`; circuit-breaker escalates
  tier instead of halting; quota/crash back off and retry; only STOP/SIGTERM/max-iter end it.
  *Test:* T-SUP-1, T-SUP-3.
- **INV-6 (Honest completion).** `goals_done=true` ⇒ (MISSION criteria met) ∧ (LEDGER.OPEN empty for
  T1–T6) ∧ (referee READY). The agent alone cannot set it. Even when true, the loop does **not**
  stop — it enters perpetual T7→re-feed. *Test:* T-SUP-4.
- **INV-7 (Bounded run).** No single `agy` run can hang the loop > `RALPH_AGY_TIMEOUT_S + 60`s; the
  group-kill watchdog reclaims the slot (rc 124). *Test:* T-BOUND-1.
- **INV-8 (Kill-switch latency).** `touch .ralph/STOP` halts within `max(RALPH_MIN_INTERVAL_S, ~20s)`
  even mid-backoff (interruptible sleep re-checks the sentinel). *Test:* T-SUP-2.
- **INV-9 (No foreign push).** The supervisor never pushes unless `RALPH_PUSH=1` AND the `origin`
  URL is under the user's GitHub org; never force-pushes. *Test:* T-SAFE-1.

---

## 2. Directory & file layout

### 2.1 The tool repo (the deliverable, committed)

```
antigravity-ralph/
├── bin/
│   ├── ralph                       # CLI dispatcher (§8). Installed → ~/.local/bin/ralph.
│   │                               #   Hidden verb `__run-supervisor <target>` = launchd entry.
│   └── ralph-supervisor.sh         # the state machine (§7). Sourced/exec'd by `ralph start`.
├── lib/
│   ├── bounded.sh                  # bounded_run group-kill watchdog (§6.1)
│   ├── classify.sh                 # classify_result, agy_reachable, recover_agy_substrate (§7.4)
│   ├── backoff.sh                  # expo_backoff_jitter, sleep_interruptible, crash-loop window (§7.3)
│   ├── state.sh                    # heartbeat / state.json / lock / iteration-record IO (§3, §6.2)
│   ├── ratchet.sh                  # run_one_iteration, ratchet_gate, measure_*, revert (§5)
│   ├── gate.sh                     # maybe_commit_gate, guard_no_push, referee invocation (§5.7)
│   ├── prompt.sh                   # render_prompt (fills prompts/iterate.tmpl from .ralph/ files) (§4)
│   ├── extract_trailer.py          # robust trailer salvage ladder (§3.4.2)
│   ├── validate_trailer.py         # schema coerce/clamp (§3.4.1)
│   ├── ratchet.py                  # RATCHET.json: render-table | check | why | click (§5.2)
│   └── state.py                    # atomic state.json read/modify/write helper (§6.2)
├── prompts/
│   ├── iterate.tmpl                # THE iteration prompt template (§4) — final text
│   └── referee.tmpl                # GO/NO-GO referee prompt (§5.7)
├── integrations/
│   ├── claude-code/ralph-antigravity.md     # → ~/.claude/commands/ (Surface 2, §8.2)
│   ├── antigravity/never-stop-ralph.md      # → ~/.gemini/antigravity/global_workflows/ (Surface 3a)
│   ├── antigravity/GEMINI.snippet.md        # → appended to ~/.gemini/GEMINI.md (Surface 3b)
│   └── launchd/com.ralph.TEMPLATE.plist     # rendered by `ralph install-daemon` (§8 / §9)
├── tests/
│   ├── ratchet.bats                # INV-1..3,5 (§11)
│   ├── state.bats                  # INV-4, atomic writes, lock steal
│   ├── trailer.bats                # salvage ladder cases
│   ├── classify.bats               # exit-code/output oracle
│   ├── bounded.bats                # INV-7
│   ├── supervisor.bats             # INV-5,6,8 (with a stub `agy`)
│   ├── safety.bats                 # INV-9, allowlist
│   └── fixtures/                   # canned agy transcripts, malformed trailers, fake repos
├── docs/
│   ├── TECH_GROUNDING.md           # verified env facts (already present)
│   └── RUNBOOK.md                  # quota outage recovery, stale lock, "alive but not progressing"
├── .gitignore                      # ignores .ralph/ entirely (R7) + scratch
├── LICENSE
└── SPEC.md                         # this file
```

`.gitignore` (tool repo) must contain at minimum:
```
.ralph/
*.tmp
```

### 2.2 The per-target runtime dir `<target>/.ralph/` (git-ignored, R1+R7)

A "target" = one repo/workspace the loop improves. (For the deliverable's own dogfooding the target
*is* `antigravity-ralph` itself.) All mutable state lives here; nothing leaks into the target's tree.

```
<target>/.ralph/
├── config.env              # per-target knobs, KEY=VALUE only, sourced (§3.6)
├── MISSION.md              # north star, read-only to agent (§3.2). Seeded at init.
├── PROGRESS.md             # append-only journal, one block/iter + harness :: VERDICT (§3.3)
├── LEDGER.md               # DONE / REJECTED / OPEN work memory, append-only (§3.3)
├── RATCHET.json            # the multi-metric monotone gate / scoreboard (§3.1)  ← THE scoreboard
├── HANDOFF.md              # the single latest baton (overwritten each ADVANCE) (§3.3)
├── state.json              # supervisor + ratchet resume state (§3.5)
├── heartbeat.json          # liveness beacon, rewritten every iteration (§3.5)
├── allow.txt               # command allowlist injected into the prompt (§12)
├── ralph.pid               # PID of live supervisor (atomic write+rename); absent ⇒ not running
├── ralph.lock/             # mkdir-based mutex DIR (not a file); holds owner.pid (§6.3)
├── STOP                    # kill-switch sentinel. Exists ⇒ drain & halt (+ self-bootout) (§7,§9)
├── PAUSE                   # soft-pause sentinel. Exists ⇒ idle (heartbeat only), no agy
├── metrics/
│   ├── latest.json         # metrics snapshot from THIS iter's verify (harness/verify writes)
│   └── history.jsonl       # append-only, one line per ADVANCE
├── iter/
│   └── NNNNNN/             # zero-padded per-iteration scratch (never auto-deleted)
│       ├── prompt.txt          # exact prompt sent to agy (reproducibility)
│       ├── agy.stdout / agy.exit / agy.stderr
│       ├── trailer.json        # extracted+validated handoff (advisory)
│       ├── verify.log / verify.exit
│       ├── score.raw           # raw metric command output
│       ├── decision.json       # {decision: ADVANCE|REVERT|NOOP, cause, ...}
│       └── referee.log         # present only when a referee ran this iter
├── iterations/
│   └── NNNNNN.json         # tiny structured record per iteration; NEVER deleted (audit trail)
├── progress.ndjson         # machine-readable append-only ledger (one obj/iter; never deleted)
├── refs/best               # file holding the git SHA of the best-verified commit
├── logs/
│   ├── supervisor.log      # the loop's own stdout/stderr (rotated, §10)
│   └── iter-NNNNNN.log     # full agy transcript for that iter (rotated/gz when old)
└── archive/
    └── supervisor.log.<epoch>.gz
```

Daemon-level (not per-target):
```
~/.ralph/
├── targets.tsv             # registry: name<TAB>abs_path<TAB>added_iso
├── daemon.log              # launchd stdout/stderr sink
└── com.ralph.<name>.plist  # copy of each installed launchd plist (for ralph stop --permanent)
```

> **Why `.ralph/` is fully git-ignored (improves on all three lenses):** Lens A committed
> `progress.ndjson` and then needed a fragile stash-and-replay (`merge_ndjson.py`) to keep it alive
> across `git reset --hard`. By keeping the *entire* `.ralph/` dir out of git and excluding it from
> `git clean` (`-e .ralph`), the reset literally cannot touch history. The audit trail survives by
> construction, the target's tree stays pristine, and there is zero "commit the scoreboard → gaming
> surface" risk. The append-only files are still human-auditable; `ralph logs` surfaces them.

---

## 3. State schemas

### 3.1 `RATCHET.json` — the scoreboard (multi-metric monotone gate; R3 canonical)

Single JSON object, rewritten atomically (`tmp`+`mv` within `.ralph/`). It is the merged
A-`state.json.best`/B-`RATCHET.json`. Lens A's "single score" = one metric named `score`.

```jsonc
{
  "schema_version": 4,
  "repo_root": "/Users/nazmi/Desktop/Projeler/proje/antigravity-ralph",
  "updated_at": "2026-06-02T19:42:11Z",
  "policy": {
    "accept_rule": "no metric crosses its floor in the wrong direction; >=1 non-frozen metric strictly improves",
    "regression_tolerance": 0,          // per-metric default; 0 = strict ratchet
    "absent_policy": "verify_only",     // verify_only | tie_breaker  (when a metric is null)
    "on_reject": "git reset --hard <baseline>; record cause in LEDGER.REJECTED",
    "floor_update": "tighten each floor to the achieved value ONLY after ADVANCE (the ratchet click)"
  },

  "metrics": {
    // metric key → contract. "dir": up|down. "floor": current floor. "frozen": once true, may not regress but need not improve.
    "tests_pass":      { "dir": "up",   "floor": 0,    "frozen": false, "cmd": "AUTO:pytest_passcount", "tolerance": 0 },
    "coverage_pct":    { "dir": "up",   "floor": 0.0,  "frozen": false, "cmd": "AUTO:coverage",         "tolerance": 0.0 },
    "lint_errors":     { "dir": "down", "floor": 999,  "frozen": false, "cmd": "AUTO:lint",             "tolerance": 0 },
    "bench_p95_ms":    { "dir": "down", "floor": 1e9,  "frozen": false, "cmd": "tests/bench.sh",        "tolerance": 0.0 }
  },

  "verify": {
    "required": true,                   // false ⇒ verify advisory; metrics become the sole gate
    "cmd": "AUTO",                       // resolved at init (§3.6); writes metrics/latest.json
    "timeout_s": 900,
    "flaky_reverify_runs": 2,            // pass if ANY run passes; fail only if ALL fail (§5.4)
    "supports_focus": false              // if true, RALPH_VERIFY_FOCUS env may narrow a fast pre-check
  },

  "best": {                              // best state EVER independently verified (the floor source)
    "commit": "9f8e7d…",
    "iteration": 119,
    "metrics": { "tests_pass": 142, "coverage_pct": 71.3, "lint_errors": 0, "bench_p95_ms": 210.0 },
    "verify_passed": true,
    "summary": "added 7 edge-case tests for parser; all green",
    "achieved_at": "2026-06-02T19:21:55Z"
  },

  "baseline": {                          // snapshot at START of current iteration (usually == best)
    "commit": "a1b2c3d…",
    "tree_clean": true,
    "verify_passed": true,
    "metrics": { "tests_pass": 142, "coverage_pct": 71.3, "lint_errors": 0, "bench_p95_ms": 210.0 },
    "measured_at": "2026-06-02T19:40:02Z"
  },

  "regression_pending": null,            // populated on REVERT, consumed+cleared by next prompt (§5.6)
  "goals_done": false                    // INV-6 three-witness; never stops the loop even when true
}
```

**`AUTO:` metric resolvers** (computed by the *harness*, never the agent — INV-3):
- `AUTO:pytest_passcount` → `python3 -m pytest -q --no-header 2>/dev/null | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' | tail -1` (0 if no match). Mirrors for `cargo`/`go`/`jest`.
- `AUTO:coverage` → coverage tool's total %, parsed to float.
- `AUTO:lint` → count of `ruff`/`tsc --noEmit`/`clippy` findings (dir=down).
- A metric whose command errors or yields non-numeric → that metric is `null` for the iteration; gate falls to `absent_policy`.

### 3.2 `MISSION.md` — north star (read-only to the agent; R10)

Authored at init; if the agent edits it, the harness `git`-restores it from `.ralph/MISSION.md`
(it lives outside the target tree, so a `checkout` is unnecessary — the harness re-writes the
canonical copy and rejects the iteration). Schema:

```markdown
# MISSION
## North Star
<one present-tense paragraph: what this project IS when excellent.>
## Success Criteria (explicit, checkable)
- SC1: <criterion> — metric: <key in RATCHET.metrics> — target: <value/threshold>
- SC2: ...
<!-- When ALL SCs are met the loop does NOT stop; it shifts to the tier ladder (§9). -->
## Hard Constraints (never violate)
- HC1: never edit MISSION.md / RATCHET.json / state.json by hand
- HC2: every change must keep the verify command green
- HC3: <project-specific>
## Ratcheted Metrics (mirrors RATCHET.json)
- <key> (<dir>) ...
## Out of Scope
- <things the agent must NOT invent as "novel probes">
```

### 3.3 Work-memory markdown files

**`PROGRESS.md`** — append-only; one block per iteration, status flipped by harness:
```markdown
## ITER 0042 — 2026-06-02T19:41:07Z — tier=T2_coverage — status=PROPOSED
- baseline_handoff: 0041
- chose: "Add tests for retry/backoff classifier in lib/classify.sh"
- why_highest_leverage: "coverage floor 71.3; classify.sh retry path 0% covered; riskiest untested code (LEDGER R-7)."
- tier_rationale: "T1 has no open items (LEDGER 0 known bugs, verify green); descend to T2."
- action: "Wrote tests/classify.bats with 6 cases; no production code changed."
- verify_cmd: "make verify"
- expected_metric_delta: { coverage_pct: "+3.1", tests_pass: "+6" }
- files_touched: [ tests/classify.bats ]
- handoff_id: 0042
:: VERDICT 0042 ACCEPTED — coverage_pct 71.3→74.5, tests_pass 142→148, all floors held. commit e4a1f9c
```
(or `:: VERDICT 0042 REVERTED — bench_p95_ms 210→241 (>floor 220) → reset to 0041. cause→LEDGER R-12.`)
The harness writes the `:: VERDICT` line *after* independent measurement, so the next agent sees
ground truth, not the agent's hope.

**`LEDGER.md`** — append-only anti-thrash memory; three sections, stable ids:
```markdown
# LEDGER
## DONE (do not redo — shipped & ratcheted)
- D-7 [ITER0031] Added bats harness + `make verify`. commit 99fe01a
## REJECTED (tried, did NOT improve — do not repeat without NEW evidence)
- R-12 [ITER0042] "Replace bash backoff with python asyncio" → regressed bench_p95_ms 210→241. Don't retry unless you first prove p95≤220 in a scratch bench.
## OPEN (known work, ranked; agent picks the top viable one)
- O-1 (T1) BUG: handoff trailer parser drops multi-line `chose:` values. evidence ITER0038.
- O-2 (T3) HARDENING: ralph.lock not removed on SIGKILL → stale-lock recovery.
```

**`HANDOFF.md`** — the single latest baton, overwritten by the harness from the validated trailer on ADVANCE:
```markdown
# HANDOFF 0042 (accepted, click @ e4a1f9c)
state_after:
  tier: T2_coverage
  metrics: { tests_pass: 148, coverage_pct: 74.5, lint_errors: 0, bench_p95_ms: 210 }
i_did: "Covered the retry/backoff classifier (6 bats cases). No prod code changed."
i_did_NOT: "Did not touch O-1 (T1 parser bug) — higher priority; pick it next."
next_highest_leverage: "O-1 (T1 BUG): trailer parser drops multi-line `chose:`. Fix awk splitter in lib/extract_trailer.py; add a bats case."
watch_out: "bench_p95_ms floor tight (current 210). Don't add startup cost to the hot path."
open_count_by_tier: { T1: 1, T2: 0, T3: 1, T4: 0, T5: 0, T6: 0, T7: 0 }
```
> **Coherence guarantee:** a fresh agent reading `MISSION.md` + `HANDOFF.md` + `RATCHET.json` +
> `LEDGER.md` OPEN + the last 3 `PROGRESS.md` blocks has the goal, baton, floors, do-not-repeat
> list, and recent trajectory — everything `agy -p`'s discarded conversation would have held.

### 3.4 The HANDOFF trailer (R4: one fence, strict JSON)

#### 3.4.1 Format (exact) + schema
The agent ends its response with, and **nothing after**:
```
<<<RALPH_HANDOFF
{
  "what_changed": "Added 6 bats cases for the retry classifier; no prod code changed.",
  "files": ["tests/classify.bats"],
  "tier": "T2_coverage",
  "metrics_after": { "tests_pass": 148, "coverage_pct": 74.5, "lint_errors": 0, "bench_p95_ms": 210 },
  "next_candidate": "O-1 (T1): fix multi-line trailer parse in lib/extract_trailer.py",
  "i_did_NOT": "Left O-1 (higher tier) for next iteration.",
  "confidence": 0.78,
  "done_with_explicit_goals": false
}
RALPH_HANDOFF>>>
```
| field | type | required | role |
|---|---|---|---|
| `what_changed` | string ≤500 | yes | narrative for next prompt + PROGRESS |
| `files` | array<string> | yes | diff cross-check + optional verify-focus |
| `tier` | string | yes | recorded; carried in HANDOFF so ladder position persists |
| `metrics_after` | object<string,number\|null> | yes | **advisory only**; cross-checked vs `measure_metrics()` (INV-3) |
| `next_candidate` | string | yes | seeds next prompt on ADVANCE |
| `i_did_NOT` | string | no | the deliberately-deferred item |
| `confidence` | number 0–1 | yes | logged; low confidence widens `flaky_reverify_runs` |
| `done_with_explicit_goals` | bool | yes | necessary-not-sufficient completion signal (INV-6) |

Validated/coerced by `lib/validate_trailer.py`: fill missing keys with `null`/`[]`/`false`, clamp
`confidence` to [0,1], truncate `what_changed`. **`metrics_after` is NEVER used by the gate** — only
for the integrity audit (`record_claim_vs_truth`) and to flavor regression advice.

#### 3.4.2 Robust extraction (`lib/extract_trailer.py`) — always exits 0
Salvage ladder (status conveyed via stdout `TRAILER_STATUS=...` + the written file; never aborts the loop):
1. `re.findall(r'<<<RALPH_HANDOFF(.*?)RALPH_HANDOFF>>>', text, DOTALL)`.
2. If none → try the **last balanced `{...}` object** in the text (bare-JSON fallback).
3. If still none → `status=missing`; **synthesize from harness facts**:
   `{what_changed: <git diff --stat>, files: <changed paths>, metrics_after: null, next_candidate:"", tier:<current>, confidence:0.0, done_with_explicit_goals:false}`.
4. If multiple fences → `status=multiple`, take the **last** (agents self-correct at the end).
5. `json.loads`; on failure run `salvage_json()` (strip ```` ```json ```` fences, trailing commas,
   single→double quotes, `True/False/None`→`true/false/null`, smart-quotes, prose-stripping, close
   unbalanced braces) and retry once; else synthesize. 6. `coerce_schema()`; write `trailer.json`.

### 3.5 `state.json` (supervisor + ratchet resume) and `heartbeat.json`

**`state.json`** — makes a launchd-relaunched supervisor *resume* not *restart*:
```jsonc
{
  "iteration": 123,                  // monotonic; advances on success/timeout (R8)
  "advances": 51, "reverts": 71, "noops": 1,
  "consecutive_failures": 0,
  "consecutive_quota_hits": 2,
  "consecutive_reverts": 0,          // ratchet circuit-breaker (§9 escalates, never halts)
  "noop_streak": 0,
  "backoff_s": 0,
  "last_class": "success",           // success|rate_limit|timeout|transient_crash|fatal_misconfig
  "last_success_iso": "2026-06-02T21:10:02Z",
  "last_run_started_iso": "2026-06-02T21:39:40Z",
  "crash_loop_strikes": 0,
  "tier": "T2_coverage",
  "started_iso": "2026-06-01T23:01:00Z"
}
```
**`heartbeat.json`** — rewritten atomically at start AND end of every iteration; a watcher declares
the loop **dead** if `now - ts > 3 × max(RALPH_MIN_INTERVAL_S, last_duration_s)`:
```jsonc
{
  "ts": "2026-06-02T21:40:11Z", "epoch": 1780000811,
  "target": "antigravity-ralph", "pid": 48213,
  "iteration": 123, "phase": "running_agy",   // §7 state name
  "last_exit_code": 0, "last_class": "success",
  "consecutive_failures": 0, "consecutive_reverts": 0,
  "next_action_eta_s": 0, "backoff_s": 0, "uptime_s": 81234,
  "sha_head": "a1b2c3d",
  "stalled": false                            // true ⇒ alive but N iters with zero diff (silent-zombie guard, §12)
}
```

### 3.6 `config.env` (per-target knobs; all overridable by `ralph` flags)
```sh
RALPH_TARGET_NAME=antigravity-ralph
RALPH_MAX_ITERATIONS=0            # 0 = unlimited (the mandate)
RALPH_MIN_INTERVAL_S=20           # crash-loop floor between iteration starts
RALPH_AGY_TIMEOUT_S=900           # hard wall on a single agy run (15m); also passed as --print-timeout
RALPH_BACKOFF_BASE_S=30
RALPH_BACKOFF_CAP_S=1800          # 30m
RALPH_BACKOFF_JITTER_PCT=25
RALPH_CRASHLOOP_THRESHOLD=5       # N transient crashes in WINDOW ⇒ cooldown
RALPH_CRASHLOOP_WINDOW_S=300
RALPH_CRASHLOOP_COOLDOWN_S=600
RALPH_MAX_CONSECUTIVE_REVERTS=40  # ratchet circuit-breaker → escalate tier (never stop)
RALPH_RELAUNCH_ANTIGRAVITY=1      # relaunch IDE if language_server down
RALPH_SKIP_PERMISSIONS=1          # pass --dangerously-skip-permissions (scoped by allow.txt + sandbox)
RALPH_SANDBOX=1                   # pass agy --sandbox
RALPH_COMMIT_GATE=referee         # none | tests | referee   (R5)
RALPH_REFEREE_EVERY=10            # referee push-gate cadence (advances); also fires on goals_done
RALPH_PUSH=0                      # 0 = NEVER push (default-safe; foreign-remote guard §12)
RALPH_REVERT_STRATEGY=reset_hard  # reset_hard | revert_commit
RALPH_VERIFY_REQUIRED=1
RALPH_PROMPT_FILE=prompts/iterate.tmpl
```
**Verify/metric auto-detection at init** (frozen into `RATCHET.json` / `config.env`); probe order,
first hit wins: pytest markers → `python3 -m pytest -q`; `package.json` test script → `npm test --silent`;
`Cargo.toml` → `cargo test --quiet`; `go.mod` → `go test ./...`; `Makefile test:` → `make test`;
else `RALPH_VERIFY_REQUIRED=0` and a build/lint smoke (`compileall`/`npm run build`/`cargo build`)
becomes a cheap proxy verify; if nothing is checkable → `absent_policy=tie_breaker`.

---

## 4. The COMPLETE iteration prompt template (`prompts/iterate.tmpl`)

Final text fed to `agy -p`. `{{...}}` placeholders are filled by `lib/prompt.sh::render_prompt`
from `.ralph/` files. Rigid ordering: role → laws → disk truth → single action → verify contract →
record → commit → trailer → integrity.

```text
You are iteration {{ITER}} of an UNSTOPPABLE self-improvement loop ("Ralph loop") driving this git
repo via the `agy` headless agent. You have NO memory of prior iterations. Your ENTIRE memory is the
files on disk shown below. Trust the files, not your instincts about "what was probably done."

REPO ROOT (absolute): {{REPO_ROOT}}
GIT HEAD before you start: {{HEAD_SHA}}

═══════════════════════════════════════════════════════════════════════════
THE TWO LAWS (violating either fails the iteration):
  LAW 1 — NEVER declare the project finished, complete, or "good enough". There is ALWAYS a next
          improvement; if explicit goals are met you DESCEND the tier ladder. Do not write
          "done"/"complete"/"nothing left to do", and do not stop early.
  LAW 2 — Your handoff MUST be STRICTLY BETTER than the one you received. "Better" = you raise at
          least one non-frozen ratchet metric WITHOUT pushing any metric across its floor. You do
          NOT judge this — the harness re-measures everything itself against metrics/latest.json +
          RATCHET.json. Do not claim victory; make the change and run verify.
═══════════════════════════════════════════════════════════════════════════

── NORTH STAR (.ralph/MISSION.md — READ ONLY; editing it fails the iteration) ──
{{MISSION_MD}}

── RATCHET FLOORS you must respect (.ralph/RATCHET.json metrics) ──
{{RATCHET_TABLE}}            # metric | dir | floor | frozen

── THE BATON you were handed (.ralph/HANDOFF.md, from iteration {{PREV_ITER}}) ──
{{HANDOFF_MD}}

── OPEN / REJECTED / recent-DONE work (.ralph/LEDGER.md) ──
{{LEDGER_MD}}

── LAST 3 JOURNAL ENTRIES (tail of .ralph/PROGRESS.md, incl. their VERDICTs) ──
{{PROGRESS_TAIL}}

{{REGRESSION_NOTICE}}       # present ONLY if the previous iteration was REVERTED (see §5.6)
{{INTEGRITY_NOTICE}}        # present ONLY if prior claims didn't match measurement (INV-3)

── YOUR COMMAND ALLOWLIST (.ralph/allow.txt — do NOT run anything outside this set) ──
{{ALLOW_TXT}}

═══════════════════════════════════════════════════════════════════════════
DO EXACTLY THIS, IN ORDER. ONE unit of work — not two.

STEP 1 — ORIENT (read-only). Confirm state. `{{VERIFY_CMD}}` is your ground truth for green/red.
         You may read any file. Do NOT edit yet.

STEP 2 — SELECT ONE ITEM via the tier ladder (lower number = higher priority):
         T1 correctness/bugs → T2 coverage → T3 hardening/security → T4 performance →
         T5 docs → T6 DX/tooling → T7 novel-probe.
         Rule: take the FIRST viable LEDGER.OPEN item at the lowest present tier that you can FINISH
         in this one iteration. If OPEN is empty for T1..T6, run that tier's detector; the lowest
         tier with a real finding wins — add it to LEDGER.OPEN first, then do it. If T1..T6 are all
         clean, enter T7: run ONE bounded probe that produces a NEW evidenced OPEN item (do NOT edit
         product code in T7) and stop after recording it.
         FORBIDDEN: anything in LEDGER.REJECTED unless you cite NEW evidence in your reasoning.
         FORBIDDEN: redoing anything in LEDGER.DONE.

STEP 3 — DO THE ONE THING. Smallest change that moves your chosen metric. Focused diff. No
         "while I'm here" refactors. Do NOT edit anything under .ralph/.

STEP 4 — VERIFY. Run: {{VERIFY_CMD}}
         It must (a) pass and (b) write fresh numbers to .ralph/metrics/latest.json. If it fails or
         a metric worsens, FIX or REVERT your own change before continuing. Do not hand off red.
         (The harness independently re-runs verify and re-measures every metric; fabricated numbers
         are detected and the iteration is auto-reverted.)

STEP 5 — RECORD (your durable memory; future iterations depend on it):
         (a) APPEND exactly ONE block to .ralph/PROGRESS.md (ITER schema, status=PROPOSED). NEVER
             edit/delete earlier content.
         (b) UPDATE .ralph/LEDGER.md: move your item OPEN→DONE on success; add new work to OPEN with
             reasoning; add an abandoned approach to REJECTED with WHY.
         (c) Do NOT touch MISSION.md, RATCHET.json, state.json, metrics/history.jsonl, or anything
             else under .ralph/ except PROGRESS.md and LEDGER.md.

STEP 6 — COMMIT. Stage your changed files (commit the WORKING TREE, not .ralph/):
             git add -A && git commit -m "ralph iter {{ITER}} [{{TIER}}]: <imperative one-line>"
         One commit. Do NOT push.

STEP 7 — EMIT THE HANDOFF TRAILER as the LAST thing in your response, between the EXACT fences
         below, as strict JSON. Put NOTHING after the closing fence:

<<<RALPH_HANDOFF
{ "what_changed": "<one sentence>",
  "files": ["<changed paths>"],
  "tier": "<tier id you worked at>",
  "metrics_after": { "<each RATCHET metric key>": <value now in metrics/latest.json or null> },
  "next_candidate": "<single best next item for iteration {{ITER}}+1, with tier + where in code>",
  "i_did_NOT": "<the next-most-important thing you deliberately left, and why>",
  "confidence": <0.0-1.0>,
  "done_with_explicit_goals": false }
RALPH_HANDOFF>>>

INTEGRITY: Never fabricate a metric, a test result, or a commit. If you could NOT improve anything
this iteration, that is itself a finding: record in LEDGER.OPEN a precise, evidenced reason the loop
is blocked (e.g. "needs network access denied by HC1") and hand off honestly. Do NOT invent
progress. Remember LAW 1: do not end by saying the work is finished.

HARD LIMITS (never cross, even if asked): no financial transactions; no `rm -rf` on broad paths; no
force-push to main/master; no DB drop/truncate; no pushing to a remote you cannot confirm the user
owns; nothing outside the allowlist above.
```

**`{{REGRESSION_NOTICE}}`** (injected only after a REVERT):
```text
── ⚠ REGRESSION NOTICE — the previous iteration ({{PREV_ITER}}) was AUTO-REVERTED ──
What it tried:   {{PREV_CHOSE}}
Independent finding: {{PREV_REJECT_REASON}}   (metric {{BAD_METRIC}}: {{METRIC_BEFORE}} → {{METRIC_AFTER}}; your claim was {{CLAIMED}})
The repo is back at commit {{HEAD_SHA}} (the last good state). That approach is now in
LEDGER.REJECTED as {{REJECT_ID}}. DO NOT repeat it. Pick a DIFFERENT, ideally smaller item, and
verify the regressing metric stays within its floor BEFORE you commit.
{{ADVICE}}
```
**`{{INTEGRITY_NOTICE}}`** (only if `claim_vs_truth` gaps detected):
```text
── NOTE: prior reported metrics did not match independent measurement. Report ONLY harness-verifiable
   facts. Inflated numbers are detected and the iteration is wasted. ──
```

---

## 5. The ratchet algorithm (`lib/ratchet.sh`, called by the supervisor's RUN_AGY→GATE states)

> **The asymmetry that makes infinite running safe:** *the agent is an untrusted optimizer; the
> harness is the trusted referee that owns `git` and owns the scoreboard.* "Strictly better" is
> enforced at the gate, never requested in the prompt.

### 5.1 `run_one_iteration()` (invoked by the supervisor only on a `success`-class agy run)

```bash
run_one_iteration() {            # precondition: agy exited 0 this iteration
  N="$(jq .iteration state.json)"
  ITDIR=".ralph/iter/$(printf '%06d' "$N")"; mkdir -p "$ITDIR"

  # STEP S — SNAPSHOT BASELINE (independent; before judging the candidate)
  BASE_COMMIT="$(git rev-parse HEAD)"            # this was HEAD before agy ran (sha_before)
  # baseline metrics were measured at the END of the previous accepted iter and stored in RATCHET.baseline;
  # re-measure lazily only if baseline.commit != BASE_COMMIT (e.g. first run / external change)
  ensure_baseline_measured "$BASE_COMMIT" "$ITDIR/base"
  seed_best_if_unset "$BASE_COMMIT"              # first ever run: best := baseline
  load_floors_from RATCHET.json                  # FLOORS[m], DIRS[m], FROZEN[m], TOL[m]

  # STEP T — PARSE TRAILER (advisory only)
  python3 lib/extract_trailer.py "$ITDIR/agy.stdout" "$ITDIR/trailer.json"   # always exit 0
  python3 lib/validate_trailer.py "$ITDIR/trailer.json"

  # STEP C — DID THE AGENT CHANGE / COMMIT ANYTHING?
  if git diff --quiet && git diff --cached --quiet && [ -z "$(git status --porcelain)" ]; then
       handle_noop "$N"; return                  # identical tree → not advance, not regress (§5.8)
  fi
  if ! git diff --quiet HEAD; then               # agent forgot to commit → harness commits it, attributed
       git add -A
       git commit -q -m "ralph(iter $N): auto-commit agent working tree [agent forgot to commit]"
  fi
  CAND_COMMIT="$(git rev-parse HEAD)"

  # STEP M — INDEPENDENT RE-MEASUREMENT (the anti-fabrication core; INV-3)
  CAND_VERIFY="$(measure_verify "$ITDIR/cand")"  # harness runs verify ITSELF; writes metrics/latest.json
  declare -A CAND_M; measure_metrics CAND_M "$ITDIR/cand"   # harness derives every number ITSELF
  record_claim_vs_truth "$N" "$ITDIR/trailer.json" CAND_M   # integrity audit, never gates

  # STEP G — THE GATE (the pawl)  → ratchet_gate sets DECISION + CAUSE
  ratchet_gate "$BASE_COMMIT" "$CAND_COMMIT" "$CAND_VERIFY" CAND_M

  # STEP R/W — APPLY
  if [ "$DECISION" = ADVANCE ]; then
       update_best "$CAND_COMMIT" "$N" CAND_M "$(jq -r .what_changed "$ITDIR/trailer.json")"
       click_floors CAND_M                       # tighten each floor to achieved value (INV-2 one-way)
       echo "$CAND_COMMIT" > .ralph/refs/best
       append_history_jsonl CAND_M               # metrics/history.jsonl (append-only)
       write_handoff_from_trailer "$ITDIR/trailer.json"   # HANDOFF.md
       flip_progress_verdict "$N" ACCEPTED CAND_M
       clear_regression_pending
       set_state consecutive_reverts 0
       maybe_advance_tier                        # no major bug → coverage/hardening/probe (user pref)
       maybe_referee_gate "$CAND_COMMIT"         # §5.7 push-gate only (local commit already stands)
  else
       set_regression_pending "$N" "$CAUSE" CAND_M
       flip_progress_verdict "$N" REVERTED CAND_M
       append_ledger_rejected "$N" "$CAUSE"
       revert_to_baseline "$BASE_COMMIT"         # §5.6 (history under .ralph/ survives by exclusion)
       bump consecutive_reverts                  # §9 circuit-breaker: escalate tier, NEVER stop
  fi

  write_decision_json "$ITDIR/decision.json" "$DECISION" "$CAUSE"
  append_iteration_record "$N" "$DECISION" "$CAUSE" CAND_M   # iterations/NNNNNN.json (never deleted)
  persist_ratchet_atomic; persist_state_atomic
  # NEVER emit a "session summary and stop." Return; the supervisor re-enters. (user pref)
}
```

### 5.2 `ratchet_gate()` — the pawl (multi-metric, R3)
```bash
ratchet_gate() {                 # $1 base $2 cand $3 verify ; $4 = name of CAND_M assoc array
  local base="$1" cand="$2" verify="$3"; local -n M="$4"
  DECISION=REVERT; CAUSE=""
  if [ "$VERIFY_REQUIRED" = 1 ] && [ "$verify" != pass ]; then
       CAUSE="regression_verify_fail"; return
  fi
  if is_noop_diff "$base" "$cand"; then          # only comments/whitespace (excl .ralph) → not better
       CAUSE="noop_diff"; return
  fi
  # Vector ratchet: (a) no metric crosses its floor wrong-way; (b) >=1 non-frozen metric strictly improves.
  local improved=0 key
  for key in "${!FLOORS[@]}"; do
     local v="${M[$key]}"
     if [ "$v" = null ]; then continue; fi       # absent metric handled by absent_policy below
     if metric_crosses_floor "$key" "$v"; then    # respects DIRS[key], FLOORS[key], TOL[key]
          CAUSE="regression:${key}:floor=${FLOORS[$key]}:got=${v}"; return
     fi
     if [ "${FROZEN[$key]}" != true ] && metric_strictly_better "$key" "$v"; then improved=1; fi
  done
  if [ "$improved" -eq 1 ]; then DECISION=ADVANCE; return; fi
  # No metric strictly improved → fall to absent/secondary policy
  if absent_policy_better "$cand"; then DECISION=ADVANCE
  else CAUSE="not_strictly_better"; fi
}
```
`metric_crosses_floor`: for `dir=up`, fail if `v < floor - tol`; for `dir=down`, fail if `v > floor + tol`.
`metric_strictly_better`: `up` ⇒ `v > best.metrics[key]`; `down` ⇒ `v < best.metrics[key]`.
**The floor is always `best.metrics`, never `baseline.metrics`** — so a sequence of tiny regressions
each "better than the last bad one" can never walk a metric downhill (A's absolute-floor rule).

`absent_policy` (when no metric strictly improved or some are null):
- `verify_only` (default): ADVANCE iff `verify=pass ∧ non-noop diff ∧ committed`. The non-noop check
  prevents claiming victory via comment edits.
- `tie_breaker`: compare a secondary vector in priority — (1) verify_passed, (2) test count,
  (3) lint/type-error count (fewer better), (4) smallest acceptable diff toward goal — each
  harness-measured.

### 5.3 `lib/ratchet.py` verbs (the contract surface Lens B reads)
```
ratchet.py render-table        → markdown table of metrics (for {{RATCHET_TABLE}})
ratchet.py check <latest.json> → exit 0 if ADVANCE-eligible vs floors, non-zero otherwise (mirrors §5.2)
ratchet.py why                 → human reason for the last check failure (for VERDICT/LEDGER)
ratchet.py click <latest.json> → tighten floors to achieved values (called only after ADVANCE)
```
(The bash `ratchet_gate` is authoritative; `ratchet.py check` is the same logic exposed for
`ralph once`/CI and for B-style harness glue. They MUST agree — tested in T-RATCHET-6.)

### 5.4 `measure_*` — trusted referee primitives (anti-fabrication)
```bash
measure_verify() {              # $1 log prefix → "pass"|"fail"
  [ "$VERIFY_REQUIRED" = 1 ] || { echo pass; return; }
  local i res
  for i in $(seq 1 "${FLAKY_REVERIFY_RUNS:-2}"); do
     bounded_run "$VERIFY_TIMEOUT_S" "$1.verify.$i.log" -- sh -c "$VERIFY_CMD"
     res=$?; [ "$res" -eq 0 ] && { echo pass; return; }   # ANY green run ⇒ pass (flaky-tolerant on PASS side)
  done
  echo fail                     # failed every retry ⇒ trust the failure
}
measure_metrics() {             # $1 = assoc-array name to populate ; $2 = log prefix
  local -n OUT="$1"; local key cmd raw
  for key in "${!FLOORS[@]}"; do
     cmd="$(resolve_metric_cmd "$key")"          # AUTO:* → built-in, else the configured command
     bounded_run "$SCORE_TIMEOUT_S" "$2.$key.raw" -- sh -c "$cmd"
     raw="$(awk 'NF{last=$0} END{print last}' "$2.$key.raw" | grep -oE '^-?[0-9]+(\.[0-9]+)?$')"
     OUT["$key"]="${raw:-null}"
  done
}
```
**Structural anti-fabrication:** the values feeding `ratchet_gate` are *only* `measure_metrics`
output on the actual committed tree. The trailer's `metrics_after` is parsed solely for
`record_claim_vs_truth` (integrity audit) and to flavor regression advice. A persistent
claimed≫measured gap raises an `integrity_flag` that injects `{{INTEGRITY_NOTICE}}` into later
prompts. `done_with_explicit_goals` is necessary-not-sufficient (INV-6).

### 5.5 Flaky-test defense (asymmetric retry + EMA + quarantine)
- `measure_verify` is **pass-biased**: pass if ANY of `flaky_reverify_runs` passes; fail only if all
  fail. A real improvement is not reverted by one unlucky run; genuinely broken code fails
  deterministically every retry.
- Baseline is **re-measured each iteration**; a flaky-red baseline never lowers a floor (we keep the
  prior `best`). The floor is set only from a green measurement.
- `RATCHET.json` may carry per-metric EMA (extension): if raw oscillates while EMA is flat, raise a
  `flaky_score` flag, temporarily widen that metric's `tolerance`, and inject a prompt directive
  making "make tests X,Y deterministic" the next unit of work (a T3 hardening item).

### 5.6 `revert_to_baseline()` (R6 + INV-4)
```bash
revert_to_baseline() {           # $1 = baseline commit
  case "$RALPH_REVERT_STRATEGY" in
    reset_hard)
       git reset --hard "$1" >/dev/null
       git clean -fdx -e '.ralph' >/dev/null     # wipe stray files BUT preserve .ralph (history!)
       ;;
    revert_commit)
       git revert --no-edit "$(git rev-parse HEAD)" >/dev/null   # audited/shared branches
       ;;
  esac
}
```
Because **all** history (`iterations/`, `PROGRESS.md`, `LEDGER.md`, `progress.ndjson`) lives under
the `-e .ralph` exclusion and is git-ignored, the reset cannot touch it. (This supersedes Lens A's
fragile `merge_ndjson.py` stash-and-replay; that file is dropped from the manifest.) On REVERT the
harness sets `regression_pending` in `RATCHET.json`:
```jsonc
"regression_pending": {
  "iteration": 125,
  "what_agent_claimed": "refactor split(), +6 tests",
  "independent_finding": "verify FAILED: ImportError (circular) on every retry",
  "metric_before": { "tests_pass": 148 }, "metric_after": "unmeasurable (verify red)",
  "cause": "regression_verify_fail", "reverted_to": "e4a1f9c",
  "advice": "Avoid the top-level retry import that caused the cycle. Try a call-site-only retry, or a different next_candidate."
}
```
The prompt builder injects it verbatim as `{{REGRESSION_NOTICE}}` then clears it.

### 5.7 `maybe_commit_gate()` / referee push-gate (R5)
Local commits already happened (they are how we measure). This gates the *optional push* and the
*per-iteration commit-acceptance posture*:
```bash
maybe_commit_gate() {            # called inside the ADVANCE branch
  case "$RALPH_COMMIT_GATE" in
    none)   : ;;                                          # commit stands as-is
    tests)  [ "$CAND_VERIFY" = pass ] || return ;;        # already true on ADVANCE; defensive
    referee)
       maybe_referee_gate "$CAND_COMMIT" ;;               # periodic; see below
  esac
}
maybe_referee_gate() {           # $1 = candidate commit
  (( $(jq .advances state.json) % RALPH_REFEREE_EVERY == 0 )) || [ "$GOALS_DONE" = true ] || return 0
  local verdict
  verdict="$(bounded_run 300 "$ITDIR/referee.log" -- \
     agy -p "$(render_referee_prompt "$LAST_PUSH..HEAD")" --add-dir "$REPO_ROOT" \
         --dangerously-skip-permissions $SANDBOX_FLAG)"
  if echo "$verdict" | grep -Eq '^[[:space:]]*REFEREE:[[:space:]]*GO\b'; then
       guard_no_push                                      # §12: only if RALPH_PUSH=1 AND owned remote
  else
       append_goals_from_referee "$verdict"               # findings → top-priority LEDGER.OPEN items
       # local progress continues; only the outward push waits for READY (loop never blocks)
  fi
}
```
`prompts/referee.tmpl` forbids fabrication and demands a literal final-line token the parser greps:
```
You are the REFEREE. A Ralph iteration changed this repo. Review ONLY the diff in {{RANGE}}
(`git diff {{RANGE}}`). Verify, do not trust:
  1. Does it build/test? Run the verify command and report the REAL result.
  2. Is this STRICTLY BETTER than the prior pushed state (real fix / real coverage / real metric),
     never cosmetic or fabricated?
  3. Did the author invent a metric, claim a test that did not run, or fake completion?
INTEGRITY: if you cannot actually verify a claim, treat it as UNVERIFIED and vote NO-GO.
Answer on the FINAL line, exactly one of:
  REFEREE: GO   — <=12 word reason
  REFEREE: NO-GO — <=12 word reason
Do not print "GO" anywhere except that final line.
```

### 5.8 `handle_noop()` (agent changed nothing)
Not an advance, not a regression. Increment `noop_streak`; the next prompt says "your previous turn
produced no change; pick a concrete `next_candidate` and make exactly one improvement." After 3
consecutive noops, force tier escalation (§9). No fake progress, no stall.

### 5.9 Worked trace (two iterations)
```
ITER 124  base=a1b2 (verify=pass, tests_pass=142 cov=71.3)  floors{tests_pass≥142,cov≥71.3}  tier=T2
  agy exit 0 → run_one_iteration. agent edited tok.py+tests, committed c0ffee.
  trailer.metrics_after={tests_pass:149} ← ADVISORY
  measure_verify(c0ffee)=pass ; measure_metrics → tests_pass=149, cov=74.5  ← HARNESS's own numbers
  claim_vs_truth: 149 vs 149 → match
  gate: floors held, tests_pass 149>142 strictly better → ADVANCE
  click floors → {tests_pass≥149, cov≥74.5}; advances=52; consecutive_reverts=0; refs/best=c0ffee
  (advances%10≠0 → no push)

ITER 125  base=c0ffee (verify=pass, tests_pass=149)  floors{tests_pass≥149,cov≥74.5}  tier=T2
  agent refactor, committed dead00. trailer claims tests_pass:155.
  measure_verify: run1 FAIL (ImportError), run2 FAIL → fail
  gate: verify_required ∧ fail → CAUSE=regression_verify_fail → REVERT
  regression_pending set (independent_finding="ImportError circular"); reset --hard c0ffee + clean -e .ralph
  consecutive_reverts=1; floors UNCHANGED (never lowered by a failed candidate); .ralph history intact
  HEAD == c0ffee → strictly ≥ where iter 125 began. The pawl held.

ITER 126  base=c0ffee  + {{REGRESSION_NOTICE}} carries the advice verbatim → agent tries the safer call-site approach.
```

---

## 6. Bounded exec, atomic IO, lock (macOS primitives)

### 6.1 `bounded_run` — group-kill watchdog (R11; `lib/bounded.sh`)
No `timeout`/`flock`; `/usr/bin/perl` confirmed. The watchdog kills the whole **process group** so
hung `agy` children are reclaimed.
```bash
# bounded_run <seconds> <logfile> -- cmd args...   → returns cmd's rc, or 124 on wall-clock kill.
bounded_run() {
  local secs="$1" log="$2"; shift 2; [ "$1" = "--" ] && shift
  ( exec "$@" ) >"$log" 2>&1 &              # run under set -m so this subshell is its own pgid leader
  local cmd_pid=$!
  (
    /usr/bin/perl -e 'select(undef,undef,undef,$ARGV[0])' "$secs"   # precise, interruptible sleep
    if kill -0 "$cmd_pid" 2>/dev/null; then
       kill -TERM -"$cmd_pid" 2>/dev/null || kill -TERM "$cmd_pid" 2>/dev/null
       /usr/bin/perl -e 'select(undef,undef,undef,5)'               # 5s grace
       kill -KILL -"$cmd_pid" 2>/dev/null || kill -KILL "$cmd_pid" 2>/dev/null
       exit 124
    fi; exit 0
  ) &
  local wd_pid=$!
  wait "$cmd_pid"; local rc=$?
  if kill -0 "$wd_pid" 2>/dev/null; then kill -TERM "$wd_pid" 2>/dev/null; wait "$wd_pid" 2>/dev/null; fi
  if [ "$rc" -ge 143 ]; then wait "$wd_pid" 2>/dev/null; [ "$?" -eq 124 ] && rc=124; fi
  return "$rc"
}
```
The supervisor runs under `set -m` so `( exec "$@" )` lands in a new pgid; falls back to plain-pid
kill if group kill fails. `agy` is invoked BOTH with `--print-timeout ${RALPH_AGY_TIMEOUT_S}s`
(cooperative) AND wrapped in `bounded_run $((RALPH_AGY_TIMEOUT_S+60))` (external) — belt+suspenders
so a wedged worker can never freeze the loop (INV-7).

### 6.2 Atomic state writes
Every `RATCHET.json` / `state.json` / `heartbeat.json` update: write `<file>.tmp`, validate it parses
(`jq . <tmp> >/dev/null`), then `mv` over the original (atomic rename within `.ralph/`, same APFS
filesystem). A crash mid-write can never corrupt the live file.

### 6.3 Lock (R12; `lib/state.sh`)
```bash
acquire_lock_or_exit() {
  local lock=.ralph/ralph.lock
  if mkdir "$lock" 2>/dev/null; then echo $$ > "$lock/owner.pid"; return; fi
  local owner; owner="$(cat "$lock/owner.pid" 2>/dev/null)"
  if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
     echo "ralph: already running for this target (pid $owner)"; exit 3
  fi
  rm -rf "$lock"; mkdir "$lock"; echo $$ > "$lock/owner.pid"      # steal stale lock (owner dead)
}
trap 'rm -rf .ralph/ralph.lock; rm -f .ralph/ralph.pid' EXIT
```
`mkdir` is atomic on APFS — a correct mutex without `flock`.

---

## 7. The supervisor state machine (`bin/ralph-supervisor.sh`)

Two-layer survival (R2): **launchd** (process immortality, §9) → **supervisor** (iteration
immortality) → **disposable `agy`**. The supervisor has **no terminal state by default**.

### 7.1 States
`INIT → PREFLIGHT → GUARD_INTERVAL → RUN_AGY → CLASSIFY → {GATE | BACKOFF | CRASHLOOP_COOLDOWN | RECOVER_IDE | FATAL_WAIT} → PERSIST → (loop)`.
Terminal (rare): `DRAIN_STOP`, `MAX_ITERATIONS_REACHED`.

### 7.2 Main loop (pseudocode)
```bash
main() {
  acquire_lock_or_exit; write_pid
  load_or_init_state                       # state.json; resume@iteration
  install_signal_traps                     # SIGTERM/SIGINT → WANT_STOP=1 (graceful); SIGHUP → reload config
  set -m                                   # job control: agy children get own pgid for bounded_run
  log "supervisor up pid=$$ resume@iter=$ITER"

  while true; do
    # ── TERMINATION CHECKS (the ONLY ways out) ──
    [ -f .ralph/STOP ] && { phase=draining; heartbeat; STATE=DRAIN_STOP; break; }
    [ "$WANT_STOP" = 1 ] && { STATE=DRAIN_STOP; break; }
    [ "$RALPH_MAX_ITERATIONS" -gt 0 ] && [ "$ITER" -gt "$RALPH_MAX_ITERATIONS" ] && { STATE=MAX_ITERATIONS_REACHED; break; }

    # ── SOFT PAUSE (heartbeat continues; no agy) ──
    while [ -f .ralph/PAUSE ] && [ ! -f .ralph/STOP ]; do phase=paused; heartbeat; sleep_interruptible 10; done

    # ── PREFLIGHT ──
    phase=preflight; heartbeat
    agy_reachable || recover_agy_substrate          # relaunch language_server / Antigravity (§7.4)

    # ── CRASH-LOOP GUARD ──
    enforce_min_interval "$RALPH_MIN_INTERVAL_S"     # since last_run_started
    if crashloop_tripped; then
       phase=crashloop_cooldown; backoff_s=$RALPH_CRASHLOOP_COOLDOWN_S; heartbeat
       log "CRASHLOOP $strikes/$WINDOW → cooldown ${backoff_s}s"; sleep_interruptible "$backoff_s"
       reset_crashloop_window; continue              # do NOT burn an iteration
    fi

    # ── RUN ONE UNIT ──
    phase=running_agy; set_state last_run_started "$(now)"; heartbeat
    ITDIR=".ralph/iter/$(printf '%06d' "$ITER")"; mkdir -p "$ITDIR"
    PROMPT="$(render_prompt "$ITER")"; printf '%s' "$PROMPT" > "$ITDIR/prompt.txt"
    sha_before="$(git -C "$TARGET" rev-parse --short HEAD 2>/dev/null || echo none)"

    bounded_run "$((RALPH_AGY_TIMEOUT_S+60))" "$ITDIR/agy.stdout" -- \
        agy -p "$PROMPT" --add-dir "$TARGET" --print-timeout "${RALPH_AGY_TIMEOUT_S}s" \
            $([ "$RALPH_SKIP_PERMISSIONS" = 1 ] && echo --dangerously-skip-permissions) \
            $([ "$RALPH_SANDBOX" = 1 ]          && echo --sandbox)
    rc=$?; echo "$rc" > "$ITDIR/agy.exit"
    sha_after="$(git -C "$TARGET" rev-parse --short HEAD 2>/dev/null || echo none)"

    # ── CLASSIFY (§7.4) ──
    class="$(classify_result "$rc" "$ITDIR/agy.stdout")"
    write_iter_meta "$ITDIR" "$rc" "$class" "$sha_before" "$sha_after"

    case "$class" in
      success)
        set_state consecutive_failures 0; set_state consecutive_quota_hits 0; backoff_s=0
        run_one_iteration                            # §5 — the ratchet gate ADVANCE/REVERT
        set_state last_success "$(now)"
        ITER=$((ITER+1))                             # advance counter (unit attempted)
        ;;
      rate_limit)
        bump consecutive_quota_hits
        backoff_s="$(expo_backoff_jitter "$(jq .consecutive_quota_hits state.json)")"
        phase=backoff; heartbeat; log "RATE_LIMIT → backoff ${backoff_s}s"
        sleep_interruptible "$backoff_s"; continue   # retry SAME iteration (work not done); floor untouched
        ;;
      timeout)
        bump consecutive_failures; record_crashloop_event
        log "TIMEOUT iter=$ITER → reclaim & advance"
        revert_dirty_to "$sha_before"                # abandon wedged partial work
        backoff_s="$(min 120 $((30*$(jq .consecutive_failures state.json))))"
        sleep_interruptible "$backoff_s"
        ITER=$((ITER+1))                             # advance: unit wedged, next fresh agy picks next task
        ;;
      transient_crash)
        bump consecutive_failures; record_crashloop_event
        revert_dirty_to "$sha_before"; recover_agy_substrate
        backoff_s="$(expo_backoff_jitter "$(jq .consecutive_failures state.json)")"
        log "TRANSIENT_CRASH rc=$rc → recover+backoff ${backoff_s}s"
        sleep_interruptible "$backoff_s"; continue   # retry SAME iteration
        ;;
      fatal_misconfig)
        bump consecutive_failures
        phase=fatal_wait; heartbeat; log "FATAL_MISCONFIG (loud) → wait & retry, NEVER exit"
        sleep_interruptible 300; continue            # a human/launchd env-fix may resolve it
        ;;
    esac

    phase=persist; persist_state_atomic; rotate_if_big; phase=idle; heartbeat
  done

  log "supervisor exiting state=$STATE iter=$ITER"
  [ -f .ralph/STOP ] && self_bootout_launchd         # §9: avoid KeepAlive resurrection on intended stop
  release_lock; final_heartbeat stopped
}
```

### 7.3 Backoff / sleep / crash-loop (`lib/backoff.sh`)
- `sleep_interruptible N` = perl-sleep in background + `wait`, but the SIGTERM trap kills it so
  `ralph stop` is instant; it also re-checks `.ralph/STOP` / `.ralph/PAUSE` each ≤2s tick (INV-8).
  (Foreground `sleep` is blocked in this environment; perl-sleep is the portable substitute.)
- `expo_backoff_jitter n` → `s = min(CAP, BASE * 2^(n-1)); return s ± rand(s*JITTER_PCT/100)`. Jitter
  prevents lockstep re-hammering of shared Antigravity quota across targets.
- `enforce_min_interval` floors iteration cadence so even `success→success` can't exceed
  `1/RALPH_MIN_INTERVAL_S` iters/sec — the tightest crash loop is throttled.
- `crashloop_tripped` = ≥`RALPH_CRASHLOOP_THRESHOLD` transient/timeout events within
  `RALPH_CRASHLOOP_WINDOW_S` → cooldown (does not burn an iteration; launchd `ThrottleInterval` is
  the Layer-2 backstop).
- **`continue` vs advance `ITER` (R8):** `rate_limit`+`transient_crash` retry SAME iteration (unit
  not attempted); `timeout`+`success` advance (unit done/abandoned) — keeping the counter an honest
  measure of work attempted, not spins burned.

### 7.4 Classifier + IDE recovery (`lib/classify.sh`)
```bash
classify_result() {              # $1 rc  $2 transcript
  local rc="$1" tail; tail="$(tail -c 4000 "$2" | tr 'A-Z' 'a-z')"
  [ "$rc" -eq 124 ] && { echo timeout; return; }
  echo "$tail" | grep -Eq 'rate.?limit|quota|too many requests|429|resource[_ ]exhausted|credits? (exhausted|depleted)|usage limit' \
     && { echo rate_limit; return; }
  echo "$tail" | grep -Eq 'print.?timeout|deadline exceeded|context deadline' && { echo timeout; return; }
  if [ "$rc" -ne 0 ]; then
     command -v agy >/dev/null 2>&1 || { echo fatal_misconfig; return; }
     echo "$tail" | grep -Eq 'not (authenticated|logged in|signed in)|no such file or directory|permission denied \(workspace\)|no space left|invalid api key|unauthorized' \
        && { echo fatal_misconfig; return; }
  fi
  [ "$rc" -eq 0 ] && { echo success; return; }
  echo transient_crash
}
agy_reachable()       { pgrep -f 'language_server' >/dev/null 2>&1; }
recover_agy_substrate() {
  [ "$RALPH_RELAUNCH_ANTIGRAVITY" = 1 ] || return 0
  agy_reachable && return 0
  log "language_server down → relaunching Antigravity"; open -ga "Antigravity" 2>/dev/null
  for i in $(seq 1 12); do agy_reachable && { log "LS back"; return 0; }; phase=recover_ide; heartbeat; sleep_interruptible 5; done
  log "LS not back; treat as transient, retry next iter (loop never dies)"; return 1
}
```
**Silent-zombie guard (rc 0 but no work):** the classifier greps quota language *even when rc==0*
and demotes a suspiciously-empty success to `rate_limit`. Additionally `run_one_iteration`'s
`handle_noop` (sha unchanged) and the `stalled` heartbeat flag (N consecutive zero-diff iters)
surface "alive but not progressing" instead of a false-green.

---

## 8. The `ralph` CLI contract (`bin/ralph` → `~/.local/bin/ralph`)

`target` = path or registered name; defaults to `$PWD` if it has `.ralph/`, else error. Exit codes
shared by all surfaces: `0` ok/alive · `1` dead/error · `2` paused · `3` already-running (lock held)
· `4` misconfig (doctor FAIL).

| Subcommand | Flags | What it does / prints |
|---|---|---|
| `init [path]` | `--prompt <file>` `--gate none\|tests\|referee` `--mission <file>` | Scaffold `<target>/.ralph/` (config.env, allow.txt, MISSION.md seed, RATCHET.json from auto-detect, dirs); rename existing `.ralph_self/`→`.ralph/`; register in `~/.ralph/targets.tsv`. Prints resolved verify cmd + metric set. |
| `start [target]` | `--foreground`(default w/ TTY) `--daemon` `--max-iterations N`(default 0=∞) `--interval S` `--timeout S` `--no-sandbox`(NOT recommended) `--push`(guarded) `--force`(start despite doctor FAIL) | Runs `ralph doctor` first; refuses on FAIL unless `--force`. Launches the supervisor. `--daemon` → `nohup … & disown` (survives terminal close). Prints pid + target. |
| `once [target]` | | Run EXACTLY ONE iteration (no loop) incl. gate; for testing/CI. Prints DECISION + metric deltas + trailer status. |
| `status [target]` | `--json` `--watch` | Reads heartbeat.json+state.json: alive/dead/paused, iter, phase, last_class, consec failures/reverts, next ETA, uptime, stalled?. Exit 0=alive,1=dead,2=paused. |
| `tail [target]` | `--iter N` | `tail -f` supervisor.log (+ current iter log; or one iter). |
| `pause [target]` | | `touch .ralph/PAUSE` (idles, keeps heartbeating). |
| `resume [target]` | | `rm .ralph/PAUSE`. |
| `stop [target]` | `--hard` `--permanent` | `touch .ralph/STOP` then SIGTERM the pid for instant drain; wait+verify. `--hard` SIGKILL after 30s. `--permanent` also `launchctl bootout` the agent so reboot won't resume. |
| `doctor [target]` | | Diagnose: agy on PATH? LS up? authed (`agy -p PONG`)? target is git? disk space? lock state? config sane? RATCHET.json parses? Prints PASS/FAIL per check; exit 4 on any FAIL. |
| `install-daemon [target]` | `--uninstall` | Render+bootstrap launchd plist (§9). |
| `list` | | `~/.ralph/targets.tsv` with live/dead/paused per target. |
| `logs [target]` | `--archive` | Print log paths; `--archive` lists rotated gz. |
| `metrics [target]` | `--json` | Print current floors + best + last measured (from RATCHET.json + metrics/history.jsonl tail). |
| `version` / `help` | | Self-explanatory. |
| `__run-supervisor <target>` | (hidden) | launchd `ProgramArguments` entry; execs `ralph-supervisor.sh`. |

`ralph doctor` is the pre-flight; `start` invokes it automatically so a misconfigured loop fails
**loudly at launch** instead of silently spinning `fatal_misconfig`.

---

## 9. The three command surfaces

### 9.1 Surface 1 — CLI install
`bin/ralph` is a thin bash dispatcher that sources `lib/*.sh` (from the repo or an installed
`~/.local/share/ralph/`). Install = symlink/copy `bin/ralph` → `~/.local/bin/ralph` (on PATH).

**`ralph install-daemon`** renders `integrations/launchd/com.ralph.TEMPLATE.plist` →
`~/Library/LaunchAgents/com.ralph.<name>.plist` (true reboot-survival — Layer 2):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>com.ralph.{{NAME}}</string>
  <key>ProgramArguments</key>
    <array>
      <string>/Users/nazmi/.local/bin/ralph</string>
      <string>__run-supervisor</string>
      <string>{{TARGET_ABS}}</string>
    </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/><key>Crashed</key><true/></dict>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardOutPath</key><string>/Users/nazmi/.ralph/daemon.log</string>
  <key>StandardErrorPath</key><string>/Users/nazmi/.ralph/daemon.log</string>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/Users/nazmi/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityIO</key><true/>
</dict></plist>
```
Bootstrap (modern API): `launchctl bootstrap gui/$(id -u) <plist>` → `enable` →
`kickstart -k gui/$(id -u)/com.ralph.<name>`.
**KeepAlive resurrection paradox (resolved):** with `SuccessfulExit=false`, launchd would revive a
clean `ralph stop`. So on a STOP-sentinel drain the supervisor calls `launchctl bootout`
gui/$(id -u)/com.ralph.<name> on *itself* before exiting (`self_bootout_launchd`); `ralph stop
--permanent` does it explicitly. A genuine crash (no STOP file) is still relaunched. The STOP
sentinel is the single authority disambiguating "user wants out" from "process died." `ralph stop`
without `--permanent` leaves the plist enabled so a *reboot* resumes (still "never stops").

### 9.2 Surface 2 — Claude Code slash command (`integrations/claude-code/ralph-antigravity.md` → `~/.claude/commands/`)
```markdown
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
```

### 9.3 Surface 3a — Antigravity workflow (`integrations/antigravity/never-stop-ralph.md` → `~/.gemini/antigravity/global_workflows/`)
```markdown
---
name: never-stop-ralph
trigger: "/ralph" or "keep improving this repo until I say stop"
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
```

### 9.4 Surface 3b — Antigravity global rule (`integrations/antigravity/GEMINI.snippet.md` → appended to `~/.gemini/GEMINI.md`; create if absent)
```markdown
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
```

---

## 10. Log rotation (so "never stops" ≠ "fills the disk")
Called in PERSIST each iteration:
```bash
rotate_if_big() {
  local f=.ralph/logs/supervisor.log; [ -f "$f" ] || return
  local sz; sz="$(stat -f%z "$f")"                          # macOS stat
  if [ "$sz" -gt 10485760 ]; then                           # 10 MB
     gzip -c "$f" > ".ralph/archive/supervisor.log.$(date +%s).gz"; : > "$f"
     ls -1t .ralph/archive/*.gz | tail -n +21 | xargs -r rm  # keep newest 20
  fi
  ls -1t .ralph/logs/iter-*.log 2>/dev/null | tail -n +501 | xargs -r gzip   # gz iter logs older than newest 500
}
```
`iterations/NNNNNN.json` + `progress.ndjson` + `PROGRESS.md`/`LEDGER.md` are tiny and **never
deleted** (audit trail, INV-4). Only bulky raw transcripts rotate.

---

## 11. Test plan (`tests/*.bats` + a bounded live smoke)

All unit tests use a **stub `agy`** (a script on `PATH` that prints a canned transcript from
`tests/fixtures/` and exits with a chosen code) so the ratchet/state/classifier logic is exercised
without burning AI credits or needing Antigravity. Run via `bats` (pin a vendored copy if not
installed system-wide).

| ID | File | Asserts | Method |
|---|---|---|---|
| T-RATCHET-1 | ratchet.bats | ADVANCE when verify pass + a non-frozen metric strictly improves + floors held | fixture repo, stub agy commits a passing test; assert refs/best moves + floors clicked |
| T-RATCHET-2 (INV-3) | ratchet.bats | claimed≫measured ⇒ REVERT + integrity_flag set | trailer claims tests_pass:999, real 0; assert decision REVERT, claim_vs_truth recorded |
| T-RATCHET-3 (INV-1) | ratchet.bats | verify-fail candidate ⇒ REVERT, HEAD == baseline | stub commits import error; assert `git rev-parse HEAD` == base |
| T-RATCHET-4 (INV-1) | ratchet.bats | metric crossing floor wrong-way ⇒ REVERT | bench_p95 worsens past floor; assert REVERT cause=regression:bench_p95_ms |
| T-RATCHET-5 (INV-2) | ratchet.bats | floors never lowered, even after a flaky-red baseline | force baseline red once; assert best/floors unchanged |
| T-RATCHET-6 | ratchet.bats | `ratchet.py check` agrees with bash `ratchet_gate` on 8 vectors | table-driven parity |
| T-NOOP | ratchet.bats | identical tree ⇒ NOOP (not advance/regress), noop_streak++ | stub makes no change |
| T-STATE-1 | state.bats | atomic write: kill mid-write leaves prior valid file | inject failure between tmp-write and mv |
| T-STATE-2 | state.bats | lock steal when owner pid dead; refuse when alive | seed stale + live owner.pid |
| T-STATE-3 | state.bats | heartbeat updated start+end; `stalled` flips after N zero-diff iters | run N noops |
| T-STATE-4 (INV-4) | state.bats | `reset --hard`+`clean -e .ralph` preserves all `.ralph/` history files | write markers, revert, assert present |
| T-TRAILER-* | trailer.bats | salvage ladder: missing/multiple/code-fenced/trailing-comma/single-quote/Python-literal/truncated/bare-JSON each yields a valid coerced object, exit 0 | fixtures + assert TRAILER_STATUS |
| T-CLASSIFY-* | classify.bats | each class from rc+transcript; rc0-with-quota ⇒ rate_limit (silent-zombie) | fixture transcripts |
| T-BOUND-1 (INV-7) | bounded.bats | a `sleep 999` child is killed at the cap, rc==124, no orphan | spawn child holding a subprocess; assert pgid reaped |
| T-SUP-1 (INV-5) | supervisor.bats | error in body ⇒ loop continues (no exit) | stub agy exits non-zero; assert next iter runs |
| T-SUP-2 (INV-8) | supervisor.bats | `touch STOP` mid-backoff halts ≤ ~interval | start, set long backoff, touch STOP, time drain |
| T-SUP-3 (INV-5) | supervisor.bats | rate_limit retries SAME iter, floor untouched; timeout advances iter | stub by class |
| T-SUP-4 (INV-6) | supervisor.bats | goals_done requires 3 witnesses; loop still runs (enters T7) after | force MISSION met + OPEN empty + referee READY |
| T-SAFE-1 (INV-9) | safety.bats | push refused when RALPH_PUSH=0; and when remote not user-owned even if PUSH=1 | set fake origin urls |
| T-SAFE-2 | safety.bats | agent edit to MISSION.md/RATCHET.json ⇒ iteration rejected + canonical restored | stub mutates protected file |

**Bounded live smoke (`tests/smoke_live.sh`, opt-in, costs credits):** requires Antigravity running.
1. `ralph doctor` PASS. 2. `agy -p "Reply PONG" --dangerously-skip-permissions` returns `PONG` exit 0
(grounding sanity). 3. `ralph init` a throwaway fixture repo with one trivial failing test. 4.
`ralph once` → assert exit 0, a commit appears, `metrics/latest.json` written, `decision.json`
present, trailer parsed. 5. `touch STOP`; `ralph status` reports stopped within interval. Wrap the
whole script in `bounded_run 900` so the smoke itself can't hang CI.

---

## 12. Footguns & safety

`--dangerously-skip-permissions` runs **unattended** — the single most dangerous flag here. Layered containment:

| Footgun | Guard |
|---|---|
| **Auto-approved destructive command** (`rm -rf`, disk format) | (a) `agy --sandbox` on by default (terminal restrictions). (b) `.ralph/allow.txt` is injected into the prompt as the *only* sanctioned command set; the prompt instructs refusal of anything outside it. (c) The referee gate sees the diff before any push. (d) The user's hard limits (no financial txns, no broad `rm -rf`, no force-push main, no DB drop) are embedded verbatim in the prompt's HARD LIMITS block. |
| **Metric fabrication / fake completion** (INV-3, INV-6) | Gate compares only `measure_metrics()` on the committed tree; trailer numbers are advisory. `record_claim_vs_truth` flags gaps → `{{INTEGRITY_NOTICE}}`. `done_with_explicit_goals` is one of three required witnesses; the agent can never self-declare done. |
| **Thrash / undo (A→B→A)** | The vector ratchet is the anti-undo: a change lowering any previously-raised metric is REVERTED. `LEDGER.REJECTED` + `{{REGRESSION_NOTICE}}` name the failed approach; retry requires NEW evidence. `LEDGER.DONE` + append-only `PROGRESS.md` make "already shipped" durable across fresh contexts. |
| **Runaway commits** | Local commits are how we measure (kept), but `RALPH_COMMIT_GATE=referee` default gates push; no-op diffs never advance; circuit-breaker escalates tier after `RALPH_MAX_CONSECUTIVE_REVERTS` instead of committing junk. |
| **Push to a foreign remote** (INV-9) | `RALPH_PUSH=0` default = never push. When enabled, `guard_no_push` regex-checks `origin` is under `github.com[/:](nazmiefearmutcu\|$USER)/` and refuses otherwise; force-push is never issued. |
| **Kill-switch ignored** | `.ralph/STOP` / `.ralph/PAUSE` checked at the top of every iteration AND inside every interruptible backoff sleep; `launchctl bootout` on STOP-drain prevents KeepAlive resurrection (§9.1). |
| **Two supervisors on one target** | `mkdir .ralph/ralph.lock` mutex + stale-PID steal (§6.3); double-spend/racing-commit prevented. |
| **Tight crash-loop torches CPU/credits** | `enforce_min_interval` floor + crash-loop window cooldown + launchd `ThrottleInterval=30` (Layer-2). |
| **Wedged worker ignores its own timeout** (INV-7) | External `bounded_run` group-kill at `AGY_TIMEOUT_S+60`, normalized to rc 124 → classified `timeout` → unit abandoned, loop advances. |
| **Silent zombie (rc 0, no work)** | Classifier greps quota even on rc 0; `handle_noop` on unchanged sha; `stalled` heartbeat flag after N zero-diff iters → `ralph status` shows "alive but not progressing", never false-green. |
| **First commit on empty repo** | `git rev-parse` guarded with `|| echo none`; the first iteration tolerates empty HEAD and seeds `best` from the first passing measurement. |
| **Agent edits `.ralph/` protected files** | Harness restores canonical `MISSION.md`/`RATCHET.json`/`state.json` and REVERTS the iteration (T-SAFE-2). The prompt forbids editing anything under `.ralph/` except `PROGRESS.md`/`LEDGER.md`. |

---

## Appendix — improvements over all three lenses (where this SPEC is strictly stronger)

1. **Single runtime dir + full git-ignore (R1+R7) eliminates A's fragile log-merge.** By keeping
   *all* history under `.ralph/` (git-ignored, `-e .ralph` excluded from clean), `git reset --hard`
   cannot touch the audit trail. A's `merge_ndjson.py` stash-and-replay is deleted; INV-4 holds by
   construction, and the target's own tree never sees loop bookkeeping.
2. **Vector ratchet (R3) generalizes A's single-score floor to B's multi-metric gate** with one
   consistent rule (no floor crossed + ≥1 non-frozen strictly improves), giving A's exact monotonic
   guarantee on every dimension simultaneously — stronger than either lens alone.
3. **Two-layer immortality (R2) wraps A/B's `while true` in C's launchd-supervised, classifier-driven
   supervisor**, so quota/timeout/IDE-death/reboot are all survivable; A/B's bare loop died with its
   bash process.
4. **Belt+suspenders bounded exec (R11):** `agy --print-timeout` AND an external process-group
   watchdog — A's single-pid `alarm` would have leaked hung children.
5. **Honest, harness-computed completion (INV-6) with three independent witnesses**, plus the
   never-stop T7 generator, satisfies "never stops" and "no fabricated completion" simultaneously —
   the loop is mathematically unable to both stop and fake an advance.
6. **`ratchet.py check` parity with bash `ratchet_gate` (T-RATCHET-6)** gives B's harness-glue
   contract a tested single source of truth, removing the risk of the two lenses' gate logics
   drifting apart.
