# RUNBOOK — operating the Antigravity Ralph loop

Operational recovery guide for the never-stopping, always-improving Ralph loop that drives the
`agy` headless agent. This is the page you open at 3am when something looks wrong.

For *what* the loop is and *why*, see [README.md](../README.md). For the authoritative contract see
[SPEC.md](../SPEC.md). For verified facts about `agy`/Antigravity/macOS see
[TECH_GROUNDING.md](./TECH_GROUNDING.md).

> **Golden rule:** the loop is *designed* to never exit on its own. Almost every "it stopped" or
> "it's stuck" symptom is recoverable WITHOUT editing code — usually a STOP/PAUSE sentinel, a stale
> lock, a quota outage, or Antigravity not running. Diagnose with `ralph status` and `ralph doctor`
> before touching anything.

---

## 0. The 30-second triage

```sh
ralph status <target> --json     # alive/dead/paused? iter, phase, last_class, consec failures/reverts, stalled?
ralph doctor <target>            # PASS/FAIL per preflight check; exit 4 on any FAIL
ralph tail   <target>            # follow supervisor.log + current iteration log
```

`ralph status` exit codes: `0` alive · `1` dead/error · `2` paused · `3` already-running (lock held)
· `4` misconfig.

Decision tree:

| `ralph status` says | Most likely cause | Go to |
|---|---|---|
| `paused` (exit 2) | someone `touch`ed `.ralph/PAUSE` | §5 STOP/PAUSE |
| `dead` (exit 1), no STOP file | crash / quota / Antigravity down / reboot without daemon | §1 quota, §3 not-progressing, §6 reboot |
| `alive` but `iteration` not advancing | wedged `agy`, crash-loop cooldown, backoff | §3 alive-but-not-progressing |
| `alive`, `stalled: true` | running but N iters with zero diff (silent zombie) | §3 alive-but-not-progressing |
| exit 3 (already-running) when you tried to start | a supervisor already owns the lock, OR stale lock | §2 stale-lock |
| `doctor` FAIL | env problem (agy/PATH/auth/git/disk) | §1, §7 add-a-target |

---

## 1. Quota / credit outage recovery (`rate_limit`)

**Symptom.** `ralph status` shows `last_class: rate_limit` and a rising `consecutive_quota_hits`;
`ralph tail` shows `RATE_LIMIT → backoff <N>s`. The loop is NOT dead — it is backing off and will
retry the **same iteration** (no work was lost, no ratchet floor moved).

**What the loop is already doing for you.**
- The classifier (`lib/classify.sh`) greps the `agy` transcript for `rate.?limit|quota|429|
  resource_exhausted|credits (exhausted|depleted)|usage limit` — and demotes even an rc-0
  suspiciously-empty "success" to `rate_limit` (silent-zombie guard).
- On `rate_limit` the supervisor runs `expo_backoff_jitter consecutive_quota_hits`:
  `s = min(RALPH_BACKOFF_CAP_S, RALPH_BACKOFF_BASE_S * 2^(n-1))` ± jitter, then `continue`s the SAME
  iteration. Defaults: base 30s, cap 1800s (30m), jitter 25%. The iteration counter does NOT advance
  (the unit was never attempted), so progress accounting stays honest.

**What you do.**
1. Confirm it really is quota and not a dead loop: `ralph status --json` → `last_class=rate_limit`
   and a non-zero `backoff_s`/`next_action_eta_s`. If `heartbeat.json.ts` is fresh (within
   ~`3 × max(backoff_s, 20s)`), the loop is alive and just waiting.
2. Verify the underlying cause directly:
   ```sh
   agy -p "Reply with exactly one word: PONG" --dangerously-skip-permissions
   ```
   - Returns `PONG`, exit 0 → quota has recovered; the loop will resume on its next backoff wake.
   - Still rate-limited / errors about credits → the Antigravity account is out of AI credits. Wait
     for the quota window to reset (the loop keeps backing off up to the 30m cap; it will catch the
     recovery automatically). **Do not kill the loop** — that loses the resume state.
3. If you want it idle while you sort out billing (so it stops burning even the cheap preflight):
   `ralph pause <target>`. Resume with `ralph resume <target>` once credits are back. PAUSE keeps the
   heartbeat alive (so `status` still reports correctly) but runs no `agy`.
4. If the outage is long and you want to stop cleanly until tomorrow: `ralph stop <target>` (leaves
   the launchd plist enabled, so a reboot still resumes). Re-`start` when ready.

**Knobs (in `<target>/.ralph/config.env`, or `ralph start` flags).** `RALPH_BACKOFF_BASE_S`,
`RALPH_BACKOFF_CAP_S`, `RALPH_BACKOFF_JITTER_PCT`. Jitter exists so multiple targets don't re-hammer
the shared Antigravity quota in lockstep; do not set jitter to 0 if you run more than one target.

---

## 2. Stale-lock recovery (exit 3, "already running" but nothing is)

**Symptom.** `ralph start` / `ralph once` exits `3` with `ralph: already running for this target
(pid <N>)`, but no supervisor is actually running (e.g. after a `SIGKILL`, a power loss, or
`ralph stop --hard`).

**Why it happens.** The mutex is a directory: `.ralph/ralph.lock/` containing `owner.pid`. On a clean
exit the `trap … EXIT` removes it. A `SIGKILL` (or a hard crash) skips traps, so the lock dir is left
behind — a *stale* lock.

**The loop self-heals this.** `acquire_lock_or_exit` (`lib/state.sh`) reads `owner.pid` and runs
`kill -0 <owner>`:
- owner process is **alive** → genuine concurrent run, refuses with exit 3 (correct: two supervisors
  on one target would double-spend credits and race commits).
- owner process is **dead** → it `rm -rf`s the stale lock and steals it. So simply
  **re-running `ralph start`** usually clears a stale lock automatically.

**Manual recovery (only if the auto-steal didn't fire — e.g. PID reuse made a dead owner look alive).**
1. Confirm no live supervisor for this target:
   ```sh
   cat <target>/.ralph/ralph.lock/owner.pid     # the claimed owner
   cat <target>/.ralph/ralph.pid                # the PID the supervisor last wrote
   ps -p "$(cat <target>/.ralph/ralph.pid 2>/dev/null)" -o pid=,command=   # is it really ralph-supervisor.sh?
   ```
   If that PID is absent, or is some unrelated process (PID reuse), the lock is stale.
2. Remove the lock dir and the pid file, then start:
   ```sh
   rm -rf <target>/.ralph/ralph.lock <target>/.ralph/ralph.pid
   ralph start <target>
   ```
   This is safe to do by hand — the lock and pid are the only two files involved, and both are
   re-created on start. Do NOT delete anything else under `.ralph/` (see §8 — history is sacred).

> Footgun: never `rm -rf <target>/.ralph` to "reset" — that destroys MISSION/RATCHET/state and the
> entire audit trail. Only the lock dir + pid file are disposable.

---

## 3. "Alive but not progressing" triage (the silent zombie)

**Symptom.** `ralph status` says `alive`, but `iteration` isn't climbing, or `stalled: true`, or
`PROGRESS.md` hasn't gained a block in a while. The process is up; work isn't happening.

The loop has three independent detectors so this never reads as false-green:
- **`handle_noop`** — when a `success`-class iteration leaves the tree byte-identical (sha unchanged),
  it is recorded as NOOP (not an advance, not a regression), `noop_streak++`. After 3 consecutive
  noops the loop force-escalates the tier (§9 ladder) instead of spinning.
- **`stalled` heartbeat flag** — set true after N consecutive zero-diff iterations; surfaced by
  `ralph status` as "alive but not progressing".
- **silent-zombie classifier demotion** — an rc-0 run with quota language in the transcript is
  re-classed `rate_limit`, not `success`.

**Diagnose by phase** (`heartbeat.json.phase`, also in `ralph status --json`):

| phase stuck on | meaning | action |
|---|---|---|
| `running_agy` for > `RALPH_AGY_TIMEOUT_S + 60`s | a wedged `agy`; the group-kill watchdog should reclaim it (rc 124 → `timeout`) | wait one watchdog cycle; if it truly never returns, see "wedged worker" below |
| `backoff` | quota / transient crash backoff | §1 quota |
| `crashloop_cooldown` | ≥`RALPH_CRASHLOOP_THRESHOLD` transient/timeout events in `RALPH_CRASHLOOP_WINDOW_S` → cooling down `RALPH_CRASHLOOP_COOLDOWN_S` | look at recent iter logs for the repeating crash; fix root cause (often Antigravity auth/down — §1) |
| `recover_ide` | `language_server` is down; relaunching Antigravity | §1 / make sure Antigravity is allowed to launch |
| `fatal_wait` | `fatal_misconfig` (loud) — agy missing, not authenticated, disk full, etc. | run `ralph doctor`; fix the named check; the loop retries every 300s and resumes on its own |
| `paused` | PAUSE sentinel | `ralph resume` |
| `idle` but iter not advancing | stuck between iterations | check `consecutive_reverts` |

**High revert count (thrash).** If `consecutive_reverts` is large, the agent keeps proposing changes
the ratchet rejects (regressions / not-strictly-better / verify-fail). This is the gate doing its
job — HEAD is *not* getting worse. After `RALPH_MAX_CONSECUTIVE_REVERTS` (default 40) the loop
escalates the tier (it does NOT stop). To investigate: read the last few
`.ralph/iter/NNNNNN/decision.json` (`{decision, cause, ...}`) and the `:: VERDICT … REVERTED` lines
in `PROGRESS.md`, and the `LEDGER.md` REJECTED section for the recurring approach. If the agent is
fighting a genuinely impossible item, add a precise OPEN item or move it to REJECTED with evidence so
it stops retrying.

**Wedged worker that ignores its own timeout.** `agy` is launched with BOTH `--print-timeout
${RALPH_AGY_TIMEOUT_S}s` (cooperative) and wrapped in `bounded_run $((RALPH_AGY_TIMEOUT_S+60))`
(external process-group kill). A hung worker is reclaimed within `RALPH_AGY_TIMEOUT_S + 60`s, rc
normalized to 124, classified `timeout`, the unit abandoned, and the iteration counter advances so
the next fresh `agy` picks a new task. If you truly see `running_agy` persist far beyond that, the
watchdog itself may be blocked (extremely rare) — `ralph stop --hard <target>` then `ralph start`.

---

## 4. How to read the heartbeat & state

Two JSON files under `<target>/.ralph/`, both written atomically (tmp + `mv`):

### `heartbeat.json` — liveness beacon (rewritten at the START and END of every iteration)
```jsonc
{
  "ts": "...", "epoch": 1780000811,
  "target": "<name>", "pid": 48213,
  "iteration": 123, "phase": "running_agy",     // the supervisor state name
  "last_exit_code": 0, "last_class": "success",
  "consecutive_failures": 0, "consecutive_reverts": 0,
  "next_action_eta_s": 0, "backoff_s": 0, "uptime_s": 81234,
  "sha_head": "a1b2c3d",
  "stalled": false                               // true ⇒ alive but N zero-diff iters
}
```
**Deadness test:** `ralph status` declares the loop **dead** (exit 1) when the heartbeat is stale —
its age exceeds roughly `3 × max(backoff_s, 20s)` (the current backoff, floored at 20s, so a long
quota backoff is not mistaken for death). It computes this for you; you rarely compute it by hand.

### `state.json` — supervisor + ratchet resume state (so a launchd relaunch RESUMES, not restarts)
```jsonc
{ "iteration": 123, "advances": 51, "reverts": 71, "noops": 1,
  "consecutive_failures": 0, "consecutive_quota_hits": 2, "consecutive_reverts": 0,
  "noop_streak": 0, "backoff_s": 0,
  "last_class": "success", "last_success_iso": "...", "last_run_started_iso": "...",
  "crash_loop_strikes": 0, "tier": "T2_coverage", "started_iso": "..." }
```
Read it directly with `jq`, or use the wrappers:
```sh
ralph status  <target> --json     # heartbeat + state, summarized
ralph metrics <target> --json     # current floors + best + last measured (RATCHET.json + history)
```

### The scoreboard & memory (human-auditable, all under `<target>/.ralph/`)
- `RATCHET.json` — the multi-metric monotone gate. `best.metrics` are the floors; floors only ever
  tighten on ADVANCE, never loosen.
- `PROGRESS.md` — one block per iteration; the harness appends `:: VERDICT … ACCEPTED/REVERTED`
  AFTER independent measurement (ground truth, not the agent's hope).
- `LEDGER.md` — DONE / REJECTED / OPEN work memory (anti-thrash).
- `HANDOFF.md` — the single latest baton (overwritten each ADVANCE).
- `iterations/NNNNNN.json`, `progress.ndjson`, `metrics/history.jsonl` — append-only audit trails,
  **never deleted**, preserved even across `git reset --hard` (they live under the `-e .ralph`
  clean-exclusion and are git-ignored).
- `iter/NNNNNN/` — per-iteration scratch: `prompt.txt`, `agy.stdout/exit/stderr`, `trailer.json`,
  `verify.log/exit`, `score.raw`, `decision.json`, `referee.log`.

---

## 5. How to STOP and PAUSE

There are two sentinels and two intensities. Both are checked at the top of every iteration AND
inside every interruptible backoff sleep (≤2s tick), so they take effect fast even mid-backoff.

### PAUSE (soft, reversible) — idle but stay alive
```sh
ralph pause  <target>     # touch .ralph/PAUSE  → loop idles, keeps heartbeating, runs no agy
ralph resume <target>     # rm   .ralph/PAUSE  → resumes exactly where it was
```
Use PAUSE for a temporary quota outage, a maintenance window, or to free the machine briefly.
`ralph status` reports `paused` (exit 2). No iteration is consumed while paused.

### STOP (hard drain, halts the loop)
```sh
ralph stop <target>                 # touch .ralph/STOP, then SIGTERM the pid → instant graceful drain
ralph stop <target> --hard          # additionally SIGKILL after 30s if it hasn't drained
ralph stop <target> --permanent     # also `launchctl bootout` the agent so a REBOOT won't resume
```
Mechanics: `touch .ralph/STOP` makes the supervisor break out of its loop on the next check (or it
wakes immediately from a backoff via the SIGTERM trap), then it exits 0. With KeepAlive
`SuccessfulExit=false`, launchd does NOT resurrect a clean exit — so a plain stop stays down WITHOUT
booting out of launchd. **Only `--permanent`** drops a `.ralph/STOP_PERMANENT` marker, which makes the
supervisor `self_bootout_launchd` on itself so even a reboot won't resume. A genuine crash (no STOP
file) is still relaunched. **Kill-switch latency:** halts within `max(RALPH_MIN_INTERVAL_S, ~20s)` —
including mid-`agy`-run, where `bounded_run` proactively group-kills the in-flight agent on SIGTERM.

> **STOP vs reboot-survival.** `ralph stop` (no `--permanent`) leaves the launchd plist *enabled*, so a
> machine reboot WILL resume the loop (RunAtLoad) — intentional ("never stops" across reboots). At the
> next startup the supervisor clears the stale STOP and proceeds, and a plain `ralph start` restarts it
> immediately. Use `--permanent` (or `ralph install-daemon --uninstall`) to keep it gone across reboots.

Emergency manual stop without the CLI: `touch <target>/.ralph/STOP`. The loop drains within ~20s.

---

## 6. How reboot-survival works (and recovery if it didn't)

Two layers of immortality (SPEC §7/§9):
1. **launchd (process immortality).** `ralph install-daemon <target>` renders
   `integrations/launchd/com.ralph.TEMPLATE.plist` → `~/Library/LaunchAgents/com.ralph.<name>.plist`
   with `RunAtLoad=true` and `KeepAlive={SuccessfulExit:false, Crashed:true}`, then bootstraps it.
   On reboot/login launchd restarts the supervisor; on a crash it relaunches it (`ThrottleInterval=30`
   throttles a tight crash-loop).
2. **supervisor (iteration immortality).** The bash supervisor has no terminal state by default; the
   iteration body never calls `exit` — errors `return` and the outer `while true` re-enters. It
   resumes from `state.json` (`resume@iteration`), so a relaunch continues, not restarts.

**Recovery: the loop did NOT come back after a reboot.**
1. Was the daemon ever installed? `launchctl print gui/$(id -u)/com.ralph.<name>` — if "Could not
   find service", you never ran `ralph install-daemon` (a `--daemon` `nohup` start does NOT survive
   reboot; only the launchd agent does). Install it (see §7) and it will survive next time.
2. Daemon exists but didn't start: check the sink `~/.ralph/daemon.log` for bootstrap errors, and
   confirm Antigravity is allowed to run at login (the supervisor relaunches it via `open -ga
   Antigravity`, but the IDE must be authenticated). Kickstart it by hand:
   ```sh
   launchctl kickstart -k gui/$(id -u)/com.ralph.<name>
   ```
3. Was it intentionally stopped `--permanent`? Then the agent was booted out and won't resume by
   design — re-run `ralph install-daemon <target>`.

---

## 7. How to add a target

A "target" is one repo/workspace the loop improves. Each has its own `<target>/.ralph/` runtime dir;
nothing leaks into the target's own tree (`.ralph/` is git-ignored).

```sh
# 1. Scaffold the runtime dir (auto-detects the verify command + metric set, seeds MISSION.md,
#    RATCHET.json, config.env, allow.txt; renames a legacy .ralph_self/ → .ralph/; registers it).
ralph init /abs/path/to/repo --gate referee
#    Optional: --prompt <file>  --mission <file>  --gate none|tests|referee
#    It prints the resolved verify command + the metric set it chose — read this.

# 2. Sanity-check the environment (agy on PATH? Antigravity up & authed? git? disk? config sane?).
ralph doctor /abs/path/to/repo        # must PASS (exit 0); fix any FAIL before starting.

# 3a. Run it attended (foreground, dies with the terminal — good for a first watch):
ralph start /abs/path/to/repo --foreground
# 3b. Run it unattended for this login session (survives terminal close, NOT reboot):
ralph start /abs/path/to/repo --daemon
# 3c. Run it truly forever (survives reboot — Layer 2):
ralph install-daemon /abs/path/to/repo

# 4. Watch it.
ralph status /abs/path/to/repo --watch
ralph list                            # all registered targets with live/dead/paused
```

**After `init`, review before starting:**
- `<target>/.ralph/MISSION.md` — the north star + explicit Success Criteria. The agent never edits it
  (the harness restores it if touched). Make it concrete; vague missions produce cosmetic work.
- `<target>/.ralph/RATCHET.json` — confirm the auto-detected `verify.cmd` and `metrics` are right.
  These define "strictly better." If auto-detect found nothing checkable, `verify.required` is 0 and
  the gate falls back to `absent_policy` — add a real verify command for a meaningful ratchet.
- `<target>/.ralph/allow.txt` — the command allowlist injected into the agent's prompt. Keep it tight;
  it's a key containment layer under `--dangerously-skip-permissions`.

**Tell `ralph init` the target is a git repo with a clean-ish tree.** `init` adds `cache/` and
`.ralph/` to the target's `.gitignore` (agy writes an untracked `cache/`; the ratchet's clean-tree
check must ignore both — see TECH_GROUNDING §1).

**Multiple targets share one Antigravity quota.** Keep `RALPH_BACKOFF_JITTER_PCT > 0` so they don't
re-hammer the rate limit in lockstep, and consider a higher `RALPH_MIN_INTERVAL_S` per target.

---

## 8. Things you must NEVER do (footguns)

- **Never `rm -rf <target>/.ralph`** to "reset" the loop. That deletes MISSION/RATCHET/state and the
  entire append-only audit trail. Only `ralph.lock/` + `ralph.pid` are disposable (§2).
- **Never hand-edit** `MISSION.md`, `RATCHET.json`, or `state.json` while the loop runs — the harness
  restores the canonical copies and reverts the iteration. Change `MISSION.md`/`RATCHET.json` only
  while the loop is stopped, then `ralph start`.
- **Never lower a floor by hand** in `RATCHET.json`. Floors only tighten (INV-2). Lowering one breaks
  the monotonicity guarantee.
- **Never pass `--no-sandbox`** unless you fully understand the containment you're removing.
- **Never enable `--push`** unless the user explicitly asks AND `origin` is a remote they own. The
  `guard_no_push` allowlist refuses foreign remotes and never force-pushes (INV-9); don't bypass it.

---

## 9. Quick command reference

| Need | Command |
|---|---|
| Is it alive? | `ralph status <target>` (exit 0 alive / 1 dead / 2 paused) |
| Why won't it start? | `ralph doctor <target>` (exit 4 = a FAIL) |
| Watch live | `ralph status <target> --watch` · `ralph tail <target>` |
| One iteration only (CI/test) | `ralph once <target>` |
| Pause / resume | `ralph pause <target>` · `ralph resume <target>` |
| Stop (resumes on reboot) | `ralph stop <target>` |
| Stop hard / forever | `ralph stop <target> --hard` · `ralph stop <target> --permanent` |
| Survive reboot | `ralph install-daemon <target>` (remove: `--uninstall`) |
| Emergency halt (no CLI) | `touch <target>/.ralph/STOP` |
| Metrics / floors | `ralph metrics <target> --json` |
| All targets | `ralph list` |
