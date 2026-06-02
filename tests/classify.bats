#!/usr/bin/env bats
# tests/classify.bats — the exit-code/output oracle (SPEC §7.4, §11 T-CLASSIFY-*).
#
# Exercises lib/classify.sh::classify_result <rc> <transcript-file> → one of
#   success | rate_limit | timeout | transient_crash | fatal_misconfig
# and the silent-zombie guard (rc 0 + quota language ⇒ rate_limit).
# Uses ONLY the public function name from the spec.

load test_helper

setup() {
  ralph_test_env
  require_lib classify.sh
  require_fn classify_result
}

# classify a fixture transcript with a given rc.
classify_fix() {
  run classify_result "$1" "$RALPH_FIXTURES/$2"
}

@test "T-CLASSIFY-success: rc 0 + a normal handoff ⇒ success" {
  classify_fix 0 good_handoff.txt
  [ "$status" -eq 0 ]
  [ "$output" = "success" ]
}

@test "T-CLASSIFY-timeout-rc124: rc 124 (watchdog kill) ⇒ timeout regardless of text" {
  classify_fix 124 good_handoff.txt
  [ "$output" = "timeout" ]
}

@test "T-CLASSIFY-rate-limit: quota/429 language ⇒ rate_limit (non-zero rc)" {
  classify_fix 1 quota.txt
  [ "$output" = "rate_limit" ]
}

@test "T-CLASSIFY-silent-zombie: rc 0 BUT quota language ⇒ rate_limit (not false-green)" {
  classify_fix 0 quota.txt
  [ "$output" = "rate_limit" ]
}

@test "T-CLASSIFY-print-timeout: deadline/print-timeout text ⇒ timeout" {
  classify_fix 1 print_timeout.txt
  [ "$output" = "timeout" ]
}

@test "T-CLASSIFY-fatal: auth/credential failure + non-zero rc ⇒ fatal_misconfig" {
  classify_fix 1 fatal_misconfig.txt
  [ "$output" = "fatal_misconfig" ]
}

@test "T-CLASSIFY-transient: non-zero rc + no special language ⇒ transient_crash" {
  printf 'segfault, unexpected internal error, stack trace\n' > "${BATS_TEST_TMPDIR}/crash.txt"
  run classify_result 1 "${BATS_TEST_TMPDIR}/crash.txt"
  [ "$output" = "transient_crash" ]
}

@test "T-CLASSIFY-empty-success: rc 0 + empty transcript ⇒ success (no quota words)" {
  : > "${BATS_TEST_TMPDIR}/empty.txt"
  run classify_result 0 "${BATS_TEST_TMPDIR}/empty.txt"
  [ "$output" = "success" ]
}
