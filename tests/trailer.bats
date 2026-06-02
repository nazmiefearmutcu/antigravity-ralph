#!/usr/bin/env bats
# tests/trailer.bats — HANDOFF trailer salvage-ladder cases (SPEC §3.4.2, §11 T-TRAILER-*).
#
# Exercises lib/extract_trailer.py (always exits 0; status via TRAILER_STATUS=...
# on stdout + a written trailer.json) and lib/validate_trailer.py (schema
# coerce/clamp). Uses ONLY the public CLI contract from the spec:
#   python3 lib/extract_trailer.py <agy.stdout> <trailer.json>
#   python3 lib/validate_trailer.py <trailer.json>

load test_helper

setup() {
  ralph_test_env
  require_pylib extract_trailer.py
  OUT="${BATS_TEST_TMPDIR}/trailer.json"
}

# Run the extractor on a fixture; populate $status/$output and $OUT.
extract() {
  run "$PY3" "$RALPH_LIB/extract_trailer.py" "$RALPH_FIXTURES/$1" "$OUT"
}

# A field from the written trailer.json (via jq for robustness).
field() { jq -r "$1" "$OUT"; }

@test "T-TRAILER-good: a clean fenced strict-JSON handoff parses, exit 0, status ok" {
  extract good_handoff.txt
  [ "$status" -eq 0 ]
  [ -f "$OUT" ]
  echo "$output" | grep -q 'TRAILER_STATUS='
  echo "$output" | grep -Eq 'TRAILER_STATUS=(ok|parsed|fenced)'
  [ "$(field '.what_changed')" != "null" ]
  [ "$(field '.files[0]')" = "tests/classify.bats" ]
}

@test "T-TRAILER-missing: no fence + no JSON ⇒ status=missing, synthesized object, exit 0" {
  extract trailer_missing.txt
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'TRAILER_STATUS=missing'
  # A synthesized object must still be valid JSON with the required keys present.
  jq -e '.what_changed != null' "$OUT"
  jq -e 'has("files")' "$OUT"
  jq -e 'has("done_with_explicit_goals")' "$OUT"
}

@test "T-TRAILER-bare: bare JSON object (no fence) is recovered, exit 0" {
  extract trailer_bare_json.txt
  [ "$status" -eq 0 ]
  jq -e '.what_changed | test("bare JSON")' "$OUT"
}

@test "T-TRAILER-multiple: multiple fences ⇒ status=multiple, LAST one wins" {
  extract trailer_multiple.txt
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'TRAILER_STATUS=multiple'
  jq -e '.what_changed | test("SECOND")' "$OUT"
  jq -e '.files[0] == "right.py"' "$OUT"
}

@test "T-TRAILER-code-fenced: markdown json code-fence inside the handoff is stripped, exit 0" {
  extract trailer_code_fenced.txt
  [ "$status" -eq 0 ]
  jq -e '.metrics_after.tests_pass == 20' "$OUT"
}

@test "T-TRAILER-trailing-comma: trailing commas are salvaged, exit 0" {
  extract trailer_trailing_comma.txt
  [ "$status" -eq 0 ]
  jq -e '.metrics_after.coverage_pct == 70.0' "$OUT"
}

@test "T-TRAILER-single-quote: single→double quote salvage, exit 0" {
  extract trailer_single_quote.txt
  [ "$status" -eq 0 ]
  jq -e '.tier == "T1_correctness"' "$OUT"
}

@test "T-TRAILER-python-literal: True/False/None rewritten to JSON, exit 0" {
  extract trailer_python_literal.txt
  [ "$status" -eq 0 ]
  jq -e '.done_with_explicit_goals == false' "$OUT"
  # lint_errors was Python None → JSON null
  jq -e '.metrics_after.lint_errors == null' "$OUT"
}

@test "T-TRAILER-truncated: truncated/unbalanced JSON yields a coerced object, exit 0" {
  extract trailer_truncated.txt
  [ "$status" -eq 0 ]
  [ -f "$OUT" ]
  # Whatever the ladder recovers, it MUST be valid JSON with required keys.
  jq -e 'has("what_changed") and has("files") and has("done_with_explicit_goals")' "$OUT"
}

@test "T-TRAILER-validate: validate_trailer.py coerces/clamps missing keys + confidence" {
  require_pylib validate_trailer.py
  # A trailer that is valid JSON but missing keys + an out-of-range confidence.
  printf '%s\n' '{ "what_changed": "x", "confidence": 5 }' > "$OUT"
  run "$PY3" "$RALPH_LIB/validate_trailer.py" "$OUT"
  [ "$status" -eq 0 ]
  # confidence clamped into [0,1]; missing required keys filled.
  jq -e '.confidence <= 1 and .confidence >= 0' "$OUT"
  jq -e 'has("files")' "$OUT"
  jq -e 'has("tier")' "$OUT"
  jq -e 'has("done_with_explicit_goals")' "$OUT"
}

@test "T-TRAILER-extract-always-exit-0: even garbage input exits 0 (loop never aborts)" {
  printf 'total garbage \x00 not json at all <<<RALPH' > "${BATS_TEST_TMPDIR}/garbage.txt"
  run "$PY3" "$RALPH_LIB/extract_trailer.py" "${BATS_TEST_TMPDIR}/garbage.txt" "$OUT"
  [ "$status" -eq 0 ]
  [ -f "$OUT" ]
}
