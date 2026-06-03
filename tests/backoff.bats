#!/usr/bin/env bats
# tests/backoff.bats — the timing primitives (SPEC §7.3; INV-8): expo_backoff_jitter,
# enforce_min_interval (incl. the P7 backward-clock-step clamp), and sleep_interruptible's
# kill-switch latency. These bound the loop's cadence WITHOUT ever wedging or blocking STOP.

load test_helper

setup() {
  ralph_test_env
  require_lib backoff.sh
  require_fn enforce_min_interval
  WS="${BATS_TEST_TMPDIR}/d"
  mkdir -p "$WS/.ralph"
  export RALPH_DIR="$WS/.ralph"
}

@test "T-BACKOFF-clock-skew (P7): a FUTURE last_run stamp does NOT inflate the min-interval sleep" {
  # Simulate a backward clock step / corrupt-but-numeric stamp: last_run_started.epoch is 1h ahead.
  # Without the clamp, diff = now-future < 0 ⇒ sleep (minsec - diff) = minsec + 3600s (a multi-hour
  # near-wedge). P7 clamps a negative diff to minsec, so the interval reads as already satisfied.
  printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$RALPH_DIR/last_run_started.epoch"
  start="$(date +%s)"
  enforce_min_interval 20
  end="$(date +%s)"
  [ "$(( end - start ))" -lt 5 ]
  # And it self-heals: the stamp is rewritten to ~now (no longer in the future).
  stamp="$(cat "$RALPH_DIR/last_run_started.epoch")"
  [ "$stamp" -le "$(date +%s)" ]
}

@test "T-BACKOFF-min-interval: a recent stamp returns within the floor (never hangs)" {
  printf '%s\n' "$(date +%s)" > "$RALPH_DIR/last_run_started.epoch"
  start="$(date +%s)"
  enforce_min_interval 3
  end="$(date +%s)"
  [ "$(( end - start ))" -le 5 ]
}

@test "T-BACKOFF-expo-cap: expo_backoff_jitter is capped and always >= 1" {
  export RALPH_BACKOFF_BASE_S=30 RALPH_BACKOFF_CAP_S=120 RALPH_BACKOFF_JITTER_PCT=0
  v="$(expo_backoff_jitter 99)"      # huge attempt count ⇒ must saturate at the cap, not overflow
  [ "$v" -le 120 ]
  [ "$v" -ge 1 ]
  v1="$(expo_backoff_jitter 0)"      # n<=0 treated as 1 ⇒ base
  [ "$v1" -ge 1 ]
}

@test "T-BACKOFF-stop-wakes-sleep (INV-8): sleep_interruptible returns instantly when STOP is present" {
  require_fn sleep_interruptible
  touch "$RALPH_DIR/STOP"
  start="$(date +%s)"
  sleep_interruptible 30          # a 30s backoff that STOP must cut short to ~0
  end="$(date +%s)"
  [ "$(( end - start ))" -lt 3 ]
}
