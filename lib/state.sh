#!/usr/bin/env bash
# lib/state.sh — lock / pid / state.json / heartbeat / iteration-record IO
#                (SPEC §3.5, §6.2, §6.3; INV-4, INV-5).
#
# Role: the supervisor's durable-bookkeeping primitives. Owns:
#   - the mkdir mutex + stale-PID steal (acquire_lock_or_exit, §6.3)
#   - atomic pid write (write_pid) and the EXIT trap that frees lock+pid
#   - state.json init/resume + atomic field mutation (load_or_init_state / set_state / bump
#     / persist_state_atomic), delegating the crash-safe write to lib/state.py (§6.2)
#   - the liveness beacon heartbeat.json, rewritten at start AND end of every iteration (§3.5)
#   - per-iteration metadata (write_iter_meta) and the never-deleted audit record
#     iterations/NNNNNN.json + progress.ndjson (append_iteration_record, INV-4)
#   - the generic atomic-json-write helper (atomic_json_write, §6.2) other libs call
#   - shared helpers now() and log() that the other lib/*.sh files reference.
#
# BASH-3.2 / ASSOC-ARRAY HAZARD (integrator note): macOS bash is 3.2.57 and there is NO
# /opt/homebrew/bin/bash here. This file uses NO associative arrays and NO namerefs. All
# structured state lives in JSON files mutated atomically by lib/state.py (tmp+validate+
# rename), NOT in `declare -A` maps. That both dodges the bash-4 requirement AND gives the
# crash-safety §6.2 demands. Metric vectors that DO need maps (ratchet group) are passed via
# temp JSON files, never namerefs.
#
# RESOLUTION of the §6.3 trap pseudocode: the spec shows a top-level
#   `trap 'rm -rf .ralph/ralph.lock; rm -f .ralph/ralph.pid' EXIT`
# with bare relative paths. We instead install the trap from install_exit_trap() using the
# absolute $RALPH_DIR so it is correct regardless of cwd, only removing the lock if WE own it
# (owner.pid == $$), so a stolen/foreign lock is never clobbered on our exit. This is a
# faithful, hardened implementation of the same intent.
#
# Idempotent source guard.

if [ -n "${__RALPH_STATE_SH_LOADED:-}" ]; then
  return 0 2>/dev/null || true
fi
__RALPH_STATE_SH_LOADED=1

# ---- locate ourselves so we can call the python helper next to us ----
# RALPH_LIB_DIR: directory containing this script and lib/state.py.
if [ -z "${RALPH_LIB_DIR:-}" ]; then
  # BASH_SOURCE[0] is this file even when sourced.
  __state_self="${BASH_SOURCE[0]:-$0}"
  RALPH_LIB_DIR="$(cd "$(dirname "$__state_self")" 2>/dev/null && pwd)"
  unset __state_self
fi
: "${RALPH_STATE_PY:=$RALPH_LIB_DIR/state.py}"
: "${RALPH_PERL:=/usr/bin/perl}"

# RALPH_DIR: absolute path to <target>/.ralph. Default to ./.ralph for stand-alone/test use.
: "${RALPH_DIR:=.ralph}"

# Convenience paths (recomputed lazily so a late RALPH_DIR change is honored).
_state_file()     { printf '%s/state.json'     "$RALPH_DIR"; }
_heartbeat_file() { printf '%s/heartbeat.json' "$RALPH_DIR"; }
_pid_file()       { printf '%s/ralph.pid'      "$RALPH_DIR"; }
_lock_dir()       { printf '%s/ralph.lock'     "$RALPH_DIR"; }

# ---- shared helpers (other lib/*.sh files reference these by name) ----

# now: UTC ISO-8601 with trailing Z (the timestamp format every schema in §3 uses).
now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# _epoch: integer seconds since epoch.
_epoch() {
  date +%s
}

# log: append a timestamped line to the supervisor log AND echo to stderr. Created here so
# classify.sh / backoff.sh / the supervisor share one logger. Honors RALPH_LOG_FILE if set,
# else <RALPH_DIR>/logs/supervisor.log.
log() {
  local line dest
  line="$(now) [$$] $*"
  dest="${RALPH_LOG_FILE:-$RALPH_DIR/logs/supervisor.log}"
  local dir
  dir="$(dirname "$dest")"
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || true
  printf '%s\n' "$line" >> "$dest" 2>/dev/null || true
  printf '%s\n' "$line" >&2
}

# atomic_json_write <file> <json-string>
#   Generic crash-safe JSON writer (§6.2): write to <file>.tmp, validate it parses with jq,
#   then atomic-rename over <file>. Returns non-zero (and leaves the live file untouched) if
#   the payload does not parse. Used by libs that already hold a full JSON string in hand.
atomic_json_write() {
  local file="$1" payload="$2"
  local dir tmp
  dir="$(dirname "$file")"
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || true
  tmp="$file.tmp.$$"
  printf '%s' "$payload" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  if ! jq . "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  mv -f "$tmp" "$file" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}

# ---- lock + pid (§6.3) ----

# acquire_lock_or_exit
#   mkdir-based mutex. If the lock is held by a LIVE pid -> print + exit 3 (already-running).
#   If held by a DEAD pid -> steal it. mkdir is atomic on APFS, so this is a correct mutex
#   without flock. Writes our pid into owner.pid on acquire.
acquire_lock_or_exit() {
  local lock owner
  lock="$(_lock_dir)"
  [ -d "$RALPH_DIR" ] || mkdir -p "$RALPH_DIR" 2>/dev/null || true
  if mkdir "$lock" 2>/dev/null; then
    echo $$ > "$lock/owner.pid"
    return 0
  fi
  owner="$(cat "$lock/owner.pid" 2>/dev/null)"
  if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
    echo "ralph: already running for this target (pid $owner)"
    exit 3
  fi
  # Owner is dead (or unknown) -> steal the stale lock.
  rm -rf "$lock" 2>/dev/null
  mkdir "$lock" 2>/dev/null || { echo "ralph: could not acquire lock"; exit 3; }
  echo $$ > "$lock/owner.pid"
  return 0
}

# release_lock: remove the lock ONLY if we own it. Never clobber a foreign/stolen lock.
release_lock() {
  local lock owner
  lock="$(_lock_dir)"
  owner="$(cat "$lock/owner.pid" 2>/dev/null)"
  if [ "$owner" = "$$" ]; then
    rm -rf "$lock" 2>/dev/null || true
  fi
}

# write_pid: atomically record our pid so `ralph status`/`ralph stop` can find us.
write_pid() {
  local f tmp
  f="$(_pid_file)"
  [ -d "$RALPH_DIR" ] || mkdir -p "$RALPH_DIR" 2>/dev/null || true
  tmp="$f.tmp.$$"
  printf '%s\n' "$$" > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}

# remove_pid: drop our pid file if it points at us.
remove_pid() {
  local f cur
  f="$(_pid_file)"
  cur="$(cat "$f" 2>/dev/null)"
  if [ "$cur" = "$$" ]; then
    rm -f "$f" 2>/dev/null || true
  fi
}

# install_exit_trap: free lock + pid on EXIT (§6.3), only what we own. Call once after
# acquire_lock_or_exit + write_pid.
install_exit_trap() {
  trap '__ralph_on_exit' EXIT
}
__ralph_on_exit() {
  release_lock
  remove_pid
}

# ---- state.json init / resume / mutate (§3.5) ----

# _state_seed: the canonical fresh state.json object (printed as JSON).
_state_seed() {
  cat <<JSON
{
  "iteration": 0,
  "advances": 0,
  "reverts": 0,
  "noops": 0,
  "consecutive_failures": 0,
  "consecutive_quota_hits": 0,
  "consecutive_reverts": 0,
  "noop_streak": 0,
  "backoff_s": 0,
  "last_class": "none",
  "last_success_iso": "",
  "last_run_started_iso": "",
  "crash_loop_strikes": 0,
  "tier": "T1_correctness",
  "started_iso": "$(now)"
}
JSON
}

# load_or_init_state
#   Ensure state.json exists (seed if absent/corrupt), then export ITER from it so a
#   launchd-relaunched supervisor RESUMES at the saved iteration rather than restarting.
#   Exports: ITER (current iteration counter).
load_or_init_state() {
  local f
  f="$(_state_file)"
  [ -d "$RALPH_DIR" ] || mkdir -p "$RALPH_DIR" 2>/dev/null || true
  # init = create only if missing/unparseable.
  python3 "$RALPH_STATE_PY" init "$f" "$(_state_seed)" >/dev/null 2>&1 || {
    # Fallback if python helper is unavailable: write the seed via jq-validated atomic write.
    if [ ! -f "$f" ] || ! jq . "$f" >/dev/null 2>&1; then
      atomic_json_write "$f" "$(_state_seed)"
    fi
  }
  ITER="$(python3 "$RALPH_STATE_PY" get-raw "$f" iteration 0 2>/dev/null)"
  case "$ITER" in
    *[!0-9]* | "" ) ITER=0 ;;
  esac
  export ITER
}

# set_state <key> <value>
#   Atomically set a top-level (or dotted) field in state.json. Numeric-looking and JSON
#   values are stored typed; everything else is stored as a string. Delegates to state.py.
set_state() {
  local key="$1" value="$2" f
  f="$(_state_file)"
  python3 "$RALPH_STATE_PY" set "$f" "$key" "$value" >/dev/null 2>&1
}

# set_state_str <key> <value> : force string assignment (e.g. ISO timestamps).
set_state_str() {
  local key="$1" value="$2" f
  f="$(_state_file)"
  python3 "$RALPH_STATE_PY" set-str "$f" "$key" "$value" >/dev/null 2>&1
}

# bump <key> [delta]
#   Atomically increment a numeric state.json field (delta default 1). Echoes the new value.
bump() {
  local key="$1" delta="${2:-1}" f
  f="$(_state_file)"
  python3 "$RALPH_STATE_PY" bump "$f" "$key" "$delta" 2>/dev/null
}

# get_state <key> [default] : read a state.json field (raw scalar).
get_state() {
  local key="$1" def="${2:-}" f
  f="$(_state_file)"
  python3 "$RALPH_STATE_PY" get-raw "$f" "$key" "$def" 2>/dev/null
}

# persist_state_atomic
#   No-op consolidation point: every set_state/bump already writes atomically via state.py,
#   so the live file is always consistent. This function exists for the call sites in §5/§7
#   that explicitly "persist" at PERSIST; it re-validates the file and rewrites it atomically
#   if (somehow) it does not parse, guaranteeing a clean file at each checkpoint.
persist_state_atomic() {
  local f
  f="$(_state_file)"
  if jq . "$f" >/dev/null 2>&1; then
    return 0
  fi
  # Corrupt -> reseed (do not lose the loop; INV-5). Loud about it.
  log "WARN state.json unparseable at persist -> reseeding"
  atomic_json_write "$f" "$(_state_seed)"
}

# ---- heartbeat.json (§3.5) ----
#
# heartbeat [phase_override]
#   Rewrite the liveness beacon atomically. Reads counters from state.json so the beacon is
#   always consistent with persisted state. Uses the shell variables the supervisor maintains
#   ($phase, $ITER, $rc, $class, $backoff_s, $sha_after, ...) when present, falling back to
#   state.json / safe defaults otherwise. A watcher declares the loop dead if
#   now - ts > 3 * max(RALPH_MIN_INTERVAL_S, last_duration_s).
heartbeat() {
  local ph="${1:-${phase:-idle}}"
  local f epoch ts iter sha started uptime
  f="$(_heartbeat_file)"
  epoch="$(_epoch)"
  ts="$(now)"
  iter="${ITER:-$(get_state iteration 0)}"
  sha="${sha_after:-${sha_before:-}}"
  started="$(get_state started_iso "")"

  # uptime: epoch - started_iso epoch, best-effort.
  uptime=0
  if [ -n "$started" ]; then
    local sepoch
    sepoch="$(date -u -j -f %Y-%m-%dT%H:%M:%SZ "$started" +%s 2>/dev/null || echo "")"
    case "$sepoch" in
      *[!0-9]* | "" ) sepoch="" ;;
    esac
    [ -n "$sepoch" ] && uptime=$((epoch - sepoch))
    [ "$uptime" -lt 0 ] && uptime=0
  fi

  local cfail crev last_exit last_class bks stalled target pid next_eta
  cfail="$(get_state consecutive_failures 0)"
  crev="$(get_state consecutive_reverts 0)"
  last_class="${class:-$(get_state last_class none)}"
  last_exit="${rc:-0}"
  case "$last_exit" in *[!0-9]* | "" ) last_exit=0 ;; esac
  bks="${backoff_s:-$(get_state backoff_s 0)}"
  case "$bks" in *[!0-9.]* | "" ) bks=0 ;; esac
  next_eta="${next_action_eta_s:-$bks}"
  case "$next_eta" in *[!0-9.]* | "" ) next_eta=0 ;; esac
  stalled="${stalled:-false}"
  case "$stalled" in true|false ) : ;; * ) stalled=false ;; esac
  target="${RALPH_TARGET_NAME:-$(basename "$(dirname "$RALPH_DIR" 2>/dev/null)" 2>/dev/null)}"
  pid=$$

  # Build the JSON via jq so values are correctly typed/escaped (jq is verified present).
  local payload
  payload="$(jq -n \
    --arg ts "$ts" \
    --argjson epoch "$epoch" \
    --arg target "$target" \
    --argjson pid "$pid" \
    --argjson iteration "${iter:-0}" \
    --arg phase "$ph" \
    --argjson last_exit_code "$last_exit" \
    --arg last_class "$last_class" \
    --argjson consecutive_failures "${cfail:-0}" \
    --argjson consecutive_reverts "${crev:-0}" \
    --argjson next_action_eta_s "$next_eta" \
    --argjson backoff_s "$bks" \
    --argjson uptime_s "$uptime" \
    --arg sha_head "$sha" \
    --argjson stalled "$stalled" \
    '{ts:$ts, epoch:$epoch, target:$target, pid:$pid, iteration:$iteration,
      phase:$phase, last_exit_code:$last_exit_code, last_class:$last_class,
      consecutive_failures:$consecutive_failures, consecutive_reverts:$consecutive_reverts,
      next_action_eta_s:$next_action_eta_s, backoff_s:$backoff_s, uptime_s:$uptime_s,
      sha_head:$sha_head, stalled:$stalled}' 2>/dev/null)"

  if [ -n "$payload" ]; then
    atomic_json_write "$f" "$payload" || true
  fi
}

# final_heartbeat <phase>: write one last beacon (used at shutdown).
final_heartbeat() {
  heartbeat "${1:-stopped}"
}

# ---- per-iteration metadata + audit trail (§3.5, INV-4) ----

# write_iter_meta <itdir> <rc> <class> <sha_before> <sha_after>
#   Write the per-iteration meta.json into the iter scratch dir (reproducibility). This is
#   the iter/NNNNNN/ scratch record (separate from the never-deleted iterations/NNNNNN.json).
write_iter_meta() {
  local itdir="$1" rc="$2" class="$3" sha_before="$4" sha_after="$5"
  [ -d "$itdir" ] || mkdir -p "$itdir" 2>/dev/null || true
  local payload
  payload="$(jq -n \
    --arg ts "$(now)" \
    --argjson rc "${rc:-0}" \
    --arg class "$class" \
    --arg sha_before "$sha_before" \
    --arg sha_after "$sha_after" \
    --argjson iteration "${ITER:-0}" \
    '{ts:$ts, iteration:$iteration, rc:$rc, class:$class,
      sha_before:$sha_before, sha_after:$sha_after}' 2>/dev/null)"
  [ -n "$payload" ] && atomic_json_write "$itdir/meta.json" "$payload" || true
}

# append_iteration_record <n> <decision> <cause> <metrics_json>
#   Write the durable, NEVER-DELETED audit record iterations/NNNNNN.json AND append one line
#   to progress.ndjson (INV-4). <metrics_json> is a JSON object string (may be "{}" or
#   "null"); the ratchet group passes the harness-measured metric vector. Both files live
#   under .ralph/ and are excluded from `git clean -e .ralph`, so they survive every revert.
append_iteration_record() {
  local n="$1" decision="$2" cause="$3" metrics_json="${4:-null}"
  local padded recdir recfile ndj
  padded="$(printf '%06d' "$n" 2>/dev/null || printf '%s' "$n")"
  recdir="$RALPH_DIR/iterations"
  recfile="$recdir/$padded.json"
  ndj="$RALPH_DIR/progress.ndjson"
  [ -d "$recdir" ] || mkdir -p "$recdir" 2>/dev/null || true

  # Validate metrics_json; fall back to null if it doesn't parse.
  if ! printf '%s' "$metrics_json" | jq . >/dev/null 2>&1; then
    metrics_json='null'
  fi

  local payload
  payload="$(jq -n \
    --argjson iteration "${n:-0}" \
    --arg ts "$(now)" \
    --arg decision "$decision" \
    --arg cause "$cause" \
    --arg tier "$(get_state tier "")" \
    --arg last_class "$(get_state last_class none)" \
    --argjson metrics "$metrics_json" \
    '{iteration:$iteration, ts:$ts, decision:$decision, cause:$cause,
      tier:$tier, last_class:$last_class, metrics:$metrics}' 2>/dev/null)"

  if [ -n "$payload" ]; then
    # iterations/NNNNNN.json is written once and never deleted; atomic write is still nice.
    atomic_json_write "$recfile" "$payload" || true
    # progress.ndjson: one compact object per line, append-only.
    printf '%s\n' "$(printf '%s' "$payload" | jq -c . 2>/dev/null)" >> "$ndj" 2>/dev/null || true
  fi
}
