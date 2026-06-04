#!/usr/bin/env python3
"""ralph console — a combined LIVE monitor + chat box for the never-stop loop.

Top pane: live loop status (iteration / phase / what it's doing now / last change / model quota).
Bottom pane: a chat box — just TYPE a directive and press Enter; it is queued to .ralph/INBOX.md and the
running loop injects it into the next iteration (as an OPERATOR DIRECTIVE) without ever stopping. The
console also shows when each message is DELIVERED (consumed by an iteration), so it reads like a chat.

curses gives a flicker-free, double-buffered redraw and real line input alongside the ~1s status refresh.
Run as: python3 console.py <target-repo>   (bin/ralph: `ralph console [target]`).
"""
import curses
import glob
import json
import os
import re
import shlex
import subprocess
import sys
import time

TARGET = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.getcwd()
RALPH = os.path.join(TARGET, ".ralph")
NAME = os.path.basename(TARGET)
RALPH_BIN = os.environ.get("RALPH_BIN", "ralph")


def _read(path):
    try:
        with open(path, "r", errors="replace") as f:
            return f.read()
    except Exception:
        return ""


def _jget(path, key, default=""):
    m = re.search(r'"%s"\s*:\s*"?([^",}]*)"?' % re.escape(key), _read(path))
    return m.group(1).strip() if m else default


def _hnum(n):
    try:
        n = int(n)
    except Exception:
        return str(n)
    if n >= 1_000_000:
        return "%.2fM" % (n / 1_000_000)
    if n >= 1_000:
        return "%.1fk" % (n / 1_000)
    return str(n)


def read_status():
    st = os.path.join(RALPH, "state.json")
    hb = os.path.join(RALPH, "heartbeat.json")
    s = {
        "iter": _jget(st, "iteration", "?"),
        "phase": _jget(hb, "phase", "?"),
        "last_class": _jget(st, "last_class", "?"),
        "stalled": _jget(hb, "stalled", "false"),
    }
    # alive: pid file + kill -0
    pid = _read(os.path.join(RALPH, "ralph.pid")).strip()
    alive = False
    if pid.isdigit():
        try:
            os.kill(int(pid), 0)
            alive = True
        except Exception:
            alive = False
    s["alive"] = alive
    # elapsed on the current iteration
    try:
        startep = int(_read(os.path.join(RALPH, "last_run_started.epoch")).strip() or 0)
        e = max(0, int(time.time()) - startep)
        s["elapsed"] = ("%dh%dm" % (e // 3600, (e % 3600) // 60)) if e >= 3600 else ("%dm%ds" % (e // 60, e % 60))
    except Exception:
        s["elapsed"] = "?"
    # doing now: newest iter dir's agy.stdout (or verify log) last meaningful line
    s["doing"] = ""
    try:
        dirs = sorted(glob.glob(os.path.join(RALPH, "iter", "*/")), key=os.path.getmtime)
        if dirs:
            cur = dirs[-1]
            af = os.path.join(cur, "agy.stdout")
            vf = os.path.join(cur, "base.verify.1.log")
            if os.path.exists(vf) and (not os.path.exists(af) or os.path.getmtime(vf) > os.path.getmtime(af)):
                s["doing"] = "running the verify suite (pytest)…"
            elif os.path.exists(af):
                for ln in reversed(_read(af).splitlines()):
                    t = ln.strip()
                    if t and not re.match(r'^[\s{}"]|RALPH_HANDOFF|TRAILER_STATUS|^\d+$|confidence|files|metrics_after|what_changed|next_candidate|i_did_NOT|done_with', t):
                        s["doing"] = t[:120]
                        break
    except Exception:
        pass
    # last change (real): git show --stat HEAD oneline
    s["last_change"] = ""
    try:
        out = subprocess.run(["git", "-C", TARGET, "show", "--stat", "--oneline", "HEAD"],
                             capture_output=True, text=True, timeout=4).stdout.splitlines()
        if out:
            head = out[0][:70]
            files = [x.strip() for x in out[1:] if "|" in x]
            s["last_change"] = head + ("   (" + files[0].split("|")[0].strip() + " …)" if files else "")
    except Exception:
        pass
    # model + live quota cache
    s["model"] = os.environ.get("RALPH_MODEL", "") or _jget(
        os.path.expanduser("~/.gemini/antigravity-cli/settings.json"), "model", "(unknown)")
    q = _read(os.path.join(RALPH, "quota.live"))
    s["quota"] = ""
    s["quota_pct"] = -1
    m_reset = re.search(r"RESET_EPOCH=(\d+)", q)
    m_cred = re.search(r"CREDITS=(\d+)", q)
    if m_reset:
        win = int(os.environ.get("RALPH_USAGE_WINDOW_S", "10800") or 10800)
        reset_e = int(m_reset.group(1))
        now = int(time.time())
        while reset_e <= now:
            reset_e += win
        rin = reset_e - now
        clk = time.strftime("%H:%M", time.localtime(reset_e))
        cred = (" · %s credits" % m_cred.group(1)) if m_cred else ""
        s["quota"] = "refreshes %s (in %dh%02dm)%s" % (clk, rin // 3600, (rin % 3600) // 60, cred)
        s["quota_pct"] = max(0, min(100, int(rin * 100 / win)))  # % of the refresh window remaining
    # latest completed iteration (for conversational "replies" in the chat)
    s["prog_iter"] = None
    s["prog_summary"] = ""
    prog = _read(os.path.join(RALPH, "PROGRESS.md"))
    mi = re.findall(r"## ITER (\d+)", prog)
    if mi:
        s["prog_iter"] = mi[-1]
        last = re.split(r"## ITER ", prog)[-1]
        tm = re.search(r"\*\*Task\*\*:\s*(.+)", last)
        vm = re.search(r"VERDICT \d+ (ACCEPTED|REJECTED)[^\n]*", last)
        dm = re.search(r"\*\*Decision\*\*:\s*(.+)", last)
        task = tm.group(1).strip()[:70] if tm else ""
        verdict = vm.group(0).strip()[:64] if vm else (dm.group(1).strip()[:40] if dm else "")
        s["prog_summary"] = (task + ((" → " + verdict) if verdict else "")).strip()[:118]
    # last consumed iter (for chat "delivered" feedback)
    arch = _read(os.path.join(RALPH, "INBOX.archive"))
    mc = re.findall(r"consumed @ iter (\d+)", arch)
    s["last_consumed"] = mc[-1] if mc else None
    s["inbox_pending"] = sum(1 for l in _read(os.path.join(RALPH, "INBOX.md")).splitlines() if l.strip().startswith("-"))
    return s


def queue_message(msg):
    try:
        os.makedirs(RALPH, exist_ok=True)
        with open(os.path.join(RALPH, "INBOX.md"), "a") as f:
            f.write("- [%s] %s\n" % (time.strftime("%Y-%m-%d %H:%M"), msg))
        return True
    except Exception:
        return False


def refresh_quota_bg():
    # Probe the IDE for live quota in the background; write atomically (rename only AFTER it completes,
    # ~1-2s) so read_status never sees a half-written file. Reads quota.live each tick.
    live = os.path.join(RALPH, "quota.live")
    cmd = "%s quota %s > %s.new 2>/dev/null && mv -f %s.new %s" % (
        shlex.quote(RALPH_BIN), shlex.quote(TARGET),
        shlex.quote(live), shlex.quote(live), shlex.quote(live))
    try:
        subprocess.Popen(["/bin/sh", "-c", cmd])
    except Exception:
        pass


def main(stdscr):
    curses.curs_set(1)
    stdscr.timeout(150)  # getch blocks up to 150ms then returns -1 → ~status refresh cadence
    try:
        curses.start_color()
        curses.use_default_colors()
        curses.init_pair(1, curses.COLOR_GREEN, -1)
        curses.init_pair(2, curses.COLOR_CYAN, -1)
        curses.init_pair(3, curses.COLOR_YELLOW, -1)
        curses.init_pair(4, curses.COLOR_MAGENTA, -1)
    except Exception:
        pass

    inp = ""
    chat = []          # list of (who, text)
    status = read_status()
    pending_msgs = []  # messages queued, awaiting delivery
    last_refresh = 0.0
    last_qprobe = 0.0
    base_consumed = status.get("last_consumed")
    last_shown_iter = status.get("prog_iter")   # don't replay history; only show iterations from now on

    chat.append(("sys", "Connected to the loop on %s. Just type a directive + Enter — it steers the loop" % NAME))
    chat.append(("sys", "on its next iteration (never stops). The loop's completed iterations show up here as replies."))

    while True:
        now = time.time()
        if now - last_refresh > 1.0:
            status = read_status()
            last_refresh = now
            # delivery feedback: a new "consumed @ iter N" appeared and we had pending msgs
            lc = status.get("last_consumed")
            if pending_msgs and lc and lc != base_consumed:
                for _ in pending_msgs:
                    chat.append(("ralph", "✓ delivered to iteration %s — acting on it now" % lc))
                pending_msgs = []
                base_consumed = lc
            # conversational reply: the loop finished an iteration → show what it did
            pi = status.get("prog_iter")
            if pi and pi != last_shown_iter:
                last_shown_iter = pi
                summ = status.get("prog_summary") or "(done)"
                chat.append(("ralph", "iter %s ✓  %s" % (pi, summ)))
        if now - last_qprobe > 60:
            refresh_quota_bg()
            last_qprobe = now

        draw(stdscr, status, chat, inp)

        try:
            ch = stdscr.getch()
        except KeyboardInterrupt:
            break
        if ch == -1:
            continue
        if ch in (10, 13, curses.KEY_ENTER):
            msg = inp.strip()
            inp = ""
            if msg:
                if msg.lower() in ("/quit", "/exit", ":q"):
                    break
                if queue_message(msg):
                    chat.append(("you", msg))
                    chat.append(("ralph", "📨 queued — will reach the loop next iteration"))
                    pending_msgs.append(msg)
                else:
                    chat.append(("ralph", "⚠ could not write to inbox"))
        elif ch in (curses.KEY_BACKSPACE, 127, 8):
            inp = inp[:-1]
        elif ch == 3:  # Ctrl-C
            break
        elif ch == curses.KEY_RESIZE:
            pass
        elif 32 <= ch < 127:
            inp += chr(ch)


def _addstr(stdscr, y, x, s, attr=0):
    h, w = stdscr.getmaxyx()
    if 0 <= y < h and x < w:
        try:
            stdscr.addnstr(y, x, s, max(0, w - x - 1), attr)
        except Exception:
            pass


def _bar(pct, w=16):
    try:
        pct = max(0, min(100, int(pct)))
    except Exception:
        pct = 0
    f = pct * w // 100
    return "█" * f + "░" * (w - f)


def _rule(stdscr, y, label=""):
    """A full-width horizontal divider line, optionally with an embedded label."""
    h, w = stdscr.getmaxyx()
    if label:
        lab = " " + label + " "
        line = "──" + lab + ("─" * max(0, w - len(lab) - 3))
    else:
        line = "─" * max(0, w - 1)
    _addstr(stdscr, y, 0, line[:max(0, w - 1)], curses.color_pair(3))


def draw(stdscr, s, chat, inp):
    stdscr.erase()
    h, w = stdscr.getmaxyx()
    GR = curses.color_pair(1)
    CY = curses.color_pair(2)
    YE = curses.color_pair(3)
    MA = curses.color_pair(4)
    BOLD = curses.A_BOLD

    alive = s.get("alive")
    head = "  ralph · %s    iter %s · %s · %s" % (
        NAME, s.get("iter", "?"), s.get("elapsed", "?"),
        ("● alive" if alive else "○ stopped"))
    _addstr(stdscr, 0, 0, head.ljust(w - 1), (GR if alive else YE) | BOLD)
    phase = s.get("phase", "?")
    plabel = {"running_agy": "🍳 cooking — agy is working", "backoff": "⏳ backing off",
              "paused": "⏸ paused"}.get(phase, phase)
    if s.get("stalled") == "true":
        plabel = "⚠ STALLED?"
    _addstr(stdscr, 1, 0, "  %s" % plabel, CY)
    _addstr(stdscr, 2, 0, "  model : %s" % s.get("model", "?"), 0)
    # quota on its OWN line with a refresh-CYCLE bar (time left until the quota window refreshes — this is
    # exact; the app's per-model remaining-% isn't exposed outside its UI). Live refresh time + AI credits.
    qpct = s.get("quota_pct", -1)
    if qpct >= 0:
        _addstr(stdscr, 3, 0, "  quota : %s  %s" % (_bar(qpct, 16), s.get("quota", "")), MA | BOLD)
    else:
        _addstr(stdscr, 3, 0, "  quota : (open the app's Settings ▸ Models panel for live quota)", MA)
    _addstr(stdscr, 4, 0, "  ▸ doing: %s" % (s.get("doing") or "(thinking…)"), GR)
    _addstr(stdscr, 5, 0, "  ▸ last : %s" % (s.get("last_change") or "(none yet)"), 0)

    # ── clear full-width divider that opens the CHAT region ──
    pend = s.get("inbox_pending", 0)
    label = "CHAT — just type a directive + Enter to steer the loop (it never stops)"
    if pend:
        label += "  ·  📨 %d queued" % pend
    div_y = 6
    _rule(stdscr, div_y, label)

    # chat log — BOTTOM-anchored (newest messages sit right above the input, like a real chat, so a reply
    # is never stranded at the top of a tall window).
    top = div_y + 1
    rows = max(0, h - 2 - top)
    lines = []
    for who, text in chat:
        if who == "you":
            lines.append(("you ▸ " + text, CY | BOLD))
        elif who == "ralph":
            lines.append(("ralph ▸ " + text, GR))
        else:
            lines.append(("      " + text, curses.A_DIM))
    visible = lines[-rows:] if rows > 0 else []
    y0 = max(top, (h - 2) - len(visible))
    for i, (text, attr) in enumerate(visible):
        _addstr(stdscr, y0 + i, 1, text, attr)

    # ── divider directly above the input box, then the input line ──
    _rule(stdscr, h - 2)
    _addstr(stdscr, h - 1, 0, "> " + inp, BOLD)
    try:
        stdscr.move(h - 1, min(w - 1, 2 + len(inp)))
    except Exception:
        pass
    stdscr.refresh()


if __name__ == "__main__":
    try:
        curses.wrapper(main)
    except KeyboardInterrupt:
        pass
    print("ralph console closed — the loop kept running in the background.")
