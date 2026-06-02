# Ralph test harness (SPEC §11)

These tests prove the invariants INV-1..INV-9 **without burning AI credits**:
all unit tests drive a **stub `agy`** (`tests/stub_agy.sh`) that prints a canned
transcript from `tests/fixtures/` and exits a chosen code. Only the opt-in
`smoke_live.sh` touches the real `agy`.

## Requirements

- **bats-core** is required for the unit suite (`*.bats`). It is not bundled.

  ```sh
  brew install bats-core
  # or vendor it (run.sh auto-discovers this path):
  git clone --depth 1 https://github.com/bats-core/bats-core tests/vendor/bats-core
  ```

- `jq`, `python3` (3.14), `/usr/bin/perl` — all present on the target macOS box.
- **No** `timeout`/`gtimeout`/`flock` are used (none exist here); bounded
  execution is the spec's `lib/bounded.sh::bounded_run` perl-watchdog.

> macOS `/bin/bash` is **3.2** (no `declare -A`, no `local -n`). Every script in
> `tests/` is written to bash 3.2. The *code under test* solves the associative-
> array need internally (`lib/state.py`, jq, temp JSON); the tests only call the
> public contracts, so they run under 3.2 fine. bats itself runs the `.bats`
> bodies under its own bash.

## Running

```sh
tests/run.sh                 # all *.bats (auto-finds bats; soft-skips if absent)
tests/run.sh ratchet.bats    # a subset
BATS=/path/to/bats tests/run.sh
```

`run.sh` **degrades gracefully**: with no bats it prints install guidance and
runs a couple of stdlib-only sanity checks instead of hard-failing.

### Live smoke (costs AI credits — opt in)

```sh
RALPH_SMOKE_LIVE=1 tests/smoke_live.sh
```

Requires Antigravity running/authenticated. The whole script is wrapped in
`bounded_run 900` so it can never hang CI. Without `RALPH_SMOKE_LIVE=1` it soft-
skips (exit 0). Set `RALPH_SMOKE_STRICT=1` to turn skips into failures.

## Layout

| File | Asserts (IDs) |
|---|---|
| `ratchet.bats`    | T-RATCHET-1..6, T-NOOP (INV-1, INV-2, INV-3) |
| `state.bats`      | T-STATE-1..4 (INV-4), atomic writes, lock steal |
| `trailer.bats`    | T-TRAILER-* salvage ladder (§3.4.2) |
| `classify.bats`   | T-CLASSIFY-* exit-code/output oracle (silent-zombie) |
| `bounded.bats`    | T-BOUND-1 (INV-7) group-kill watchdog |
| `supervisor.bats` | T-SUP-1..4 (INV-5, INV-6, INV-8) — bounded, max-iterations |
| `safety.bats`     | T-SAFE-1 (INV-9), T-SAFE-2 protected-file restore |

### Shared pieces

- `tests/test_helper.bash` — every `.bats` does `load test_helper`. Resolves repo
  paths, sources the **real** `lib/*.sh`, installs the stub `agy`, and provides
  `require_lib` / `require_pylib` / `require_fn` / `require_cmd` that **`skip`**
  (not error) when a peer group's file/function isn't merged yet. The suite is
  therefore runnable incrementally during integration.
- `tests/stub_agy.sh` — the fake `agy` + `install_stub_agy <bindir>` helper.
  Env-driven: `STUB_AGY_FIXTURE`, `STUB_AGY_EXIT`, `STUB_AGY_COMMIT=1`
  (create+commit a change), `STUB_AGY_WRITE_ONLY=1`, `STUB_AGY_DELAY_S`,
  `STUB_AGY_COMMIT_FILE/BODY/MSG`, `STUB_AGY_LOG`.
- `tests/fixtures/setup.sh` — `make_python_repo` / `seed_ralph` / metric-mutators
  that build a **real** pytest git repo so measurements are genuine.
- `tests/fixtures/*.txt` — canned transcripts: `good_handoff`,
  `claimed_gt_measured`, `verify_fail`, `noop`, `quota`, `print_timeout`,
  `fatal_misconfig`, `goals_done_handoff`, `edit_mission`, and the trailer-
  salvage cases (`trailer_missing`, `trailer_bare_json`, `trailer_multiple`,
  `trailer_code_fenced`, `trailer_trailing_comma`, `trailer_single_quote`,
  `trailer_python_literal`, `trailer_truncated`).

## Contracts the tests depend on (must match the merged `lib/`)

The tests call ONLY public names from the SPEC:

- `lib/extract_trailer.py <stdin-file> <out.json>` — always exit 0; prints
  `TRAILER_STATUS=<ok|missing|multiple|...>`; writes a coerced object.
- `lib/validate_trailer.py <trailer.json>` — coerce/clamp in place; exit 0.
- `lib/state.py get|get-raw|set|set-num|bump|init|merge|validate <file> ...`.
- `lib/classify.sh::classify_result <rc> <transcript-file>` → class word.
- `lib/bounded.sh::bounded_run <secs> <log> -- cmd...` → rc, or 124 on kill.
- `lib/state.sh::acquire_lock_or_exit` / `heartbeat`.
- `lib/ratchet.sh::run_one_iteration` / `ratchet_gate` / `revert_to_baseline`
  (and, if exposed, `restore_protected_files`).
- `lib/ratchet.py check <latest.json> [--ratchet <RATCHET.json>]` /
  `render-table` / `why` / `click`.
- `lib/gate.sh::guard_no_push`.

If a peer file lands with a slightly different flag surface (e.g. `ratchet.py
check` taking the RATCHET path positionally rather than via `--ratchet`), the
affected test `skip`s with a clear message rather than producing a false
failure — adjust the one `run` line to the merged surface.
