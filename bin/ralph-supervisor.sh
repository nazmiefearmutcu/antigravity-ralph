#!/usr/bin/env bash
#
# ralph-supervisor.sh — the immortal iteration state machine (SPEC §7).
#
# Role: This is the Layer-1.5 process in the two-layer survival model (SPEC §7.1, R2):
#   launchd (process immortality, §9)  →  THIS supervisor (iteration immortality)  →  disposable `agy`.
# It runs the §7.2 main() state machine VERBATIM in behavior:
#   INIT → PREFLIGHT → GUARD_INTERVAL → RUN_AGY → CLASSIFY →
#          {GATE | BACKOFF | CRASHLOOP_COOLDOWN | RECOVER_IDE | FATAL_WAIT} → PERSIST → (loop)
# The ONLY ways out of the loop body are: the .ralph/STOP sentinel (DRAIN_STOP),
# a SIGTERM/SIGINT-driven WANT_STOP (DRAIN_STOP), or --max-iterations being reached
# (MAX_ITERATIONS_REACHED). NO `exit` is ever reached from inside the loop body (INV-5):
# every error class `return`s/`continue`s and the outer `while true` re-enters.
#
# Spec sections implemented here: §7.1 (states), §7.2 (main loop), §7.3 (backoff cadence
# invocation), §6.1/§6.3 (bounded_run + lock usage), §9.1 (self_bootout_launchd on STOP-drain),
# §10 (rotate_if_big invocation). The ratchet (§5) is delegated to lib/ratchet.sh::run_one_iteration.
#
# Bash compatibility: This file uses NO associative arrays and NO namerefs at this layer
# (those live in lib/ratchet.sh, which the integrator runs under a 4+ bash). The supervisor
# itself is plain POSIX-ish bash and works under macOS /bin/bash 3.2. The CLI (bin/ralph)
# is responsible for re-exec'ing under a >=4 bash when one is available; we do not duplicate
# that here, but we deliberately avoid any 4-only construct so this layer can run anywhere.
#
# Sourcing safety: this file is normally EXEC'd (it has a main()). If it is sourced (e.g. by a
# test harness) the include guard below makes a second source a no-op, and main() is NOT run
# unless invoked explicitly.

# ── include guard (source-twice safe) ─────────────────────────────────────────
if [ -n "${__RALPH_SUPERVISOR_SH_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
__RALPH_SUPERVISOR_SH_LOADED=1

set -uo pipefail   # NOT -e: the loop body must survive non-zero returns (INV-5).

# ── locate our own dir + the lib dir robustly ─────────────────────────────────
# Works whether invoked as bin/ralph-supervisor.sh in-repo, symlinked into ~/.local/bin,
# or exec'd by `ralph __run-supervisor`. Resolves symlinks without relying on GNU readlink -f.
__ralph_resolve_self() {
  local src="${BASH_SOURCE[0]}" dir
  while [ -h "$src" ]; do
    dir="$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)"
    src="$(readlink "$src")"
    case "$src" in
      /*) : ;;                 # absolute
      *)  src="$dir/$src" ;;   # relative to the link's dir
    esac
  done
  cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd
}
RALPH_BIN_DIR="$(__ralph_resolve_self)"
RALPH_HOME="$(cd -P "$RALPH_BIN_DIR/.." >/dev/null 2>&1 && pwd)"

# lib/ install-path resolution (SPEC §9.1): repo lib/ when run in-repo, else the installed copy.
if [ -d "$RALPH_HOME/lib" ] && [ -f "$RALPH_HOME/lib/state.sh" ]; then
  RALPH_LIB_DIR="$RALPH_HOME/lib"
elif [ -n "${RALPH_LIB_DIR:-}" ] && [ -d "$RALPH_LIB_DIR" ]; then
  : # honor an explicit override
elif [ -d "$HOME/.local/share/ralph/lib" ]; then
  RALPH_LIB_DIR="$HOME/.local/share/ralph/lib"
else
  RALPH_LIB_DIR="$RALPH_HOME/lib"   # last resort; sourcing will fail loudly below
fi
export RALPH_LIB_DIR RALPH_HOME RALPH_BIN_DIR

# ── source the library layer (functions defined by the other groups) ──────────
# These provide: bounded_run; classify_result/agy_reachable/recover_agy_substrate;
# expo_backoff_jitter/sleep_interruptible/enforce_min_interval/crashloop_tripped/
# record_crashloop_event/reset_crashloop_window; acquire_lock_or_exit/release_lock/
# write_pid/set_state/bump/persist_state_atomic/heartbeat/final_heartbeat/write_iter_meta/
# get_state; render_prompt; run_one_iteration/revert_dirty_to.
for __libf in bounded classify backoff state ratchet gate prompt; do
  if [ -f "$RALPH_LIB_DIR/$__libf.sh" ]; then
    # shellcheck disable=SC1090
    . "$RALPH_LIB_DIR/$__libf.sh"
  fi
done
unset __libf

# ── small local helpers (only those not owned by a lib group) ─────────────────
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# min A B → smaller integer (used for the timeout-class linear backoff, §7.2).
min() {
  if [ "$1" -le "$2" ]; then printf '%s\n' "$1"; else printf '%s\n' "$2"; fi
}

# log <msg> → timestamped line to the supervisor log + stderr (launchd captures stderr).
log() {
  local line; line="$(now) [sup pid=$$ iter=${ITER:-?}] $*"
  printf '%s\n' "$line" >>"$SUP_LOG" 2>/dev/null || true
  printf '%s\n' "$line" >&2 2>/dev/null || true
}

# A defensive no-op fallback so the loop never dies if a lib helper is missing.
# (Each is overridden the moment the real lib defines it — these only fire if a
#  group's file was not installed, keeping INV-5 true even under partial install.)
if ! command -v heartbeat >/dev/null 2>&1;            then heartbeat() { :; }; fi
if ! command -v final_heartbeat >/dev/null 2>&1;      then final_heartbeat() { :; }; fi
if ! command -v set_state >/dev/null 2>&1;            then set_state() { :; }; fi
if ! command -v bump >/dev/null 2>&1;                 then bump() { :; }; fi
if ! command -v get_state >/dev/null 2>&1;            then get_state() { jq -r ".$1 // empty" .ralph/state.json 2>/dev/null; }; fi
if ! command -v persist_state_atomic >/dev/null 2>&1; then persist_state_atomic() { :; }; fi
if ! command -v write_iter_meta >/dev/null 2>&1;      then write_iter_meta() { :; }; fi
if ! command -v enforce_min_interval >/dev/null 2>&1; then enforce_min_interval() { :; }; fi
if ! command -v crashloop_tripped >/dev/null 2>&1;    then crashloop_tripped() { return 1; }; fi
if ! command -v record_crashloop_event >/dev/null 2>&1; then record_crashloop_event() { :; }; fi
if ! command -v reset_crashloop_window >/dev/null 2>&1; then reset_crashloop_window() { :; }; fi
if ! command -v recover_agy_substrate >/dev/null 2>&1; then recover_agy_substrate() { return 0; }; fi
if ! command -v agy_reachable >/dev/null 2>&1;        then agy_reachable() { pgrep -f 'language_server' >/dev/null 2>&1; }; fi
if ! command -v rotate_if_big >/dev/null 2>&1;        then rotate_if_big() { :; }; fi

# self_bootout_launchd lives in §9.1; provide a faithful local impl if no lib supplies it.
if ! command -v self_bootout_launchd >/dev/null 2>&1; then
  self_bootout_launchd() {
    # On an intended STOP drain, remove ourselves from launchd so KeepAlive=SuccessfulExit:false
    # cannot resurrect us (the "resurrection paradox", §9.1). A genuine crash (no STOP file)
    # leaves the plist in place so launchd relaunches.
    local name="${RALPH_TARGET_NAME:-$(basename "$TARGET" 2>/dev/null)}"
    [ -n "$name" ] || return 0
    local label="com.ralph.$name"
    if command -v launchctl >/dev/null 2>&1; then
      launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
    fi
  }
fi

# ── configuration load (SPEC §3.6) ────────────────────────────────────────────
# Defaults mirror config.env exactly; .ralph/config.env overrides; env already set wins last
# only via SIGHUP reload (a fresh source). We export so child `agy`/verify see them.
load_config() {
  # Hard defaults (verbatim from §3.6).
  : "${RALPH_TARGET_NAME:=$(basename "$TARGET")}"
  : "${RALPH_MAX_ITERATIONS:=0}"
  : "${RALPH_MIN_INTERVAL_S:=20}"
  : "${RALPH_AGY_TIMEOUT_S:=900}"
  : "${RALPH_BACKOFF_BASE_S:=30}"
  : "${RALPH_BACKOFF_CAP_S:=1800}"
  : "${RALPH_BACKOFF_JITTER_PCT:=25}"
  : "${RALPH_CRASHLOOP_THRESHOLD:=5}"
  : "${RALPH_CRASHLOOP_WINDOW_S:=300}"
  : "${RALPH_CRASHLOOP_COOLDOWN_S:=600}"
  : "${RALPH_MAX_CONSECUTIVE_REVERTS:=40}"
  : "${RALPH_RELAUNCH_ANTIGRAVITY:=1}"
  : "${RALPH_SKIP_PERMISSIONS:=1}"
  : "${RALPH_SANDBOX:=1}"
  : "${RALPH_COMMIT_GATE:=referee}"
  : "${RALPH_REFEREE_EVERY:=10}"
  : "${RALPH_PUSH:=0}"
  : "${RALPH_REVERT_STRATEGY:=reset_hard}"
  : "${RALPH_VERIFY_REQUIRED:=1}"
  : "${RALPH_PROMPT_FILE:=prompts/iterate.tmpl}"

  # Per-target overrides (KEY=VALUE only, sourced). These override the built-in defaults above.
  if [ -f .ralph/config.env ]; then
    set -a
    # shellcheck disable=SC1091
    . .ralph/config.env
    set +a
  fi

  # PER-RUN CLI overrides MUST win over config.env (SPEC §3.6: "all overridable by ralph flags").
  # They arrive as RALPH_OVERRIDE — a newline-separated list of KEY=VALUE set by `ralph start
  # --flags` / `ralph once` — applied AFTER config.env so the flag for THIS run is authoritative.
  # (Plain env vars cannot do this: `. config.env` re-assigns them. This dedicated channel can.)
  if [ -n "${RALPH_OVERRIDE:-}" ]; then
    local _ol _ok _ov
    while IFS= read -r _ol; do
      [ -n "$_ol" ] || continue
      _ok="${_ol%%=*}"; _ov="${_ol#*=}"
      case "$_ok" in
        RALPH_*) printf -v "$_ok" '%s' "$_ov" 2>/dev/null && export "$_ok" ;;
      esac
    done <<RALPH_OVR_EOF
$RALPH_OVERRIDE
RALPH_OVR_EOF
  fi

  # ── Resolve the VERIFY contract from RATCHET.json and BRIDGE it to the UNPREFIXED names the ratchet
  #    library actually reads (lib/ratchet.sh: VERIFY_CMD / VERIFY_REQUIRED / VERIFY_TIMEOUT_S /
  #    SCORE_TIMEOUT_S / FLAKY_REVERIFY_RUNS). Without this, measure_verify runs `${VERIFY_CMD:-true}`
  #    — i.e. verify ALWAYS passes — and the entire "strictly better" verify dimension is dead. The
  #    RATCHET.json verify block is the per-target authoritative contract (frozen at `ralph init`). ──
  local _rj=.ralph/RATCHET.json _cano=.ralph/.canonical/RATCHET.cmds.json
  if [ -f "$_rj" ]; then
    local _vc _vt _vr _fr
    # verify.cmd is EXECUTED → take it from the operator-canonical snapshot (RCE guard), not the
    # agent-writable RATCHET.json. Live file only as fallback when no canonical exists (hand-scaffolded).
    if [ -f "$_cano" ]; then _vc="$(jq -r '.verify // ""' "$_cano" 2>/dev/null)"; else _vc=""; fi
    [ -n "$_vc" ] || _vc="$(jq -r '.verify.cmd // ""'     "$_rj" 2>/dev/null)"
    _vt="$(jq -r '.verify.timeout_s // 900'       "$_rj" 2>/dev/null)"
    _vr="$(jq -r 'if .verify.required==false then 0 else 1 end' "$_rj" 2>/dev/null)"
    _fr="$(jq -r '.verify.flaky_reverify_runs // 2' "$_rj" 2>/dev/null)"
    case "$_vc" in
      ""|null|AUTO|AUTO:*) VERIFY_CMD="true"; _vr=0 ;;   # nothing checkable → verify advisory (metrics gate)
      *)                   VERIFY_CMD="$_vc" ;;
    esac
    VERIFY_TIMEOUT_S="$_vt"; SCORE_TIMEOUT_S="$_vt"; FLAKY_REVERIFY_RUNS="$_fr"; VERIFY_REQUIRED="$_vr"
  else
    VERIFY_CMD="${VERIFY_CMD:-true}"; VERIFY_REQUIRED="${RALPH_VERIFY_REQUIRED:-1}"
    VERIFY_TIMEOUT_S="${VERIFY_TIMEOUT_S:-900}"; SCORE_TIMEOUT_S="${SCORE_TIMEOUT_S:-900}"
    FLAKY_REVERIFY_RUNS="${FLAKY_REVERIFY_RUNS:-2}"
  fi
  # Referee sandbox flag (gate.sh reads it; the worker also derives its own from RALPH_SANDBOX).
  SANDBOX_FLAG=""; [ "${RALPH_SANDBOX:-1}" = 1 ] && SANDBOX_FLAG="--sandbox"

  export RALPH_TARGET_NAME RALPH_MAX_ITERATIONS RALPH_MIN_INTERVAL_S RALPH_AGY_TIMEOUT_S \
         RALPH_BACKOFF_BASE_S RALPH_BACKOFF_CAP_S RALPH_BACKOFF_JITTER_PCT \
         RALPH_CRASHLOOP_THRESHOLD RALPH_CRASHLOOP_WINDOW_S RALPH_CRASHLOOP_COOLDOWN_S \
         RALPH_MAX_CONSECUTIVE_REVERTS RALPH_RELAUNCH_ANTIGRAVITY RALPH_SKIP_PERMISSIONS \
         RALPH_SANDBOX RALPH_COMMIT_GATE RALPH_REFEREE_EVERY RALPH_PUSH \
         RALPH_REVERT_STRATEGY RALPH_VERIFY_REQUIRED RALPH_PROMPT_FILE \
         VERIFY_CMD VERIFY_REQUIRED VERIFY_TIMEOUT_S SCORE_TIMEOUT_S FLAKY_REVERIFY_RUNS SANDBOX_FLAG
}

# load_or_init_state — read iteration counter so a launchd-relaunched supervisor RESUMES
# (not restarts). Delegates the real schema write to lib/state.sh::set_state when present.
load_or_init_state() {
  mkdir -p .ralph/iter .ralph/iterations .ralph/metrics .ralph/logs .ralph/archive .ralph/refs
  if [ ! -f .ralph/state.json ]; then
    # Seed a minimal valid state.json atomically; lib/state.py owns the rich schema thereafter.
    local tmp=.ralph/state.json.tmp
    cat >"$tmp" <<JSON
{"iteration":0,"advances":0,"reverts":0,"noops":0,"consecutive_failures":0,
"consecutive_quota_hits":0,"consecutive_reverts":0,"noop_streak":0,"backoff_s":0,
"last_class":"none","last_success_iso":"","last_run_started_iso":"",
"crash_loop_strikes":0,"tier":"T1_correctness","started_iso":"$(now)"}
JSON
    if jq . "$tmp" >/dev/null 2>&1; then mv -f "$tmp" .ralph/state.json; else rm -f "$tmp"; fi
  fi
  ITER="$(jq -r '.iteration // 0' .ralph/state.json 2>/dev/null)"
  case "$ITER" in ''|*[!0-9]*) ITER=0 ;; esac
}

# ── signal handling (SPEC §7.2 install_signal_traps) ──────────────────────────
# SIGTERM/SIGINT → WANT_STOP=1 (graceful drain). SIGHUP → reload config (no restart).
WANT_STOP=0
WANT_RELOAD=0
install_signal_traps() {
  trap '__on_term'   TERM INT
  trap '__on_reload' HUP
  # Best-effort cleanup on EXIT; the real lock/pid removal lives in lib/state.sh's EXIT trap too,
  # but we keep a guarded fallback so a partial-install supervisor still tidies up.
  trap '__on_exit' EXIT
}
__on_term()   { WANT_STOP=1; }
__on_reload() { WANT_RELOAD=1; }
__on_exit()   {
  # Only remove our own artifacts; never clobber another live owner.
  [ -f .ralph/ralph.pid ] && [ "$(cat .ralph/ralph.pid 2>/dev/null)" = "$$" ] && rm -f .ralph/ralph.pid 2>/dev/null || true
  if [ -d .ralph/ralph.lock ] && [ "$(cat .ralph/ralph.lock/owner.pid 2>/dev/null)" = "$$" ]; then
    rm -rf .ralph/ralph.lock 2>/dev/null || true
  fi
}

# write_pid — atomic write+rename (SPEC §2.2 ralph.pid contract).
if ! command -v write_pid >/dev/null 2>&1; then
  write_pid() {
    printf '%s\n' "$$" > .ralph/ralph.pid.tmp && mv -f .ralph/ralph.pid.tmp .ralph/ralph.pid
  }
fi
if ! command -v release_lock >/dev/null 2>&1; then
  release_lock() {
    if [ -d .ralph/ralph.lock ] && [ "$(cat .ralph/ralph.lock/owner.pid 2>/dev/null)" = "$$" ]; then
      rm -rf .ralph/ralph.lock 2>/dev/null || true
    fi
  }
fi
# acquire_lock_or_exit fallback (faithful to §6.3) if lib/state.sh is absent.
if ! command -v acquire_lock_or_exit >/dev/null 2>&1; then
  acquire_lock_or_exit() {
    local lock=.ralph/ralph.lock
    if mkdir "$lock" 2>/dev/null; then echo $$ > "$lock/owner.pid"; return; fi
    local owner; owner="$(cat "$lock/owner.pid" 2>/dev/null)"
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
      echo "ralph: already running for this target (pid $owner)" >&2; exit 3
    fi
    rm -rf "$lock"; mkdir "$lock"; echo $$ > "$lock/owner.pid"
  }
fi

# ── THE STATE MACHINE (SPEC §7.2 main()) ──────────────────────────────────────
main() {
  TARGET="${1:-$PWD}"
  # Normalize to an absolute path and chdir; all .ralph/ paths are relative to the target root.
  if [ -d "$TARGET" ]; then
    TARGET="$(cd "$TARGET" >/dev/null 2>&1 && pwd)"
  fi
  cd "$TARGET" || { printf 'ralph-supervisor: cannot cd to target %s\n' "$TARGET" >&2; exit 1; }
  if [ ! -d .ralph ]; then
    printf 'ralph-supervisor: %s has no .ralph/ (run: ralph init)\n' "$TARGET" >&2
    exit 4
  fi

  REPO_ROOT="$TARGET"
  export TARGET REPO_ROOT
  SUP_LOG=".ralph/logs/supervisor.log"
  mkdir -p .ralph/logs

  load_config
  acquire_lock_or_exit          # §6.3 mkdir mutex + stale-PID steal; exit 3 if a live owner holds it
  write_pid                     # §2.2 atomic pid file
  load_or_init_state            # resume @ iteration
  # STOP semantics at startup:
  #   - STOP_PERMANENT present → the operator asked to stay down (`ralph stop --permanent`); ensure a
  #     STOP sentinel exists so we drain immediately even if launchd relaunched us.
  #   - else a plain stale STOP from a PRIOR run is CLEARED so an explicit restart / reboot-relaunch
  #     actually proceeds (a leftover STOP would otherwise drain us instantly). `ralph stop` re-touches
  #     STOP on the LIVE instance, so in-run stops are unaffected.
  if [ -f .ralph/STOP_PERMANENT ]; then
    log "STOP_PERMANENT set → staying stopped"; touch .ralph/STOP
  elif [ -f .ralph/STOP ]; then
    log "clearing stale STOP sentinel from a prior run"; rm -f .ralph/STOP
  fi
  install_signal_traps          # §7.2: TERM/INT→WANT_STOP, HUP→reload
  set -m                        # job control so agy children get their own pgid (bounded_run, §6.1)

  STATE=RUNNING
  phase=init; heartbeat
  log "supervisor up pid=$$ target=$TARGET resume@iter=$ITER lib=$RALPH_LIB_DIR"

  while true; do
    # Honor a pending SIGHUP reload before anything else this turn.
    if [ "$WANT_RELOAD" = 1 ]; then WANT_RELOAD=0; load_config; log "config reloaded (SIGHUP)"; fi

    # ── TERMINATION CHECKS (the ONLY ways out — INV-5) ──
    if [ -f .ralph/STOP ]; then phase=draining; heartbeat; STATE=DRAIN_STOP; break; fi
    if [ "$WANT_STOP" = 1 ]; then STATE=DRAIN_STOP; break; fi
    # -ge so `--max-iterations N` runs EXACTLY N units from a fresh target (ITER starts at 0, is
    # incremented AFTER each resolved unit): iter 0..N-1 run, then ITER==N stops.
    if [ "$RALPH_MAX_ITERATIONS" -gt 0 ] && [ "$ITER" -ge "$RALPH_MAX_ITERATIONS" ]; then
      STATE=MAX_ITERATIONS_REACHED; break
    fi

    # ── SOFT PAUSE (heartbeat continues; no agy) ──
    while [ -f .ralph/PAUSE ] && [ ! -f .ralph/STOP ]; do
      phase=paused; heartbeat; sleep_interruptible 10
      [ "$WANT_STOP" = 1 ] && break
    done
    # If a STOP/SIGTERM arrived during pause, loop to the top to take the exit path.
    if [ -f .ralph/STOP ] || [ "$WANT_STOP" = 1 ]; then continue; fi

    # ── PREFLIGHT ──
    phase=preflight; heartbeat
    agy_reachable || recover_agy_substrate     # §7.4 relaunch language_server / Antigravity

    # ── CRASH-LOOP GUARD (GUARD_INTERVAL) ──
    enforce_min_interval "$RALPH_MIN_INTERVAL_S"   # cadence floor since last_run_started (§7.3)
    if crashloop_tripped; then
      phase=crashloop_cooldown; backoff_s="$RALPH_CRASHLOOP_COOLDOWN_S"
      set_state backoff_s "$backoff_s"; heartbeat
      log "CRASHLOOP → cooldown ${backoff_s}s"
      sleep_interruptible "$backoff_s"
      reset_crashloop_window
      continue                                     # do NOT burn an iteration
    fi

    # ── RUN ONE UNIT (RUN_AGY) ──
    phase=running_agy; set_state last_run_started_iso "$(now)"; heartbeat
    ITDIR=".ralph/iter/$(printf '%06d' "$ITER")"; mkdir -p "$ITDIR"
    export ITDIR
    PROMPT="$(render_prompt "$ITER")"
    printf '%s' "$PROMPT" > "$ITDIR/prompt.txt"
    sha_before="$(git -C "$TARGET" rev-parse --short HEAD 2>/dev/null || echo none)"

    # Build the agy flag set per config (§7.2). --print-timeout is cooperative; bounded_run is
    # the external belt-and-suspenders wall (§6.1) at AGY_TIMEOUT_S+60 → rc 124 on a wedged worker.
    set -- agy -p "$PROMPT" --add-dir "$TARGET" --print-timeout "${RALPH_AGY_TIMEOUT_S}s"
    [ "$RALPH_SKIP_PERMISSIONS" = 1 ] && set -- "$@" --dangerously-skip-permissions
    [ "$RALPH_SANDBOX" = 1 ]          && set -- "$@" --sandbox

    bounded_run "$((RALPH_AGY_TIMEOUT_S + 60))" "$ITDIR/agy.stdout" -- "$@"
    rc=$?
    printf '%s\n' "$rc" > "$ITDIR/agy.exit"
    sha_after="$(git -C "$TARGET" rev-parse --short HEAD 2>/dev/null || echo none)"

    # ── CLASSIFY (§7.4) ──
    class="$(classify_result "$rc" "$ITDIR/agy.stdout")"
    set_state last_class "$class"
    write_iter_meta "$ITDIR" "$rc" "$class" "$sha_before" "$sha_after"
    log "iter=$ITER rc=$rc class=$class sha=${sha_before}->${sha_after}"

    case "$class" in
      success)
        set_state consecutive_failures 0
        set_state consecutive_quota_hits 0
        backoff_s=0; set_state backoff_s 0
        # The ratchet's baseline is the PRE-agy HEAD. agy has already committed by now, so HEAD is the
        # CANDIDATE; run_one_iteration MUST be told sha_before explicitly (resolution order #1) or it
        # would mistake base==cand and score every first iteration as a phantom NOOP.
        export RALPH_BASE_COMMIT="$sha_before"
        # §5 — the ratchet gate (ADVANCE/REVERT) runs as the iteration BODY. It must never exit.
        run_one_iteration || log "run_one_iteration returned non-zero (handled, loop continues)"
        unset RALPH_BASE_COMMIT
        set_state last_success_iso "$(now)"
        ITER=$((ITER + 1)); set_state iteration "$ITER"   # unit attempted (R8)
        [ "${RALPH_ONCE:-0}" = 1 ] && { log "RALPH_ONCE: one unit resolved (gate ran) → draining"; WANT_STOP=1; }
        ;;
      rate_limit)
        bump consecutive_quota_hits
        # A silent-zombie rc=0→rate_limit demotion (classify.sh) can leave agy's ungated edits/commit
        # in the tree. Reclaim them before retrying so the next attempt starts from the last good state
        # (no-op when the tree is already clean, i.e. a normal quota error that did no work).
        revert_dirty_to "$sha_before"
        backoff_s="$(expo_backoff_jitter "$(get_state consecutive_quota_hits)")"
        set_state backoff_s "$backoff_s"
        phase=backoff; heartbeat
        log "RATE_LIMIT → backoff ${backoff_s}s (retry SAME iter $ITER)"
        sleep_interruptible "$backoff_s"
        continue                                       # retry SAME iteration; floor untouched (R8)
        ;;
      timeout)
        # A timeout = agy's cooperative --print-timeout/deadline, its SIGNATURE soft response-timeout
        # ("timed out waiting for response", rc 143), or the bounded_run wall-clock kill (rc 124). On
        # long units agy OFTEN finishes the work and COMMITS *before* the wrapper reports the timeout,
        # so a timeout is NOT inherently lost work. Decide by whether HEAD moved:
        #   • HEAD moved  → agy committed a real candidate. Run the §5 ratchet to keep-if-strictly-better
        #     (or revert) EXACTLY like success — never `git reset --hard` a committed unit blindly.
        #   • HEAD same   → genuinely wedged / nothing produced. Reclaim the dirty tree and back off.
        # EITHER WAY advance the iteration (R8). The old code routed agy's soft-timeout to transient_crash
        # (`continue`, retry the SAME iter forever) — wedging the loop at iter 0; advancing here is the fix.
        set_state consecutive_quota_hits 0
        if [ "$sha_after" != "$sha_before" ] && [ "$sha_before" != none ] && [ "$sha_after" != none ]; then
          set_state consecutive_failures 0
          backoff_s=0; set_state backoff_s 0
          export RALPH_BASE_COMMIT="$sha_before"
          log "TIMEOUT iter=$ITER but agy committed ${sha_before}->${sha_after} → ratchet the candidate, advance"
          run_one_iteration || log "run_one_iteration returned non-zero (handled, loop continues)"
          unset RALPH_BASE_COMMIT
          set_state last_success_iso "$(now)"
        else
          bump consecutive_failures; record_crashloop_event
          log "TIMEOUT iter=$ITER (no commit) → reclaim wedged work, backoff & advance"
          revert_dirty_to "$sha_before"                  # abandon wedged partial work
          local _cf; _cf="$(get_state consecutive_failures)"; case "$_cf" in ''|*[!0-9]*) _cf=1 ;; esac
          backoff_s="$(min 120 $((30 * _cf)))"
          set_state backoff_s "$backoff_s"
          phase=backoff; heartbeat
          sleep_interruptible "$backoff_s"
        fi
        ITER=$((ITER + 1)); set_state iteration "$ITER" # unit resolved → advance to a fresh task (R8)
        [ "${RALPH_ONCE:-0}" = 1 ] && { log "RALPH_ONCE: one unit resolved (timeout) → draining"; WANT_STOP=1; }
        ;;
      transient_crash)
        # A genuine non-zero crash with no recognized timeout/quota/fatal signal. R8: NORMALLY retry the
        # SAME iteration (a substrate hiccup that recovery clears). Two guarantees keep this from ever
        # WEDGING the loop (the never-progress arm of INV-5), symmetric with the timeout fix above:
        #   • commit-aware: if agy committed before crashing (HEAD moved), ratchet the candidate + advance
        #     instead of blindly `git reset --hard`-ing real work away.
        #   • forced-advance escape hatch: a DETERMINISTIC crash that repeats on one poison unit must not
        #     freeze ITER forever. After RALPH_CRASHLOOP_THRESHOLD consecutive failures on this iter we
        #     abandon the unit and advance to a fresh task (loud, still immortal — never `exit`).
        bump consecutive_failures; record_crashloop_event
        recover_agy_substrate
        if [ "$sha_after" != "$sha_before" ] && [ "$sha_before" != none ] && [ "$sha_after" != none ]; then
          set_state consecutive_failures 0
          backoff_s=0; set_state backoff_s 0
          export RALPH_BASE_COMMIT="$sha_before"
          log "TRANSIENT_CRASH rc=$rc but agy committed ${sha_before}->${sha_after} → ratchet the candidate, advance"
          run_one_iteration || log "run_one_iteration returned non-zero (handled, loop continues)"
          unset RALPH_BASE_COMMIT
          set_state last_success_iso "$(now)"
          ITER=$((ITER + 1)); set_state iteration "$ITER"
        else
          revert_dirty_to "$sha_before"
          local _cf; _cf="$(get_state consecutive_failures)"; case "$_cf" in ''|*[!0-9]*) _cf=1 ;; esac
          backoff_s="$(expo_backoff_jitter "$_cf")"
          set_state backoff_s "$backoff_s"
          phase=backoff; heartbeat
          if [ "$_cf" -ge "$RALPH_CRASHLOOP_THRESHOLD" ]; then
            log "TRANSIENT_CRASH rc=$rc → $_cf consecutive on iter $ITER (poison unit) → abandon & ADVANCE (never wedge)"
            set_state consecutive_failures 0; reset_crashloop_window
            sleep_interruptible "$backoff_s"
            ITER=$((ITER + 1)); set_state iteration "$ITER"
          else
            log "TRANSIENT_CRASH rc=$rc → recover+backoff ${backoff_s}s (retry SAME iter $ITER)"
            sleep_interruptible "$backoff_s"
            continue                                   # retry SAME iteration (R8)
          fi
        fi
        [ "${RALPH_ONCE:-0}" = 1 ] && { log "RALPH_ONCE: one unit resolved (transient) → draining"; WANT_STOP=1; }
        ;;
      fatal_misconfig)
        bump consecutive_failures
        phase=fatal_wait; heartbeat
        log "FATAL_MISCONFIG (loud) → wait 300s & retry, NEVER exit (INV-5)"
        sleep_interruptible 300
        continue                                       # a human/launchd env-fix may resolve it
        ;;
      *)
        # Unknown class: treat as transient so the loop never dies (INV-5) — WITH the same forced-advance
        # escape hatch as transient_crash so an unrecognized repeating failure cannot wedge ITER forever.
        bump consecutive_failures; record_crashloop_event
        revert_dirty_to "$sha_before"
        local _cu; _cu="$(get_state consecutive_failures)"; case "$_cu" in ''|*[!0-9]*) _cu=1 ;; esac
        backoff_s="$(expo_backoff_jitter "$_cu")"
        set_state backoff_s "$backoff_s"; phase=backoff; heartbeat
        if [ "$_cu" -ge "$RALPH_CRASHLOOP_THRESHOLD" ]; then
          log "UNKNOWN class='$class' rc=$rc → $_cu consecutive on iter $ITER → abandon & ADVANCE (never wedge)"
          set_state consecutive_failures 0; reset_crashloop_window
          sleep_interruptible "$backoff_s"
          ITER=$((ITER + 1)); set_state iteration "$ITER"
        else
          log "UNKNOWN class='$class' rc=$rc → treat as transient, backoff ${backoff_s}s (retry SAME iter $ITER)"
          sleep_interruptible "$backoff_s"
          continue
        fi
        ;;
    esac

    # ── PERSIST ──
    phase=persist; persist_state_atomic; rotate_if_big; phase=idle; heartbeat
  done

  log "supervisor exiting state=$STATE iter=$ITER"
  # Only a PERMANENT stop boots us out of launchd. A plain `ralph stop` exits 0; with KeepAlive
  # SuccessfulExit=false launchd will NOT resurrect a clean exit, yet the plist stays registered so a
  # reboot (RunAtLoad) resumes — and the next startup clears the stale STOP and proceeds. This removes
  # the §9.1 "resurrection paradox" without the contradiction the docs reviewer flagged.
  if [ -f .ralph/STOP_PERMANENT ]; then
    self_bootout_launchd
  fi
  release_lock
  final_heartbeat stopped
  # A clean, intended end. (No `exit N` from the loop body ever reached here — INV-5.)
  exit 0
}

# Only run main() when executed directly, not when sourced (e.g. by tests).
# BASH_SOURCE[0] == $0 ⇒ executed as a script.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
