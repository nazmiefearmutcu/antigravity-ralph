#!/usr/bin/env bash
# tests/stub_agy.sh — a FAKE `agy` placed on PATH during tests (SPEC §11).
#
# Role: the test harness's stand-in for the real Antigravity `agy` CLI so the
# ratchet / supervisor / classifier logic can be exercised WITHOUT burning AI
# credits or needing Antigravity running. The ratchet and supervisor invoke
# `agy -p "<prompt>" ...`; this script ignores the prompt, prints a canned
# transcript from a fixture, optionally mutates+commits the workspace, and exits
# with a chosen code — exactly the surface §7.2 / §5.1 observe.
#
# It is driven ENTIRELY by environment variables (so a single on-PATH copy can
# play every role a test needs without editing the script):
#
#   STUB_AGY_FIXTURE   absolute (or fixtures-relative) path to a transcript file
#                      whose contents are printed verbatim to stdout. If unset,
#                      a minimal valid handoff transcript is synthesized.
#   STUB_AGY_EXIT      integer exit code to return (default 0). The classifier
#                      maps rc + transcript → success|rate_limit|timeout|...
#   STUB_AGY_COMMIT    if "1", create/append a file in the workspace and `git
#                      commit` it (simulating an agent that did real work + ran
#                      `git commit` itself, per TECH_GROUNDING §1). Controlled by:
#                        STUB_AGY_COMMIT_FILE   path (rel to workspace) to write
#                                               (default: ralph_change.txt)
#                        STUB_AGY_COMMIT_BODY   bytes to append to that file
#                                               (default: a unique marker line)
#                        STUB_AGY_COMMIT_MSG    commit message
#                                               (default: "stub agy change")
#   STUB_AGY_WRITE_ONLY  if "1", write the change file but do NOT commit it
#                        (simulates "agent forgot to commit"; §5.1 STEP C).
#   STUB_AGY_DELAY_S   if set, sleep this many seconds before doing anything
#                      (used by bounded_run / timeout tests). Uses /usr/bin/perl
#                      so it is interruptible by the group-kill watchdog.
#   STUB_AGY_WORKDIR   workspace to operate in. Default: value of --add-dir if
#                      present on the argv, else $PWD.
#   STUB_AGY_LOG       if set, append the received argv to this file (for asserting
#                      how the harness invoked agy, e.g. --sandbox / --print-timeout).
#
# This file is BOTH the real stub installed on PATH (as a file literally named
# `agy`) AND sourceable for its helper; install_stub_agy() (below) is the helper
# the .bats files call to put a copy named `agy` first on PATH.
#
# Portability: macOS /bin/bash is 3.2 — NO `declare -A`, NO `local -n`. This
# script avoids both. It uses only POSIX-ish bash 3.2 features.

set -u

# Record our own path early (works in bash via BASH_SOURCE; falls back to $0).
# Used by install_stub_agy when no explicit <src> is given.
__STUB_AGY_SELF="${BASH_SOURCE:-$0}"

# Re-source guard (this file is occasionally sourced for install_stub_agy()).
if [ "${__STUB_AGY_SH_SOURCED:-}" = "1" ] && [ "${__STUB_AGY_AS_MAIN:-}" != "1" ]; then
  return 0 2>/dev/null || true
fi
__STUB_AGY_SH_SOURCED=1

# ---------------------------------------------------------------------------
# install_stub_agy <bin_dir> [<src>]
#   Copy this stub to <bin_dir>/agy (executable) and prepend <bin_dir> to PATH
#   in the CALLER's shell. Tests do:  install_stub_agy "$BATS_TEST_TMPDIR/bin"
# ---------------------------------------------------------------------------
install_stub_agy() {
  local bindir="$1"
  local src="${2:-}"
  if [ -z "$src" ]; then
    # Prefer BASH_SOURCE (bash); fall back to a recorded path or $0 so this is
    # usable when sourced from zsh or another shell during ad-hoc checks.
    src="${BASH_SOURCE:-${__STUB_AGY_SELF:-$0}}"
  fi
  mkdir -p "$bindir"
  cp "$src" "$bindir/agy"
  chmod +x "$bindir/agy"
  case ":$PATH:" in
    *":$bindir:"*) : ;;
    *) PATH="$bindir:$PATH" ;;
  esac
  export PATH
}

# ---------------------------------------------------------------------------
# The actual stub behavior when this file is RUN as `agy`.
# ---------------------------------------------------------------------------
_stub_agy_main() {
  # Parse just enough of agy's argv to find --add-dir and to log the call.
  local add_dir=""
  local prev=""
  local a
  for a in "$@"; do
    case "$prev" in
      --add-dir) add_dir="$a" ;;
    esac
    prev="$a"
  done

  if [ -n "${STUB_AGY_LOG:-}" ]; then
    printf '%s\n' "$*" >> "$STUB_AGY_LOG" 2>/dev/null || true
  fi

  local workdir="${STUB_AGY_WORKDIR:-}"
  if [ -z "$workdir" ]; then
    if [ -n "$add_dir" ]; then workdir="$add_dir"; else workdir="$PWD"; fi
  fi

  # Optional delay (interruptible — group-kill watchdog must be able to reap us).
  if [ -n "${STUB_AGY_DELAY_S:-}" ]; then
    /usr/bin/perl -e 'select(undef,undef,undef,$ARGV[0])' "${STUB_AGY_DELAY_S}" 2>/dev/null || sleep "${STUB_AGY_DELAY_S}" 2>/dev/null || true
  fi

  # Optionally do real work in the workspace.
  if [ "${STUB_AGY_COMMIT:-0}" = "1" ] || [ "${STUB_AGY_WRITE_ONLY:-0}" = "1" ]; then
    local f="${STUB_AGY_COMMIT_FILE:-ralph_change.txt}"
    local body="${STUB_AGY_COMMIT_BODY:-stub change $(date +%s)-$$-$RANDOM}"
    local msg="${STUB_AGY_COMMIT_MSG:-stub agy change}"
    if [ -d "$workdir" ]; then
      printf '%s\n' "$body" >> "$workdir/$f"
      if [ "${STUB_AGY_COMMIT:-0}" = "1" ]; then
        git -C "$workdir" add -A >/dev/null 2>&1 || true
        git -C "$workdir" commit -q -m "$msg" >/dev/null 2>&1 || true
      fi
    fi
  fi

  # Emit the transcript.
  local fix="${STUB_AGY_FIXTURE:-}"
  if [ -n "$fix" ] && [ -f "$fix" ]; then
    cat "$fix"
  elif [ -n "$fix" ] && [ -f "$(dirname "${BASH_SOURCE[0]}")/fixtures/$fix" ]; then
    cat "$(dirname "${BASH_SOURCE[0]}")/fixtures/$fix"
  else
    # Synthesize a minimal, valid handoff so plain `agy -p` always parses.
    cat <<'EOF'
Did one small improvement this iteration.
<<<RALPH_HANDOFF
{ "what_changed": "stub change", "files": ["ralph_change.txt"], "tier": "T2_coverage",
  "metrics_after": { "tests_pass": 0, "coverage_pct": 0, "lint_errors": 0, "bench_p95_ms": 0 },
  "next_candidate": "stub next", "i_did_NOT": "nothing deferred", "confidence": 0.5,
  "done_with_explicit_goals": false }
RALPH_HANDOFF>>>
EOF
  fi

  return "${STUB_AGY_EXIT:-0}"
}

# Run as a program iff invoked directly (i.e. as the on-PATH `agy`), not when
# sourced for install_stub_agy().
case "${0##*/}" in
  agy|stub_agy.sh)
    # When the file is named `agy` on PATH it is executed; when a test sources
    # `stub_agy.sh` to get install_stub_agy, $0 is the test runner, not us.
    if [ "${0##*/}" = "agy" ] || [ "${__STUB_AGY_AS_MAIN:-}" = "1" ]; then
      _stub_agy_main "$@"
      exit $?
    fi
    ;;
esac
