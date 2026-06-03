#!/usr/bin/env bats
# tests/bounded.bats — bounded_run group-kill watchdog (SPEC §6.1, §11 T-BOUND-1 / INV-7).
#
# Asserts: a long-running child is killed at the wall-clock cap, bounded_run
# returns rc 124, a child that finishes early returns its real rc, and no orphan
# process group survives. Uses ONLY the public function `bounded_run` from §6.1:
#   bounded_run <seconds> <logfile> -- cmd args...

load test_helper

setup() {
  ralph_test_env
  require_lib bounded.sh
  require_fn bounded_run
  set -m 2>/dev/null || true   # §6.1 requires job control so the child gets its own pgid
  LOG="${BATS_TEST_TMPDIR}/bounded.log"
}

@test "T-BOUND-1: a sleeping child is killed at the cap, rc==124" {
  start="$(date +%s)"
  run bounded_run 1 "$LOG" -- /usr/bin/perl -e 'select(undef,undef,undef,30)'
  end="$(date +%s)"
  [ "$status" -eq 124 ]
  # Killed near the cap, not after 30s.
  [ "$((end - start))" -lt 15 ]
}

@test "T-BOUND-fast: a child that finishes early returns its own rc (0)" {
  run bounded_run 10 "$LOG" -- /bin/sh -c 'exit 0'
  [ "$status" -eq 0 ]
}

@test "T-BOUND-rc: a child's non-zero rc is propagated when within the cap" {
  run bounded_run 10 "$LOG" -- /bin/sh -c 'exit 7'
  [ "$status" -eq 7 ]
}

@test "T-BOUND-log: stdout+stderr of the child are captured to the logfile" {
  run bounded_run 10 "$LOG" -- /bin/sh -c 'echo hello-out; echo hello-err 1>&2'
  [ "$status" -eq 0 ]
  grep -q 'hello-out' "$LOG"
  grep -q 'hello-err' "$LOG"
}

@test "T-BOUND-idle: a SILENT-but-alive child is reclaimed by the idle watchdog (124) before the wall cap" {
  # Output once, then go silent far longer than BOUNDED_IDLE_S but well under the 30s wall. The idle
  # watchdog must group-kill it as a stall (rc 124) within ~idle+grace — this is agy frozen "waiting for
  # response" recovering in seconds instead of waiting out the whole wall.
  export BOUNDED_IDLE_S=2
  start="$(date +%s)"
  run bounded_run 30 "$LOG" -- /bin/sh -c 'echo working; /usr/bin/perl -e "select(undef,undef,undef,25)"'
  end="$(date +%s)"
  unset BOUNDED_IDLE_S
  [ "$status" -eq 124 ]
  [ "$((end - start))" -lt 14 ]
}

@test "T-BOUND-idle-healthy: a child that KEEPS emitting is NOT killed by the idle watchdog" {
  # Emits a line ~every second for ~5s then exits 0. With BOUNDED_IDLE_S=3 the log keeps growing, so the
  # idle watchdog must NEVER fire — bounded_run returns the child's real rc 0 (no false stall-kill).
  export BOUNDED_IDLE_S=3
  run bounded_run 30 "$LOG" -- /bin/sh -c 'for i in 1 2 3 4 5; do echo tick $i; /usr/bin/perl -e "select(undef,undef,undef,1)"; done; exit 0'
  unset BOUNDED_IDLE_S
  [ "$status" -eq 0 ]
}

@test "T-BOUND-no-orphan: the whole process group is reaped (hung grandchild dies)" {
  # A child that spawns a long-lived grandchild then itself hangs. The group-kill
  # watchdog must reap BOTH. We tag the grandchild so we can grep for survivors.
  # §6.1 requires `set -m` so `( exec "$@" )` is a pgid leader and `kill -<pgid>`
  # reaches the group. bats does not reliably propagate job control into the test
  # body, so we run the bounded_run call inside a fresh `bash -c 'set -m; ...'`
  # subshell (this is exactly how a supervisor — which sets -m — invokes it).
  TAG="ralphbnd_$$_${RANDOM}"
  script="${BATS_TEST_TMPDIR}/spawn.sh"
  cat > "$script" <<EOF
#!/bin/sh
# grandchild: long sleep, identifiable by TAG in argv
/usr/bin/perl -e 'select(undef,undef,undef,30)' $TAG &
# parent also hangs so bounded_run must kill the group
/usr/bin/perl -e 'select(undef,undef,undef,30)'
EOF
  chmod +x "$script"
  run bash -c '
    set -m
    . "'"$RALPH_LIB"'/bounded.sh"
    bounded_run 1 "'"$LOG"'" -- /bin/sh "'"$script"'"
  '
  [ "$status" -eq 124 ]
  # Give the kill a beat to propagate (interruptible).
  /usr/bin/perl -e 'select(undef,undef,undef,1)' || true
  survivors="$(pgrep -f "$TAG" 2>/dev/null | wc -l | tr -d ' ')"
  # Belt: clean up any survivor so a failure here never leaks across tests.
  [ "$survivors" -eq 0 ] || { pkill -f "$TAG" 2>/dev/null; false; }
}
