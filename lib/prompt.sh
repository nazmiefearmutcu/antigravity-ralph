#!/usr/bin/env bash
# lib/prompt.sh — render the iteration prompt from .ralph/ disk state (SPEC §4).
#
# Role: render_prompt <iter> reads the per-target .ralph/ memory files
# (MISSION.md, HANDOFF.md, LEDGER.md, PROGRESS.md, RATCHET.json, state.json,
# allow.txt, metrics) and fills EVERY {{...}} placeholder in
# prompts/iterate.tmpl, then prints the finished prompt to stdout.
#
# This file is part of SPEC §4. The referee prompt renderer
# (render_referee_prompt) is owned by lib/gate.sh per SPEC §5.7, NOT here.
#
# bash 3.2 NOTE / RESOLUTION: macOS /bin/bash is 3.2 and lacks `declare -A`,
# `local -n`, and namerefs. This file therefore uses NO associative arrays and
# NO namerefs. Placeholder substitution is done by /usr/bin/perl reading the
# replacement values from EXPORTED ENVIRONMENT VARIABLES (not regex
# replacement strings), so arbitrary file content — slashes, ampersands,
# backslashes, the `<<<RALPH_HANDOFF` fence, newlines — is substituted
# literally with zero escaping hazards. This is the approach SPEC §4 implies
# ("filled by lib/prompt.sh::render_prompt from .ralph/ files"): treat file
# bodies as opaque literal text.
#
# Sourcing this file twice is safe (idempotent guard below).

# ── idempotent source guard ──
if [ -n "${_RALPH_PROMPT_SH_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
_RALPH_PROMPT_SH_LOADED=1

# Resolve this lib dir and the repo root (one level up from lib/) so we can find
# the template and the python helpers regardless of caller CWD.
_prompt_self_dir() {
  # shellcheck disable=SC2128
  local src="${BASH_SOURCE[0]:-$0}"
  local dir
  dir="$(cd "$(dirname "$src")" >/dev/null 2>&1 && pwd)"
  printf '%s' "$dir"
}

# ─────────────────────────────────────────────────────────────── helpers ──

# Read a file's full contents to stdout; empty string if absent/unreadable.
_pf_read_file() {
  local f="$1"
  if [ -f "$f" ]; then
    cat "$f" 2>/dev/null || true
  fi
}

# Tail the last N "## ITER" blocks (with their `:: VERDICT` lines) from
# PROGRESS.md. A block starts at a line beginning "## ITER" and runs until the
# next such header (or EOF). We emit the last N blocks in order.
_pf_progress_tail() {
  local f="$1" n="${2:-3}"
  [ -f "$f" ] || { printf '%s' "(no journal entries yet)"; return 0; }
  # Use perl: split on the block header, keep the last N blocks.
  RALPH_PT_N="$n" /usr/bin/perl -0777 -ne '
    my $n = $ENV{RALPH_PT_N} || 3;
    my @parts = split /(?=^\#\#\s+ITER\b)/m, $_;
    @parts = grep { /\S/ } @parts;
    my @last = @parts > $n ? @parts[-$n .. -1] : @parts;
    my $out = join("", @last);
    $out =~ s/\s+\z//;
    print $out;
  ' "$f" 2>/dev/null || _pf_read_file "$f"
}

# Resolve VERIFY_CMD from RATCHET.json (verify.cmd), falling back to config.env
# / a sane default. "AUTO" is left as-is (the prompt is descriptive; the harness
# resolves AUTO elsewhere).
_pf_verify_cmd() {
  local ratchet="$1" v=""
  if [ -f "$ratchet" ] && command -v jq >/dev/null 2>&1; then
    v="$(jq -r '.verify.cmd // empty' "$ratchet" 2>/dev/null)"
  fi
  if [ -z "$v" ] || [ "$v" = "null" ]; then
    v="${RALPH_VERIFY_CMD:-make verify}"
  fi
  printf '%s' "$v"
}

# Build the REGRESSION_NOTICE block from RATCHET.regression_pending (§5.6), or
# emit nothing if there is no pending regression.
_pf_regression_notice() {
  local ratchet="$1" head_sha="$2"
  command -v jq >/dev/null 2>&1 || { printf ''; return 0; }
  [ -f "$ratchet" ] || { printf ''; return 0; }
  local has
  has="$(jq -r 'if (.regression_pending == null) then "no" else "yes" end' "$ratchet" 2>/dev/null)"
  [ "$has" = "yes" ] || { printf ''; return 0; }

  local prev_iter prev_chose reject_reason bad_metric m_before m_after claimed reject_id advice
  prev_iter="$(jq -r '.regression_pending.iteration // ""' "$ratchet" 2>/dev/null)"
  prev_chose="$(jq -r '.regression_pending.what_agent_claimed // ""' "$ratchet" 2>/dev/null)"
  reject_reason="$(jq -r '.regression_pending.independent_finding // .regression_pending.cause // ""' "$ratchet" 2>/dev/null)"
  reject_id="$(jq -r '.regression_pending.reject_id // ""' "$ratchet" 2>/dev/null)"
  advice="$(jq -r '.regression_pending.advice // ""' "$ratchet" 2>/dev/null)"
  # Identify the regressing metric: first key under metric_after, else cause-derived.
  bad_metric="$(jq -r '
    (.regression_pending.metric_after // {} | keys[0]?) //
    (if (.regression_pending.cause // "" | startswith("regression:"))
       then (.regression_pending.cause | split(":")[1]) else "" end) // ""' \
    "$ratchet" 2>/dev/null)"
  if [ -n "$bad_metric" ] && [ "$bad_metric" != "null" ]; then
    m_before="$(jq -r --arg k "$bad_metric" '.regression_pending.metric_before[$k] // .best.metrics[$k] // ""' "$ratchet" 2>/dev/null)"
    m_after="$(jq -r --arg k "$bad_metric" '
      (.regression_pending.metric_after[$k]? ) //
      (.regression_pending.metric_after // "") | tostring' "$ratchet" 2>/dev/null)"
    claimed="$(jq -r --arg k "$bad_metric" '.regression_pending.metric_after[$k] // ""' "$ratchet" 2>/dev/null)"
  else
    bad_metric=""
    m_before=""
    m_after="$(jq -r '.regression_pending.metric_after // "" | tostring' "$ratchet" 2>/dev/null)"
    claimed=""
  fi

  cat <<EOF
── ⚠ REGRESSION NOTICE — the previous iteration (${prev_iter}) was AUTO-REVERTED ──
What it tried:   ${prev_chose}
Independent finding: ${reject_reason}   (metric ${bad_metric}: ${m_before} → ${m_after}; your claim was ${claimed})
The repo is back at commit ${head_sha} (the last good state). That approach is now in
LEDGER.REJECTED as ${reject_id}. DO NOT repeat it. Pick a DIFFERENT, ideally smaller item, and
verify the regressing metric stays within its floor BEFORE you commit.
${advice}
EOF
}

# Build the INTEGRITY_NOTICE block iff an integrity_flag is set (§5.4 / INV-3).
# The flag may live in RATCHET.json (.integrity_flag) or state.json
# (.integrity_flag). Either truthy → emit the notice.
_pf_integrity_notice() {
  local ratchet="$1" state="$2" flag="false"
  # integrity_flag is set by record_claim_vs_truth via `bump` → it is an INTEGER streak (1,2,3…) when
  # claims!=measurements, reset to 0 when clean. Treat ANY non-zero / non-false value as truthy (the
  # earlier `== "true"` check never matched the integer, so the notice never fired).
  _truthy() { case "$1" in ""|"0"|"false"|"null") return 1 ;; *) return 0 ;; esac; }
  if command -v jq >/dev/null 2>&1; then
    if [ -f "$ratchet" ]; then
      local rf
      rf="$(jq -r '.integrity_flag // 0' "$ratchet" 2>/dev/null)"
      _truthy "$rf" && flag="true"
    fi
    if [ "$flag" != "true" ] && [ -f "$state" ]; then
      local sf
      sf="$(jq -r '.integrity_flag // 0' "$state" 2>/dev/null)"
      _truthy "$sf" && flag="true"
    fi
  fi
  [ "$flag" = "true" ] || { printf ''; return 0; }
  cat <<'EOF'
── NOTE: prior reported metrics did not match independent measurement. Report ONLY harness-verifiable
   facts. Inflated numbers are detected and the iteration is wasted. ──
EOF
}

# ───────────────────────────────────────────────────── render_prompt ──

# render_prompt <iter>
#   Reads .ralph/ state and prints the fully-substituted iteration prompt to
#   stdout. Expects to be run with CWD == target repo root (so ".ralph" is a
#   relative path), matching the supervisor's invocation in §7.2. Honors
#   $RALPH_TARGET / $TARGET / $REPO_ROOT if set, else uses $PWD.
render_prompt() {
  local iter="${1:-0}"

  local target="${RALPH_TARGET:-${TARGET:-${REPO_ROOT:-$PWD}}}"
  local ralph="$target/.ralph"

  local lib_dir tmpl
  lib_dir="$(_prompt_self_dir)"
  # Template lives at <repo>/prompts/iterate.tmpl. Allow override via env/config.
  if [ -n "${RALPH_PROMPT_FILE:-}" ] && [ -f "${RALPH_PROMPT_FILE}" ]; then
    tmpl="${RALPH_PROMPT_FILE}"
  elif [ -n "${RALPH_PROMPT_FILE:-}" ] && [ -f "$lib_dir/../${RALPH_PROMPT_FILE}" ]; then
    tmpl="$lib_dir/../${RALPH_PROMPT_FILE}"
  else
    tmpl="$lib_dir/../prompts/iterate.tmpl"
  fi

  if [ ! -f "$tmpl" ]; then
    echo "render_prompt: template not found: $tmpl" >&2
    return 1
  fi

  # ── gather facts ──
  local repo_root head_sha prev_iter tier
  repo_root="$(cd "$target" >/dev/null 2>&1 && pwd)"
  head_sha="$(git -C "$target" rev-parse HEAD 2>/dev/null || echo none)"

  if command -v jq >/dev/null 2>&1 && [ -f "$ralph/state.json" ]; then
    tier="$(jq -r '.tier // "T1_correctness"' "$ralph/state.json" 2>/dev/null)"
  else
    tier="${tier:-T1_correctness}"
  fi
  if [ -z "$tier" ] || [ "$tier" = "null" ]; then tier="T1_correctness"; fi

  # PREV_ITER = iter-1, clamped at 0.
  if [ "$iter" -gt 0 ] 2>/dev/null; then
    prev_iter=$((iter - 1))
  else
    prev_iter=0
  fi

  # ── render RATCHET_TABLE via ratchet.py (§5.3) with a graceful fallback ──
  local ratchet_table=""
  if [ -f "$lib_dir/ratchet.py" ]; then
    ratchet_table="$(cd "$target" >/dev/null 2>&1 && python3 "$lib_dir/ratchet.py" render-table 2>/dev/null)"
  fi
  if [ -z "$ratchet_table" ]; then
    # Minimal fallback table directly from RATCHET.json so the prompt is never empty.
    if command -v jq >/dev/null 2>&1 && [ -f "$ralph/RATCHET.json" ]; then
      ratchet_table="$(jq -r '
        "| metric | dir | floor | frozen |",
        "|---|---|---|---|",
        (.metrics | to_entries[] |
          "| \(.key) | \(.value.dir) | \(.value.floor) | \(.value.frozen) |")' \
        "$ralph/RATCHET.json" 2>/dev/null)"
    fi
  fi
  [ -n "$ratchet_table" ] || ratchet_table="(no ratchet metrics configured)"

  # ── gather all placeholder bodies ──
  local mission_md handoff_md ledger_md progress_tail allow_txt verify_cmd
  local regression_notice integrity_notice
  mission_md="$(_pf_read_file "$ralph/MISSION.md")"
  [ -n "$mission_md" ] || mission_md="(MISSION.md missing)"
  handoff_md="$(_pf_read_file "$ralph/HANDOFF.md")"
  [ -n "$handoff_md" ] || handoff_md="(no prior handoff — this may be the first iteration)"
  ledger_md="$(_pf_read_file "$ralph/LEDGER.md")"
  [ -n "$ledger_md" ] || ledger_md="(LEDGER.md empty)"
  progress_tail="$(_pf_progress_tail "$ralph/PROGRESS.md" 3)"
  allow_txt="$(_pf_read_file "$ralph/allow.txt")"
  [ -n "$allow_txt" ] || allow_txt="(allow.txt empty — treat as: no commands sanctioned)"
  verify_cmd="$(_pf_verify_cmd "$ralph/RATCHET.json")"
  regression_notice="$(_pf_regression_notice "$ralph/RATCHET.json" "$head_sha")"
  integrity_notice="$(_pf_integrity_notice "$ralph/RATCHET.json" "$ralph/state.json")"

  # ── OPERATOR INBOX (live side-channel) — pending human directives queued via `ralph say` / `ralph chat`
  #    while the loop keeps running. Read them, then ARCHIVE + clear so each is delivered to the agent
  #    exactly once and steers THIS iteration only. The loop is never stopped to receive them. ──
  local operator_inbox=""
  if [ -s "$ralph/INBOX.md" ]; then
    operator_inbox="$(cat "$ralph/INBOX.md" 2>/dev/null)"
    { printf '\n=== consumed @ iter %s (%s) ===\n' "$iter" "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"; cat "$ralph/INBOX.md"; } >> "$ralph/INBOX.archive" 2>/dev/null || true
    : > "$ralph/INBOX.md" 2>/dev/null || true
  fi
  [ -n "$operator_inbox" ] || operator_inbox="(none — no pending operator messages)"

  # ── substitute every {{...}} placeholder via perl, values passed as env vars
  #    (so file bodies are treated as opaque literals — no regex escaping). ──
  RP_ITER="$iter" \
  RP_REPO_ROOT="$repo_root" \
  RP_HEAD_SHA="$head_sha" \
  RP_PREV_ITER="$prev_iter" \
  RP_TIER="$tier" \
  RP_VERIFY_CMD="$verify_cmd" \
  RP_MISSION_MD="$mission_md" \
  RP_RATCHET_TABLE="$ratchet_table" \
  RP_HANDOFF_MD="$handoff_md" \
  RP_LEDGER_MD="$ledger_md" \
  RP_PROGRESS_TAIL="$progress_tail" \
  RP_REGRESSION_NOTICE="$regression_notice" \
  RP_INTEGRITY_NOTICE="$integrity_notice" \
  RP_ALLOW_TXT="$allow_txt" \
  RP_OPERATOR_INBOX="$operator_inbox" \
  /usr/bin/perl -0777 -pe '
    my %map = (
      "ITER"               => $ENV{RP_ITER},
      "REPO_ROOT"          => $ENV{RP_REPO_ROOT},
      "HEAD_SHA"           => $ENV{RP_HEAD_SHA},
      "PREV_ITER"          => $ENV{RP_PREV_ITER},
      "TIER"               => $ENV{RP_TIER},
      "VERIFY_CMD"         => $ENV{RP_VERIFY_CMD},
      "MISSION_MD"         => $ENV{RP_MISSION_MD},
      "RATCHET_TABLE"      => $ENV{RP_RATCHET_TABLE},
      "HANDOFF_MD"         => $ENV{RP_HANDOFF_MD},
      "LEDGER_MD"          => $ENV{RP_LEDGER_MD},
      "PROGRESS_TAIL"      => $ENV{RP_PROGRESS_TAIL},
      "REGRESSION_NOTICE"  => $ENV{RP_REGRESSION_NOTICE},
      "INTEGRITY_NOTICE"   => $ENV{RP_INTEGRITY_NOTICE},
      "ALLOW_TXT"          => $ENV{RP_ALLOW_TXT},
      "OPERATOR_INBOX"     => $ENV{RP_OPERATOR_INBOX},
    );
    # Replace {{KEY}} for each known key; unknown placeholders are left intact.
    s/\{\{([A-Z_]+)\}\}/ exists $map{$1} ? (defined $map{$1} ? $map{$1} : "") : "{{$1}}" /ge;
  ' "$tmpl"
}
