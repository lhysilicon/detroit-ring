#!/usr/bin/env python3
"""ring-emit: Claude Code hook entrypoint for the Detroit Ring status indicator.

Usage (from a settings.json hook):  python3 ring_emit.py <event>
  events: session-start | working | waiting | done | session-end

Reads the hook JSON payload from stdin to key state per session_id, then writes a
tiny per-session state file under ~/.claude/ring/sessions/<session_id>.json.
The DetroitRing app watches that directory and aggregates across all live sessions.

Contract (must never disturb a Claude Code turn):
  - ALWAYS exit 0, even on any error.
  - Emit NOTHING on stdout (stdout from a hook can inject context / block Stop).
  - Be fast: `working` is wired to UserPromptSubmit + PreToolUse (per-tool heartbeat so an
    actively-working window is detected mid-run); python startup is cheap enough for that.
"""
import sys, os, json, time, tempfile

RING_DIR = os.environ.get("DETROIT_RING_DIR") or os.path.expanduser("~/.claude/ring")
SESS_DIR = os.path.join(RING_DIR, "sessions")
LOG = os.path.join(RING_DIR, "emit.log")
LOG_CAP = 262144   # bytes; trim to the last LOG_KEEP lines past this so the debug log can't grow forever
LOG_KEEP = 300
ATTN_CARRY = 2.0   # seconds a waiting/error "attention" episode is carried forward onto following `working`
                   # writes, so the app sees it even if its ~0.4s poll missed the raw waiting/error file.

# event -> ring state. session-start/end are handled specially.
EVENT_STATE = {
    "session-start": "idle",
    "working": "working",
    "waiting": "waiting",
    "done": "done",
    "error": "error",   # PostToolUseFailure → red distress ring (auto-clears on next working/done)
}


def _atomic_write(path, data):
    d = os.path.dirname(path)
    # suffix is .tmp, NOT .json: the app globs sessions/*.json, so a temp left behind by a signal-kill
    # between write and os.replace must NOT match that glob — it carries the real session_id and would
    # otherwise be aggregated as a bogus DUPLICATE ring. The committed file is still renamed to <id>.json.
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(data)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except Exception:
            pass


def _read_state(path):
    try:
        with open(path) as f:
            o = json.load(f)
        return o.get("state"), o.get("cwd", ""), float(o.get("ts", 0) or 0)
    except Exception:
        return None, "", 0.0


def _read_full(path):
    """The whole prev session dict (or {} on any error) — used to carry an attention episode
    (waiting/error) forward onto later `working` writes so the app never misses the amber/red blip."""
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return {}


# ---- pure decision helpers (unit-tested by tools/test_emit.py; no IO, no globals) ----

def _working_extra(prev, now, carry=ATTN_CARRY):
    """Visual-timing fields to attach to a `working` write: attn_state/attn_ts = the most-recent waiting/error
    "attention" episode, so the app shows that color for one guaranteed dwell then returns to blue (non-lossy:
    never missed, never stuck). Carried forward from a prior working (within `carry` seconds) so a late poll
    still sees it even if it never sampled the raw waiting/error file. Pure. Returns {} if no recent episode."""
    extra = {}
    ps = prev.get("state")
    if ps in ("waiting", "error"):
        extra["attn_state"] = ps
        extra["attn_ts"] = float(prev.get("ts") or 0)
    else:
        pa = prev.get("attn_state") or ""
        pts = float(prev.get("attn_ts") or 0)
        if pa in ("waiting", "error") and (now - pts) < carry:
            extra["attn_state"] = pa
            extra["attn_ts"] = pts
    return extra


def _end_is_abandon(reason, is_interrupt):
    """True when a SessionEnd is an explicit user abandon (so NO green ✅ 'done' should be surfaced for
    the in-flight work): an Esc interrupt, a /clear, or Ctrl-C at the prompt. Pure."""
    return bool(is_interrupt) or reason in ("clear", "prompt_input_exit")


def _focus_meta(path):
    """(term_program, tty) of the CC process so the app can raise this session's terminal on click. Captured
    ONCE and carried forward from the prev session file, so `ps` is shelled at most once per session (keeps
    the per-tool heartbeat fast)."""
    try:
        with open(path) as f:
            o = json.load(f)
        # reuse once the keys exist AT ALL (even empty) — so a no-TERM_PROGRAM/headless terminal doesn't
        # re-shell `ps` on every heartbeat trying to fill an unfillable value.
        if "tty" in o or "term_program" in o:
            return o.get("term_program", ""), o.get("tty", "")
    except Exception:
        pass
    term = os.environ.get("TERM_PROGRAM", "")
    tty = ""
    try:
        import subprocess
        r = subprocess.run(["ps", "-o", "tty=", "-p", str(os.getppid())],
                           capture_output=True, text=True, timeout=2)
        s = r.stdout.strip()
        if s and s not in ("??", "?"):
            tty = s if s.startswith("/dev/") else "/dev/" + s
    except Exception:
        pass
    return term, tty


def _has_claude_ancestor():
    """True if THIS claude process (getppid) has ANOTHER `claude` process above it in the tree — i.e. it is a
    nested / headless `claude -p` spawned from inside another claude session (a pipeline / automation LLM call),
    not the interactive top-level terminal session a human watches. A foreground `claude -p` inherits the
    parent terminal's controlling tty, so the tty check alone can't catch it; the ancestry can. A top-level
    interactive claude has only shell/login/terminal ancestors (no claude) → returns False → its ring shows.
    One `ps` snapshot + an in-memory parent walk (cheap, bounded). Errs toward False (show) on any failure so a
    genuine interactive ring is never hidden by a guess."""
    try:
        import subprocess
        r = subprocess.run(["ps", "-axo", "pid=,ppid=,comm="], capture_output=True, text=True, timeout=3)
        parent, comm = {}, {}
        for line in r.stdout.splitlines():
            p = line.split(None, 2)
            if len(p) < 2 or not p[0].isdigit() or not p[1].isdigit():
                continue
            pid = int(p[0]); parent[pid] = int(p[1])
            comm[pid] = os.path.basename(p[2]) if len(p) > 2 else ""
        cur = parent.get(os.getppid(), 0)   # start at the PARENT of this session's claude (skip self)
        seen = set()
        for _ in range(24):
            if cur <= 1 or cur in seen:
                break
            seen.add(cur)
            if comm.get(cur, "") == "claude":
                return True
            cur = parent.get(cur, 0)
    except Exception:
        pass
    return False


def _ctty_known_absent():
    """True ONLY when we can DEFINITIVELY confirm this claude process has NO controlling tty — i.e. `ps`
    actually RAN (returncode 0) and reported empty/`??`. This distinguishes a genuinely headless session
    (safe to cache as no-ring) from a transient `ps` failure/timeout (must NOT cache, or a one-off failure
    would permanently suppress a real interactive session). Errs toward False (don't cache) on any error."""
    try:
        import subprocess
        r = subprocess.run(["ps", "-o", "tty=", "-p", str(os.getppid())],
                           capture_output=True, text=True, timeout=2)
        return r.returncode == 0 and r.stdout.strip() in ("", "??", "?")
    except Exception:
        return False


def main():
    event = sys.argv[1] if len(sys.argv) > 1 else ""

    # Pull session_id (+ a little context) from the hook payload on stdin, if present.
    session_id = "default"
    cwd = ""
    message = ""
    is_interrupt = False
    notif_type = ""
    reason = ""
    try:
        raw = sys.stdin.read()
        if raw.strip():
            payload = json.loads(raw)
            session_id = str(payload.get("session_id") or payload.get("sessionId") or "default")
            cwd = str(payload.get("cwd") or "")
            message = str(payload.get("message") or "")
            is_interrupt = bool(payload.get("is_interrupt", False))
            # CC's own classification of a Notification (authoritative when present; older CC may omit it →
            # we fall back to message keywords). Values seen in CC 2.1.183: idle_prompt / permission_prompt /
            # permission_request / worker_permission_prompt / elicitation.
            notif_type = str(payload.get("notification_type") or payload.get("notificationType") or "")
            # SessionEnd reason — CC sends one of {clear, logout, prompt_input_exit, other}. Used so an
            # explicitly-abandoned turn (/clear, Ctrl-C at the prompt, Esc interrupt) does NOT surface a
            # green ✅ "completed" the way a genuine finish would.
            reason = str(payload.get("reason") or "")
    except Exception:
        pass

    # ensure the dir tree exists BEFORE any file op (so the very first event also logs/writes)
    os.makedirs(SESS_DIR, exist_ok=True)   # also creates RING_DIR

    # opportunistic GC: sweep stale dot-led temp files older than the app's eviction horizon —
    #   `.hl-*.tmp`  headless markers left by a headless session killed WITHOUT session-end, and
    #   `.tmp-*.tmp` atomic-write temps orphaned by a signal-kill between mkstemp and os.replace.
    # Runs only on session-start (once per session, low frequency) so it never burdens the per-tool heartbeat.
    if event == "session-start":
        try:
            cutoff = time.time() - 14400   # mirror AppCore Cfg.staleSec (4h)
            for f in os.listdir(SESS_DIR):
                if (f.startswith(".hl-") or f.startswith(".tmp-")) and f.endswith(".tmp"):
                    fp = os.path.join(SESS_DIR, f)
                    try:
                        if os.path.getmtime(fp) < cutoff:
                            os.unlink(fp)
                    except Exception:
                        pass
        except Exception:
            pass

    # debug log — actually capped (trim to the last LOG_KEEP lines once it passes LOG_CAP bytes)
    try:
        if os.path.exists(LOG) and os.path.getsize(LOG) > LOG_CAP:
            with open(LOG) as f:
                tail = f.readlines()[-LOG_KEEP:]
            with open(LOG, "w") as f:
                f.writelines(tail)
        with open(LOG, "a") as f:
            # sid in the log line so a recurring "extra ring" can be traced to the session that orphaned a file
            f.write("%.3f %-13s sid=%s msg=%r\n" % (time.time(), event, str(session_id)[:8], message[:80]))
    except Exception:
        pass

    # sanitize session_id for use as a filename
    safe = "".join(c for c in session_id if c.isalnum() or c in "-_") or "default"
    path = os.path.join(SESS_DIR, safe + ".json")
    # dot-marker cache: once a session is decided HEADLESS (no tty, or a nested `claude -p` with a claude
    # ancestor) we drop this and never recompute, so later heartbeats skip the process walk / ps entirely. It
    # is dot-prefixed AND .tmp (the app's readAll globs `*.json` and skips dotfiles) so it is never seen as a ring.
    marker = os.path.join(SESS_DIR, ".hl-" + safe + ".tmp")

    if event == "session-end":
        try:
            os.unlink(marker)   # clear the headless cache for this (now ended) session
        except Exception:
            pass
        # If the session ended while still working/waiting, surface a TERMINAL "done" so the app fires the
        # ✅ completion ping + a final ring, instead of the work vanishing silently — BUT only when the end
        # is NOT an explicit user abandon. A /clear, a Ctrl-C at the prompt (prompt_input_exit), or an Esc
        # interrupt all leave the file at working/waiting yet did NOT complete anything; surfacing a green
        # "✅ 完成" for thrown-away work is a lie. For those, just remove the ring. (reason taxonomy:
        # clear / logout / prompt_input_exit / other.)
        prev_state, prev_cwd, _ = _read_state(path)
        abandoned = _end_is_abandon(reason, is_interrupt)
        if prev_state in ("working", "waiting") and not abandoned:
            term_program, tty = _focus_meta(path)
            _atomic_write(path, json.dumps({
                "state": "done", "ts": time.time(), "session_id": safe,
                "cwd": cwd or prev_cwd, "final": True,
                "cc_pid": os.getppid(), "term_program": term_program, "tty": tty,
            }))
        else:
            try:
                os.unlink(path)
            except Exception:
                pass
        return

    # Cached headless (a nested / no-tty `claude -p`): skip ALL work — no ring, and no ps / process-tree walk.
    if os.path.exists(marker):
        return

    # The Notification hook fires for BOTH genuine permission prompts AND the idle "waiting for your input"
    # nudge that lands right after a turn completes (which would clobber a just-written "done"). Decide via
    # CC's own `notification_type` when present (authoritative), else fall back to message keywords.
    if event == "waiting":
        # types that genuinely mean "the human needs to act" → amber. Verified against the CC 2.1.183 binary:
        # worker_permission_prompt + elicitation_dialog/elicitation_url_dialog are the ACTUAL emitted types;
        # permission_prompt is the documented (currently un-emitted) mainline value, kept for forward-compat.
        # (Dropped bare "elicitation" and "permission_request": neither is ever emitted as a notification_type,
        # so the old tuple matched elicitation prompts only by accidental "needs your" keyword luck.)
        PERMISSION_TYPES = ("permission_prompt", "worker_permission_prompt", "elicitation_dialog", "elicitation_url_dialog")
        if notif_type == "idle_prompt":
            return                       # idle nudge — authoritatively NOT a "needs you"; never amber
        elif notif_type in PERMISSION_TYPES:
            pass                         # genuine permission / elicitation prompt → amber
        else:
            # unknown type (a future permission variant) OR no type field (older CC) → keyword fallback, the
            # original behavior. A non-permission typed notification (auth_success, computer_use…) carries no
            # permission keyword in its message, so it is correctly rejected here too.
            m = message.lower()
            if not any(k in m for k in ("permission", "approve", "approval", "needs your", "wants to", "allow")):
                return  # idle nudge / non-action notification — do NOT overwrite done/working

    if event == "error" and is_interrupt:
        return  # user-initiated tool interrupt (Esc) is not an error → don't flash the red ring

    state = EVENT_STATE.get(event)
    if state is None:
        return  # unknown event -> no-op

    # Per-write extra fields the app uses for purely-visual timing decisions (see the pure helpers above).
    # The OLD anti-clobber here DISCARDED a `working` for 0.5-0.8s after a waiting/error so the app's 0.4s
    # poll could sample it — but on a turn with no follow-up tool the discarded working had no replacement,
    # so the ring stuck amber until the next Stop ("状态没及时回蓝"). Now we never discard: we TAG instead.
    extra = {}
    if event == "working":
        extra = _working_extra(_read_full(path), time.time())
    elif event in ("waiting", "error"):
        # stamp the attention episode so a following `working` can carry it forward (app honors it once)
        extra["attn_state"] = state
        extra["attn_ts"] = time.time()

    term_program, tty = _focus_meta(path)
    # A ring is for an INTERACTIVE CLI session a human is watching. Suppress a headless `claude -p` two ways:
    # (a) NO controlling tty → a detached pipeline / launchd `claude -p` (e.g. a cron/automation script).
    #     Cache the no-ring verdict (skip re-ps on later heartbeats) ONLY when `ps` DEFINITIVELY confirms the
    #     absence (_ctty_known_absent) and only on first sight — a transient `ps` failure inside _focus_meta also
    #     yields an empty tty, and caching THAT would permanently suppress a genuine interactive session. When
    #     not definitive we return without a marker → self-heals on the next event (the original behavior).
    if not tty:
        if not os.path.exists(path) and _ctty_known_absent():
            try:
                open(marker, "w").close()
            except Exception:
                pass
        return
    # (b) a `claude` ANCESTOR in the process tree → a `claude -p` spawned from INSIDE another claude session,
    #     which INHERITS the parent terminal's tty (so (a) misses it) yet still fires these global hooks and
    #     would pop a phantom second ring on that terminal. Process ancestry is STABLE for a session's lifetime,
    #     so caching it is safe: mark headless once (dot-marker) and the early `if os.path.exists(marker)` then
    #     short-circuits every later event. The walk runs at most ONCE per session — only on first sight (no
    #     file yet). A top-level interactive session has shell/login/terminal ancestors (no claude) → shows.
    if not os.path.exists(path) and _has_claude_ancestor():
        try:
            open(marker, "w").close()
        except Exception:
            pass
        return
    _atomic_write(path, json.dumps({
        "state": state, "ts": time.time(), "session_id": safe, "cwd": cwd,
        # getppid() is the live Claude Code process (the hook is a direct child of it). The app uses
        # kill(pid,0) to evict a crashed session's ring instantly instead of waiting out staleSec.
        # NOTE: getppid() == the real Claude Code pid ONLY because this hook is invoked as a SIMPLE single
        # command, so /bin/sh execs into python (parent stays CC). If the hook command ever becomes compound
        # (a pipe or `; foo`), getppid would capture a transient shell that exits → the app would wrongly
        # insta-evict the ring. Keep the settings.json hook command a single plain invocation.
        "cc_pid": os.getppid(),
        # so clicking the ring can raise this session's terminal tab (Terminal.app: exact tab by tty).
        "term_program": term_program, "tty": tty,
        # visual-timing hint: attn_state/attn_ts = most-recent waiting/error so the app's reducer shows the
        # amber/red "needs you" cue once even if its poll missed the raw file, then returns to blue (non-lossy).
        **extra,
    }))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
