#!/usr/bin/env bash
# tests/test_helper.bash — shared bats setup for the Ralph test suite (SPEC §11).
#
# Role: every *.bats file `load`s this. It resolves the repo's absolute paths,
# sources the REAL lib/*.sh from /Users/.../antigravity-ralph/lib (never a stub of
# the code under test), installs the stub `agy` on PATH, and provides small
# helpers. It uses ONLY the public function names / file contracts from the spec.
#
# If a lib file or public function another group still owns is absent, the
# relevant test `skip`s with a clear reason instead of erroring — so the suite is
# runnable incrementally as the merge fills in. (bats `skip` is graceful.)
#
# bash 3.2 safe: no `declare -A`, no `local -n`.

# --- repo layout -----------------------------------------------------------
# This file lives at <repo>/tests/test_helper.bash.
RALPH_TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_REPO_ROOT="$(cd "$RALPH_TESTS_DIR/.." && pwd)"
RALPH_LIB="$RALPH_REPO_ROOT/lib"
RALPH_BIN="$RALPH_REPO_ROOT/bin"
RALPH_PROMPTS="$RALPH_REPO_ROOT/prompts"
RALPH_FIXTURES="$RALPH_TESTS_DIR/fixtures"
export RALPH_TESTS_DIR RALPH_REPO_ROOT RALPH_LIB RALPH_BIN RALPH_PROMPTS RALPH_FIXTURES

# Fixture builders + the stub agy installer (always available; we own these).
# shellcheck source=tests/fixtures/setup.sh
. "$RALPH_FIXTURES/setup.sh"
# shellcheck source=tests/stub_agy.sh
. "$RALPH_TESTS_DIR/stub_agy.sh"

# --- lib sourcing (gracefully skip if not yet written) ---------------------
# Source one lib/*.sh; returns 0 if present+sourced, 1 if absent.
ralph_source_lib() {
  local name="$1"
  local f="$RALPH_LIB/$name"
  if [ -f "$f" ]; then
    # shellcheck disable=SC1090
    . "$f"
    return 0
  fi
  return 1
}

# require_lib <file.sh> ...  → skip the current bats test if any is missing.
require_lib() {
  local name
  for name in "$@"; do
    if ! ralph_source_lib "$name"; then
      skip "lib/$name not present yet (owned by another group)"
    fi
  done
}

# require_pylib <file.py> ... → skip if a python helper is missing.
require_pylib() {
  local name
  for name in "$@"; do
    if [ ! -f "$RALPH_LIB/$name" ]; then
      skip "lib/$name not present yet (owned by another group)"
    fi
  done
}

# require_fn <fn> ... → skip if a (presumably-sourced) function isn't defined.
require_fn() {
  local fn
  for fn in "$@"; do
    if ! command -v "$fn" >/dev/null 2>&1 && ! type -t "$fn" >/dev/null 2>&1; then
      skip "function '$fn' not defined (its lib not present / different name)"
    fi
  done
}

# require_cmd <cmd> ... → skip if an external tool is missing.
require_cmd() {
  local c
  for c in "$@"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      skip "external tool '$c' not available"
    fi
  done
}

PY3="$(command -v python3 || true)"

# --- per-test workspace ----------------------------------------------------
# Make a fresh tmp workdir, cd into it, and put a stub agy on PATH.
ralph_make_workspace() {
  RALPH_WORK="${BATS_TEST_TMPDIR:-$(mktemp -d)}/ws.$$.${RANDOM:-0}"
  mkdir -p "$RALPH_WORK"
  install_stub_agy "$RALPH_WORK/bin"
  export RALPH_WORK
}

# Common env so sourced lib/*.sh behave deterministically in tests.
ralph_test_env() {
  export RALPH_VERIFY_REQUIRED="${RALPH_VERIFY_REQUIRED:-1}"
  export RALPH_REVERT_STRATEGY="${RALPH_REVERT_STRATEGY:-reset_hard}"
  export RALPH_MIN_INTERVAL_S="${RALPH_MIN_INTERVAL_S:-1}"
  export RALPH_AGY_TIMEOUT_S="${RALPH_AGY_TIMEOUT_S:-30}"
  export RALPH_BACKOFF_BASE_S="${RALPH_BACKOFF_BASE_S:-1}"
  export RALPH_BACKOFF_CAP_S="${RALPH_BACKOFF_CAP_S:-4}"
  export RALPH_BACKOFF_JITTER_PCT="${RALPH_BACKOFF_JITTER_PCT:-0}"
  export RALPH_PUSH="${RALPH_PUSH:-0}"
  export RALPH_SANDBOX="${RALPH_SANDBOX:-1}"
  export RALPH_SKIP_PERMISSIONS="${RALPH_SKIP_PERMISSIONS:-1}"
  export RALPH_RELAUNCH_ANTIGRAVITY="${RALPH_RELAUNCH_ANTIGRAVITY:-0}"
}

# Locate the `ralph` CLI entrypoint if present (else skip a CLI test).
ralph_cli() {
  if [ -x "$RALPH_BIN/ralph" ]; then printf '%s\n' "$RALPH_BIN/ralph"; return 0; fi
  if [ -f "$RALPH_BIN/ralph" ]; then printf '%s\n' "$RALPH_BIN/ralph"; return 0; fi
  return 1
}

# Locate the supervisor script if present.
ralph_supervisor() {
  if [ -f "$RALPH_BIN/ralph-supervisor.sh" ]; then printf '%s\n' "$RALPH_BIN/ralph-supervisor.sh"; return 0; fi
  return 1
}
