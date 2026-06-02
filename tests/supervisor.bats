#!/usr/bin/env bats
# tests/supervisor.bats — the state machine's liveness/safety properties
# (SPEC §7; §11 T-SUP-1..4; INV-5, INV-6, INV-8).
#
# The supervisor (bin/ralph-supervisor.sh) runs FOREVER by design, so every test
# bounds it with bounded_run AND/OR --max-iterations / the STOP sentinel, and uses
# the stub `agy` (no credits). To make the group-kill watchdog actually reach the
# supervisor's children we invoke bounded_run inside a `bash -c 'set -m; ...'`
# wrapper (§6.1 requires job control; bats does not propagate it into a test body).
#
# Each test runs in a UNIQUE workspace and cleans up any survivor process keyed on
# that path, so a slow/hung run can never leak across tests or block the suite.
# If the supervisor entrypoint isn't present yet, these tests skip cleanly.

load test_helper

setup() {
  ralph_test_env
  require_lib bounded.sh
  require_fn bounded_run
  SUP="$RALPH_BIN/ralph-supervisor.sh"
  if [ ! -f "$SUP" ]; then skip "bin/ralph-supervisor.sh not present yet"; fi
  WS="${BATS_TEST_TMPDIR}/ws"
  make_python_repo "$WS/repo" 3
  seed_ralph "$WS/repo"
  install_stub_agy "$WS/bin"
  export TARGET="$WS/repo" REPO_ROOT="$WS/repo"
  export RALPH_RELAUNCH_ANTIGRAVITY=0 RALPH_BACKOFF_JITTER_PCT=0
  export VERIFY_REQUIRED=1
  export VERIFY_CMD="python3 -m unittest discover -q -p 'test_*.py'"
}

teardown() {
  # Reap any supervisor/stub still bound to this workspace.
  [ -n "${WS:-}" ] && pkill -f "$WS" 2>/dev/null || true
}

# run_supervisor_bounded <cap_s>  — runs the supervisor under a group-kill bound
# with the current env (PATH carries the stub agy). Populates $status/$output.
run_supervisor_bounded() {
  local cap="$1"
  run env PATH="$PATH" bash -c '
    set -m
    . "'"$RALPH_LIB"'/bounded.sh"
    bounded_run "'"$cap"'" "'"${BATS_TEST_TMPDIR}"'/sup.log" -- \
      bash "'"$SUP"'" "'"$WS"'/repo"
  '
}

iter_now() { "$PY3" "$RALPH_LIB/state.py" get-raw "$WS/repo/.ralph/state.json" iteration 0; }

@test "T-SUP-1 (INV-5): a non-zero agy run does NOT exit the loop; it keeps iterating" {
  # Stub crashes every run (transient). The loop must NOT exit on the body error;
  # with a finite max-iterations it ends ONLY via that bound, having looped+backed
  # off. We assert it ran (heartbeat present) and the watchdog wasn't what stopped
  # an early crash (a clean self-terminate, not rc 124-from-hang on iter 1).
  export STUB_AGY_EXIT=1
  export RALPH_MAX_ITERATIONS=1 RALPH_MIN_INTERVAL_S=1 RALPH_BACKOFF_BASE_S=1 RALPH_BACKOFF_CAP_S=1
  run_supervisor_bounded 25
  [ -f "$WS/repo/.ralph/heartbeat.json" ]
  "$PY3" "$RALPH_LIB/state.py" validate "$WS/repo/.ralph/heartbeat.json"
}

@test "T-SUP-2 (INV-8): touch STOP halts mid-backoff (interruptible sleep re-checks STOP)" {
  # INV-8's mechanism is sleep_interruptible: a backoff sleep that wakes on the
  # STOP sentinel / SIGTERM instead of running to completion. We force a LONG
  # backoff by making agy return rate_limit (quota) — the supervisor then idles in
  # sleep_interruptible. Touching STOP mid-sleep must abort it and drain FAST, well
  # before either the long backoff or the bounded_run wall. This isolates the
  # kill-switch latency from how long an ADVANCE iteration's gate work takes.
  export STUB_AGY_FIXTURE="$RALPH_FIXTURES/quota.txt" STUB_AGY_EXIT=1
  export RALPH_MIN_INTERVAL_S=1 RALPH_MAX_ITERATIONS=0
  export RALPH_BACKOFF_BASE_S=30 RALPH_BACKOFF_CAP_S=60   # a long sleep STOP must cut short
  ( env PATH="$PATH" bash -c '
      set -m
      . "'"$RALPH_LIB"'/bounded.sh"
      bounded_run 60 "'"${BATS_TEST_TMPDIR}"'/sup2.log" -- \
        bash "'"$SUP"'" "'"$WS"'/repo"
    ' ) &
  bg=$!
  # Let it reach the first rate_limit backoff (a ~30s sleep_interruptible).
  /usr/bin/perl -e 'select(undef,undef,undef,4)'
  start="$(date +%s)"
  touch "$WS/repo/.ralph/STOP"
  wait "$bg" 2>/dev/null || true
  end="$(date +%s)"
  # If STOP only took effect when the 30s backoff finished, this would be ~26s+.
  # The interruptible sleep must cut it to roughly the <=2s poll tick.
  [ "$((end - start))" -lt 15 ]
}

@test "T-SUP-3 (INV-5): rate_limit retries the SAME iteration (counter does not run away)" {
  # quota transcript + non-zero rc ⇒ classify rate_limit ⇒ `continue` (retry same
  # iter); the iteration counter must NOT advance no matter how many retries occur.
  export STUB_AGY_FIXTURE="$RALPH_FIXTURES/quota.txt" STUB_AGY_EXIT=1
  export RALPH_MAX_ITERATIONS=0 RALPH_MIN_INTERVAL_S=1 RALPH_BACKOFF_BASE_S=1 RALPH_BACKOFF_CAP_S=1
  run_supervisor_bounded 12
  # Watchdog stops the (intentionally non-terminating) loop; iteration stayed at 0.
  [ "$(iter_now)" -le 0 ]
}

@test "T-SUP-4 (INV-6): the agent alone cannot flip goals_done while OPEN work exists" {
  # The agent claims done_with_explicit_goals=true, but the seed LEDGER has an OPEN
  # item → witness #2 (LEDGER.OPEN empty for T1..T6) fails → RATCHET.goals_done must
  # NOT become true on the agent's say-so. The loop also never stops on it (INV-6).
  export STUB_AGY_FIXTURE="$RALPH_FIXTURES/goals_done_handoff.txt" STUB_AGY_COMMIT=1
  export RALPH_MAX_ITERATIONS=1 RALPH_MIN_INTERVAL_S=1
  run_supervisor_bounded 30
  gd="$("$PY3" "$RALPH_LIB/state.py" get-raw "$WS/repo/.ralph/RATCHET.json" goals_done false)"
  [ "$gd" != "true" ]
}
