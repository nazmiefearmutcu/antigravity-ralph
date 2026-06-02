#!/usr/bin/env bash
# lib/backoff.sh — backoff / interruptible sleep / crash-loop window (SPEC §7.3; INV-8).
#
# Role: the timing primitives the supervisor uses to throttle itself without ever dying.
#   - expo_backoff_jitter   : exponential backoff with jitter (anti-lockstep across targets)
#   - sleep_interruptible   : perl-based sleep that wakes INSTANTLY on STOP/SIGTERM and
#                             re-checks STOP/PAUSE every <=2s (kill-switch latency, INV-8)
#   - enforce_min_interval  : floor the iteration cadence (tightest crash loop is throttled)
#   - crashloop_tripped     : >= THRESHOLD transient/timeout events within WINDOW ?
#   - record_crashloop_event: append a now() epoch to the crash-loop event ledger
#   - reset_crashloop_window: clear the event ledger after a cooldown
#
# WHY perl-sleep: foreground `sleep` is blocked in this environment and there is no
# `timeout`/`flock`; /usr/bin/perl is verified present. We run the sleep in the BACKGROUND
# and `wait` on it so the supervisor's SIGTERM trap can kill the sleeper and make
# `ralph stop` instant (INV-8). The loop also polls STOP/PAUSE sentinels each tick.
#
# BASH-3.2 SAFE: no associative arrays, no namerefs. State that must persist across the
# supervisor process (the crash-loop event window) is kept in a plain newline-delimited
# file under .ralph/ (one epoch seconds value per line), NOT an in-memory assoc array, so
# it survives a launchd relaunch and needs no bash-4 features.
#
# Contracts this file ASSUMES another group provides (called by name, see structured notes):
#   - now()                : echoes a UTC ISO-8601 timestamp (Z). Defined in lib/state.sh.
#   - RALPH_DIR            : absolute path to <target>/.ralph (exported by the supervisor).
#   - config knobs (RALPH_BACKOFF_BASE_S, RALPH_BACKOFF_CAP_S, RALPH_BACKOFF_JITTER_PCT,
#     RALPH_CRASHLOOP_THRESHOLD, RALPH_CRASHLOOP_WINDOW_S, RALPH_MIN_INTERVAL_S) sourced
#     from config.env. Sensible defaults are applied here if unset.
#   - WANT_STOP           : set to 1 by the SIGTERM/SIGINT trap (lib/state.sh installs it).
# It depends on lib/bounded.sh ONLY for $RALPH_PERL (the perl path); we re-default it here
# so this file is usable stand-alone in tests.
#
# Idempotent source guard.

if [ -n "${__RALPH_BACKOFF_SH_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
__RALPH_BACKOFF_SH_LOADED=1

: "${RALPH_PERL:=/usr/bin/perl}"

# ---- config defaults (mirror config.env §3.6; real values come from sourced config) ----
: "${RALPH_BACKOFF_BASE_S:=30}"
: "${RALPH_BACKOFF_CAP_S:=1800}"
: "${RALPH_BACKOFF_JITTER_PCT:=25}"
: "${RALPH_CRASHLOOP_THRESHOLD:=5}"
: "${RALPH_CRASHLOOP_WINDOW_S:=300}"
: "${RALPH_MIN_INTERVAL_S:=20}"

# Where the crash-loop event ledger lives. RALPH_DIR is set by the supervisor; default to
# ./.ralph so the helpers are testable in a fixture cwd.
_backoff_dir() {
  printf '%s' "${RALPH_DIR:-.ralph}"
}
_crashloop_file() {
  printf '%s/crashloop.events' "$(_backoff_dir)"
}

# _epoch_now: integer seconds since epoch (portable; date +%s on macOS).
_epoch_now() {
  date +%s
}

# expo_backoff_jitter <n>  -> seconds (integer) = min(CAP, BASE * 2^(n-1)) +/- jitter%.
#   n is the attempt count (1-based). n<=0 is treated as 1. Result is always >= 1.
#   Jitter is symmetric (+/-) and bounded so we never exceed ~CAP*(1+jitter) or drop below 1.
expo_backoff_jitter() {
  local n="${1:-1}"
  case "$n" in
    *[!0-9]* | "" ) n=1 ;;
  esac
  [ "$n" -lt 1 ] && n=1

  local base="$RALPH_BACKOFF_BASE_S" cap="$RALPH_BACKOFF_CAP_S" jit="$RALPH_BACKOFF_JITTER_PCT"
  # s = base * 2^(n-1), capped. Cap the shift so we don't overflow on huge n.
  local exp=$((n - 1))
  [ "$exp" -gt 30 ] && exp=30
  local mult=1 i=0
  while [ "$i" -lt "$exp" ]; do
    mult=$((mult * 2))
    # If we've already blown past the cap, stop doubling.
    if [ $((base * mult)) -ge "$cap" ]; then
      break
    fi
    i=$((i + 1))
  done
  local s=$((base * mult))
  [ "$s" -gt "$cap" ] && s="$cap"
  [ "$s" -lt 1 ] && s=1

  # Jitter: +/- (s * jit / 100), uniformly random.
  local span=$((s * jit / 100))
  local delta=0
  if [ "$span" -gt 0 ]; then
    # RANDOM is 0..32767 in bash; map to [-span, +span].
    local r=$((RANDOM % (2 * span + 1)))
    delta=$((r - span))
  fi
  local out=$((s + delta))
  [ "$out" -lt 1 ] && out=1
  printf '%s' "$out"
}

# _stop_or_pause_pending: returns 0 (true) if the loop should wake early from a sleep.
#   - STOP sentinel present  -> wake (graceful drain)
#   - WANT_STOP trap fired   -> wake
# PAUSE alone does NOT wake an interruptible sleep meant for backoff, but the supervisor's
# pause loop calls sleep_interruptible itself and re-checks PAUSE between ticks; we surface
# PAUSE appearing as a wake too so a freshly-touched PAUSE is honored quickly.
_stop_or_pause_pending() {
  local d
  d="$(_backoff_dir)"
  [ -f "$d/STOP" ] && return 0
  [ "${WANT_STOP:-0}" = 1 ] && return 0
  return 1
}

# sleep_interruptible <seconds>
#   Sleep up to <seconds>, but:
#     * wake immediately if STOP appears, WANT_STOP is set, or we receive SIGTERM/SIGINT
#       (the trap kills the background perl sleeper -> wait returns instantly), and
#     * re-check the STOP/PAUSE sentinels at least every 2 seconds.
#   Always returns 0. Safe with <seconds> = 0 (returns immediately).
sleep_interruptible() {
  local total="${1:-0}"
  case "$total" in
    *[!0-9]* | "" ) total=0 ;;
  esac
  local remaining="$total"
  local tick
  while [ "$remaining" -gt 0 ]; do
    # Early-out before sleeping at all.
    if _stop_or_pause_pending; then
      return 0
    fi
    tick=2
    [ "$remaining" -lt 2 ] && tick="$remaining"
    # Background perl sleeper + wait, so a SIGTERM-triggered trap that kills children makes
    # this return at once. We capture the pid so the supervisor's trap (which sets WANT_STOP
    # and may `kill` the process group) breaks us out.
    "$RALPH_PERL" -e 'select(undef,undef,undef,$ARGV[0])' "$tick" &
    local sl_pid=$!
    wait "$sl_pid" 2>/dev/null
    remaining=$((remaining - tick))
    if _stop_or_pause_pending; then
      return 0
    fi
  done
  return 0
}

# enforce_min_interval <min_seconds>
#   Ensure at least <min_seconds> have elapsed since the previous iteration START. Reads the
#   last start epoch from .ralph/last_run_started.epoch (written by us at each call) and
#   sleeps (interruptibly) for any shortfall. Floors the tightest crash loop's cadence.
enforce_min_interval() {
  local minsec="${1:-$RALPH_MIN_INTERVAL_S}"
  case "$minsec" in
    *[!0-9]* | "" ) minsec=0 ;;
  esac
  local d stampf last now diff
  d="$(_backoff_dir)"
  stampf="$d/last_run_started.epoch"
  now="$(_epoch_now)"
  if [ -f "$stampf" ]; then
    last="$(cat "$stampf" 2>/dev/null)"
    case "$last" in
      *[!0-9]* | "" ) last=0 ;;
    esac
    diff=$((now - last))
    if [ "$diff" -lt "$minsec" ]; then
      sleep_interruptible $((minsec - diff))
    fi
  fi
  # Record THIS start for the next interval check.
  [ -d "$d" ] || mkdir -p "$d" 2>/dev/null || true
  printf '%s\n' "$(_epoch_now)" > "$stampf.tmp" 2>/dev/null && mv -f "$stampf.tmp" "$stampf" 2>/dev/null || true
}

# record_crashloop_event
#   Append the current epoch to the crash-loop event ledger (one line per transient/timeout).
record_crashloop_event() {
  local d f
  d="$(_backoff_dir)"
  f="$(_crashloop_file)"
  [ -d "$d" ] || mkdir -p "$d" 2>/dev/null || true
  printf '%s\n' "$(_epoch_now)" >> "$f" 2>/dev/null || true
}

# crashloop_tripped
#   Returns 0 (true) iff >= RALPH_CRASHLOOP_THRESHOLD events fall within the last
#   RALPH_CRASHLOOP_WINDOW_S seconds. Side-effect: prunes events older than the window so the
#   ledger stays small. Returns 1 (false) otherwise.
crashloop_tripped() {
  local f now cutoff cnt line
  f="$(_crashloop_file)"
  [ -f "$f" ] || return 1
  now="$(_epoch_now)"
  cutoff=$((now - RALPH_CRASHLOOP_WINDOW_S))
  cnt=0
  local tmp="$f.tmp"
  : > "$tmp" 2>/dev/null || return 1
  while IFS= read -r line; do
    case "$line" in
      *[!0-9]* | "" ) continue ;;
    esac
    if [ "$line" -ge "$cutoff" ]; then
      printf '%s\n' "$line" >> "$tmp"
      cnt=$((cnt + 1))
    fi
  done < "$f"
  mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  if [ "$cnt" -ge "$RALPH_CRASHLOOP_THRESHOLD" ]; then
    return 0
  fi
  return 1
}

# reset_crashloop_window
#   Clear the crash-loop event ledger (called after a cooldown so we start a fresh window).
reset_crashloop_window() {
  local f
  f="$(_crashloop_file)"
  : > "$f" 2>/dev/null || rm -f "$f" 2>/dev/null || true
}
