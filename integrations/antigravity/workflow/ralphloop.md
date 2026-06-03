---
description: Start the NEVER-STOPPING Ralph engine on THIS repo. /ralphloop launches the background daemon (ralph start --daemon) that improves the repo FOREVER and auto-recovers from any agy stall/timeout; follow it LIVE from a terminal with `ralph status <repo> --watch` or `ralph tail <repo>`. It does NOT stop until you run `ralph stop`.
---
# /ralphloop — start the never-stop engine (watch it live with `ralph status --watch` / `ralph tail`)

When the user types /ralphloop they want THIS repo to start improving itself FOREVER and to NOT stop
until they stop it. A single agy chat session CANNOT do that — it stalls or ends — so DO NOT loop in
this conversation. Instead LAUNCH THE EXTERNAL DAEMON: it runs in the BACKGROUND (that is precisely
what makes it never-stop + stall-proof), and the user FOLLOWS IT LIVE from any terminal.

Do EXACTLY this, in order. Run each in the FOREGROUND; each returns immediately (never background-poll):
1. ralph init "$PWD" 2>/dev/null || true        # scaffold if needed (no-op otherwise)
2. ralph start "$PWD" --daemon                  # start the never-stopping background daemon (idempotent)
3. ralph status "$PWD"                           # confirm ALIVE + show pid/iteration

Then tell the user EXACTLY this (these are the commands they run in the IDE's integrated terminal to
WATCH THE LOOP LIVE — the work runs in the daemon, the terminal is their live window into it):
  "✅ Never-stop Ralph engine is running in the background (pid + iteration above). It keeps improving
   this repo FOREVER and auto-recovers from any agy stall/timeout — it will NOT stop until you stop it.
   It runs as a background daemon ON PURPOSE: that is what lets it survive stalls and run forever. Watch
   it LIVE from a terminal (Antigravity ▸ Terminal):
     • Live dashboard (refreshes every 2s):   ralph status \"$PWD\" --watch
     • Live iteration-by-iteration stream:     ralph tail \"$PWD\"
     • The full journal of what it changed:    cat \"$PWD/.ralph/PROGRESS.md\"
     • Stop it:                                ralph stop \"$PWD\"   (or: touch .ralph/STOP)"

You are DONE after that — do NOT iterate/poll/summarize here; the daemon owns the loop and survives this
chat closing. If `ralph status` shows it is NOT alive (sandbox blocked the launch), tell the user to run
`ralph start "$PWD" --daemon` once in a plain terminal. (`ralph` = the antigravity-ralph repo's bin/ralph.)
