#!/usr/bin/env bash
# lib/gate.sh — commit / referee push-gate (SPEC §5.7) + push safety (§12).
#
# ROLE: local commits ALWAYS happen (they are how the ratchet measures). This file gates the
# OPTIONAL push and the per-iteration commit-acceptance posture:
#   - maybe_commit_gate        : dispatch on RALPH_COMMIT_GATE (none | tests | referee)
#   - maybe_referee_gate       : every RALPH_REFEREE_EVERY advances OR on goals_done, run the referee
#                                agent over the unpushed diff; GO ⇒ guarded push, NO-GO ⇒ findings→LEDGER
#   - guard_no_push            : §12 owned-remote regex; never force-push; RALPH_PUSH=0 ⇒ never push
#   - render_referee_prompt    : fill prompts/referee.tmpl with the diff RANGE
#   - append_goals_from_referee: a NO-GO referee's findings become top-priority LEDGER.OPEN items
#
# BASH 3.2 NOTE: no associative arrays / namerefs are needed here. Plain strings + jq only.
#
# Env contract (READ; set by config.env / state.sh — other groups):
#   RALPH_COMMIT_GATE, RALPH_REFEREE_EVERY, RALPH_PUSH, REPO_ROOT, SANDBOX_FLAG, ITDIR
#   GOALS_DONE (bool string), LAST_PUSH (commit/ref the last successful push reached; may be empty)
#   CAND_VERIFY (set by run_one_iteration before the ADVANCE branch)
# External primitives we CALL (other groups):
#   bounded_run (lib/bounded.sh §6.1), now/log/set_state (lib/state.sh), maybe_referee_gate's `agy`.
#
# Idempotent source guard.
if [ -n "${_RALPH_GATE_SH_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
_RALPH_GATE_SH_LOADED=1

RALPH_DIR="${RALPH_DIR:-.ralph}"
_GATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo lib)"
_GATE_REPO_ROOT_DEFAULT="$(cd "$_GATE_LIB_DIR/.." 2>/dev/null && pwd || echo .)"

# soft fallbacks (overridden by state.sh if sourced). Guard on FUNCTION existence (declare -F), NOT
# `command -v`: macOS ships a system binary /usr/sbin/log that command -v would resolve, suppressing
# our fallback and routing every log "..." to Apple's logging CLI.
if ! declare -F now >/dev/null 2>&1; then now() { date -u +%Y-%m-%dT%H:%M:%SZ; }; fi
if ! declare -F log >/dev/null 2>&1; then log() { printf '%s gate: %s\n' "$(now)" "$*" >&2; }; fi

# ===================================================================================================
# §5.7  maybe_commit_gate — per-iteration acceptance posture (called inside the ADVANCE branch).
#   Local commit already stands; this only governs the optional push.
# ===================================================================================================
maybe_commit_gate() {
  case "${RALPH_COMMIT_GATE:-referee}" in
    none)
      : ;;                                              # commit stands as-is; no push gate
    tests)
      # already true on ADVANCE (verify passed); defensive re-check before any push.
      [ "${CAND_VERIFY:-pass}" = pass ] || return 0
      # tests-gate does not push by itself unless an explicit push is wired; honor RALPH_PUSH guard.
      guard_no_push ;;
    referee)
      maybe_referee_gate "${1:-$(git rev-parse HEAD 2>/dev/null || echo HEAD)}" ;;
    *)
      maybe_referee_gate "${1:-$(git rev-parse HEAD 2>/dev/null || echo HEAD)}" ;;
  esac
}

# ===================================================================================================
# §5.7  maybe_referee_gate <candidate-commit>
#   Fires every RALPH_REFEREE_EVERY advances OR when goals_done. Runs the referee agent over the
#   unpushed range; GO ⇒ guarded push; NO-GO ⇒ findings → LEDGER.OPEN (loop never blocks).
# ===================================================================================================
maybe_referee_gate() {
  local cand="${1:-$(git rev-parse HEAD 2>/dev/null || echo HEAD)}"
  local advances every goals
  advances="$(jq -r '.advances // 0' "$RALPH_DIR/state.json" 2>/dev/null || echo 0)"
  case "$advances" in ''|*[!0-9]*) advances=0;; esac
  every="${RALPH_REFEREE_EVERY:-10}"
  case "$every" in ''|*[!0-9]*) every=10;; esac
  [ "$every" -lt 1 ] && every=1
  goals="${GOALS_DONE:-false}"

  # cadence: only on every Nth advance OR on goals_done
  if [ "$((advances % every))" -ne 0 ] && [ "$goals" != true ]; then
    return 0
  fi

  local range
  range="$(_referee_range)"
  log "referee gate firing (advances=$advances every=$every goals_done=$goals) range=$range"

  local prompt verdict reflog="${ITDIR:-$RALPH_DIR}/referee.log"
  prompt="$(render_referee_prompt "$range")"

  if command -v agy >/dev/null 2>&1 && command -v bounded_run >/dev/null 2>&1; then
    # The referee MUST inherit the worker's sandboxing. SANDBOX_FLAG was never set anywhere; derive it
    # here from RALPH_SANDBOX (same source the main loop uses) so the referee isn't silently unsandboxed.
    local sbx=""; [ "${RALPH_SANDBOX:-1}" = 1 ] && sbx="--sandbox"
    bounded_run 300 "$reflog" -- \
      agy -p "$prompt" --add-dir "${REPO_ROOT:-$_GATE_REPO_ROOT_DEFAULT}" \
          --dangerously-skip-permissions $sbx
    verdict="$(cat "$reflog" 2>/dev/null || echo '')"
  else
    log "referee: agy/bounded_run unavailable → defer push (no-op, loop continues)"
    return 0
  fi

  # The referee MUST answer on the FINAL line: REFEREE: GO  or  REFEREE: NO-GO.
  if printf '%s' "$verdict" | grep -Eq '^[[:space:]]*REFEREE:[[:space:]]*GO\b'; then
    log "referee: GO"
    guard_no_push
  else
    log "referee: NO-GO (or unparseable) → findings → LEDGER.OPEN; push deferred"
    append_goals_from_referee "$verdict"
    # local progress continues; only the outward push waits for READY. Loop NEVER blocks.
  fi
  return 0
}

# _referee_range — the diff range the referee reviews: LAST_PUSH..HEAD if known, else last commit.
_referee_range() {
  local last="${LAST_PUSH:-}"
  if [ -z "$last" ]; then
    last="$(cat "$RALPH_DIR/refs/last_push" 2>/dev/null || echo '')"
  fi
  if [ -n "$last" ] && git rev-parse --verify "$last" >/dev/null 2>&1; then
    printf '%s..HEAD' "$last"
  else
    # no recorded push baseline → review the single most recent commit
    if git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
      printf 'HEAD~1..HEAD'
    else
      printf 'HEAD'
    fi
  fi
}

# ===================================================================================================
# §5.7  render_referee_prompt <range>  — fill prompts/referee.tmpl ({{RANGE}}).
#   Falls back to a spec-faithful inline template if the file is absent.
# ===================================================================================================
render_referee_prompt() {
  local range="$1"
  local tmpl="${REPO_ROOT:-$_GATE_REPO_ROOT_DEFAULT}/prompts/referee.tmpl"
  [ -f "$tmpl" ] || tmpl="$_GATE_LIB_DIR/../prompts/referee.tmpl"
  if [ -f "$tmpl" ]; then
    # substitute {{RANGE}} without invoking sed on arbitrary content (range is a safe git ref-spec).
    local body; body="$(cat "$tmpl")"
    printf '%s\n' "${body//\{\{RANGE\}\}/$range}"
    return 0
  fi
  # Inline fallback — verbatim from SPEC §5.7 prompts/referee.tmpl.
  cat <<EOF
You are the REFEREE. A Ralph iteration changed this repo. Review ONLY the diff in $range
(\`git diff $range\`). Verify, do not trust:
  1. Does it build/test? Run the verify command and report the REAL result.
  2. Is this STRICTLY BETTER than the prior pushed state (real fix / real coverage / real metric),
     never cosmetic or fabricated?
  3. Did the author invent a metric, claim a test that did not run, or fake completion?
INTEGRITY: if you cannot actually verify a claim, treat it as UNVERIFIED and vote NO-GO.
Answer on the FINAL line, exactly one of:
  REFEREE: GO   — <=12 word reason
  REFEREE: NO-GO — <=12 word reason
Do not print "GO" anywhere except that final line.
EOF
}

# ===================================================================================================
# §5.7  append_goals_from_referee <referee-transcript>
#   A NO-GO referee's concrete findings become top-priority LEDGER.OPEN items (T1). Append-only.
# ===================================================================================================
append_goals_from_referee() {
  local verdict="$1" lf="$RALPH_DIR/LEDGER.md"
  local reason
  reason="$(printf '%s' "$verdict" | grep -E '^[[:space:]]*REFEREE:[[:space:]]*NO-GO' | head -1 \
            | sed -E 's/^[[:space:]]*REFEREE:[[:space:]]*NO-GO[[:space:]—-]*//')"
  [ -n "$reason" ] || reason="referee voted NO-GO (see referee.log)"

  # next stable O-id
  local oid
  oid="$(grep -oE '^- O-[0-9]+' "$lf" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1)"
  case "$oid" in ''|*[!0-9]*) oid=0;; esac
  oid=$((oid+1))

  if ! grep -qE '^## OPEN' "$lf" 2>/dev/null; then
    printf '\n## OPEN (known work, ranked; agent picks the top viable one)\n' >> "$lf"
  fi
  # Insert as a top-priority T1 item. We append-only (never rewrite earlier lines); ordering is by
  # tier tag which the agent honors, so a T1 tag makes it the highest-priority open item.
  local n; n="$(jq -r '.iteration // 0' "$RALPH_DIR/state.json" 2>/dev/null || echo 0)"
  printf -- '- O-%s (T1) REFEREE-BLOCK: %s evidence ITER%s referee NO-GO.\n' \
    "$oid" "$reason" "$(printf '%04d' "$n")" >> "$lf"
  log "referee finding recorded as LEDGER.OPEN O-$oid (T1): $reason"
}

# ===================================================================================================
# §12  guard_no_push — push only if RALPH_PUSH=1 AND origin is under the user's GitHub org.
#   Never force-push. Default-safe: RALPH_PUSH=0 ⇒ NEVER push (INV-9).
# ===================================================================================================
guard_no_push() {
  if [ "${RALPH_PUSH:-0}" != 1 ]; then
    log "push: RALPH_PUSH!=1 → not pushing (default-safe)"
    return 0
  fi
  local url
  url="$(git remote get-url origin 2>/dev/null || echo '')"
  if [ -z "$url" ]; then
    log "push: no 'origin' remote → refusing to push"
    return 0
  fi
  # Strictly parse host + owner from the remote URL and require EXACT membership in operator-set
  # allowlists. We never substring-match (so `evil-github.com/owner` / `x.com?ref=github.com/owner`
  # are rejected) and never trust $USER (the OS login is unrelated to GitHub ownership).
  #   RALPH_PUSH_HOSTS   (comma/space list, default "github.com")
  #   RALPH_PUSH_OWNERS  (comma/space list, default "nazmiefearmutcu")
  local u host rest owner
  u="${url#*://}"          # strip scheme://  (https:// or ssh://) if present
  u="${u#*@}"              # strip user@      (git@) if present
  case "$u" in
    *:*/*) host="${u%%:*}"; rest="${u#*:}" ;;   # scp form  host:owner/repo
    */*)   host="${u%%/*}"; rest="${u#*/}" ;;   # url form  host/owner/repo
    *)     host="$u";       rest="" ;;
  esac
  owner="${rest%%/*}"
  local hosts="${RALPH_PUSH_HOSTS:-github.com}" owners="${RALPH_PUSH_OWNERS:-nazmiefearmutcu}"
  local host_ok=0 owner_ok=0 t
  for t in $(printf '%s' "$hosts"  | tr ',' ' '); do [ "$t" = "$host"  ] && host_ok=1; done
  for t in $(printf '%s' "$owners" | tr ',' ' '); do [ "$t" = "$owner" ] && owner_ok=1; done
  if [ "$host_ok" = 1 ] && [ "$owner_ok" = 1 ] && [ -n "$owner" ]; then
    local branch; branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
    log "push: owned remote confirmed (host=$host owner=$owner) → git push origin $branch (no force)"
    # NEVER force-push. Plain fast-forward push only.
    if command -v bounded_run >/dev/null 2>&1; then
      bounded_run 120 "${ITDIR:-$RALPH_DIR}/push.log" -- git push origin "$branch"
    else
      git push origin "$branch" >"${ITDIR:-$RALPH_DIR}/push.log" 2>&1
    fi
    local rc=$?
    if [ "$rc" -eq 0 ]; then
      mkdir -p "$RALPH_DIR/refs" 2>/dev/null || true
      git rev-parse HEAD > "$RALPH_DIR/refs/last_push" 2>/dev/null || true
      log "push: ok (recorded refs/last_push)"
    else
      log "push: git push failed rc=$rc (loop continues; will retry next gate)"
    fi
    return 0
  fi
  log "push: REFUSED — origin '$url' (host='$host' owner='$owner') not in RALPH_PUSH_HOSTS/OWNERS allowlist (INV-9)"
  return 0
}
