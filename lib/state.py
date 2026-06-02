#!/usr/bin/env python3
# lib/state.py — atomic read/modify/write helper for JSON state files (SPEC §3.5, §6.2).
#
# Role: the trusted, crash-safe mutator for .ralph/state.json and .ralph/RATCHET.json
# (and any other .ralph/*.json). Implements the "tmp + validate-parse + atomic rename"
# contract from SPEC §6.2 so a crash mid-write can never corrupt the live file. Used by
# lib/state.sh (set_state/bump/persist_*) and by lib/ratchet.py for RATCHET.json clicks.
#
# This is stdlib-only (no pip deps), targets python3.14, and ALWAYS exits 0 for the
# read/query verbs that the loop body depends on never aborting; mutate verbs exit
# non-zero only on truly unrecoverable IO/usage errors so a caller can detect failure,
# but they NEVER leave a half-written live file (writes go tmp->fsync->rename).
#
# CLI contract (stable; called by name from lib/state.sh):
#
#   state.py get      <file> <dotted.key> [default]
#       Print the value at dotted.key (JSON-encoded if non-scalar, raw if scalar string).
#       Missing key -> print `default` (or empty string) and still exit 0.
#
#   state.py get-raw  <file> <dotted.key> [default]
#       Like get, but scalars are printed without JSON quoting (numbers/strings bare).
#
#   state.py set      <file> <dotted.key> <value>
#       Set dotted.key = value. `value` is parsed as JSON if it parses, else kept as a
#       string. Creates intermediate objects as needed. Atomic write.
#
#   state.py set-str  <file> <dotted.key> <value>
#       Force string assignment (never JSON-coerce). Atomic write.
#
#   state.py set-num  <file> <dotted.key> <value>
#       Force numeric assignment (int if integral, else float). Atomic write.
#
#   state.py bump     <file> <dotted.key> [delta]
#       Numeric increment (delta default 1; may be negative). Missing/non-numeric -> 0
#       base. Prints the new value. Atomic write.
#
#   state.py init     <file> <json-literal>
#       Create <file> with the given JSON object ONLY if it does not already exist or is
#       unparseable. Prints "created" or "kept". Atomic write when creating.
#
#   state.py merge    <file> <json-literal>
#       Shallow-merge the given JSON object into the top-level object (existing keys
#       overwritten by provided keys). Creates the file if absent. Atomic write.
#
#   state.py validate <file>
#       Exit 0 iff <file> parses as JSON; non-zero otherwise. Prints nothing.
#
# Dotted keys address nested objects: "best.metrics.tests_pass". List indices are not
# supported (state schemas here are object-only).

import json
import os
import sys
import tempfile


def _die_usage(msg):
    sys.stderr.write("state.py: " + msg + "\n")
    sys.exit(2)


def _load(path):
    """Return (obj, ok). ok=False if file missing or unparseable."""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh), True
    except FileNotFoundError:
        return {}, False
    except (ValueError, OSError):
        return {}, False


def _atomic_write(path, obj):
    """tmp + validate-parse + fsync + atomic rename, all within the same dir (SPEC §6.2)."""
    data = json.dumps(obj, ensure_ascii=False, indent=2, sort_keys=False)
    # Validate it parses before we touch the live file.
    json.loads(data)
    d = os.path.dirname(os.path.abspath(path)) or "."
    try:
        os.makedirs(d, exist_ok=True)
    except OSError:
        pass
    fd, tmp = tempfile.mkstemp(prefix=".state.", suffix=".tmp", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)  # atomic rename within the same filesystem
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _split_key(dotted):
    parts = [p for p in dotted.split(".") if p != ""]
    if not parts:
        _die_usage("empty dotted key")
    return parts


def _get(obj, parts):
    cur = obj
    for p in parts:
        if isinstance(cur, dict) and p in cur:
            cur = cur[p]
        else:
            return None, False
    return cur, True


def _set(obj, parts, value):
    if not isinstance(obj, dict):
        obj = {}
    cur = obj
    for p in parts[:-1]:
        nxt = cur.get(p)
        if not isinstance(nxt, dict):
            nxt = {}
            cur[p] = nxt
        cur = nxt
    cur[parts[-1]] = value
    return obj


def _coerce_json_or_str(s):
    try:
        return json.loads(s)
    except ValueError:
        return s


def _coerce_num(s):
    try:
        f = float(s)
    except ValueError:
        _die_usage("not a number: " + repr(s))
    if f.is_integer():
        return int(f)
    return f


def _print_scalar(v, raw):
    if v is None:
        print("" if raw else "null")
        return
    if isinstance(v, bool):
        print("true" if v else "false")
        return
    if isinstance(v, (int, float, str)):
        if raw or isinstance(v, str):
            print(v)
        else:
            print(json.dumps(v))
        return
    # objects/arrays always JSON-encoded
    print(json.dumps(v, ensure_ascii=False))


def cmd_get(args, raw):
    if len(args) < 2:
        _die_usage("get <file> <dotted.key> [default]")
    path, dotted = args[0], args[1]
    default = args[2] if len(args) >= 3 else ""
    obj, _ok = _load(path)
    val, found = _get(obj, _split_key(dotted))
    if not found:
        print(default)
        return 0
    _print_scalar(val, raw)
    return 0


def cmd_set(args, mode):
    if len(args) < 3:
        _die_usage("set <file> <dotted.key> <value>")
    path, dotted, raw_value = args[0], args[1], args[2]
    if mode == "auto":
        value = _coerce_json_or_str(raw_value)
    elif mode == "str":
        value = raw_value
    elif mode == "num":
        value = _coerce_num(raw_value)
    else:
        _die_usage("internal: bad set mode")
    obj, _ok = _load(path)
    obj = _set(obj, _split_key(dotted), value)
    _atomic_write(path, obj)
    return 0


def cmd_bump(args):
    if len(args) < 2:
        _die_usage("bump <file> <dotted.key> [delta]")
    path, dotted = args[0], args[1]
    delta = _coerce_num(args[2]) if len(args) >= 3 else 1
    obj, _ok = _load(path)
    parts = _split_key(dotted)
    cur, found = _get(obj, parts)
    base = 0
    if found and isinstance(cur, (int, float)) and not isinstance(cur, bool):
        base = cur
    new = base + delta
    if isinstance(new, float) and new.is_integer():
        new = int(new)
    obj = _set(obj, parts, new)
    _atomic_write(path, obj)
    print(new)
    return 0


def cmd_init(args):
    if len(args) < 2:
        _die_usage("init <file> <json-literal>")
    path, literal = args[0], args[1]
    _obj, ok = _load(path)
    if ok:
        print("kept")
        return 0
    try:
        seed = json.loads(literal)
    except ValueError as e:
        _die_usage("init literal not JSON: " + str(e))
    _atomic_write(path, seed)
    print("created")
    return 0


def cmd_merge(args):
    if len(args) < 2:
        _die_usage("merge <file> <json-literal>")
    path, literal = args[0], args[1]
    try:
        patch = json.loads(literal)
    except ValueError as e:
        _die_usage("merge literal not JSON: " + str(e))
    if not isinstance(patch, dict):
        _die_usage("merge literal must be a JSON object")
    obj, _ok = _load(path)
    if not isinstance(obj, dict):
        obj = {}
    for k, v in patch.items():
        obj[k] = v
    _atomic_write(path, obj)
    return 0


def cmd_validate(args):
    if len(args) < 1:
        _die_usage("validate <file>")
    _obj, ok = _load(args[0])
    return 0 if ok else 1


def main(argv):
    if len(argv) < 2:
        _die_usage("usage: state.py <verb> <file> ...")
    verb = argv[1]
    args = argv[2:]
    if verb == "get":
        return cmd_get(args, raw=False)
    if verb == "get-raw":
        return cmd_get(args, raw=True)
    if verb == "set":
        return cmd_set(args, "auto")
    if verb == "set-str":
        return cmd_set(args, "str")
    if verb == "set-num":
        return cmd_set(args, "num")
    if verb == "bump":
        return cmd_bump(args)
    if verb == "init":
        return cmd_init(args)
    if verb == "merge":
        return cmd_merge(args)
    if verb == "validate":
        return cmd_validate(args)
    _die_usage("unknown verb: " + verb)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
