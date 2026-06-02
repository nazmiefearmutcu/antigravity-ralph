# Technical Grounding — Antigravity control surfaces (verified 2026-06-02)

Everything below was **empirically verified** on this machine (macOS, Antigravity IDE 2.0.10,
`agy` CLI 1.0.3). Treat as the source of truth for how the Ralph loop drives Antigravity.

## 1. `agy` — Antigravity headless agent CLI  ← PRIMARY DRIVER

Path: `/Users/nazmi/.local/bin/agy` (Mach-O arm64, v1.0.3). On PATH.

```
agy -p "<prompt>"                 # --print: run ONE prompt non-interactively, print response to stdout
agy --prompt "<p>" / --print      # aliases of -p
agy -i "<p>" / --prompt-interactive
agy -c / --continue               # continue the most recent conversation
agy --conversation <id>           # resume a conversation by id
agy --add-dir <dir>               # add a directory to the workspace (repeatable)
agy --dangerously-skip-permissions  # auto-approve all tool permission requests
agy --print-timeout <dur>         # max wait for print mode (default 5m0s)
agy --sandbox                     # sandboxed terminal restrictions
agy --log-file <path>             # override CLI log file
# subcommands: changelog | help | install | plugin/plugins | update
```

**Verified live:** `agy -p "Reply with exactly one word: PONG" --dangerously-skip-permissions`
→ stdout `PONG`, exit code `0`, ~10s for a trivial prompt. Antigravity must be running/authenticated
(it shares the running `language_server`). Uses AI credits (`useAiCredits: true` in config).

Contract we rely on:
- **stdout** = the agent's final response text.
- **exit 0** = success; non-zero = failure (crash/quota/timeout) → loop must classify & back off.
- Each `-p` invocation is a **fresh conversation** (clean context) unless `--continue`/`--conversation`.
  → This is the Ralph principle: durable state lives on disk, not in the conversation.

**Verified git behavior (matters for the ratchet):** when instructed, `agy` runs the `git commit`
itself and returns the new SHA — the harness does NOT need to commit on the agent's behalf, only to
record HEAD before/after and `git reset --hard <HEAD_before>` to revert a regressing iteration.
**Gotcha:** `agy` writes an untracked `cache/` directory into the workspace. The ratchet's
"clean working tree" / revert logic must ignore (or clean) `cache/` and `.ralph/`, or it will
misread the tree as dirty. Add both to the target repo's `.gitignore` on `ralph init`.

Config: `~/.gemini/config/config.json` (`userSettings.globalPermissionGrants.allow`, model/theme).
No model-selection flag is exposed on `agy -p`; model = Antigravity default. Resilience to
rate-limits is therefore via **backoff + retry** (and optional config nudge), not a per-call flag.

## 2. `agentapi` — drive the GUI Agent Manager (secondary surface)

`~/.gemini/antigravity/bin/agentapi` → `exec language_server agentapi "$@"`.
Requires env `ANTIGRAVITY_LS_ADDRESS=127.0.0.1:<port>`. Returns JSON `{"response":{},"error":""}`.

Verbs (extracted from the binary):
```
agentapi new-conversation "<initial message>"          # spawn a fresh GUI agent conversation
agentapi send-message "<conversation-id>" "<message>"  # message an existing conversation
agentapi get-conversation-metadata "<conversation-id>" # read conversation/agent state
agentapi call | message | script                       # lower-level
```
Use when the user wants the loop reflected in the **visible Agent Manager** rather than headless.

## 3. Running processes / ports (example snapshot)

- `Antigravity` (main) listens `127.0.0.1:55809`.
- `language_server --standalone ... --csrf_token <uuid> --https_server_port 0` listens on two
  ephemeral ports (e.g. `55811`, `55812`). The **CSRF token is on the process cmdline** and is the
  auth for the local gRPC-Web API (`SendUserCascadeMessage`, `GetConversation`, …) — this is what
  the abhishekbhakat VS Code extension reverse-engineered. We prefer `agy`, which needs none of this.

Discover at runtime:
```
LS_PID=$(pgrep -f 'language_server .*--standalone')
CSRF=$(ps -o command= -p "$LS_PID" | grep -oE -- '--csrf_token [0-9a-f-]+' | awk '{print $2}')
PORTS=$(lsof -nP -iTCP -sTCP:LISTEN -p "$LS_PID" | grep -oE '127.0.0.1:[0-9]+' )
```

## 4. Antigravity memory / artifact locations (for the in-IDE workflow integration)

- `~/.gemini/GEMINI.md` — global rules (does not exist yet → we can create the never-stop rule here).
- `~/.gemini/antigravity/global_workflows/` — shared workflows (does not exist yet → we create one).
- `~/.gemini/antigravity/brain/<conversation-id>/{task.md,implementation_plan.md,walkthrough.md}` —
  per-mission agent "brain" artifacts.
- Per-workspace `.agent/` (a.k.a `.antigravity/`) — workspace rules/workflows.

## 5. Design mandate (from the user)

> "Bir ralph loop yaz … onun **hiç durmamasını** ve **sürekli süreci teslim ettiği yerden daha
> iyisine taşımasını** sağlamalı." → never stops; every handoff strictly better than the last.

Plus standing preferences: never pause for a summary mid-loop; if no major bug remains, move to
coverage/hardening/probe; commit only after a referee gate; integrity (no fabricated metrics).
