#!/usr/bin/env bats
# tests/review_fixes.bats — regression tests pinning the adversarial-review fixes (2026-06).
# Each asserts a bug the 6-reviewer gate found, so it can never silently come back.

load test_helper

setup() {
  ralph_test_env
  WS="${BATS_TEST_TMPDIR}/ws"
  make_python_repo "$WS/repo" 3
  seed_ralph "$WS/repo"
  cd "$WS/repo"
  export TARGET="$WS/repo" REPO_ROOT="$WS/repo" RALPH_DIR="$WS/repo/.ralph"
  export RATCHET_JSON="$WS/repo/.ralph/RATCHET.json"
}

# ── ratchet HIGH: update_best must NOT clobber a prior best high-water with a null candidate value ──
@test "RF-1: update_best preserves prior best when a candidate metric measured null" {
  require_lib ratchet.sh
  require_fn update_best
  # seed a prior best with tests_pass=142
  jq '.best={commit:"old",metrics:{tests_pass:142}}' "$RATCHET_JSON" > "$RATCHET_JSON.t"
  mv "$RATCHET_JSON.t" "$RATCHET_JSON"
  # candidate measured tests_pass=null (transient tool failure) but improved coverage_pct=80
  printf '%s' '{"tests_pass":null,"coverage_pct":80}' > cand.json
  update_best "newsha" 5 cand.json "merged-best test"
  # prior high-water for tests_pass must SURVIVE; coverage added
  run jq -r '.best.metrics.tests_pass' "$RATCHET_JSON"
  [ "$output" = "142" ]
  run jq -r '.best.metrics.coverage_pct' "$RATCHET_JSON"
  [ "$output" = "80" ]
}

# ── safety CRITICAL: the EXECUTED metric command comes from canonical, never the agent-writable file ──
@test "RF-2: resolve_metric_cmd takes the command from .canonical, ignoring tampered RATCHET.json" {
  require_lib ratchet.sh
  require_fn resolve_metric_cmd
  mkdir -p "$RALPH_DIR/.canonical"
  printf '%s' '{"verify":"true","metrics":{"tests_pass":"echo 7"}}' > "$RALPH_DIR/.canonical/RATCHET.cmds.json"
  # agent tampers the live RATCHET.json with a hostile command
  jq '.metrics.tests_pass.cmd="touch /tmp/ralph_pwned_$$"' "$RATCHET_JSON" > "$RATCHET_JSON.t" && mv "$RATCHET_JSON.t" "$RATCHET_JSON"
  run resolve_metric_cmd tests_pass
  [ "$output" = "echo 7" ]                       # canonical wins; the tamper is never returned
  [ ! -e "/tmp/ralph_pwned_$$" ]                 # and was never executed
}

# ── safety HIGH (INV-9): guard_no_push must reject a lookalike host (substring match bug) ──
@test "RF-3: guard_no_push refuses a 'evil-github.com' lookalike even with an owned-looking path" {
  require_lib gate.sh
  require_fn guard_no_push
  local rec="${BATS_TEST_TMPDIR}/push.rec"; : > "$rec"
  local bindir="${BATS_TEST_TMPDIR}/bin"; mkdir -p "$bindir"
  local REAL_GIT; REAL_GIT="$(command -v git)"
  cat > "$bindir/git" <<EOF
#!/bin/sh
for a in "\$@"; do [ "\$a" = "push" ] && { echo "PUSH \$*" >> "$rec"; exit 0; }; done
exec "$REAL_GIT" "\$@"
EOF
  chmod +x "$bindir/git"; PATH="$bindir:$PATH"
  git remote remove origin 2>/dev/null || true
  git remote add origin "https://evil-github.com/nazmiefearmutcu/repo.git"
  export RALPH_PUSH=1
  guard_no_push || true
  [ ! -s "$rec" ]                                # NO push was issued to the lookalike host
}

# ── safety HIGH (INV-9): a real owned remote IS allowed (so the strict parser isn't over-tight) ──
@test "RF-4: guard_no_push allows the exact owned github.com remote" {
  require_lib gate.sh
  require_fn guard_no_push
  local rec="${BATS_TEST_TMPDIR}/push2.rec"; : > "$rec"
  local bindir="${BATS_TEST_TMPDIR}/bin2"; mkdir -p "$bindir"
  local REAL_GIT; REAL_GIT="$(command -v git)"
  cat > "$bindir/git" <<EOF
#!/bin/sh
for a in "\$@"; do [ "\$a" = "push" ] && { echo "PUSH \$*" >> "$rec"; exit 0; }; done
exec "$REAL_GIT" "\$@"
EOF
  chmod +x "$bindir/git"; PATH="$bindir:$PATH"
  git remote remove origin 2>/dev/null || true
  git remote add origin "git@github.com:nazmiefearmutcu/repo.git"
  export RALPH_PUSH=1 RALPH_PUSH_OWNERS=nazmiefearmutcu
  guard_no_push || true
  grep -q '^PUSH' "$rec"                         # a (non-force) push WAS issued to the owned remote
  ! grep -q -- '--force' "$rec"                  # and it was never a force-push
}
