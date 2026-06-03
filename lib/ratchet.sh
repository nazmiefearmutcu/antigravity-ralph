#!/usr/bin/env bash
# lib/ratchet.sh — the trusted referee / scoreboard (SPEC §5: §5.1, §5.2, §5.4, §5.6, §5.8).
#
# ROLE: the heart of "always strictly better". This file owns the gate (the pawl), independent
# re-measurement (INV-3 anti-fabrication), one-way floor clicks (INV-2), memory-preserving revert
# (INV-4), no-op handling (§5.8), and the integrity audit (claim-vs-truth). It is sourced by the
# supervisor and invoked on a `success`-class agy run via run_one_iteration().
#
# BASH 3.2 NOTE / RESOLUTION (REQUIRED by build rules): macOS ships /bin/bash 3.2 ONLY; there is no
# /opt/homebrew/bin/bash on this machine, so `declare -A` / `local -n` namerefs are UNAVAILABLE.
# The SPEC's §5.1/§5.2 pseudocode uses `declare -A CAND_M` and `local -n M=...`. We resolve this the
# spec-sanctioned way: metric vectors are passed BETWEEN FUNCTIONS AS JSON FILES (written under the
# per-iter scratch dir) and read with `jq`. So where the spec writes `CAND_M` (an assoc-array name)
# we instead accept a PATH to a metrics JSON file of shape {"<metric>": <number>|null, ...}. Floors,
# dirs, frozen-flags and tolerances are read live from RATCHET.json via jq each time (no global
# assoc arrays). This keeps the EXACT function names, semantics, ordering, and gate rule the spec
# defines while running on bash 3.2.
#
# Idempotent source guard: safe to `source` twice.
if [ -n "${_RALPH_RATCHET_SH_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
_RALPH_RATCHET_SH_LOADED=1

# ---------------------------------------------------------------------------------------------------
# Conventions
#   - All paths are relative to the target repo CWD (the supervisor cd's into the target). RATCHET.json
#     lives at .ralph/RATCHET.json.
#   - Functions communicate via two output globals the supervisor reads after ratchet_gate:
#       DECISION  ∈ { ADVANCE | REVERT | NOOP }
#       CAUSE     human/parse-friendly reason string
#   - Env contract (set by config.env / state.sh, owned by other groups; we READ them):
#       VERIFY_REQUIRED, VERIFY_CMD, VERIFY_TIMEOUT_S, SCORE_TIMEOUT_S, FLAKY_REVERIFY_RUNS
#       RALPH_REVERT_STRATEGY, REPO_ROOT
#   - External primitives we CALL (defined by other groups):
#       bounded_run            (lib/bounded.sh §6.1)
#   - State helpers we CALL (defined by lib/state.sh / state.py, other group):
#       set_state, bump, persist_state_atomic, persist_ratchet_atomic, append_iteration_record,
#       now, log, maybe_advance_tier
#     Each is wrapped in a soft fallback so this file is unit-testable standalone.
# ---------------------------------------------------------------------------------------------------

RALPH_DIR="${RALPH_DIR:-.ralph}"
RATCHET_JSON="${RATCHET_JSON:-$RALPH_DIR/RATCHET.json}"
_RATCHET_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo lib)"

# ---- soft fallbacks so ratchet.sh works even if a sibling lib is not yet sourced ----
# NOTE: guard on whether a FUNCTION exists (declare -F), NOT `command -v`, because macOS ships a
# system binary `/usr/sbin/log` — `command -v log` would find it and we'd never define our own,
# then every `log "..."` would invoke Apple's logging tool. `declare -F` only sees shell functions.
if ! declare -F now >/dev/null 2>&1; then
  now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
fi
if ! declare -F log >/dev/null 2>&1; then
  log() { printf '%s ratchet: %s\n' "$(now)" "$*" >&2; }
fi
if ! declare -F set_state >/dev/null 2>&1; then
  # minimal atomic state.json key writer (number or string); other group's state.sh overrides this.
  set_state() {
    local key="$1" val="$2" sf="$RALPH_DIR/state.json" tmp
    [ -f "$sf" ] || printf '{}' > "$sf"
    tmp="$sf.tmp.$$"
    if printf '%s' "$val" | grep -Eq '^-?[0-9]+(\.[0-9]+)?$'; then
      jq --arg k "$key" --argjson v "$val" '.[$k]=$v' "$sf" > "$tmp" 2>/dev/null && mv "$tmp" "$sf"
    else
      jq --arg k "$key" --arg v "$val" '.[$k]=$v' "$sf" > "$tmp" 2>/dev/null && mv "$tmp" "$sf"
    fi
    rm -f "$tmp" 2>/dev/null || true
  }
fi
if ! declare -F bump >/dev/null 2>&1; then
  bump() {
    local key="$1" sf="$RALPH_DIR/state.json" cur tmp
    [ -f "$sf" ] || printf '{}' > "$sf"
    cur="$(jq -r --arg k "$key" '.[$k] // 0' "$sf" 2>/dev/null)"
    case "$cur" in ''|*[!0-9-]*) cur=0;; esac
    tmp="$sf.tmp.$$"
    jq --arg k "$key" --argjson v "$((cur+1))" '.[$k]=$v' "$sf" > "$tmp" 2>/dev/null && mv "$tmp" "$sf"
    rm -f "$tmp" 2>/dev/null || true
  }
fi
if ! declare -F persist_state_atomic >/dev/null 2>&1; then
  persist_state_atomic() { :; }   # state.sh writes incrementally; nothing buffered here
fi
if ! declare -F persist_ratchet_atomic >/dev/null 2>&1; then
  persist_ratchet_atomic() { :; } # we already write RATCHET.json atomically in-place below
fi
if ! declare -F append_iteration_record >/dev/null 2>&1; then
  append_iteration_record() {
    # $1 N  $2 DECISION  $3 CAUSE  $4 metrics-json-path  (audit trail, never deleted — INV-4)
    local n="$1" dec="$2" cause="$3" mfile="$4"
    local rec; rec="$(printf '%s' "$RALPH_DIR/iterations/$(printf '%06d' "$n").json")"
    mkdir -p "$RALPH_DIR/iterations"
    local metrics='{}'
    [ -f "$mfile" ] && metrics="$(cat "$mfile" 2>/dev/null || echo '{}')"
    jq -n --argjson n "$n" --arg dec "$dec" --arg cause "$cause" \
          --arg ts "$(now)" --argjson m "$metrics" \
          '{iteration:$n,decision:$dec,cause:$cause,ts:$ts,metrics:$m}' \
          > "$rec" 2>/dev/null || true
    # machine-readable append-only ledger, never deleted
    jq -n --argjson n "$n" --arg dec "$dec" --arg cause "$cause" \
          --arg ts "$(now)" --argjson m "$metrics" \
          -c '{iteration:$n,decision:$dec,cause:$cause,ts:$ts,metrics:$m}' \
          >> "$RALPH_DIR/progress.ndjson" 2>/dev/null || true
  }
fi
# Tier ladder (SPEC §9). The agent self-selects its working tier each iteration via the prompt and
# reports it in the trailer; the harness records it (status/heartbeat reflect reality) and, when the
# loop stalls (handle_noop force / consecutive reverts), ESCALATES to the next tier to push the agent
# toward fresh work. The loop NEVER stops at T7 — T7 generates new OPEN items, then wraps.
_RALPH_TIER_LADDER="T1_correctness T2_coverage T3_hardening T4_performance T5_docs T6_dx T7_probe"
maybe_advance_tier() {
  local force="${1:-}" cur tt t found pick
  cur="$(jq -r '.tier // "T1_correctness"' "$RALPH_DIR/state.json" 2>/dev/null)"
  case "$cur" in ''|null) cur="T1_correctness" ;; esac
  if [ "$force" = force ]; then
    found=0; pick=""
    for t in $_RALPH_TIER_LADDER; do
      [ "$found" = 1 ] && { pick="$t"; break; }
      [ "$t" = "$cur" ] && found=1
    done
    pick="${pick:-T7_probe}"           # at/after T7 stay at T7 (it keeps generating new work)
    if [ "$pick" != "$cur" ]; then set_state tier "$pick"; log "tier escalation $cur → $pick (forced)"; fi
    return 0
  fi
  # normal ADVANCE: adopt the agent's self-reported tier from the trailer if it is a valid ladder tier.
  tt="$(jq -r '.tier // ""' "${ITDIR:-.}/trailer.json" 2>/dev/null)"
  case " $_RALPH_TIER_LADDER " in
    *" $tt "*) [ "$tt" != "$cur" ] && set_state tier "$tt" ;;
  esac
  return 0
}

# _recompute_goals_done — INV-6 honest, HARNESS-computed completion signal. The agent CANNOT set it
# (it is derived here from LEDGER.OPEN, not from the trailer's done_with_explicit_goals). Witness:
# no OPEN work tagged T1..T6 remains (T7 is the perpetual novel-probe tier and never blocks). Even
# when true the loop does NOT stop — it keeps running T7; goals_done only fires the referee push-gate.
# Persists RATCHET.goals_done and exports GOALS_DONE for lib/gate.sh::maybe_referee_gate.
_recompute_goals_done() {
  local lf="$RALPH_DIR/LEDGER.md" open_t16=0
  if [ -f "$lf" ]; then
    open_t16="$(awk '/^## OPEN/{o=1;next} /^## /{o=0} o' "$lf" 2>/dev/null | grep -cE '^- *O-.*\(T[1-6]' || true)"
    case "$open_t16" in ''|*[!0-9]*) open_t16=0 ;; esac
  fi
  if [ "$open_t16" -eq 0 ]; then GOALS_DONE=true; else GOALS_DONE=false; fi
  _ratchet_json_set ".goals_done = \$g" --argjson g "$GOALS_DONE" 2>/dev/null || true
  export GOALS_DONE
}

# ===================================================================================================
# §5.4  measure_* — trusted referee primitives (anti-fabrication core; INV-3)
# ===================================================================================================

# measure_verify <log-prefix>  → prints "pass" | "fail". Pass-biased (§5.5): pass if ANY retry passes.
measure_verify() {
  local prefix="$1"
  [ "${VERIFY_REQUIRED:-1}" = 1 ] || { echo pass; return 0; }
  local runs="${FLAKY_REVERIFY_RUNS:-2}" i res
  case "$runs" in ''|*[!0-9]*) runs=2;; esac
  [ "$runs" -lt 1 ] && runs=1
  for i in $(seq 1 "$runs"); do
    if command -v bounded_run >/dev/null 2>&1; then
      bounded_run "${VERIFY_TIMEOUT_S:-900}" "$prefix.verify.$i.log" -- sh -c "${VERIFY_CMD:-true}"
      res=$?
    else
      sh -c "${VERIFY_CMD:-true}" > "$prefix.verify.$i.log" 2>&1
      res=$?
    fi
    [ "$res" -eq 0 ] && { echo pass; return 0; }   # ANY green run ⇒ pass
  done
  echo fail                                         # failed every retry ⇒ trust the failure
}

# measure_metrics <metrics-json-out-path> <log-prefix>
#   The harness derives EVERY number itself on the committed tree (INV-3). Writes a JSON object
#   {"<metric>": <number>|null}. The trailer's metrics_after NEVER enters this path.
measure_metrics() {
  local out="$1" prefix="$2"
  [ -f "$RATCHET_JSON" ] || { printf '{}' > "$out"; return 0; }
  local keys key cmd raw
  keys="$(jq -r '.metrics | keys[]' "$RATCHET_JSON" 2>/dev/null)"
  printf '{}' > "$out.tmp.build"
  if [ -n "$keys" ]; then
    printf '%s\n' "$keys" | while IFS= read -r key; do
      [ -n "$key" ] || continue
      cmd="$(resolve_metric_cmd "$key")"
      if command -v bounded_run >/dev/null 2>&1; then
        bounded_run "${SCORE_TIMEOUT_S:-900}" "$prefix.$key.raw" -- sh -c "$cmd"
      else
        sh -c "$cmd" > "$prefix.$key.raw" 2>&1 || true
      fi
      # last numeric token on the last non-empty line; non-numeric ⇒ null
      raw="$(awk 'NF{last=$0} END{print last}' "$prefix.$key.raw" 2>/dev/null \
             | grep -oE '^-?[0-9]+(\.[0-9]+)?$' | tail -1)"
      if [ -n "$raw" ]; then
        jq --arg k "$key" --argjson v "$raw" '.[$k]=$v' "$out.tmp.build" > "$out.tmp.next" \
          && mv "$out.tmp.next" "$out.tmp.build"
      else
        jq --arg k "$key" '.[$k]=null' "$out.tmp.build" > "$out.tmp.next" \
          && mv "$out.tmp.next" "$out.tmp.build"
      fi
    done
  fi
  mv "$out.tmp.build" "$out" 2>/dev/null || printf '{}' > "$out"
  rm -f "$out.tmp.next" 2>/dev/null || true
}

# resolve_metric_cmd <metric-key>  → prints the shell command that produces the metric number.
#   AUTO:* resolvers per §3.1 are computed by the harness (never the agent). Non-AUTO → literal cmd.
resolve_metric_cmd() {
  local key="$1" cmd cano="$RALPH_DIR/.canonical/RATCHET.cmds.json"
  # SECURITY (RCE): the executed command is the one RUN by the harness via `sh -c`. The agent can
  # write .ralph/RATCHET.json (it's on disk, --dangerously-skip-permissions), so we NEVER take the
  # command from the live, agent-writable RATCHET.json. We take it from the operator-canonical
  # snapshot seeded at `ralph init` (.ralph/.canonical/RATCHET.cmds.json). Fall back to the live file
  # ONLY when no canonical exists (e.g. test fixtures that scaffold .ralph by hand without init).
  if [ -f "$cano" ]; then
    cmd="$(jq -r --arg k "$key" '.metrics[$k] // ""' "$cano" 2>/dev/null)"
  else
    cmd="$(jq -r --arg k "$key" '.metrics[$k].cmd // ""' "$RATCHET_JSON" 2>/dev/null)"
  fi
  case "$cmd" in
    AUTO:pytest_passcount)
      echo "command -v pytest >/dev/null 2>&1 || python3 -c 'import pytest' >/dev/null 2>&1 || exit 0; python3 -m pytest -q --no-header 2>/dev/null | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' | tail -1"
      ;;
    AUTO:jest_passcount)
      echo "command -v npx >/dev/null 2>&1 || exit 0; npx --no-install jest --silent 2>&1 | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' | tail -1"
      ;;
    AUTO:cargo_passcount)
      echo "command -v cargo >/dev/null 2>&1 || exit 0; cargo test --quiet 2>&1 | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' | tail -1"
      ;;
    AUTO:go_passcount)
      # guard: when `go` is absent, emit NOTHING (→ metric null), not a bare `grep -c` 0.
      echo "command -v go >/dev/null 2>&1 || exit 0; go test ./... 2>&1 | grep -cE '^(ok|--- PASS)'"
      ;;
    AUTO:coverage)
      # coverage tool total %, parsed to a float. Tries python coverage first.
      echo "python3 -c 'import coverage' >/dev/null 2>&1 || exit 0; python3 -m coverage report 2>/dev/null | awk '/^TOTAL/{gsub(/%/,\"\",\$NF); print \$NF}' | tail -1"
      ;;
    AUTO:lint)
      # count of ruff findings (dir=down). When ruff is absent, emit NOTHING (→ null), not a bare 0.
      echo "command -v ruff >/dev/null 2>&1 || exit 0; ruff check . 2>/dev/null | grep -cE 'Found|error|^[^ ]+:[0-9]+:[0-9]+' || true"
      ;;
    AUTO|AUTO:*)
      # unknown AUTO resolver → emit nothing numeric ⇒ metric becomes null this iter
      echo "true"
      ;;
    "" )
      echo "true"
      ;;
    *)
      echo "$cmd"
      ;;
  esac
}

# ===================================================================================================
# Floor / best accessors (read live from RATCHET.json; no global assoc arrays under bash 3.2)
# ===================================================================================================

# load_floors_from <ratchet.json>  — under bash 3.2 we cannot populate assoc arrays for the caller.
#   We keep the spec name as a no-op validity check + path pin; the gate reads floors live via jq.
load_floors_from() {
  local rj="${1:-$RATCHET_JSON}"
  RATCHET_JSON="$rj"
  jq -e '.metrics' "$rj" >/dev/null 2>&1 || { log "load_floors_from: $rj has no .metrics"; return 1; }
  return 0
}

_metric_keys() { jq -r '.metrics | keys[]' "$RATCHET_JSON" 2>/dev/null; }
_metric_dir()    { jq -r --arg k "$1" '.metrics[$k].dir // "up"'        "$RATCHET_JSON" 2>/dev/null; }
_metric_floor()  { jq -r --arg k "$1" '.metrics[$k].floor // 0'         "$RATCHET_JSON" 2>/dev/null; }
_metric_frozen() { jq -r --arg k "$1" '.metrics[$k].frozen // false'    "$RATCHET_JSON" 2>/dev/null; }
_metric_tol()    { jq -r --arg k "$1" '.metrics[$k].tolerance // 0'     "$RATCHET_JSON" 2>/dev/null; }
_best_metric()   { jq -r --arg k "$1" '.best.metrics[$k] // null'       "$RATCHET_JSON" 2>/dev/null; }

# numeric compare via awk; prints "1" if true, "0" if false.  _cmp <a> <op> <b>   op ∈ < > <= >=
_cmp() {
  awk -v a="$1" -v b="$3" -v op="$2" 'BEGIN{
    if(a=="null"||b=="null"||a==""||b==""){print 0; exit}
    if(op=="<"){print (a<b)?1:0}
    else if(op==">"){print (a>b)?1:0}
    else if(op=="<="){print (a<=b)?1:0}
    else if(op==">="){print (a>=b)?1:0}
    else print 0
  }'
}

# metric_crosses_floor <key> <value>  → exit 0 (true) if value crosses floor in the WRONG direction.
#   dir=up:   fail if v < floor - tol     dir=down: fail if v > floor + tol
metric_crosses_floor() {
  local key="$1" v="$2" dir floor tol
  [ "$v" = null ] && return 1
  dir="$(_metric_dir "$key")"; floor="$(_metric_floor "$key")"; tol="$(_metric_tol "$key")"
  if [ "$dir" = down ]; then
    local lim; lim="$(awk -v f="$floor" -v t="$tol" 'BEGIN{print f+t}')"
    [ "$(_cmp "$v" '>' "$lim")" = 1 ] && return 0 || return 1
  else
    local lim; lim="$(awk -v f="$floor" -v t="$tol" 'BEGIN{print f-t}')"
    [ "$(_cmp "$v" '<' "$lim")" = 1 ] && return 0 || return 1
  fi
}

# metric_strictly_better <key> <value>  → exit 0 (true) if value beats best.metrics[key].
#   The floor of comparison is ALWAYS best.metrics (never baseline) — §5.2 absolute-floor rule.
metric_strictly_better() {
  local key="$1" v="$2" dir best
  [ "$v" = null ] && return 1
  dir="$(_metric_dir "$key")"; best="$(_best_metric "$key")"
  if [ "$best" = null ] || [ -z "$best" ]; then
    # no prior best for this metric ⇒ any real number is an improvement
    return 0
  fi
  if [ "$dir" = down ]; then
    [ "$(_cmp "$v" '<' "$best")" = 1 ] && return 0 || return 1
  else
    [ "$(_cmp "$v" '>' "$best")" = 1 ] && return 0 || return 1
  fi
}

# absent_policy_better <cand-commit>  → exit 0 (true) if the absent_policy permits an ADVANCE when no
#   metric strictly improved (e.g. all-null / verify-only project). §5.2.
absent_policy_better() {
  local cand="$1" policy
  policy="$(jq -r '.policy.absent_policy // "verify_only"' "$RATCHET_JSON" 2>/dev/null)"
  case "$policy" in
    tie_breaker)
      # (1) verify passed is the dominant secondary signal; we are only called after verify passed
      #     (ratchet_gate returns early on verify fail), and after the non-noop check. So a committed,
      #     verified, non-noop diff that holds all floors is accepted as a tie-broken improvement.
      return 0
      ;;
    verify_only|*)
      # ADVANCE iff verify=pass ∧ non-noop diff ∧ committed. verify & non-noop already established by
      # the caller before we are reached; so the policy is satisfied.
      return 0
      ;;
  esac
}

# is_noop_diff <base> <cand>  → exit 0 (true) if the diff contains ONLY comment/whitespace changes
#   (excluding .ralph and cache). A cosmetic-only change must NOT count as "better".
is_noop_diff() {
  local base="$1" cand="$2"
  # identical trees ⇒ noop
  if [ "$base" = "$cand" ]; then return 0; fi
  # files changed outside .ralph/ and cache/. Use git PATHSPEC exclusions (NOT a shell-expanded file
  # list) so agent-chosen filenames with spaces/globs/dashes can never word-split into git's argv.
  local changed
  changed="$(git diff --name-only "$base" "$cand" -- . ':(exclude).ralph' ':(exclude).ralph/**' ':(exclude)cache' ':(exclude)cache/**' 2>/dev/null || true)"
  [ -z "$changed" ] && return 0   # only .ralph/cache touched ⇒ noop for ratchet purposes
  # any added/removed non-blank, non-comment line ⇒ NOT a noop
  local meaningful
  meaningful="$(git diff -U0 "$base" "$cand" -- . ':(exclude).ralph' ':(exclude).ralph/**' ':(exclude)cache' ':(exclude)cache/**' 2>/dev/null \
    | grep -E '^[+-]' \
    | grep -vE '^(\+\+\+|---)' \
    | sed -E 's/^[+-]//' \
    | sed -E 's/[[:space:]]+$//' \
    | grep -vE '^[[:space:]]*$' \
    | grep -vE '^[[:space:]]*(#|//|\*|/\*|\*/)' \
    | head -1 || true)"
  [ -z "$meaningful" ] && return 0
  return 1
}

# ===================================================================================================
# §5.2  ratchet_gate — the pawl (multi-metric, R3).  Sets DECISION + CAUSE globals.
#   Args: $1 base-commit  $2 cand-commit  $3 verify("pass"|"fail")  $4 PATH to cand metrics JSON.
#   (Spec param $4 = "name of CAND_M assoc array"; under bash 3.2 it is a metrics JSON file path.)
# ===================================================================================================
ratchet_gate() {
  local base="$1" cand="$2" verify="$3" mfile="$4"
  DECISION=REVERT; CAUSE=""

  if [ "${VERIFY_REQUIRED:-1}" = 1 ] && [ "$verify" != pass ]; then
    CAUSE="regression_verify_fail"; return 0
  fi
  if is_noop_diff "$base" "$cand"; then
    CAUSE="noop_diff"; return 0
  fi

  local improved=0 key v
  for key in $(_metric_keys); do
    [ -n "$key" ] || continue
    v="$(jq -r --arg k "$key" '.[$k] // "null"' "$mfile" 2>/dev/null)"
    [ "$v" = null ] && continue                      # absent metric → absent_policy below
    if metric_crosses_floor "$key" "$v"; then
      CAUSE="regression:${key}:floor=$(_metric_floor "$key"):got=${v}"; return 0
    fi
    if [ "$(_metric_frozen "$key")" != true ] && metric_strictly_better "$key" "$v"; then
      improved=1
    fi
  done

  if [ "$improved" -eq 1 ]; then DECISION=ADVANCE; return 0; fi
  if absent_policy_better "$cand"; then
    DECISION=ADVANCE
  else
    CAUSE="not_strictly_better"
  fi
  return 0
}

# ===================================================================================================
# §5.1 helpers — baseline / best seeding
# ===================================================================================================

# ensure_baseline_measured <base-commit> <log-prefix>
#   Re-measure the baseline lazily only if RATCHET.baseline.commit != base (first run / external change).
ensure_baseline_measured() {
  local base="$1" prefix="$2"
  local cur; cur="$(jq -r '.baseline.commit // ""' "$RATCHET_JSON" 2>/dev/null)"
  if [ "$cur" = "$base" ] && [ "$(jq -r '.baseline.metrics // empty' "$RATCHET_JSON" 2>/dev/null)" != "" ]; then
    return 0
  fi
  mkdir -p "$(dirname "$prefix")" 2>/dev/null || true
  local mfile="$prefix.metrics.json" vr
  measure_metrics "$mfile" "$prefix"
  vr="$(measure_verify "$prefix")"
  local metrics; metrics="$(cat "$mfile" 2>/dev/null || echo '{}')"
  _ratchet_json_set ".baseline = {commit:\$c, tree_clean:true, verify_passed:\$vp, metrics:\$m, measured_at:\$ts}" \
    --arg c "$base" \
    --argjson vp "$([ "$vr" = pass ] && echo true || echo false)" \
    --argjson m "$metrics" \
    --arg ts "$(now)"
}

# seed_best_if_unset <base-commit>  — first-ever run: best := baseline.
seed_best_if_unset() {
  local base="$1"
  local have; have="$(jq -r '.best.commit // ""' "$RATCHET_JSON" 2>/dev/null)"
  [ -n "$have" ] && return 0
  local metrics; metrics="$(jq -c '.baseline.metrics // {}' "$RATCHET_JSON" 2>/dev/null)"
  local vp;      vp="$(jq -r '.baseline.verify_passed // true' "$RATCHET_JSON" 2>/dev/null)"
  local n;       n="$(jq -r '.iteration // 0' "$RALPH_DIR/state.json" 2>/dev/null || echo 0)"
  _ratchet_json_set ".best = {commit:\$c, iteration:\$n, metrics:\$m, verify_passed:\$vp, summary:\"seed: initial baseline\", achieved_at:\$ts}" \
    --arg c "$base" \
    --argjson n "${n:-0}" \
    --argjson m "$metrics" \
    --argjson vp "$vp" \
    --arg ts "$(now)"
  # Seeding best from baseline ALSO seeds the floors from the same numbers (the ratchet's starting click).
  _seed_floors_from_metrics "$metrics"
}

# _seed_floors_from_metrics <metrics-json>  — set each metric.floor to the achieved baseline value
#   (only used at first seed; never lowers a floor afterward).
_seed_floors_from_metrics() {
  local metrics="$1" key v
  for key in $(_metric_keys); do
    [ -n "$key" ] || continue
    v="$(printf '%s' "$metrics" | jq -r --arg k "$key" '.[$k] // "null"' 2>/dev/null)"
    [ "$v" = null ] && continue
    _ratchet_json_set ".metrics[\$k].floor = \$v" --arg k "$key" --argjson v "$v"
  done
}

# ===================================================================================================
# §5.1 ADVANCE-branch mutators
# ===================================================================================================

# update_best <cand-commit> <iteration> <cand-metrics-json-path> <summary>
#   MERGE per-metric: keep the prior best high-water for any metric the candidate measured `null`
#   (a transient tool failure must NOT erase the recorded best — that would corrupt the monotone
#   record (INV-2) and make metric_strictly_better treat a later return-to-prior-value as a false
#   "better than null" advance (INV-3)). Only non-null candidate values overwrite; new metrics add.
update_best() {
  local cand="$1" n="$2" mfile="$3" summary="$4"
  local cm prev merged
  cm="$(cat "$mfile" 2>/dev/null || echo '{}')"
  prev="$(jq -c '.best.metrics // {}' "$RATCHET_JSON" 2>/dev/null || echo '{}')"
  merged="$(jq -cn --argjson prev "$prev" --argjson cur "$cm" \
              '$prev + ($cur | with_entries(select(.value != null)))' 2>/dev/null || echo "$cm")"
  _ratchet_json_set ".best = {commit:\$c, iteration:\$n, metrics:\$m, verify_passed:true, summary:\$s, achieved_at:\$ts}" \
    --arg c "$cand" \
    --argjson n "$n" \
    --argjson m "$merged" \
    --arg s "$summary" \
    --arg ts "$(now)"
}

# click_floors <cand-metrics-json-path>  — tighten each floor to the achieved value (INV-2 one-way).
#   ONLY called after ADVANCE. A floor is NEVER lowered: for dir=up we max(floor,achieved); for
#   dir=down we min(floor,achieved). A floor that frozen-metrics already passed is left untouched if
#   the achieved value would loosen it.
click_floors() {
  local mfile="$1" key v dir cur new
  for key in $(_metric_keys); do
    [ -n "$key" ] || continue
    v="$(jq -r --arg k "$key" '.[$k] // "null"' "$mfile" 2>/dev/null)"
    [ "$v" = null ] && continue
    dir="$(_metric_dir "$key")"; cur="$(_metric_floor "$key")"
    if [ "$dir" = down ]; then
      # tighter floor = smaller; only lower the cap toward the achieved (never raise it → never loosen)
      new="$(awk -v a="$cur" -v b="$v" 'BEGIN{print (b<a)?b:a}')"
    else
      # tighter floor = larger; only raise toward achieved (never lower → never loosen)
      new="$(awk -v a="$cur" -v b="$v" 'BEGIN{print (b>a)?b:a}')"
    fi
    _ratchet_json_set ".metrics[\$k].floor = \$v" --arg k "$key" --argjson v "$new"
  done
}

# append_history_jsonl <cand-metrics-json-path>  — metrics/history.jsonl (append-only, one line/ADVANCE).
append_history_jsonl() {
  local mfile="$1"
  mkdir -p "$RALPH_DIR/metrics" 2>/dev/null || true
  local metrics; metrics="$(cat "$mfile" 2>/dev/null || echo '{}')"
  local n; n="$(jq -r '.iteration // 0' "$RALPH_DIR/state.json" 2>/dev/null || echo 0)"
  local cand; cand="$(git rev-parse HEAD 2>/dev/null || echo none)"
  jq -n -c --argjson n "${n:-0}" --arg c "$cand" --arg ts "$(now)" --argjson m "$metrics" \
    '{iteration:$n, commit:$c, ts:$ts, metrics:$m}' \
    >> "$RALPH_DIR/metrics/history.jsonl" 2>/dev/null || true
}

# write_handoff_from_trailer <trailer-json-path>  — overwrite HANDOFF.md from the validated trailer.
write_handoff_from_trailer() {
  local tj="$1" hf="$RALPH_DIR/HANDOFF.md"
  local n; n="$(jq -r '.iteration // 0' "$RALPH_DIR/state.json" 2>/dev/null || echo 0)"
  local cand; cand="$(git rev-parse --short HEAD 2>/dev/null || echo none)"
  local what tier did_not next conf metrics_after
  what="$(jq -r '.what_changed // ""' "$tj" 2>/dev/null)"
  tier="$(jq -r '.tier // ""' "$tj" 2>/dev/null)"
  did_not="$(jq -r '.i_did_NOT // ""' "$tj" 2>/dev/null)"
  next="$(jq -r '.next_candidate // ""' "$tj" 2>/dev/null)"
  conf="$(jq -r '.confidence // 0' "$tj" 2>/dev/null)"
  # metrics for the baton come from the HARNESS best, not the trailer claim (truth, not hope).
  metrics_after="$(jq -c '.best.metrics // {}' "$RATCHET_JSON" 2>/dev/null)"
  {
    printf '# HANDOFF %s (accepted, click @ %s)\n' "$(printf '%04d' "$n")" "$cand"
    printf 'state_after:\n'
    printf '  tier: %s\n' "${tier:-unknown}"
    printf '  metrics: %s\n' "$metrics_after"
    printf 'i_did: "%s"\n' "$(_yaml_escape "$what")"
    printf 'i_did_NOT: "%s"\n' "$(_yaml_escape "$did_not")"
    printf 'next_highest_leverage: "%s"\n' "$(_yaml_escape "$next")"
    printf 'confidence: %s\n' "${conf:-0}"
  } > "$hf.tmp.$$" && mv "$hf.tmp.$$" "$hf"
  rm -f "$hf.tmp.$$" 2>/dev/null || true
}

_yaml_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n'; }

# flip_progress_verdict <iteration> <ACCEPTED|REVERTED> <cand-metrics-json-path>
#   Append the harness :: VERDICT line to the most recent PROGRESS.md block (written AFTER measurement
#   so the next agent sees ground truth, §3.3).
flip_progress_verdict() {
  local n="$1" verdict="$2" mfile="$3" pf="$RALPH_DIR/PROGRESS.md"
  local cand; cand="$(git rev-parse --short HEAD 2>/dev/null || echo none)"
  local nm; nm="$(printf '%04d' "$n")"
  local summary
  if [ "$verdict" = ACCEPTED ]; then
    summary="$(_metric_delta_summary "$mfile")"
    printf ':: VERDICT %s ACCEPTED — %s commit %s\n' "$nm" "${summary:-floors held}" "$cand" >> "$pf"
  else
    printf ':: VERDICT %s REVERTED — %s → reset to baseline. cause→LEDGER.\n' "$nm" "${CAUSE:-not_strictly_better}" >> "$pf"
  fi
}

# _metric_delta_summary <cand-metrics-json>  — "tests_pass 142→148, coverage_pct 71.3→74.5, all floors held"
_metric_delta_summary() {
  local mfile="$1" key v best parts=""
  for key in $(_metric_keys); do
    [ -n "$key" ] || continue
    v="$(jq -r --arg k "$key" '.[$k] // "null"' "$mfile" 2>/dev/null)"
    [ "$v" = null ] && continue
    best="$(_best_metric "$key")"
    if [ -n "$parts" ]; then parts="$parts, "; fi
    parts="$parts$key ${best}→${v}"
  done
  [ -n "$parts" ] && printf '%s, all floors held' "$parts" || printf 'all floors held'
}

# ===================================================================================================
# §5.6 revert + regression bookkeeping (INV-4: never touches .ralph history)
# ===================================================================================================

# set_regression_pending <iteration> <cause> <cand-metrics-json-path>
#   Populated on REVERT, consumed+cleared by the next prompt (§5.6). metric_before from best;
#   metric_after = the candidate's measured values (or "unmeasurable" when verify red).
set_regression_pending() {
  local n="$1" cause="$2" mfile="$3"
  local tj="${ITDIR:-.}/trailer.json"
  local claimed; claimed="$(jq -r '.what_changed // ""' "$tj" 2>/dev/null)"
  local before; before="$(jq -c '.best.metrics // {}' "$RATCHET_JSON" 2>/dev/null)"
  local after finding advice reverted
  reverted="$(git rev-parse --short HEAD 2>/dev/null || echo none)"
  case "$cause" in
    regression_verify_fail)
      after='"unmeasurable (verify red)"'
      finding="verify FAILED on every retry"
      advice="Avoid whatever broke the verify command. Try a smaller, isolated change and run the verify command BEFORE committing."
      ;;
    regression:*)
      after="$(cat "$mfile" 2>/dev/null || echo '{}')"
      finding="$cause"
      advice="A ratcheted metric crossed its floor. Pick a DIFFERENT, smaller item and confirm the regressing metric stays within its floor before committing."
      ;;
    *)
      after="$(cat "$mfile" 2>/dev/null || echo '{}')"
      finding="${cause:-not_strictly_better}"
      advice="The change was not strictly better. Choose a higher-leverage item that raises a non-frozen metric."
      ;;
  esac
  _ratchet_json_set ".regression_pending = {iteration:\$n, what_agent_claimed:\$claimed, independent_finding:\$finding, metric_before:\$before, metric_after:\$after, cause:\$cause, reverted_to:\$rev, advice:\$advice}" \
    --argjson n "$n" \
    --arg claimed "$claimed" \
    --arg finding "$finding" \
    --argjson before "$before" \
    --argjson after "$after" \
    --arg cause "$cause" \
    --arg rev "$reverted" \
    --arg advice "$advice"
}

# clear_regression_pending  — consumed by the next prompt after an ADVANCE.
clear_regression_pending() {
  _ratchet_json_set ".regression_pending = null"
}

# append_ledger_rejected <iteration> <cause>  — add a REJECTED entry (anti-thrash memory, §3.3).
append_ledger_rejected() {
  local n="$1" cause="$2" lf="$RALPH_DIR/LEDGER.md"
  local tj="${ITDIR:-.}/trailer.json"
  local tried; tried="$(jq -r '.what_changed // "(no trailer)"' "$tj" 2>/dev/null)"
  local nm; nm="$(printf '%04d' "$n")"
  # next stable R-id = (max existing R-id)+1
  local rid
  rid="$(grep -oE '^- R-[0-9]+' "$lf" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1)"
  case "$rid" in ''|*[!0-9]*) rid=0;; esac
  rid=$((rid+1))
  # ensure a REJECTED section exists; append under it (append-only — we never rewrite earlier lines).
  if ! grep -qE '^## REJECTED' "$lf" 2>/dev/null; then
    printf '\n## REJECTED (tried, did NOT improve — do not repeat without NEW evidence)\n' >> "$lf"
  fi
  printf -- '- R-%s [ITER%s] "%s" → %s. Do not retry without NEW evidence.\n' \
    "$rid" "$nm" "$tried" "$cause" >> "$lf"
}

# revert_to_baseline <baseline-commit>  — §5.6. reset_hard default with -e .ralph (INV-4); revert_commit opt-in.
revert_to_baseline() {
  local base="$1"
  case "${RALPH_REVERT_STRATEGY:-reset_hard}" in
    reset_hard)
      git reset --hard "$base" >/dev/null 2>&1
      # wipe stray files BUT preserve .ralph (history!) and agy's cache/. INV-4 holds by exclusion.
      git clean -fdx -e '.ralph' -e 'cache' >/dev/null 2>&1
      ;;
    revert_commit)
      # core.hooksPath=/dev/null: a harness-internal revert must not run the target repo's commit hooks —
      # an unbounded hanging hook here would freeze the loop body (INV-5). </dev/null denies blocking stdin.
      git -c core.hooksPath=/dev/null revert --no-edit "$(git rev-parse HEAD 2>/dev/null)" </dev/null >/dev/null 2>&1
      ;;
    *)
      git reset --hard "$base" >/dev/null 2>&1
      git clean -fdx -e '.ralph' -e 'cache' >/dev/null 2>&1
      ;;
  esac
}

# revert_dirty_to <sha>  — §7.2 timeout/transient_crash path: abandon a wedged worker's PARTIAL work
#   (uncommitted edits and/or commits it managed to make) back to the pre-agy HEAD, WITHOUT touching
#   .ralph history (INV-4) or agy's cache/. Tolerant of a missing/"none"/invalid sha (first-ever run).
revert_dirty_to() {
  local sha="$1"
  if [ -z "$sha" ] || [ "$sha" = none ] || ! git rev-parse --verify "$sha" >/dev/null 2>&1; then
    # no known-good commit to land on: just discard uncommitted changes, keep .ralph + cache.
    git reset --hard >/dev/null 2>&1 || true
    git clean -fdx -e '.ralph' -e 'cache' >/dev/null 2>&1 || true
    return 0
  fi
  git reset --hard "$sha" >/dev/null 2>&1 || true
  git clean -fdx -e '.ralph' -e 'cache' >/dev/null 2>&1 || true
  return 0
}

# rotate_if_big  — §10. Keep "never stops" from meaning "fills the disk". Gzip+truncate the supervisor
#   log past 10MB (keep newest 20 archives); gzip iter logs older than the newest 500. The tiny
#   append-only audit trail (iterations/, progress.ndjson, PROGRESS.md, LEDGER.md) is NEVER rotated.
rotate_if_big() {
  local f="$RALPH_DIR/logs/supervisor.log" sz
  mkdir -p "$RALPH_DIR/archive" 2>/dev/null || true
  if [ -f "$f" ]; then
    sz="$(stat -f%z "$f" 2>/dev/null || echo 0)"; case "$sz" in ''|*[!0-9]*) sz=0;; esac
    if [ "$sz" -gt 10485760 ]; then
      gzip -c "$f" > "$RALPH_DIR/archive/supervisor.log.$(date +%s).gz" 2>/dev/null && : > "$f"
      ls -1t "$RALPH_DIR"/archive/*.gz 2>/dev/null | tail -n +21 | while IFS= read -r old; do
        rm -f "$old" 2>/dev/null || true; done
    fi
  fi
  ls -1t "$RALPH_DIR"/logs/iter-*.log 2>/dev/null | tail -n +501 | while IFS= read -r old; do
    gzip "$old" 2>/dev/null || true; done
  return 0
}

# restore_protected_files  — §3.2 / §12 / T-SAFE-2. MISSION.md is READ-ONLY to the agent. We keep a
#   trust-on-first-use canonical copy at .ralph/.canonical/MISSION.md; if the live MISSION.md diverges
#   (the agent edited it), we restore the canonical and ECHO the violated filename(s). We also restore
#   RATCHET.json / state.json from the canonical if the agent corrupted them to non-parseable JSON
#   (the harness owns those; a structural break would blind the gate). Always returns 0; the caller
#   decides the verdict (a MISSION violation forces a REVERT in run_one_iteration).
restore_protected_files() {
  local cdir="$RALPH_DIR/.canonical" violations=""
  mkdir -p "$cdir" 2>/dev/null || true
  # MISSION.md — strict, content-pinned (TOFU).
  if [ -f "$RALPH_DIR/MISSION.md" ]; then
    if [ ! -f "$cdir/MISSION.md" ]; then
      cp "$RALPH_DIR/MISSION.md" "$cdir/MISSION.md" 2>/dev/null || true   # first sight = canonical
    elif ! cmp -s "$RALPH_DIR/MISSION.md" "$cdir/MISSION.md"; then
      cp "$cdir/MISSION.md" "$RALPH_DIR/MISSION.md" 2>/dev/null || true    # restore canonical
      violations="MISSION.md"
    fi
  fi
  # RATCHET.json / state.json — harness-owned; only repair if the agent made them unparseable.
  local pf
  for pf in RATCHET.json state.json; do
    [ -f "$RALPH_DIR/$pf" ] || continue
    if jq . "$RALPH_DIR/$pf" >/dev/null 2>&1; then
      cp "$RALPH_DIR/$pf" "$cdir/$pf" 2>/dev/null || true                 # refresh good canonical
    elif [ -f "$cdir/$pf" ]; then
      cp "$cdir/$pf" "$RALPH_DIR/$pf" 2>/dev/null || true                 # restore last-good
      violations="${violations:+$violations,}$pf"
    fi
  done
  [ -n "$violations" ] && printf '%s' "$violations"
  return 0
}

# ===================================================================================================
# §5.8 handle_noop — agent changed nothing.  Not advance, not regression.
# ===================================================================================================
handle_noop() {
  local n="$1"
  DECISION=NOOP; CAUSE="noop_no_change"
  bump noop_streak
  local streak; streak="$(jq -r '.noop_streak // 0' "$RALPH_DIR/state.json" 2>/dev/null || echo 0)"
  case "$streak" in ''|*[!0-9]*) streak=0;; esac
  flip_progress_noop "$n"
  if [ "$streak" -ge 3 ]; then
    log "noop_streak=$streak ≥ 3 → force tier escalation (§9)"
    maybe_advance_tier force
  fi
  write_decision_json "${ITDIR:-.}/decision.json" NOOP "$CAUSE"
  local empty="${ITDIR:-.}/noop.metrics.json"; printf '{}' > "$empty"
  append_iteration_record "$n" NOOP "$CAUSE" "$empty"
  persist_ratchet_atomic; persist_state_atomic
}

flip_progress_noop() {
  local n="$1" pf="$RALPH_DIR/PROGRESS.md"
  printf ':: VERDICT %s NOOP — agent produced no change; next prompt requests one concrete improvement.\n' \
    "$(printf '%04d' "$n")" >> "$pf"
}

# ===================================================================================================
# Integrity audit — record_claim_vs_truth (never gates; INV-3 transparency)
# ===================================================================================================

# record_claim_vs_truth <iteration> <trailer-json-path> <cand-metrics-json-path>
#   Compares the agent's CLAIMED metrics_after against the HARNESS-measured truth. A persistent gap
#   raises integrity_flag (consumed by the prompt builder as {{INTEGRITY_NOTICE}}). NEVER affects the
#   gate decision.
record_claim_vs_truth() {
  local n="$1" tj="$2" mfile="$3"
  local audit="${ITDIR:-.}/claim_vs_truth.json"
  local key claimed measured gaps=0 acc='[]'
  # NOTE: build the gap list in the CURRENT shell (no pipe subshell) so the `gaps` counter survives.
  for key in $(_metric_keys); do
    [ -n "$key" ] || continue
    claimed="$(jq -r --arg k "$key" '.metrics_after[$k] // "null"' "$tj" 2>/dev/null)"
    measured="$(jq -r --arg k "$key" '.[$k] // "null"' "$mfile" 2>/dev/null)"
    if [ "$claimed" != null ] && [ "$measured" != null ]; then
      # gap if they differ by more than a tiny epsilon
      if [ "$(awk -v a="$claimed" -v b="$measured" 'BEGIN{d=a-b; if(d<0)d=-d; print (d>0.0001)?1:0}')" = 1 ]; then
        gaps=$((gaps+1))
        acc="$(printf '%s' "$acc" | jq -c --arg k "$key" --argjson c "$claimed" --argjson m "$measured" '. + [{metric:$k, claimed:$c, measured:$m}]')"
      fi
    elif [ "$claimed" != null ] && [ "$measured" = null ]; then
      gaps=$((gaps+1))
      acc="$(printf '%s' "$acc" | jq -c --arg k "$key" --argjson c "$claimed" '. + [{metric:$k, claimed:$c, measured:null}]')"
    fi
  done
  jq -n --argjson n "$n" --argjson gaps "$gaps" --argjson details "${acc:-[]}" --arg ts "$(now)" \
    '{iteration:$n, gap_count:$gaps, gaps:$details, ts:$ts}' > "$audit" 2>/dev/null || true

  # persistent gaps → raise integrity_flag streak in state.json (prompt builder reads it).
  if [ "$gaps" -gt 0 ]; then
    bump integrity_flag
    log "integrity: $gaps claimed/measured gap(s) at iter $n (advisory only, gate unaffected)"
  else
    set_state integrity_flag 0
  fi
}

# write_decision_json <out-path> <DECISION> <CAUSE>
write_decision_json() {
  local out="$1" decision="$2" cause="$3"
  local n; n="$(jq -r '.iteration // 0' "$RALPH_DIR/state.json" 2>/dev/null || echo 0)"
  local head; head="$(git rev-parse HEAD 2>/dev/null || echo none)"
  jq -n --argjson n "${n:-0}" --arg d "$decision" --arg c "$cause" --arg h "$head" --arg ts "$(now)" \
    '{iteration:$n, decision:$d, cause:$c, head:$h, ts:$ts}' > "$out.tmp.$$" 2>/dev/null \
    && mv "$out.tmp.$$" "$out"
  rm -f "$out.tmp.$$" 2>/dev/null || true
}

# ===================================================================================================
# Atomic RATCHET.json mutator (write tmp, validate parses, mv over — §6.2). Internal helper.
#   _ratchet_json_set "<jq-assignment-expr>" [jq --arg/--argjson pairs...]
# ===================================================================================================
_ratchet_json_set() {
  local expr="$1"; shift
  local tmp="$RATCHET_JSON.tmp.$$"
  [ -f "$RATCHET_JSON" ] || printf '{}' > "$RATCHET_JSON"
  if jq "$@" "$expr | .updated_at=\"$(now)\"" "$RATCHET_JSON" > "$tmp" 2>/dev/null && jq . "$tmp" >/dev/null 2>&1; then
    mv "$tmp" "$RATCHET_JSON"
  else
    log "_ratchet_json_set: jq update failed for expr [$expr]; leaving RATCHET.json unchanged"
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  rm -f "$tmp" 2>/dev/null || true
}

# ===================================================================================================
# §5.1  run_one_iteration — the orchestrator (invoked by the supervisor only on a success-class run)
#   Precondition: agy exited 0 this iteration. CWD = target repo. ITDIR may be preset by supervisor.
# ===================================================================================================
run_one_iteration() {
  local N ITDIR_LOCAL
  N="$(jq -r '.iteration // 0' "$RALPH_DIR/state.json" 2>/dev/null || echo 0)"
  case "$N" in ''|*[!0-9]*) N=0;; esac
  ITDIR_LOCAL="${ITDIR:-$RALPH_DIR/iter/$(printf '%06d' "$N")}"
  ITDIR="$ITDIR_LOCAL"
  mkdir -p "$ITDIR" 2>/dev/null || true

  # STEP S — SNAPSHOT BASELINE (independent; before judging the candidate).
  #   The baseline is the PRE-AGY HEAD ("sha_before"), NOT the current HEAD — agy may have already
  #   committed by now, so `git rev-parse HEAD` is the CANDIDATE, not the base. Resolution order:
  #     1. RALPH_BASE_COMMIT env (the supervisor's recorded sha_before) — authoritative.
  #     2. RATCHET.baseline.commit (snapshot at the start of this iteration).
  #     3. refs/best (last known-good).
  #     4. HEAD (first-ever run / external change — ensure_baseline_measured re-measures it).
  local BASE_COMMIT HEAD_NOW
  HEAD_NOW="$(git rev-parse HEAD 2>/dev/null || echo none)"
  BASE_COMMIT="${RALPH_BASE_COMMIT:-}"
  if [ -z "$BASE_COMMIT" ]; then
    BASE_COMMIT="$(jq -r '.baseline.commit // ""' "$RATCHET_JSON" 2>/dev/null)"
  fi
  if [ -z "$BASE_COMMIT" ] && [ -f "$RALPH_DIR/refs/best" ]; then
    BASE_COMMIT="$(cat "$RALPH_DIR/refs/best" 2>/dev/null)"
  fi
  if [ -z "$BASE_COMMIT" ] || ! git rev-parse --verify "$BASE_COMMIT" >/dev/null 2>&1; then
    BASE_COMMIT="$HEAD_NOW"
  fi
  ensure_baseline_measured "$BASE_COMMIT" "$ITDIR/base"
  seed_best_if_unset "$BASE_COMMIT"
  load_floors_from "$RATCHET_JSON"

  # STEP T — PARSE TRAILER (advisory only; both helpers always exit 0)
  python3 "$_RATCHET_LIB_DIR/extract_trailer.py"  "$ITDIR/agy.stdout" "$ITDIR/trailer.json" 2>/dev/null || true
  python3 "$_RATCHET_LIB_DIR/validate_trailer.py" "$ITDIR/trailer.json" 2>/dev/null || true
  [ -f "$ITDIR/trailer.json" ] || printf '{}' > "$ITDIR/trailer.json"

  # STEP P — PROTECTED-FILE GUARD (§3.2/§12, T-SAFE-2). MISSION.md is read-only; RATCHET/state are
  #   harness-owned. If the agent tampered, restore canonical and HARD-REJECT this iteration: discard
  #   the agent's commit/work back to the baseline so a tamper can never be rewarded.
  local PROT_VIOLATION; PROT_VIOLATION="$(restore_protected_files)"
  if [ -n "$PROT_VIOLATION" ]; then
    log "PROTECTED-FILE VIOLATION ($PROT_VIOLATION) at iter $N → restored canonical + REVERT"
    DECISION=REVERT; CAUSE="protected_file_violation:$PROT_VIOLATION"
    local _empty="$ITDIR/prot.metrics.json"; printf '{}' > "$_empty"
    bump reverts
    set_regression_pending "$N" "$CAUSE" "$_empty"
    flip_progress_verdict "$N" REVERTED "$_empty"
    append_ledger_rejected "$N" "$CAUSE"
    revert_to_baseline "$BASE_COMMIT"
    bump consecutive_reverts
    write_decision_json "$ITDIR/decision.json" REVERT "$CAUSE"
    append_iteration_record "$N" REVERT "$CAUSE" "$_empty"
    persist_ratchet_atomic; persist_state_atomic
    return 0
  fi

  # STEP C — DID THE AGENT CHANGE / COMMIT ANYTHING?
  # Compare RESOLVED revisions, not raw strings: BASE_COMMIT arrives as a SHORT sha (the supervisor
  # captures sha_before with `git rev-parse --short`), while HEAD here is FULL. A raw `short = full`
  # string test is ALWAYS false on a true no-op, mis-routing a do-nothing iteration into the REVERT
  # branch (mislabelled a regression) and starving the noop_streak→tier-escalation lever. Resolve both.
  if git diff --quiet 2>/dev/null && git diff --cached --quiet 2>/dev/null \
     && [ -z "$(git status --porcelain 2>/dev/null | grep -vE '^.. (\.ralph/|cache/)' || true)" ] \
     && [ "$(git rev-parse "$BASE_COMMIT" 2>/dev/null || echo base)" = "$(git rev-parse HEAD 2>/dev/null || echo none)" ]; then
    handle_noop "$N"; return 0
  fi
  if ! git diff --quiet HEAD 2>/dev/null; then          # agent forgot to commit → harness commits it
    git add -A >/dev/null 2>&1
    # core.hooksPath=/dev/null + --no-verify: this is an INTERNAL bookkeeping commit; it must NEVER run the
    # TARGET repo's git hooks. An UNBOUNDED hanging pre-commit/commit-msg hook here would freeze
    # run_one_iteration and thus the whole supervisor — even STOP/SIGTERM can't drain a body wedged inside
    # a foreground git child (the trap is deferred). </dev/null also denies a hook any blocking stdin.
    git -c core.hooksPath=/dev/null commit -q --no-verify \
      -m "ralph(iter $N): auto-commit agent working tree [agent forgot to commit]" </dev/null >/dev/null 2>&1 || true
  fi
  local CAND_COMMIT; CAND_COMMIT="$(git rev-parse HEAD 2>/dev/null || echo none)"

  # STEP M — INDEPENDENT RE-MEASUREMENT (the anti-fabrication core; INV-3)
  local CAND_VERIFY CAND_M
  CAND_VERIFY="$(measure_verify "$ITDIR/cand")"
  CAND_M="$ITDIR/cand.metrics.json"
  measure_metrics "$CAND_M" "$ITDIR/cand"
  # Publish the canonical per-iteration metrics snapshot the spec promises (§2.2/§3.1): the harness's
  # OWN measurement of the candidate tree, not the agent's claim. Other tools + the next prompt read it.
  mkdir -p "$RALPH_DIR/metrics" 2>/dev/null || true
  cp "$CAND_M" "$RALPH_DIR/metrics/latest.json" 2>/dev/null || true
  record_claim_vs_truth "$N" "$ITDIR/trailer.json" "$CAND_M"

  # STEP G — THE GATE (the pawl) → sets DECISION + CAUSE
  ratchet_gate "$BASE_COMMIT" "$CAND_COMMIT" "$CAND_VERIFY" "$CAND_M"

  # Refresh the harness-computed completion witness (INV-6) so the referee push-gate sees it.
  _recompute_goals_done

  # STEP R/W — APPLY
  if [ "$DECISION" = ADVANCE ]; then
    update_best "$CAND_COMMIT" "$N" "$CAND_M" "$(jq -r '.what_changed // ""' "$ITDIR/trailer.json" 2>/dev/null)"
    click_floors "$CAND_M"
    mkdir -p "$RALPH_DIR/refs" 2>/dev/null || true
    printf '%s\n' "$CAND_COMMIT" > "$RALPH_DIR/refs/best"
    # Re-sync RATCHET.baseline to the newly accepted HEAD so the next iteration's fallback baseline
    # (and any REVERT that resolves base from RATCHET.json) lands on THIS accepted commit, not a stale one.
    _ratchet_json_set ".baseline = {commit:\$c, tree_clean:true, verify_passed:true, metrics:(.best.metrics // {}), measured_at:\$ts}" \
      --arg c "$CAND_COMMIT" --arg ts "$(now)"
    append_history_jsonl "$CAND_M"
    write_handoff_from_trailer "$ITDIR/trailer.json"
    flip_progress_verdict "$N" ACCEPTED "$CAND_M"
    clear_regression_pending
    set_state consecutive_reverts 0
    bump advances
    maybe_advance_tier
    if declare -F maybe_referee_gate >/dev/null 2>&1; then
      maybe_referee_gate "$CAND_COMMIT"               # §5.7 push-gate only (local commit stands)
    fi
  else
    bump reverts
    set_regression_pending "$N" "$CAUSE" "$CAND_M"
    flip_progress_verdict "$N" REVERTED "$CAND_M"
    append_ledger_rejected "$N" "$CAUSE"
    revert_to_baseline "$BASE_COMMIT"
    bump consecutive_reverts                           # §9 circuit-breaker: escalate tier, NEVER stop
  fi

  write_decision_json "$ITDIR/decision.json" "$DECISION" "$CAUSE"
  append_iteration_record "$N" "$DECISION" "$CAUSE" "$CAND_M"
  persist_ratchet_atomic; persist_state_atomic
  # NEVER emit a "session summary and stop." Return; the supervisor re-enters.
  return 0
}
