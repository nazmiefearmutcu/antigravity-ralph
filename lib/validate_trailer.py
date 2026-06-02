#!/usr/bin/env python3
"""lib/validate_trailer.py — HANDOFF trailer schema coerce/clamp (SPEC §3.4.1).

Role: take a trailer.json (as produced by extract_trailer.py, or any near-shaped JSON)
and normalize it IN PLACE to the canonical schema: fill missing keys with
null/[]/false, clamp `confidence` to [0,1], truncate `what_changed` to <=500 chars,
coerce `files` to a string array, coerce `metrics_after` to object<string,number|null>.

Per SPEC §5.1 STEP T this runs right after extract_trailer.py:
    python3 lib/extract_trailer.py "$ITDIR/agy.stdout" "$ITDIR/trailer.json"
    python3 lib/validate_trailer.py "$ITDIR/trailer.json"

Idempotent: validating an already-validated file is a no-op-shaped rewrite.

`metrics_after` is ADVISORY ONLY — the ratchet gate never reads it (INV-3). It is
preserved here purely for the integrity audit (record_claim_vs_truth) and to flavor
regression advice.

Always exits 0. Pure stdlib. Importable: from validate_trailer import validate, coerce_schema.

Usage:
    python3 lib/validate_trailer.py <trailer.json>
"""

import json
import os
import sys

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


def _clamp_confidence(value):
    if isinstance(value, bool):
        return 0.0
    if isinstance(value, (int, float)):
        return max(0.0, min(1.0, float(value)))
    try:
        return max(0.0, min(1.0, float(value)))
    except (TypeError, ValueError):
        return 0.0


def _coerce_files(value):
    if isinstance(value, list):
        return [str(f) for f in value]
    if isinstance(value, str) and value:
        return [value]
    return []


def _coerce_metrics_after(value):
    """object<string,number|null> or null. Non-numeric values become null."""
    if not isinstance(value, dict):
        return None
    clean = {}
    for k, v in value.items():
        key = str(k)
        if v is None:
            clean[key] = None
        elif isinstance(v, bool):
            # booleans are not metric numbers
            clean[key] = None
        elif isinstance(v, (int, float)):
            clean[key] = v
        else:
            try:
                sv = str(v)
                clean[key] = float(sv) if ("." in sv or "e" in sv.lower()) else int(sv)
            except (TypeError, ValueError):
                clean[key] = None
    return clean


def coerce_schema(obj):
    """Return a canonical, fully-populated trailer dict from any input object."""
    out = dict(SCHEMA_DEFAULTS)
    if not isinstance(obj, dict):
        obj = {}

    wc = obj.get("what_changed")
    if isinstance(wc, str):
        out["what_changed"] = wc[:WHAT_CHANGED_MAX]
    elif wc is not None:
        out["what_changed"] = str(wc)[:WHAT_CHANGED_MAX]

    out["files"] = _coerce_files(obj.get("files"))

    tier = obj.get("tier")
    if isinstance(tier, str):
        out["tier"] = tier
    elif tier is not None:
        out["tier"] = str(tier)

    out["metrics_after"] = _coerce_metrics_after(obj.get("metrics_after"))

    nc = obj.get("next_candidate")
    if isinstance(nc, str):
        out["next_candidate"] = nc
    elif nc is not None:
        out["next_candidate"] = str(nc)

    idn = obj.get("i_did_NOT")
    if isinstance(idn, str):
        out["i_did_NOT"] = idn
    elif idn is not None:
        out["i_did_NOT"] = str(idn)

    out["confidence"] = _clamp_confidence(obj.get("confidence"))

    out["done_with_explicit_goals"] = obj.get("done_with_explicit_goals") is True

    return out


def validate(path):
    """Read, coerce, and atomically rewrite the trailer file at `path`.

    Returns the coerced dict. Never raises; on a totally unreadable/corrupt file it
    writes a default-shaped object so downstream consumers always find valid JSON.
    """
    obj = None
    try:
        if os.path.exists(path):
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                obj = json.load(fh)
    except Exception:
        obj = None

    coerced = coerce_schema(obj if isinstance(obj, dict) else {})

    try:
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(coerced, fh, indent=2)
        os.replace(tmp, path)
    except Exception:
        try:
            with open(path, "w", encoding="utf-8") as fh:
                json.dump(coerced, fh, indent=2)
        except Exception:
            pass

    return coerced


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: validate_trailer.py <trailer.json>\n")
        return 0
    validate(argv[1])
    return 0


if __name__ == "__main__":
    try:
        main(sys.argv)
    except Exception:
        pass
    sys.exit(0)
