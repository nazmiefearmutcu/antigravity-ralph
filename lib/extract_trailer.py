#!/usr/bin/env python3
"""lib/extract_trailer.py — robust HANDOFF trailer salvage ladder (SPEC §3.4.2).

Role: extract the agent's `<<<RALPH_HANDOFF ... RALPH_HANDOFF>>>` JSON trailer from a raw
agy stdout transcript, salvaging through malformed/fenced/truncated/Python-literal variants,
and ALWAYS exit 0. Conveys outcome via a single stdout line `TRAILER_STATUS=<status>` and by
writing the coerced object to the output file.

Usage:
    python3 lib/extract_trailer.py <agy.stdout> <out.trailer.json>

This module is the front of the two-step contract:
    extract_trailer.py  (this file, salvage)  →  validate_trailer.py (schema coerce/clamp)
It already runs coerce_schema() itself so the written file is always schema-shaped; running
validate_trailer.py afterward (as §5.1 STEP T does) is idempotent/defensive.

Pure stdlib. Importable: from extract_trailer import extract_trailer, salvage_json, coerce_schema.

Statuses emitted (TRAILER_STATUS=...):
    ok        — clean fence + parseable JSON
    salvaged  — fence/bare JSON recovered only after salvage_json() repairs
    multiple  — more than one fence present; took the LAST
    bare      — no fence; recovered the last balanced {...} object in the text
    missing   — nothing usable; synthesized from harness git facts
"""

import json
import os
import re
import subprocess
import sys

FENCE_RE = re.compile(r"<<<RALPH_HANDOFF(.*?)RALPH_HANDOFF>>>", re.DOTALL)

# Schema defaults — kept consistent with SPEC §3.4.1 and validate_trailer.py.
SCHEMA_DEFAULTS = {
    "what_changed": "",
    "files": [],
    "tier": "",
    "metrics_after": None,
    "next_candidate": "",
    "i_did_NOT": "",
    "confidence": 0.0,
    "done_with_explicit_goals": False,
}

WHAT_CHANGED_MAX = 500


# ───────────────────────────────────────── balanced-object scan ──

def _find_balanced_objects(text):
    """Return all top-level balanced {...} substrings in textual order.

    Brace counting is string-aware (ignores braces inside JSON string literals,
    honoring backslash escapes) so prose containing stray braces does not corrupt
    the scan.
    """
    objects = []
    depth = 0
    start = -1
    in_str = False
    esc = False
    quote = ""
    for i, ch in enumerate(text):
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == quote:
                in_str = False
            continue
        if ch in ('"', "'"):
            in_str = True
            quote = ch
            continue
        if ch == "{":
            if depth == 0:
                start = i
            depth += 1
        elif ch == "}":
            if depth > 0:
                depth -= 1
                if depth == 0 and start >= 0:
                    objects.append(text[start : i + 1])
                    start = -1
    return objects


# ───────────────────────────────────────────────── json salvage ──

def salvage_json(blob):
    """Best-effort repair of a near-JSON blob → python object, or raise.

    Handles (SPEC §3.4.2 step 5): markdown ```json fences, trailing commas,
    single→double quotes, Python literals True/False/None, smart quotes,
    leading/trailing prose, and unbalanced closing braces.
    """
    s = blob.strip()

    # Strip a leading ```json / ``` fence and any trailing ``` fence.
    s = re.sub(r"^\s*```[a-zA-Z0-9_-]*\s*", "", s)
    s = re.sub(r"\s*```\s*$", "", s)
    s = s.strip()

    # Prose-strip: narrow to the last balanced {...} if there is leading/trailing chatter.
    objs = _find_balanced_objects(s)
    if objs:
        s = objs[-1]
    else:
        # Unbalanced: take from the first '{' onward and try to close it below.
        brace = s.find("{")
        if brace > 0:
            s = s[brace:]

    # Try as-is first (maybe it was only prose-wrapped).
    try:
        return json.loads(s)
    except Exception:
        pass

    repaired = s

    # Smart quotes → ASCII.
    smart = {
        "“": '"', "”": '"', "„": '"', "‟": '"',
        "‘": "'", "’": "'", "‚": "'", "‛": "'",
    }
    for bad, good in smart.items():
        repaired = repaired.replace(bad, good)

    # Python literals → JSON literals (word-boundary; avoids touching substrings).
    repaired = re.sub(r"\bTrue\b", "true", repaired)
    repaired = re.sub(r"\bFalse\b", "false", repaired)
    repaired = re.sub(r"\bNone\b", "null", repaired)

    # Single-quoted strings/keys → double-quoted. Only convert single quotes that
    # are not already inside a double-quoted string. Do a guarded global swap of
    # ' → " when no double quotes are present at all, else a key/value-targeted swap.
    if '"' not in repaired:
        repaired = repaired.replace("'", '"')
    else:
        # Convert 'key': and : 'value' style single quotes around tokens.
        repaired = re.sub(r"'([^'\"]*)'", r'"\1"', repaired)

    # Remove trailing commas before } or ].
    repaired = re.sub(r",\s*([}\]])", r"\1", repaired)

    # Close any unbalanced brackets/braces in the correct (reverse-nesting) order.
    # Truncated trailers commonly look like  { "files": ["c.py"  — we must close
    # the inner ] before the outer }, which a naive count-and-append cannot do.
    repaired = _close_unbalanced(repaired)

    return json.loads(repaired)


def _close_unbalanced(s):
    """Append the closers needed to balance a truncated JSON object/array.

    Walks the string string-aware, builds the stack of currently-open
    {/[ delimiters, strips any dangling trailing comma or colon, then appends
    the matching closers in reverse order (inner first).
    """
    stack = []
    in_str = False
    esc = False
    quote = ""
    for ch in s:
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == quote:
                in_str = False
            continue
        if ch in ('"', "'"):
            in_str = True
            quote = ch
        elif ch in "{[":
            stack.append(ch)
        elif ch == "}":
            if stack and stack[-1] == "{":
                stack.pop()
        elif ch == "]":
            if stack and stack[-1] == "[":
                stack.pop()

    out = s
    # If the trailer was cut mid-string, close the open string literal first.
    if in_str:
        out = out + quote
    # Drop a dangling comma/colon that would otherwise precede the closers.
    out = re.sub(r"[,:]\s*$", "", out)
    closers = "".join("}" if c == "{" else "]" for c in reversed(stack))
    return out + closers


# ──────────────────────────────────────────── schema coercion ──

def coerce_schema(obj):
    """Fill missing keys, drop bad types, clamp confidence, truncate what_changed.

    Mirrors validate_trailer.py so a freshly-extracted file is already schema-shaped.
    """
    out = dict(SCHEMA_DEFAULTS)
    if not isinstance(obj, dict):
        obj = {}

    if isinstance(obj.get("what_changed"), str):
        out["what_changed"] = obj["what_changed"][:WHAT_CHANGED_MAX]

    files = obj.get("files")
    if isinstance(files, list):
        out["files"] = [str(f) for f in files]
    elif isinstance(files, str) and files:
        out["files"] = [files]

    if isinstance(obj.get("tier"), str):
        out["tier"] = obj["tier"]

    ma = obj.get("metrics_after")
    if isinstance(ma, dict):
        clean = {}
        for k, v in ma.items():
            if v is None or isinstance(v, bool):
                clean[str(k)] = None if v is None else v
            elif isinstance(v, (int, float)):
                clean[str(k)] = v
            else:
                # numeric-looking strings → number, else null
                try:
                    clean[str(k)] = float(v) if ("." in str(v) or "e" in str(v).lower()) else int(v)
                except (TypeError, ValueError):
                    clean[str(k)] = None
        out["metrics_after"] = clean
    else:
        out["metrics_after"] = None

    if isinstance(obj.get("next_candidate"), str):
        out["next_candidate"] = obj["next_candidate"]

    if isinstance(obj.get("i_did_NOT"), str):
        out["i_did_NOT"] = obj["i_did_NOT"]

    conf = obj.get("confidence")
    if isinstance(conf, bool):
        conf = None
    if isinstance(conf, (int, float)):
        out["confidence"] = max(0.0, min(1.0, float(conf)))
    else:
        try:
            out["confidence"] = max(0.0, min(1.0, float(conf)))
        except (TypeError, ValueError):
            out["confidence"] = 0.0

    dwg = obj.get("done_with_explicit_goals")
    out["done_with_explicit_goals"] = dwg is True

    return out


# ──────────────────────────────────────── harness-fact synthesis ──

def _git_diff_stat():
    try:
        return subprocess.run(
            ["git", "diff", "--stat", "HEAD"],
            capture_output=True, text=True, timeout=30,
        ).stdout.strip()
    except Exception:
        return ""


def _git_changed_paths():
    paths = []
    try:
        out = subprocess.run(
            ["git", "status", "--porcelain"],
            capture_output=True, text=True, timeout=30,
        ).stdout
        for line in out.splitlines():
            line = line.rstrip()
            if len(line) > 3:
                paths.append(line[3:].strip())
    except Exception:
        pass
    return paths


def _synthesize(current_tier=""):
    """Step 3: nothing usable — synthesize from harness git facts."""
    diffstat = _git_diff_stat()
    obj = {
        "what_changed": diffstat or "(no trailer; synthesized from harness facts)",
        "files": _git_changed_paths(),
        "metrics_after": None,
        "next_candidate": "",
        "tier": current_tier,
        "confidence": 0.0,
        "done_with_explicit_goals": False,
    }
    return coerce_schema(obj)


# ───────────────────────────────────────────────── salvage ladder ──

def extract_trailer(text, current_tier=""):
    """Run the §3.4.2 salvage ladder. Returns (coerced_obj, status)."""
    if text is None:
        text = ""

    # 1. fenced matches
    fences = FENCE_RE.findall(text)

    if fences:
        # 4. multiple fences → take the LAST (agents self-correct at the end).
        #    The "multiple" signal dominates over "salvaged" so the integrity
        #    audit still sees that the agent emitted more than one fence.
        multi = len(fences) > 1
        body = fences[-1]
        try:
            obj = json.loads(body)
            return coerce_schema(obj), ("multiple" if multi else "ok")
        except Exception:
            try:
                obj = salvage_json(body)
                return coerce_schema(obj), ("multiple" if multi else "salvaged")
            except Exception:
                # fenced but irreparable — fall through to bare-JSON scan
                pass

    # 2. bare-JSON fallback: last balanced {...} object in the whole text.
    objs = _find_balanced_objects(text)
    for blob in reversed(objs):
        try:
            obj = json.loads(blob)
            return coerce_schema(obj), "bare"
        except Exception:
            try:
                obj = salvage_json(blob)
                return coerce_schema(obj), "salvaged"
            except Exception:
                continue

    # 3. nothing usable → synthesize from harness facts.
    return _synthesize(current_tier), "missing"


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(
            "usage: extract_trailer.py <agy.stdout> <out.trailer.json> [current_tier]\n"
        )
        # Still write a synthesized file + status so the loop never aborts.
        out_path = argv[2] if len(argv) >= 3 else "trailer.json"
        try:
            obj = _synthesize("")
            with open(out_path, "w", encoding="utf-8") as fh:
                json.dump(obj, fh, indent=2)
        except Exception:
            pass
        print("TRAILER_STATUS=missing")
        return 0

    in_path = argv[1]
    out_path = argv[2]
    current_tier = argv[3] if len(argv) >= 4 else ""

    text = ""
    try:
        if os.path.exists(in_path):
            with open(in_path, "r", encoding="utf-8", errors="replace") as fh:
                text = fh.read()
    except Exception:
        text = ""

    try:
        obj, status = extract_trailer(text, current_tier)
    except Exception:
        # Absolute backstop: never let an unexpected error abort the loop.
        obj, status = _synthesize(current_tier), "missing"

    try:
        tmp = out_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(obj, fh, indent=2)
        os.replace(tmp, out_path)
    except Exception:
        # Best-effort direct write if atomic replace failed.
        try:
            with open(out_path, "w", encoding="utf-8") as fh:
                json.dump(obj, fh, indent=2)
        except Exception:
            pass

    print("TRAILER_STATUS=" + status)
    return 0


if __name__ == "__main__":
    # ALWAYS exit 0 (SPEC §3.4.2): the loop must never be aborted by extraction.
    try:
        main(sys.argv)
    except Exception:
        try:
            print("TRAILER_STATUS=missing")
        except Exception:
            pass
    sys.exit(0)
