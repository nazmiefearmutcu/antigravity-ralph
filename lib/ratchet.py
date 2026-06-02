#!/usr/bin/env python3
"""lib/ratchet.py — RATCHET.json verbs (SPEC §5.3) and the gate logic mirrored from lib/ratchet.sh.

ROLE: the contract surface Lens B reads. Four verbs:

    ratchet.py render-table              → markdown table of metrics (fills {{RATCHET_TABLE}})
    ratchet.py check <latest.json>       → exit 0 if ADVANCE-eligible vs floors, non-zero otherwise
    ratchet.py why                       → human reason for the last `check` failure
    ratchet.py click <latest.json>       → tighten floors to achieved values (only after ADVANCE)

PARITY (T-RATCHET-6): `check` MUST agree with bash `ratchet_gate` on the metric-vector decision.
The bash gate ALSO short-circuits on verify-fail and noop-diff before the metric vector is even
examined; those are git/verify-level facts the bash side establishes. `check` therefore evaluates
the SAME vector rule the bash side reaches after those two short-circuits:

    (a) no metric crosses its floor in the wrong direction (dir=up: v < floor-tol ; dir=down: v > floor+tol)
    (b) >= 1 non-frozen metric strictly improves vs best.metrics  (up: v>best ; down: v<best)
        else fall to absent_policy (verify_only / tie_breaker), which — given a committed, verified,
        non-noop diff that holds all floors — ADVANCEs.

`check` reads <latest.json> = {"<metric>": number|null, ...} (the harness-measured vector) and
compares it against .ralph/RATCHET.json floors+best. It writes the failure reason to
.ralph/.ratchet_why so `why` can surface it. stdlib only; AUTO: resolvers per §3.1 are provided so
this module can also re-measure if asked, but `check` operates on a pre-measured vector for parity.

stdlib only. No pip deps.
"""

import json
import os
import subprocess
import sys

RALPH_DIR = os.environ.get("RALPH_DIR", ".ralph")
RATCHET_JSON = os.environ.get("RATCHET_JSON", os.path.join(RALPH_DIR, "RATCHET.json"))
WHY_FILE = os.path.join(RALPH_DIR, ".ratchet_why")
EPS = 1e-9


# ---------------------------------------------------------------------------------------------------
# IO helpers
# ---------------------------------------------------------------------------------------------------
def _load_ratchet():
    try:
        with open(RATCHET_JSON, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return {}


def _load_vector(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        if isinstance(data, dict):
            return data
    except Exception:
        pass
    return {}


def _write_why(msg):
    try:
        os.makedirs(RALPH_DIR, exist_ok=True)
        with open(WHY_FILE, "w", encoding="utf-8") as fh:
            fh.write(msg.rstrip("\n") + "\n")
    except Exception:
        pass


def _atomic_write_ratchet(obj):
    tmp = RATCHET_JSON + ".tmp.%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, indent=2)
    # validate it parses before swapping
    with open(tmp, "r", encoding="utf-8") as fh:
        json.load(fh)
    os.replace(tmp, RATCHET_JSON)


def _num(v):
    """Coerce to float or return None (null/non-numeric)."""
    if v is None:
        return None
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, str):
        s = v.strip()
        if s == "" or s.lower() == "null":
            return None
        try:
            return float(s)
        except ValueError:
            return None
    return None


# ---------------------------------------------------------------------------------------------------
# Gate primitives — byte-for-byte mirror of lib/ratchet.sh's metric_crosses_floor /
# metric_strictly_better / absent_policy_better.
# ---------------------------------------------------------------------------------------------------
def metric_crosses_floor(metric, value):
    """True if value crosses the floor in the WRONG direction (a regression)."""
    v = _num(value)
    if v is None:
        return False
    dirn = metric.get("dir", "up")
    floor = _num(metric.get("floor", 0)) or 0.0
    tol = _num(metric.get("tolerance", 0)) or 0.0
    if dirn == "down":
        return v > (floor + tol)
    return v < (floor - tol)


def metric_strictly_better(metric, value, best_value):
    """True if value beats best_value. Floor of comparison is ALWAYS best.metrics (§5.2)."""
    v = _num(value)
    if v is None:
        return False
    b = _num(best_value)
    if b is None:
        return True  # no prior best ⇒ any real number is an improvement
    dirn = metric.get("dir", "up")
    if dirn == "down":
        return v < b
    return v > b


def absent_policy_advances(ratchet):
    """When no metric strictly improves: verify_only and tie_breaker both ADVANCE a committed,
    verified, non-noop, floor-holding candidate (the verify/noop facts are the bash side's job)."""
    policy = ratchet.get("policy", {}).get("absent_policy", "verify_only")
    # Both 'verify_only' and 'tie_breaker' resolve to "accept the floor-holding committed candidate"
    # at the point `check` is reached (verify already passed upstream).
    return policy in ("verify_only", "tie_breaker")


def evaluate(ratchet, vector):
    """Mirror of ratchet_gate's METRIC-VECTOR phase. Returns (decision, cause).
    decision ∈ {"ADVANCE","REVERT"}; cause is a reason string ("" on ADVANCE)."""
    metrics = ratchet.get("metrics", {}) or {}
    best = (ratchet.get("best", {}) or {}).get("metrics", {}) or {}
    improved = False
    for key in sorted(metrics.keys()):
        m = metrics[key]
        v = vector.get(key, None)
        if _num(v) is None:
            continue  # absent metric → absent_policy below
        if metric_crosses_floor(m, v):
            return ("REVERT", "regression:%s:floor=%s:got=%s" % (key, m.get("floor"), v))
        if not m.get("frozen", False) and metric_strictly_better(m, v, best.get(key)):
            improved = True
    if improved:
        return ("ADVANCE", "")
    if absent_policy_advances(ratchet):
        return ("ADVANCE", "")
    return ("REVERT", "not_strictly_better")


# ---------------------------------------------------------------------------------------------------
# AUTO: metric resolvers (§3.1) — provided for symmetry with lib/ratchet.sh::resolve_metric_cmd.
# `check` does NOT call these (it consumes a pre-measured vector for parity); they exist so this
# module can re-measure for `ralph once`/CI glue when handed a metric key instead of a vector.
# ---------------------------------------------------------------------------------------------------
AUTO_RESOLVERS = {
    "AUTO:pytest_passcount":
        "python3 -m pytest -q --no-header 2>/dev/null | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' | tail -1",
    "AUTO:jest_passcount":
        "npx --no-install jest --silent 2>&1 | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' | tail -1",
    "AUTO:cargo_passcount":
        "cargo test --quiet 2>&1 | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' | tail -1",
    "AUTO:go_passcount":
        "go test ./... 2>&1 | grep -cE '^(ok|--- PASS)'",
    "AUTO:coverage":
        "python3 -m coverage report 2>/dev/null | awk '/^TOTAL/{gsub(/%/,\"\",$NF); print $NF}' | tail -1",
    "AUTO:lint":
        "ruff check . 2>/dev/null | grep -cE 'Found|error|^[^ ]+:[0-9]+:[0-9]+' || true",
}


def resolve_metric_cmd(ratchet, key):
    # SECURITY (RCE): take the EXECUTED command from the operator-canonical snapshot, never from the
    # agent-writable RATCHET.json. Fall back to the live file only when no canonical exists.
    cmd = ""
    _cano = os.path.join(RALPH_DIR, ".canonical", "RATCHET.cmds.json")
    if os.path.exists(_cano):
        try:
            with open(_cano, "r", encoding="utf-8") as _fh:
                cmd = ((json.load(_fh).get("metrics", {}) or {}).get(key, "")) or ""
        except Exception:
            cmd = ""
    if not cmd:
        cmd = (ratchet.get("metrics", {}).get(key, {}) or {}).get("cmd", "") or ""
    if cmd in AUTO_RESOLVERS:
        return AUTO_RESOLVERS[cmd]
    if cmd.startswith("AUTO"):
        return "true"
    if cmd == "":
        return "true"
    return cmd


def measure_one(ratchet, key):
    """Run the resolver for one metric, return float or None. (Glue convenience, not used by check.)"""
    cmd = resolve_metric_cmd(ratchet, key)
    try:
        out = subprocess.run(["sh", "-c", cmd], capture_output=True, text=True, timeout=900).stdout
    except Exception:
        return None
    last = ""
    for line in out.splitlines():
        if line.strip():
            last = line.strip()
    return _num(last.split()[-1]) if last else None


# ---------------------------------------------------------------------------------------------------
# Verbs
# ---------------------------------------------------------------------------------------------------
def verb_render_table():
    """markdown table of metrics for {{RATCHET_TABLE}}: metric | dir | floor | frozen."""
    ratchet = _load_ratchet()
    metrics = ratchet.get("metrics", {}) or {}
    lines = ["| metric | dir | floor | frozen |", "|---|---|---|---|"]
    for key in sorted(metrics.keys()):
        m = metrics[key]
        floor = m.get("floor", 0)
        # render integer floors without a trailing .0
        if isinstance(floor, float) and floor.is_integer():
            floor = int(floor)
        lines.append("| %s | %s | %s | %s |" % (
            key, m.get("dir", "up"), floor, str(m.get("frozen", False)).lower()))
    sys.stdout.write("\n".join(lines) + "\n")
    return 0


def verb_check(vector_path):
    """exit 0 if ADVANCE-eligible vs floors, non-zero otherwise (mirrors §5.2 vector phase)."""
    ratchet = _load_ratchet()
    if not ratchet.get("metrics"):
        _write_why("no metrics defined in RATCHET.json")
        sys.stdout.write("ADVANCE: no metrics defined (absent_policy)\n")
        return 0
    vector = _load_vector(vector_path)
    decision, cause = evaluate(ratchet, vector)
    if decision == "ADVANCE":
        _write_why("")
        sys.stdout.write("ADVANCE\n")
        return 0
    _write_why(cause)
    sys.stdout.write("REVERT: %s\n" % cause)
    return 1


def verb_why():
    """human reason for the last check failure (for VERDICT/LEDGER)."""
    try:
        with open(WHY_FILE, "r", encoding="utf-8") as fh:
            txt = fh.read().strip()
    except Exception:
        txt = ""
    sys.stdout.write((txt if txt else "no recorded check failure") + "\n")
    return 0


def verb_click(vector_path):
    """tighten floors to achieved values (called only after ADVANCE; one-way, INV-2)."""
    ratchet = _load_ratchet()
    metrics = ratchet.get("metrics", {}) or {}
    vector = _load_vector(vector_path)
    changed = False
    for key in sorted(metrics.keys()):
        v = _num(vector.get(key, None))
        if v is None:
            continue
        m = metrics[key]
        dirn = m.get("dir", "up")
        cur = _num(m.get("floor", 0)) or 0.0
        if dirn == "down":
            new = v if v < cur else cur     # only tighten the cap downward
        else:
            new = v if v > cur else cur     # only raise the floor upward
        if abs(new - cur) > EPS:
            # preserve int-ness when the value is whole
            m["floor"] = int(new) if float(new).is_integer() else new
            changed = True
    if changed:
        ratchet["metrics"] = metrics
        try:
            _atomic_write_ratchet(ratchet)
        except Exception as exc:  # never crash the loop
            sys.stderr.write("ratchet.py click: write failed: %s\n" % exc)
            return 1
    sys.stdout.write("clicked\n")
    return 0


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: ratchet.py render-table | check <latest.json> | why | click <latest.json>\n")
        return 2
    verb = argv[1]
    if verb == "render-table":
        return verb_render_table()
    if verb == "check":
        if len(argv) < 3:
            sys.stderr.write("ratchet.py check needs <latest.json>\n")
            return 2
        return verb_check(argv[2])
    if verb == "why":
        return verb_why()
    if verb == "click":
        if len(argv) < 3:
            sys.stderr.write("ratchet.py click needs <latest.json>\n")
            return 2
        return verb_click(argv[2])
    sys.stderr.write("unknown verb: %s\n" % verb)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
