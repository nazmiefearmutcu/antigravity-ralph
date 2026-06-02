#!/usr/bin/env bats
# tests/safety.bats — push allowlist + protected-file restore
# (SPEC §5.7, §12; §11 T-SAFE-1 / INV-9, T-SAFE-2).
#
# Public surfaces:
#   lib/gate.sh  guard_no_push   — never pushes unless RALPH_PUSH=1 AND origin is
#                                  under the user's GitHub org; never force-pushes (INV-9).
#   lib/ratchet.sh (or gate.sh) restore-protected — agent edits to .ralph/MISSION.md /
#                                  RATCHET.json / state.json ⇒ iteration rejected + canonical restored.

load test_helper

setup() {
  ralph_test_env
  WS="${BATS_TEST_TMPDIR}/ws"
  make_python_repo "$WS/repo" 3
  seed_ralph "$WS/repo"
  install_stub_agy "$WS/bin"
  cd "$WS/repo"
  export TARGET="$WS/repo" REPO_ROOT="$WS/repo"
}

# A fake `git` that records any `push` invocation instead of performing it, so we
# can assert guard_no_push NEVER calls push when it must refuse. Real git is used
# for everything else.
install_push_recorder() {
  local bindir="$1" rec="$2"
  mkdir -p "$bindir"
  REAL_GIT="$(command -v git)"
  cat > "$bindir/git" <<EOF
#!/bin/sh
for a in "\$@"; do
  if [ "\$a" = "push" ]; then echo "PUSH_CALLED \$*" >> "$rec"; exit 0; fi
done
exec "$REAL_GIT" "\$@"
EOF
  chmod +x "$bindir/git"
  case ":$PATH:" in *":$bindir:"*) : ;; *) PATH="$bindir:$PATH" ;; esac
  export PATH
}

@test "T-SAFE-1a (INV-9): RALPH_PUSH=0 ⇒ guard_no_push refuses to push" {
  require_lib gate.sh
  require_fn guard_no_push
  rec="${BATS_TEST_TMPDIR}/push.rec"; : > "$rec"
  install_push_recorder "${BATS_TEST_TMPDIR}/gitshim" "$rec"
  git -C "$WS/repo" remote add origin "git@github.com:nazmiefearmutcu/antigravity-ralph.git" 2>/dev/null || true
  export RALPH_PUSH=0
  ( cd "$WS/repo" && guard_no_push ) || true
  [ ! -s "$rec" ]    # no PUSH_CALLED recorded
}

@test "T-SAFE-1b (INV-9): RALPH_PUSH=1 but FOREIGN remote ⇒ still refuses" {
  require_lib gate.sh
  require_fn guard_no_push
  rec="${BATS_TEST_TMPDIR}/push.rec"; : > "$rec"
  install_push_recorder "${BATS_TEST_TMPDIR}/gitshim" "$rec"
  git -C "$WS/repo" remote add origin "git@github.com:someoneelse/not-yours.git" 2>/dev/null || true
  export RALPH_PUSH=1
  ( cd "$WS/repo" && guard_no_push ) || true
  [ ! -s "$rec" ]    # foreign remote ⇒ no push
}

@test "T-SAFE-1c (INV-9): RALPH_PUSH=1 + OWNED remote ⇒ a (non-force) push may be issued" {
  require_lib gate.sh
  require_fn guard_no_push
  rec="${BATS_TEST_TMPDIR}/push.rec"; : > "$rec"
  install_push_recorder "${BATS_TEST_TMPDIR}/gitshim" "$rec"
  git -C "$WS/repo" remote add origin "git@github.com:nazmiefearmutcu/antigravity-ralph.git" 2>/dev/null || true
  export RALPH_PUSH=1
  ( cd "$WS/repo" && guard_no_push ) || true
  if [ -s "$rec" ]; then
    # If it pushed, it must NEVER be a force-push.
    ! grep -Eq -- '--force|-f\b|--force-with-lease' "$rec"
  fi
  # (If guard_no_push is conservative and still skips here, that's also acceptable
  #  safety behavior — the invariant is "never an UNSAFE push", asserted above.)
}

@test "T-SAFE-2: agent edit to a protected .ralph file ⇒ canonical restored" {
  # The agent (stub) overwrites .ralph/MISSION.md. The harness must restore the
  # canonical content. We snapshot the canonical MISSION before, let the stub
  # mutate it, then invoke whatever public restore surface exists; if none is
  # present yet, skip (its owner hasn't merged).
  canon="$(cat "$WS/repo/.ralph/MISSION.md")"
  # Stub mutates the protected file directly (write-only; harness owns commits).
  STUB_AGY_FIXTURE="$RALPH_FIXTURES/edit_mission.txt" \
  STUB_AGY_WRITE_ONLY=1 STUB_AGY_COMMIT_FILE=".ralph/MISSION.md" \
  STUB_AGY_COMMIT_BODY="HACKED: lowered the bar" \
  agy -p "x" --add-dir "$WS/repo" >/dev/null 2>&1 || true
  grep -q 'HACKED' "$WS/repo/.ralph/MISSION.md"   # confirm the tamper landed

  restored=0
  if ralph_source_lib ratchet.sh && command -v restore_protected_files >/dev/null 2>&1; then
    ( cd "$WS/repo" && restore_protected_files ) || true; restored=1
  elif ralph_source_lib gate.sh && command -v restore_protected_files >/dev/null 2>&1; then
    ( cd "$WS/repo" && restore_protected_files ) || true; restored=1
  fi
  if [ "$restored" -eq 0 ]; then
    skip "restore_protected_files not present yet (owned by another group)"
  fi
  # Canonical MISSION restored (no HACKED marker).
  ! grep -q 'HACKED' "$WS/repo/.ralph/MISSION.md"
}
