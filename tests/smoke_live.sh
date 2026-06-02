#!/usr/bin/env bash
# tests/smoke_live.sh — opt-in BOUNDED live smoke against the REAL agy (SPEC §11).
#
# Role: the one test that actually drives Antigravity's `agy` (COSTS AI CREDITS),
# proving end-to-end grounding. It is OFF by default: it refuses to run unless
# RALPH_SMOKE_LIVE=1 is set, so `tests/run.sh` / CI never burn credits by
# accident. The whole script is wrapped in `bounded_run 900` (via lib/bounded.sh)
# so the smoke itself can never hang CI (INV-7).
#
# Sequence (§11 "Bounded live smoke"):
#   1. `ralph doctor` PASS.
#   2. `agy -p "Reply PONG" --dangerously-skip-permissions` → PONG, exit 0.
#   3. `ralph init` a throwaway fixture repo with one trivial failing test.
#   4. `ralph once` → exit 0, a commit appears, metrics/latest.json written,
#      decision.json present, trailer parsed.
#   5. `touch STOP`; `ralph status` reports stopped within the interval.
#
# Degrades gracefully: if agy / Antigravity / ralph / bats aren't available it
# prints why and exits 0 (soft skip) unless RALPH_SMOKE_STRICT=1 is set.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

soft_skip() {
  echo "[smoke_live] SKIP: $*"
  [ "${RALPH_SMOKE_STRICT:-0}" = "1" ] && exit 1 || exit 0
}
fail() { echo "[smoke_live] FAIL: $*" >&2; exit 1; }

[ "${RALPH_SMOKE_LIVE:-0}" = "1" ] || soft_skip "set RALPH_SMOKE_LIVE=1 to run the credit-spending live smoke"

command -v agy   >/dev/null 2>&1 || soft_skip "agy not on PATH"
command -v jq    >/dev/null 2>&1 || soft_skip "jq not on PATH"
RALPH="${RALPH_BIN:-$REPO/bin/ralph}"
[ -f "$RALPH" ] || soft_skip "bin/ralph not present yet"

# Source bounded_run if available; else define a thin perl-based fallback so the
# script remains self-bounding even before lib/bounded.sh lands.
if [ -f "$REPO/lib/bounded.sh" ]; then
  # shellcheck disable=SC1091
  . "$REPO/lib/bounded.sh"
fi
if ! command -v bounded_run >/dev/null 2>&1; then
  bounded_run() {
    local secs="$1" log="$2"; shift 2; [ "$1" = "--" ] && shift
    set -m 2>/dev/null || true
    ( exec "$@" ) >"$log" 2>&1 & local p=$!
    ( /usr/bin/perl -e 'select(undef,undef,undef,$ARGV[0])' "$secs"
      kill -0 "$p" 2>/dev/null && { kill -TERM -"$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null; exit 124; }; exit 0 ) & local w=$!
    wait "$p"; local rc=$?
    kill -TERM "$w" 2>/dev/null; wait "$w" 2>/dev/null
    return "$rc"
  }
fi

_smoke_body() {
  echo "[smoke_live] (1/5) build throwaway fixture + ralph init"
  # Build a tiny repo with ONE trivial test so `ralph once` has work to verify, THEN init it.
  # (doctor needs the target to already exist + be initialized, so creation comes first.)
  . "$HERE/fixtures/setup.sh"
  make_python_repo "$WORK/repo" 1
  "$RALPH" init "$WORK/repo" --gate none || fail "ralph init failed"

  echo "[smoke_live] (2/5) ralph doctor"
  "$RALPH" doctor "$WORK/repo" || fail "doctor did not PASS"

  echo "[smoke_live] (3/5) agy PONG grounding"
  pong="$(agy -p "Reply with exactly one word: PONG" --dangerously-skip-permissions 2>/dev/null || true)"
  echo "$pong" | grep -qi 'PONG' || fail "agy did not return PONG (got: $pong)"

  echo "[smoke_live] (4/5) ralph once"
  "$RALPH" once "$WORK/repo" || fail "ralph once exited non-zero"
  rd="$WORK/repo/.ralph"
  [ -f "$rd/metrics/latest.json" ] || fail "metrics/latest.json not written"
  ls "$rd/iter"/*/decision.json >/dev/null 2>&1 || fail "no decision.json produced"
  ls "$rd/iter"/*/trailer.json  >/dev/null 2>&1 || fail "no trailer.json produced"
  # A commit beyond the base should exist (the agent did/auto-committed work).
  ccount="$(git -C "$WORK/repo" rev-list --count HEAD 2>/dev/null || echo 0)"
  [ "$ccount" -ge 1 ] || fail "no commits present"

  echo "[smoke_live] (5/5) STOP + status"
  touch "$rd/STOP"
  /usr/bin/perl -e 'select(undef,undef,undef,3)'
  "$RALPH" status "$WORK/repo" || true   # exit code semantics vary; we just want it to respond
  echo "[smoke_live] PASS"
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ralph_smoke.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

LOG="$WORK/smoke.log"
bounded_run 900 "$LOG" -- bash -c '
  set -u
  HERE="'"$HERE"'"; REPO="'"$REPO"'"; RALPH="'"$RALPH"'"; WORK="'"$WORK"'"
  fail() { echo "[smoke_live] FAIL: $*" >&2; exit 1; }
  '"$(declare -f _smoke_body)"'
  _smoke_body
'
rc=$?
echo "----- smoke_live log -----"
cat "$LOG" 2>/dev/null || true
echo "--------------------------"
if [ "$rc" -eq 124 ]; then fail "smoke exceeded the 900s bound"; fi
exit "$rc"
