#!/usr/bin/env bash
# lib/bounded.sh — bounded_run: group-kill wall-clock watchdog (SPEC §6.1, R11; INV-7).
#
# Role: run a command with a hard wall-clock cap WITHOUT `timeout`/`gtimeout`/`flock`
# (all absent on this macOS box). Uses /usr/bin/perl (verified present) for a precise,
# sub-second-capable, interruptible sleep, and kills the command's whole PROCESS GROUP
# on expiry so hung `agy` *children* are reclaimed (a single-pid alarm would leak them).
# Returns the command's real exit code, or 124 if the wall-clock killed it.
#
# BASH-3.2 / ASSOC-ARRAY HAZARD (per integrator note): macOS /bin/bash IS 3.2.57 and there
# is NO /opt/homebrew/bin/bash on this machine. This file therefore uses NO associative
# arrays and NO namerefs (`declare -A` / `local -n`). It is pure bash-3.2-safe. Callers
# must run under `set -m` (job control) so the `( exec "$@" )` subshell becomes its own
# process-group leader and `kill -<pgid>` reaches the whole group; if that is unavailable
# we fall back to single-pid kill (still correct, just less thorough), exactly as §6.1 says.
#
# Idempotent source guard: sourcing twice is a no-op.

if [ -n "${__RALPH_BOUNDED_SH_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
__RALPH_BOUNDED_SH_LOADED=1

# Resolve the perl we sleep with. /usr/bin/perl is the verified path.
: "${RALPH_PERL:=/usr/bin/perl}"

# bounded_run <seconds> <logfile> [--] cmd args...
#   Runs `cmd args...` with stdout+stderr -> <logfile>. Wall-clock cap = <seconds>.
#   Returns cmd's rc, or 124 if the watchdog had to kill it (TERM, 5s grace, then KILL).
#
#   <seconds> may be fractional (perl select handles sub-second). Negative/zero/non-numeric
#   is treated as "no meaningful cap" -> default 1s minimum guard so we never busy-spin.
bounded_run() {
  local secs="$1" log="$2"
  shift 2
  if [ "${1:-}" = "--" ]; then
    shift
  fi
  if [ "$#" -eq 0 ]; then
    # Nothing to run; behave like a successful no-op but record it.
    : > "$log" 2>/dev/null || true
    return 0
  fi

  # Guard the duration: must be a positive number; otherwise floor to 1s.
  case "$secs" in
    *[!0-9.]* | "" | "." )
      secs=1
      ;;
    * )
      : # numeric-ish; perl will interpret it
      ;;
  esac

  # Make sure the log's directory exists and truncate it.
  local logdir
  logdir="$(dirname "$log")"
  [ -d "$logdir" ] || mkdir -p "$logdir" 2>/dev/null || true
  : > "$log" 2>/dev/null || true

  # Launch the command in its own subshell. Under `set -m` (set by the supervisor) this
  # subshell becomes a process-group leader, so its PID == its PGID, and killing -PID
  # reaches every descendant. `exec` replaces the subshell so the PID we hold IS the cmd.
  ( exec "$@" ) >"$log" 2>&1 &
  local cmd_pid=$!

  # Watchdog: wait up to the cap, then if the command still lives, TERM the group, grace, KILL.
  # Exits 124 if it had to kill; 0 if the command finished on its own first.
  #
  # Two robustness properties (both matter for never-stops + clean tests, INV-7):
  #   1. FDs are FULLY detached (</dev/null >/dev/null 2>&1). A watchdog must never hold an
  #      inherited stdout/stderr pipe — otherwise, if it is orphaned when an OUTER bound kills our
  #      caller (e.g. the supervisor's own bounded_run watchdog when the supervisor is wall-killed),
  #      it would keep a parent pipe open and hang the reader (bats `run`, a pipeline, etc.).
  #   2. It POLLS in <=2s ticks instead of one long unbroken sleep, exiting the instant its target
  #      is gone. So an orphaned watchdog dies within ~1 tick of its dead target instead of lingering
  #      for the full (possibly 90s) cap.
  (
    rem="$secs"
    while [ "$(awk -v r="$rem" 'BEGIN{print (r>0)?1:0}')" = 1 ]; do
      kill -0 "$cmd_pid" 2>/dev/null || exit 0          # target finished/killed → leave promptly
      step="$(awk -v r="$rem" 'BEGIN{print (r<2)?r:2}')" # tick = min(2, remaining)
      "$RALPH_PERL" -e 'select(undef,undef,undef,$ARGV[0])' "$step"
      rem="$(awk -v r="$rem" -v s="$step" 'BEGIN{print r-s}')"
    done
    if kill -0 "$cmd_pid" 2>/dev/null; then
      # Try whole-group TERM first (reaches agy's children), fall back to single pid.
      kill -TERM -"$cmd_pid" 2>/dev/null || kill -TERM "$cmd_pid" 2>/dev/null
      "$RALPH_PERL" -e 'select(undef,undef,undef,5)'   # 5s grace for clean shutdown
      kill -KILL -"$cmd_pid" 2>/dev/null || kill -KILL "$cmd_pid" 2>/dev/null
      exit 124
    fi
    exit 0
  ) </dev/null >/dev/null 2>&1 &
  local wd_pid=$!

  # Wait for the command itself.
  wait "$cmd_pid"
  local rc=$?

  if [ "$rc" -ge 128 ]; then
    # `wait` returned signaled (143=TERM, 137=KILL, ...). Two cases:
    #   (a) the WATCHDOG killed the child (wall-clock) → child already dead; watchdog will exit 124.
    #   (b) OUR process took a signal (e.g. `ralph stop` SIGTERMs the supervisor) → wait was interrupted
    #       but the agy CHILD (its own pgid) is STILL ALIVE. Reclaim it NOW; do NOT block until the
    #       watchdog's wall-clock (~minutes) — that was the INV-8 kill-switch latency bug.
    local wd_rc=0
    if kill -0 "$cmd_pid" 2>/dev/null; then
      # case (b): group-kill the surviving child immediately (TERM, brief grace, KILL), then stop the wd.
      kill -TERM -"$cmd_pid" 2>/dev/null || kill -TERM "$cmd_pid" 2>/dev/null
      "$RALPH_PERL" -e 'select(undef,undef,undef,3)' 2>/dev/null
      kill -KILL -"$cmd_pid" 2>/dev/null || kill -KILL "$cmd_pid" 2>/dev/null
      wait "$cmd_pid" 2>/dev/null || true
      kill -TERM "$wd_pid" 2>/dev/null; wait "$wd_pid" 2>/dev/null
    else
      # case (a) (or a race): child is already gone. Give the watchdog a BOUNDED window (~8s) to finish
      # its TERM+grace+KILL and exit 124 so we normalize a real timeout; if it's instead just sleeping
      # its full cap (not firing), don't block — terminate it. Either way we never wait the whole cap.
      local _w=0
      while [ "$_w" -lt 16 ]; do
        kill -0 "$wd_pid" 2>/dev/null || break
        "$RALPH_PERL" -e 'select(undef,undef,undef,0.5)' 2>/dev/null
        _w=$((_w + 1))
      done
      kill -0 "$wd_pid" 2>/dev/null && kill -TERM "$wd_pid" 2>/dev/null
      wait "$wd_pid" 2>/dev/null; wd_rc=$?
      [ "$wd_rc" -eq 124 ] && rc=124
    fi
  else
    # The command finished on its own (normal exit). Stop the still-sleeping watchdog so it
    # cannot fire later against a reused pid.
    if kill -0 "$wd_pid" 2>/dev/null; then
      kill -TERM "$wd_pid" 2>/dev/null
    fi
    wait "$wd_pid" 2>/dev/null
  fi

  return "$rc"
}
