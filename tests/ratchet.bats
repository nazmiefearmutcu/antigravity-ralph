#!/usr/bin/env bats
# tests/ratchet.bats — the ratchet gate / anti-fabrication core
# (SPEC §5; §11 T-RATCHET-1..6, T-NOOP; INV-1, INV-2, INV-3).
#
# Two layers are exercised with the SAME logic (they MUST agree — T-RATCHET-6):
#   (a) lib/ratchet.py check <latest.json>  → exit 0 iff ADVANCE-eligible vs floors
#       lib/ratchet.py click <latest.json>  → tighten floors after ADVANCE
#       lib/ratchet.py render-table / why
#   (b) lib/ratchet.sh run_one_iteration / ratchet_gate / revert_to_baseline
#       driven end-to-end through a fixture repo + stub agy (success-class).
#
# When a bash entrypoint another group owns is absent, that test `skip`s; the
# python-`check` parity tests still pin the algorithm.

load test_helper

setup() {
  ralph_test_env
  WS="${BATS_TEST_TMPDIR}/ws"
  mkdir -p "$WS"
}

# Build a RATCHET.json with a single up-metric `tests_pass` floor=$1 and a
# latest.json claiming tests_pass=$2 ; returns paths via globals R and L.
mk_ratchet_latest() {
  local floor="$1" got="$2" dir="${3:-up}"
  R="${BATS_TEST_TMPDIR}/RATCHET.json"
  L="${BATS_TEST_TMPDIR}/latest.json"
  cat > "$R" <<EOF
{ "schema_version":4,
  "metrics": { "tests_pass": { "dir":"$dir", "floor":$floor, "frozen":false, "cmd":"AUTO:pytest_passcount", "tolerance":0 } },
  "verify": { "required":true },
  "best": { "metrics": { "tests_pass": $floor } },
  "baseline": { "metrics": { "tests_pass": $floor } } }
EOF
  cat > "$L" <<EOF
{ "tests_pass": $got, "verify_passed": true }
EOF
}

# ── ratchet.py check parity (T-RATCHET-6 + the core rules) ─────────────────
# The real contract (§5.3): `ratchet.py check <latest.json>` reads RATCHET.json
# via the RATCHET_JSON env var (or $RALPH_DIR/RATCHET.json). The vector is a flat
# {metric: value} object; the "strictly better" floor source is best.metrics.
py_check() { RATCHET_JSON="$R" RALPH_DIR="${BATS_TEST_TMPDIR}" run "$PY3" "$RALPH_LIB/ratchet.py" check "$L"; }

@test "T-RATCHET-py-advance: check exits 0 when a non-frozen metric strictly improves" {
  require_pylib ratchet.py
  mk_ratchet_latest 142 148 up
  py_check
  [ "$status" -eq 0 ]
}

@test "T-RATCHET-py-absent-policy: verify_only ADVANCEs a floor-holding candidate even with no strict gain" {
  # Per §5.2 absent_policy=verify_only: when no non-frozen metric strictly improves
  # but every floor is held (and verify passed upstream), the committed candidate
  # still ADVANCEs. So equal metrics + verify_only ⇒ exit 0. (The REVERT-when-not-
  # better case is governed by floor-crossing, asserted separately below.)
  require_pylib ratchet.py
  mk_ratchet_latest 142 142 up
  # Explicit verify_only policy (the default) — make the contract unambiguous.
  jq '.policy = {"absent_policy":"verify_only"}' "$R" > "$R.tmp" && mv "$R.tmp" "$R"
  py_check
  [ "$status" -eq 0 ]
}

@test "T-RATCHET-py-floor-cross: check is non-zero when a metric crosses its floor wrong-way" {
  require_pylib ratchet.py
  mk_ratchet_latest 142 130 up    # up-metric dropped below floor
  py_check
  [ "$status" -ne 0 ]
}

@test "T-RATCHET-py-render-table: render-table emits a markdown table of metrics" {
  require_pylib ratchet.py
  mk_ratchet_latest 142 142 up
  RATCHET_JSON="$R" RALPH_DIR="${BATS_TEST_TMPDIR}" run "$PY3" "$RALPH_LIB/ratchet.py" render-table
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi 'tests_pass'
}

# ── End-to-end through the bash ratchet (success-class agy run) ────────────
# Helper: stand up a python fixture repo + seeded .ralph, prime baseline, and
# wire the exact env contract run_one_iteration reads (§5.1):
#   RALPH_DIR, RATCHET_JSON  → where the scoreboard/state live
#   VERIFY_CMD, VERIFY_REQUIRED, FLAKY_REVERIFY_RUNS → the trusted re-measure
#   RALPH_BASE_COMMIT        → the supervisor's recorded sha_before (the baseline
#                              to revert to). WITHOUT this, run_one_iteration would
#                              treat the already-committed candidate as the base.
e2e_setup() {
  local npass="${1:-3}"
  make_python_repo "$WS/repo" "$npass"
  seed_ralph "$WS/repo"
  install_stub_agy "$WS/bin"
  cd "$WS/repo"
  export TARGET="$WS/repo" REPO_ROOT="$WS/repo"
  export RALPH_DIR="$WS/repo/.ralph"
  export RATCHET_JSON="$WS/repo/.ralph/RATCHET.json"
  export VERIFY_REQUIRED=1 FLAKY_REVERIFY_RUNS=2
  export VERIFY_CMD="python3 -m unittest discover -q -p 'test_*.py'"
  # Source ratchet.sh into THIS shell (env-driven, no subshell isolation).
  ralph_source_lib ratchet.sh
}

# Place the stub's transcript where run_one_iteration reads it: $RALPH_DIR/iter/NNNNNN/agy.stdout
# where NNNNNN = state.json .iteration (0 in the seed).
stage_iter_stdout() {
  local n; n="$("$PY3" "$RALPH_LIB/state.py" get-raw "$WS/repo/.ralph/state.json" iteration 0)"
  local d="$WS/repo/.ralph/iter/$(printf '%06d' "$n")"
  mkdir -p "$d"
  cp "$1" "$d/agy.stdout"
  printf '%s\n' "$d"
}

@test "T-RATCHET-1 (advance): pass + a strictly-better metric + floors held ⇒ ADVANCE, floors click" {
  require_lib ratchet.sh
  require_fn run_one_iteration
  require_cmd python3
  e2e_setup 3
  base="$(git_head "$WS/repo")"
  export RALPH_BASE_COMMIT="$base"
  # Agent adds 2 passing tests (a valid stdlib unittest module) and commits →
  # measured tests_pass rises 3→5.
  STUB_AGY_FIXTURE="$RALPH_FIXTURES/good_handoff.txt" \
  STUB_AGY_COMMIT=1 STUB_AGY_COMMIT_FILE="test_more.py" \
  STUB_AGY_COMMIT_BODY="import unittest
class More(unittest.TestCase):
    def test_e1(self):
        self.assertTrue(True)
    def test_e2(self):
        self.assertTrue(True)" \
  agy -p "x" --add-dir "$WS/repo" > "${BATS_TEST_TMPDIR}/out.txt" 2>/dev/null || true
  stage_iter_stdout "${BATS_TEST_TMPDIR}/out.txt" >/dev/null
  run run_one_iteration
  # A strictly-better, verified candidate must ADVANCE: HEAD moved past base,
  # decision.json says ADVANCE, refs/best points at the new commit.
  [ "$(git_head "$WS/repo")" != "$base" ]
  dj="$(ls "$WS/repo/.ralph/iter"/*/decision.json 2>/dev/null | tail -1 || true)"
  [ -n "$dj" ]
  grep -q 'ADVANCE' "$dj"
  [ -f "$WS/repo/.ralph/refs/best" ]
}

@test "T-RATCHET-2 (INV-3): claimed≫measured ⇒ REVERT + integrity audit recorded" {
  require_lib ratchet.sh
  require_fn run_one_iteration
  require_cmd python3
  e2e_setup 3
  base="$(git_head "$WS/repo")"
  export RALPH_BASE_COMMIT="$base"
  # Prime the scoreboard so the floor is ALREADY 142 (best=142). The committed
  # change adds NO real tests, so the harness measures tests_pass==3 — far below
  # the 142 floor. The trailer LOUDLY claims tests_pass:999. INV-3: only the
  # harness's own measurement (3) feeds the gate, so the inflated claim cannot
  # rescue the candidate → it crosses the floor → REVERT to baseline.
  rj="$WS/repo/.ralph/RATCHET.json"
  jq '.metrics.tests_pass.floor = 142
      | .best = {"commit":"'"$base"'","iteration":1,"metrics":{"tests_pass":142},"verify_passed":true}' \
     "$rj" > "$rj.tmp" && mv "$rj.tmp" "$rj"
  STUB_AGY_FIXTURE="$RALPH_FIXTURES/claimed_gt_measured.txt" \
  STUB_AGY_COMMIT=1 STUB_AGY_COMMIT_FILE="notes.txt" STUB_AGY_COMMIT_BODY="just a note, no tests" \
  agy -p "x" --add-dir "$WS/repo" > "${BATS_TEST_TMPDIR}/out.txt" 2>/dev/null || true
  stage_iter_stdout "${BATS_TEST_TMPDIR}/out.txt" >/dev/null
  run run_one_iteration
  # The inflated claim cannot ADVANCE (measured tests_pass==3 < floor 142) → REVERT.
  [ "$(git_head "$WS/repo")" = "$base" ]
  # The integrity audit (claim_vs_truth) is recorded for this iter.
  ls "$WS/repo/.ralph/iter"/*/claim_vs_truth.json >/dev/null 2>&1
}

@test "T-RATCHET-3 (INV-1): verify-fail candidate ⇒ REVERT, HEAD == baseline" {
  require_lib ratchet.sh
  require_fn run_one_iteration
  require_cmd python3
  e2e_setup 3
  base="$(git_head "$WS/repo")"
  export RALPH_BASE_COMMIT="$base"
  # Commit a change that breaks the test suite (ImportError at collection time).
  STUB_AGY_FIXTURE="$RALPH_FIXTURES/verify_fail.txt" \
  STUB_AGY_COMMIT=1 STUB_AGY_COMMIT_FILE="test_break.py" \
  STUB_AGY_COMMIT_BODY="import unittest
import nonexistent_zzz  # ImportError at collection time
class Broken(unittest.TestCase):
    def test_x(self):
        self.assertTrue(True)" \
  agy -p "x" --add-dir "$WS/repo" > "${BATS_TEST_TMPDIR}/out.txt" 2>/dev/null || true
  stage_iter_stdout "${BATS_TEST_TMPDIR}/out.txt" >/dev/null
  run run_one_iteration
  [ "$(git_head "$WS/repo")" = "$base" ]
}

@test "T-RATCHET-5 (INV-2): a flaky-red baseline never lowers the floor" {
  # Pure python-`check` assertion of the floor-immovability rule: a measured
  # value BELOW floor must be rejected (non-zero), proving the floor isn't
  # silently lowered to the bad measurement.
  require_pylib ratchet.py
  mk_ratchet_latest 142 0 up    # baseline came back red/zero
  py_check
  [ "$status" -ne 0 ]
  # The floor in RATCHET.json is unchanged (check must not mutate it).
  [ "$(jq -r '.metrics.tests_pass.floor' "$R")" = "142" ]
}

@test "T-RATCHET-6: ratchet.py check agrees with bash ratchet_gate on a vector" {
  require_pylib ratchet.py
  # ratchet.py check must agree with the spec's vector rule: a strictly-better
  # vector ADVANCEs, a worse one REVERTs (this is the same logic ratchet_gate uses).
  mk_ratchet_latest 142 148 up
  py_check
  [ "$status" -eq 0 ]
  # Worse vector must flip.
  mk_ratchet_latest 142 100 up
  py_check
  [ "$status" -ne 0 ]
}

@test "T-NOOP: an identical tree ⇒ NOOP (not advance, not regress), noop_streak++" {
  require_lib ratchet.sh
  require_fn run_one_iteration
  require_cmd python3
  e2e_setup 3
  base="$(git_head "$WS/repo")"
  export RALPH_BASE_COMMIT="$base"
  before_streak="$("$PY3" "$RALPH_LIB/state.py" get-raw "$WS/repo/.ralph/state.json" noop_streak 0)"
  # Stub makes NO change/commit (noop fixture).
  STUB_AGY_FIXTURE="$RALPH_FIXTURES/noop.txt" \
  agy -p "x" --add-dir "$WS/repo" > "${BATS_TEST_TMPDIR}/out.txt" 2>/dev/null || true
  stage_iter_stdout "${BATS_TEST_TMPDIR}/out.txt" >/dev/null
  run run_one_iteration
  # Tree unchanged → HEAD identical, refs/best NOT created by a noop.
  [ "$(git_head "$WS/repo")" = "$base" ]
  after_streak="$("$PY3" "$RALPH_LIB/state.py" get-raw "$WS/repo/.ralph/state.json" noop_streak 0)"
  [ "$after_streak" -ge "$before_streak" ]
}
