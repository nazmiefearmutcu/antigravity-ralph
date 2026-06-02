#!/usr/bin/env bats
# tests/state.bats — state IO, atomic writes, lock steal, memory-preservation
# (SPEC §3.5, §6.2, §6.3; §11 T-STATE-1..4; INV-4).
#
# Public contracts exercised:
#   lib/state.py  get|set|set-num|bump|init|merge|validate   (atomic tmp+rename)
#   lib/state.sh  acquire_lock_or_exit / heartbeat / set_state / persist_*  (when present)
#   revert preserves all .ralph/ history (lib/ratchet.sh revert_to_baseline, when present)

load test_helper

setup() {
  ralph_test_env
  require_pylib state.py
  WS="${BATS_TEST_TMPDIR}/ws"
  mkdir -p "$WS/.ralph"
  STATE="$WS/.ralph/state.json"
}

# ── atomic state.py round-trips ───────────────────────────────────────────
@test "T-STATE-py-init-get: init then get a nested key" {
  run "$PY3" "$RALPH_LIB/state.py" init "$STATE" '{"iteration":0,"best":{"metrics":{"tests_pass":3}}}'
  [ "$status" -eq 0 ]
  run "$PY3" "$RALPH_LIB/state.py" get-raw "$STATE" best.metrics.tests_pass
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

@test "T-STATE-py-bump: bump increments and prints the new value" {
  "$PY3" "$RALPH_LIB/state.py" init "$STATE" '{"advances":0}'
  run "$PY3" "$RALPH_LIB/state.py" bump "$STATE" advances
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  run "$PY3" "$RALPH_LIB/state.py" bump "$STATE" advances 4
  [ "$output" = "5" ]
}

@test "T-STATE-py-validate: validate exits 0 on good JSON, non-zero on garbage" {
  "$PY3" "$RALPH_LIB/state.py" init "$STATE" '{"a":1}'
  run "$PY3" "$RALPH_LIB/state.py" validate "$STATE"
  [ "$status" -eq 0 ]
  printf 'not json {' > "$WS/.ralph/bad.json"
  run "$PY3" "$RALPH_LIB/state.py" validate "$WS/.ralph/bad.json"
  [ "$status" -ne 0 ]
}

@test "T-STATE-1: atomic write — the live file is never left half-written/garbage" {
  # Seed a valid file, then run many concurrent mutators; the live file must
  # ALWAYS parse (tmp+rename guarantees no torn read). This is the observable
  # contract of §6.2 (we cannot SIGKILL mid-fwrite portably in bats, but the
  # invariant — never a corrupt live file — is what we assert).
  "$PY3" "$RALPH_LIB/state.py" init "$STATE" '{"n":0}'
  i=0
  while [ "$i" -lt 25 ]; do
    "$PY3" "$RALPH_LIB/state.py" bump "$STATE" n >/dev/null &
    i=$((i+1))
  done
  wait
  run "$PY3" "$RALPH_LIB/state.py" validate "$STATE"
  [ "$status" -eq 0 ]
  # No leftover temp files in .ralph (atomic rename consumed them).
  run sh -c 'ls "'"$WS"'/.ralph"/.state.*.tmp 2>/dev/null | wc -l | tr -d " "'
  [ "$output" = "0" ]
}

# ── lock (§6.3) ───────────────────────────────────────────────────────────
@test "T-STATE-2: lock steal when owner pid is dead; refuse when alive" {
  require_lib state.sh
  require_fn acquire_lock_or_exit
  cd "$WS"
  # Stale lock owned by a definitely-dead pid → must be stolen.
  mkdir -p .ralph/ralph.lock
  echo 999999 > .ralph/ralph.lock/owner.pid
  run bash -c '. "'"$RALPH_LIB"'/state.sh"; cd "'"$WS"'"; acquire_lock_or_exit; echo ACQUIRED'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q ACQUIRED

  # Live owner (our own pid is alive) → must refuse with exit 3.
  rm -rf .ralph/ralph.lock; mkdir -p .ralph/ralph.lock
  echo $$ > .ralph/ralph.lock/owner.pid
  run bash -c '. "'"$RALPH_LIB"'/state.sh"; cd "'"$WS"'"; acquire_lock_or_exit; echo ACQUIRED'
  [ "$status" -eq 3 ]
}

# ── heartbeat (§3.5) ──────────────────────────────────────────────────────
@test "T-STATE-3: heartbeat.json is written and parses (start/end beacon)" {
  require_lib state.sh
  require_fn heartbeat
  cd "$WS"
  "$PY3" "$RALPH_LIB/state.py" init "$STATE" '{"iteration":1}'
  export TARGET="$WS" REPO_ROOT="$WS" ITER=1 phase=running_agy
  run bash -c '. "'"$RALPH_LIB"'/state.sh"; cd "'"$WS"'"; TARGET="'"$WS"'" ITER=1 phase=running_agy heartbeat'
  [ "$status" -eq 0 ]
  [ -f "$WS/.ralph/heartbeat.json" ]
  run "$PY3" "$RALPH_LIB/state.py" validate "$WS/.ralph/heartbeat.json"
  [ "$status" -eq 0 ]
  run "$PY3" "$RALPH_LIB/state.py" get-raw "$WS/.ralph/heartbeat.json" phase
  [ "$output" = "running_agy" ]
}

# ── INV-4: memory preservation across reset --hard + clean -e .ralph ──────
@test "T-STATE-4 (INV-4): reset --hard + clean -e .ralph preserves all .ralph history" {
  make_python_repo "$WS/repo" 3
  seed_ralph "$WS/repo"
  rd="$WS/repo/.ralph"
  # Write durable history markers that MUST survive a revert.
  mkdir -p "$rd/iterations"
  echo '{"iter":1}' > "$rd/iterations/000001.json"
  echo "## ITER 0001 marker" >> "$rd/PROGRESS.md"
  echo "## DONE marker" >> "$rd/LEDGER.md"
  echo '{"line":1}' >> "$rd/progress.ndjson"
  base="$(git_head "$WS/repo")"

  # Create a dirty/uncommitted change + a stray untracked file, then revert.
  echo "dirty change" >> "$WS/repo/mod.py"
  echo "stray" > "$WS/repo/stray_file.txt"

  if ralph_source_lib ratchet.sh && command -v revert_to_baseline >/dev/null 2>&1; then
    ( cd "$WS/repo" && RALPH_REVERT_STRATEGY=reset_hard revert_to_baseline "$base" )
  else
    # Spec-literal fallback (§5.6) so INV-4 is still asserted if ratchet.sh absent.
    ( cd "$WS/repo" && git reset --hard "$base" >/dev/null && git clean -fdx -e '.ralph' >/dev/null )
  fi

  # The stray (outside .ralph) is gone; ALL .ralph history survives.
  [ ! -f "$WS/repo/stray_file.txt" ]
  [ -f "$rd/iterations/000001.json" ]
  grep -q 'ITER 0001 marker' "$rd/PROGRESS.md"
  grep -q 'DONE marker' "$rd/LEDGER.md"
  grep -q '"line":1' "$rd/progress.ndjson"
  [ -f "$rd/RATCHET.json" ]
  [ -f "$rd/state.json" ]
}
