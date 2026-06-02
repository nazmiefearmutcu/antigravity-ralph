#!/usr/bin/env bash
# tests/run.sh — run the Ralph bats suite, degrading gracefully (SPEC §11).
#
# Role: a single entrypoint that finds `bats` (system, vendored, or PATH), runs
# every tests/*.bats, and — if bats is NOT installed — prints clear guidance and
# a non-fatal status instead of erroring out. bats-core is REQUIRED for the unit
# suite (see tests/README.md); this script just makes its absence diagnosable.
#
# Usage:
#   tests/run.sh                 # run all *.bats
#   tests/run.sh ratchet.bats    # run a subset (names or globs, repeatable)
#   BATS=/path/to/bats tests/run.sh
#
# Exit codes: 0 all-passed · non-zero some-failed · 0-with-warning if bats absent
# (so CI can choose to treat "no bats" as a soft skip rather than a hard fail —
# matching the brief's "degrade gracefully").

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

# --- locate bats ----------------------------------------------------------
find_bats() {
  if [ -n "${BATS:-}" ] && [ -x "${BATS}" ]; then printf '%s\n' "$BATS"; return 0; fi
  if command -v bats >/dev/null 2>&1; then command -v bats; return 0; fi
  # Common vendored locations.
  for c in \
    "$REPO/tests/vendor/bats-core/bin/bats" \
    "$REPO/vendor/bats-core/bin/bats" \
    "/opt/homebrew/bin/bats" \
    "/usr/local/bin/bats"; do
    [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

BATS_BIN="$(find_bats || true)"

if [ -z "$BATS_BIN" ]; then
  cat >&2 <<EOF
[run.sh] bats-core not found — the unit suite needs it.

Install one of:
  brew install bats-core
  # or vendor it:
  git clone --depth 1 https://github.com/bats-core/bats-core "$REPO/tests/vendor/bats-core"

Then re-run:  tests/run.sh
(Or set BATS=/path/to/bats.)

Sanity checks that DO run without bats:
EOF
  # Run the few stdlib-only smoke checks so 'no bats' still gives signal.
  ok=0; fail=0
  if command -v python3 >/dev/null 2>&1; then
    if [ -f "$REPO/lib/extract_trailer.py" ]; then
      if python3 "$REPO/lib/extract_trailer.py" "$HERE/fixtures/good_handoff.txt" "/tmp/.ralph_runsh.$$.json" >/dev/null 2>&1; then
        echo "  [ok] extract_trailer.py parses good_handoff.txt (exit 0)"; ok=$((ok+1))
      else
        echo "  [FAIL] extract_trailer.py did not exit 0"; fail=$((fail+1))
      fi
      rm -f "/tmp/.ralph_runsh.$$.json"
    else
      echo "  [skip] lib/extract_trailer.py not present yet"
    fi
  fi
  echo "[run.sh] ran $ok smoke check(s), $fail failure(s); install bats for the full suite." >&2
  [ "$fail" -eq 0 ] && exit 0 || exit 1
fi

echo "[run.sh] using bats: $BATS_BIN"
"$BATS_BIN" --version 2>/dev/null || true

# --- select files ---------------------------------------------------------
if [ "$#" -gt 0 ]; then
  files=()
  for a in "$@"; do
    case "$a" in
      /*) files+=("$a") ;;
      *)  files+=("$HERE/$a") ;;
    esac
  done
else
  files=()
  for f in "$HERE"/*.bats; do
    [ -e "$f" ] && files+=("$f")
  done
fi

if [ "${#files[@]}" -eq 0 ]; then
  echo "[run.sh] no .bats files found in $HERE" >&2
  exit 0
fi

echo "[run.sh] running ${#files[@]} test file(s)"
"$BATS_BIN" "${files[@]}"
