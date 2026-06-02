#!/usr/bin/env bash
# tests/fixtures/setup.sh — fixture git-repo + .ralph builders for the bats suite
# (SPEC §11). Sourced by the test helper (tests/test_helper.bash) and by run.sh.
#
# Role: provide the canned "target" repos and seeded .ralph/ state the ratchet /
# state / supervisor / safety tests run against, plus tiny helpers to mutate a
# metric so a candidate is strictly-better / floor-crossing / verify-failing.
#
# Everything here is bash 3.2 safe (no `declare -A`, no `local -n`). It creates a
# real git repo with a trivial pytest project so `AUTO:pytest_passcount` and the
# verify command have something genuine to measure (anti-fabrication is the whole
# point — fixtures must produce REAL numbers, not stubbed ones).
#
# Public functions (called by name from the .bats files):
#   make_fixture_repo  <dir>                  → empty git repo, identity set, 1 base commit
#   make_python_repo   <dir> [npass]          → git repo with a pytest file of `npass` passing tests
#   add_passing_test   <dir> [n]              → append `n` more passing tests + return (uncommitted)
#   break_python_repo  <dir>                  → introduce a syntax/import error (verify will fail)
#   seed_ralph         <dir>                  → scaffold a minimal valid <dir>/.ralph (config/MISSION/RATCHET/state/...)
#   ralph_dir          <dir>                  → echo "<dir>/.ralph"
#   git_head           <dir>                  → echo current HEAD sha
#   write_metrics_latest <dir> <json>         → write <dir>/.ralph/metrics/latest.json verbatim

set -u

# Re-source guard.
if [ "${__RALPH_FIXTURE_SETUP_SOURCED:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi
__RALPH_FIXTURE_SETUP_SOURCED=1

_git() { git -C "$1" "${@:2}"; }

_git_init_identity() {
  local dir="$1"
  git -C "$dir" init -q
  git -C "$dir" config user.email "ralph-test@example.com"
  git -C "$dir" config user.name "Ralph Test"
  git -C "$dir" config commit.gpgsign false
  # Keep agy's cache/ and .ralph/ out of the tree, per TECH_GROUNDING §1.
  printf '%s\n' ".ralph/" "cache/" "__pycache__/" "*.pyc" > "$dir/.gitignore"
}

ralph_dir() { printf '%s\n' "$1/.ralph"; }
git_head()  { git -C "$1" rev-parse HEAD 2>/dev/null; }

make_fixture_repo() {
  local dir="$1"
  mkdir -p "$dir"
  _git_init_identity "$dir"
  printf '# fixture repo\n' > "$dir/README.md"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "base commit"
}

# Write a stdlib `unittest` file with exactly $npass trivial passing tests.
# We use unittest (not pytest) so the fixture is measurable with ZERO pip deps —
# macOS python3.14 here has no pytest. The REAL harness uses AUTO:pytest_passcount
# in production; the fixture overrides the metric/verify commands (see seed_ralph)
# to stdlib equivalents so the anti-fabrication tests still produce GENUINE
# (non-stubbed) numbers. Each test method is a single `... ok` line under -v.
_write_pytest_file() {
  local dir="$1" npass="${2:-3}"
  local i
  {
    printf 'import unittest\n\n'
    printf 'class FixtureTests(unittest.TestCase):\n'
    i=1
    while [ "$i" -le "$npass" ]; do
      printf '    def test_pass_%d(self):\n        self.assertTrue(True)\n' "$i"
      i=$((i+1))
    done
    printf '\nif __name__ == "__main__":\n    unittest.main()\n'
  } > "$dir/test_fixture.py"
}

make_python_repo() {
  local dir="$1" npass="${2:-3}"
  mkdir -p "$dir"
  _git_init_identity "$dir"
  printf '# fixture python project\n' > "$dir/README.md"
  # A trivial module so coverage has something to import/measure.
  printf 'def add(a, b):\n    return a + b\n' > "$dir/mod.py"
  _write_pytest_file "$dir" "$npass"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "python base: ${npass} passing tests"
}

# Append n more passing unittest methods (does NOT commit — simulates an agent's
# working tree before the harness measures/commits). Built with pure shell to
# avoid awk multi-line -v portability issues on macOS awk.
add_passing_test() {
  local dir="$1" n="${2:-1}"
  local existing i tmp added
  existing="$(grep -cE '^    def test_' "$dir/test_fixture.py" 2>/dev/null || echo 0)"
  tmp="$dir/.test_fixture.py.tmp"
  : > "$tmp"
  added=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      'if __name__ =='*)
        if [ "$added" -eq 0 ]; then
          i=1
          while [ "$i" -le "$n" ]; do
            printf '    def test_added_%d(self):\n        self.assertTrue(True)\n' "$((existing+i))" >> "$tmp"
            i=$((i+1))
          done
          added=1
        fi
        ;;
    esac
    printf '%s\n' "$line" >> "$tmp"
  done < "$dir/test_fixture.py"
  mv "$tmp" "$dir/test_fixture.py"
}

# Introduce a hard failure so the verify command goes red on every retry
# (an import error inside a test method => unittest reports an error/failure).
break_python_repo() {
  local dir="$1" tmp
  tmp="$dir/.test_fixture.py.tmp"
  awk '
    /^if __name__ ==/ && !done {
      print "    def test_broken(self):"
      print "        import nonexistent_module_zzz  # ImportError"
      print "        self.assertTrue(True)"
      done=1
    }
    { print }
  ' "$dir/test_fixture.py" > "$tmp" && mv "$tmp" "$dir/test_fixture.py"
}

write_metrics_latest() {
  local dir="$1" json="$2"
  mkdir -p "$dir/.ralph/metrics"
  printf '%s\n' "$json" > "$dir/.ralph/metrics/latest.json"
}

# Scaffold a minimal but spec-shaped .ralph/ for <dir>. Floors are intentionally
# LOW so a fresh measurement is "strictly better" (tests override as needed).
seed_ralph() {
  local dir="$1"
  local rd="$dir/.ralph"
  mkdir -p "$rd"/metrics "$rd"/iter "$rd"/iterations "$rd"/refs "$rd"/logs "$rd"/archive

  cat > "$rd/config.env" <<'EOF'
RALPH_TARGET_NAME=fixture
RALPH_MAX_ITERATIONS=0
RALPH_MIN_INTERVAL_S=1
RALPH_AGY_TIMEOUT_S=30
RALPH_BACKOFF_BASE_S=1
RALPH_BACKOFF_CAP_S=4
RALPH_BACKOFF_JITTER_PCT=0
RALPH_CRASHLOOP_THRESHOLD=5
RALPH_CRASHLOOP_WINDOW_S=300
RALPH_CRASHLOOP_COOLDOWN_S=2
RALPH_MAX_CONSECUTIVE_REVERTS=40
RALPH_RELAUNCH_ANTIGRAVITY=0
RALPH_SKIP_PERMISSIONS=1
RALPH_SANDBOX=1
RALPH_COMMIT_GATE=none
RALPH_REFEREE_EVERY=10
RALPH_PUSH=0
RALPH_REVERT_STRATEGY=reset_hard
RALPH_VERIFY_REQUIRED=1
RALPH_PROMPT_FILE=prompts/iterate.tmpl
RALPH_VERIFY_CMD="python3 -m unittest discover -q -p 'test_*.py'"
EOF

  cat > "$rd/MISSION.md" <<'EOF'
# MISSION
## North Star
This fixture project is excellent when its tests are comprehensive and green.
## Success Criteria (explicit, checkable)
- SC1: tests pass — metric: tests_pass — target: >= 3
## Hard Constraints (never violate)
- HC1: never edit MISSION.md / RATCHET.json / state.json by hand
- HC2: every change must keep the verify command green
## Ratcheted Metrics (mirrors RATCHET.json)
- tests_pass (up)
## Out of Scope
- network access
EOF

  # canonical (TOFU) copy of the read-only MISSION.md — mirrors `ralph init` (SPEC §3.2, T-SAFE-2)
  # so restore_protected_files() has a pristine reference before any agent tampering.
  mkdir -p "$rd/.canonical"
  cp "$rd/MISSION.md" "$rd/.canonical/MISSION.md"

  cat > "$rd/RATCHET.json" <<EOF
{
  "schema_version": 4,
  "repo_root": "$dir",
  "updated_at": "1970-01-01T00:00:00Z",
  "policy": {
    "accept_rule": "no metric crosses its floor in the wrong direction; >=1 non-frozen metric strictly improves",
    "regression_tolerance": 0,
    "absent_policy": "verify_only",
    "on_reject": "git reset --hard <baseline>; record cause in LEDGER.REJECTED",
    "floor_update": "tighten each floor to the achieved value ONLY after ADVANCE"
  },
  "metrics": {
    "tests_pass":   { "dir": "up",   "floor": 0,   "frozen": false, "cmd": "python3 -m unittest discover -v -p 'test_*.py' 2>&1 | grep -c '... ok'", "tolerance": 0 },
    "lint_errors":  { "dir": "down", "floor": 999, "frozen": false, "cmd": "echo 0", "tolerance": 0 }
  },
  "verify": {
    "required": true,
    "cmd": "python3 -m unittest -q test_fixture",
    "timeout_s": 60,
    "flaky_reverify_runs": 2,
    "supports_focus": false
  },
  "best": null,
  "baseline": null,
  "regression_pending": null,
  "goals_done": false
}
EOF

  cat > "$rd/state.json" <<'EOF'
{
  "iteration": 0,
  "advances": 0, "reverts": 0, "noops": 0,
  "consecutive_failures": 0,
  "consecutive_quota_hits": 0,
  "consecutive_reverts": 0,
  "noop_streak": 0,
  "backoff_s": 0,
  "last_class": "",
  "last_success_iso": "",
  "last_run_started_iso": "",
  "crash_loop_strikes": 0,
  "tier": "T1_correctness",
  "started_iso": "1970-01-01T00:00:00Z"
}
EOF

  cat > "$rd/PROGRESS.md" <<'EOF'
# PROGRESS
EOF

  cat > "$rd/LEDGER.md" <<'EOF'
# LEDGER
## DONE (do not redo — shipped & ratcheted)
## REJECTED (tried, did NOT improve — do not repeat without NEW evidence)
## OPEN (known work, ranked; agent picks the top viable one)
- O-1 (T2) COVERAGE: add more tests for mod.add. evidence: fixture.
EOF

  cat > "$rd/HANDOFF.md" <<'EOF'
# HANDOFF 0000 (seed)
state_after:
  tier: T1_correctness
  metrics: { tests_pass: 0 }
i_did: "Seeded the loop."
next_highest_leverage: "Add a passing test (O-1)."
EOF

  : > "$rd/progress.ndjson"
  printf 'AUTO\n' > "$rd/allow.txt"
}
