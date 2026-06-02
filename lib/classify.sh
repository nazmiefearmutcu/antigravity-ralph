#!/usr/bin/env bash
# lib/classify.sh — result classifier + Antigravity substrate recovery (SPEC §7.4).
#
# Role: turn (agy exit code, agy transcript) into exactly one of:
#     success | rate_limit | timeout | transient_crash | fatal_misconfig
# This is the oracle the supervisor switches on (§7.2) to decide retry-same-iter vs
# advance-iter vs back-off vs loud-wait. It also provides the IDE liveness probe and the
# relaunch-and-wait recovery used in PREFLIGHT.
#
# SILENT-ZOMBIE GUARD (§7.4): the classifier greps quota/limit language even when rc==0,
# demoting a "successful" run whose transcript actually says "quota exhausted" down to
# rate_limit, so a credits-out run never advances the ratchet as a false-green.
#
# BASH-3.2 SAFE: no associative arrays, no namerefs. Pure string greps over the transcript
# tail. `tr 'A-Z' 'a-z'` (POSIX-portable) is used for case-folding rather than `${var,,}`
# (a bash-4 feature absent on macOS 3.2).
#
# Contracts this file ASSUMES another group provides:
#   - log()              : appends a line to the supervisor log. Defined in the supervisor
#                          / lib/state.sh. We guard-define a fallback so this file is usable
#                          stand-alone in tests (prints to stderr).
#   - sleep_interruptible: from lib/backoff.sh (for the relaunch wait loop).
#   - heartbeat / phase  : the supervisor sets `phase` and calls heartbeat during recovery;
#                          we set `phase=recover_ide` as a hint but do not require heartbeat.
#   - RALPH_RELAUNCH_ANTIGRAVITY : config knob (default 1).
#
# Idempotent source guard.

if [ -n "${__RALPH_CLASSIFY_SH_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
__RALPH_CLASSIFY_SH_LOADED=1

: "${RALPH_RELAUNCH_ANTIGRAVITY:=1}"

# Guard-define log() if the supervisor hasn't provided one (keeps this file testable).
if ! command -v log >/dev/null 2>&1; then
  log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
fi

# classify_result <rc> <transcript_file>  -> echoes the class; always returns 0.
#   Decision order (first match wins), faithful to §7.4:
#     1. rc == 124                      -> timeout            (bounded_run wall-clock kill)
#     2. transcript mentions rate/quota -> rate_limit         (even on rc 0: silent zombie)
#     3. transcript mentions print-timeout/deadline -> timeout
#     4. rc != 0 AND (agy missing OR fatal-language) -> fatal_misconfig
#     5. rc == 0                        -> success
#     6. otherwise                      -> transient_crash
classify_result() {
  local rc="$1" transcript="$2" tail=""
  case "$rc" in
    *[!0-9]* | "" ) rc=1 ;;   # defensive: a non-numeric rc is a crash
  esac
  if [ -n "$transcript" ] && [ -f "$transcript" ]; then
    tail="$(tail -c 4000 "$transcript" 2>/dev/null | tr 'A-Z' 'a-z')"
  fi

  # 1. Wall-clock kill from bounded_run.
  if [ "$rc" -eq 124 ]; then
    echo timeout
    return 0
  fi

  # 2. Quota / rate-limit language anywhere in the tail (works even when rc==0).
  if printf '%s' "$tail" | grep -Eq 'rate.?limit|quota|too many requests|429|resource[_ ]exhausted|credits? (exhausted|depleted)|usage limit'; then
    echo rate_limit
    return 0
  fi

  # 3. Cooperative print-timeout / deadline language.
  if printf '%s' "$tail" | grep -Eq 'print.?timeout|deadline exceeded|context deadline'; then
    echo timeout
    return 0
  fi

  # 4. Hard misconfiguration (only meaningful on a non-zero exit).
  if [ "$rc" -ne 0 ]; then
    if ! command -v agy >/dev/null 2>&1; then
      echo fatal_misconfig
      return 0
    fi
    if printf '%s' "$tail" | grep -Eq 'not (authenticated|logged in|signed in)|no such file or directory|permission denied \(workspace\)|no space left|invalid api key|unauthorized'; then
      echo fatal_misconfig
      return 0
    fi
  fi

  # 5. Clean success.
  if [ "$rc" -eq 0 ]; then
    echo success
    return 0
  fi

  # 6. Anything else non-zero is a transient crash worth recovering + backing off.
  echo transient_crash
  return 0
}

# agy_reachable  -> 0 (true) iff the Antigravity language_server process is alive.
#   `agy -p` shares the running language_server; if it is down, no headless run can succeed.
agy_reachable() {
  pgrep -f 'language_server' >/dev/null 2>&1
}

# recover_agy_substrate  -> 0 if the LS is (or came) back up; 1 if still down.
#   Relaunches Antigravity (if RALPH_RELAUNCH_ANTIGRAVITY=1) and waits up to ~60s for the
#   language_server to reappear. NEVER exits the loop: if it cannot recover, it returns 1 and
#   the caller treats the next run as transient and retries (loop stays immortal).
recover_agy_substrate() {
  [ "$RALPH_RELAUNCH_ANTIGRAVITY" = 1 ] || return 0
  agy_reachable && return 0
  log "language_server down -> relaunching Antigravity"
  open -ga "Antigravity" 2>/dev/null || true
  local i
  local _rd="${RALPH_DIR:-.ralph}"
  for i in $(seq 1 12); do
    # Abandon recovery promptly on a stop request (INV-8) instead of running the full 12-tick ladder.
    if [ -f "$_rd/STOP" ] || [ "${WANT_STOP:-0}" = 1 ]; then
      log "stop requested during IDE recovery → abandoning (loop will drain)"
      return 1
    fi
    if agy_reachable; then
      log "LS back"
      return 0
    fi
    # Hint the heartbeat phase if the supervisor is watching this variable.
    phase=recover_ide
    if command -v heartbeat >/dev/null 2>&1; then
      heartbeat 2>/dev/null || true
    fi
    if command -v sleep_interruptible >/dev/null 2>&1; then
      sleep_interruptible 5
    else
      "${RALPH_PERL:-/usr/bin/perl}" -e 'select(undef,undef,undef,5)' 2>/dev/null || true
    fi
  done
  log "LS not back; treat as transient, retry next iter (loop never dies)"
  return 1
}
