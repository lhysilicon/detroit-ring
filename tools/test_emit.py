#!/usr/bin/env python3
"""Persistent unit tests for the ring-emit emitter's pure decision helpers (src/ring_emit.py).

Run: python3 tools/test_emit.py   (exit 0 = pass; build.sh gates on it)

These cover the logic the prior audit only checked ad-hoc (the "29/29" run was never committed):
  - non-lossy attention carry (a `working` after a waiting/error tags the most-recent attention episode so
    the app never misses the amber/red blip), incl. carry-forward across heartbeats + expiry
  - SessionEnd abandon classification (/clear, Ctrl-C, Esc → no false green ✅)
  - a realistic turn TIMELINE: the emitted file-state sequence carries everything the app reducer needs.
The emitter's IO/tty/headless suppression is unchanged and already battle-tested; this isolates the new logic.
"""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "src", "ring_emit.py")

spec = importlib.util.spec_from_file_location("ring_emit", SRC)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

fails = []


def ok(name, cond):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


# ---- _end_is_abandon: no false green ✅ for explicitly-abandoned work ----
ok("abandon: /clear",            m._end_is_abandon("clear", False) is True)
ok("abandon: prompt_input_exit", m._end_is_abandon("prompt_input_exit", False) is True)
ok("abandon: interrupt flag",    m._end_is_abandon("", True) is True)
ok("abandon: logout is NOT",     m._end_is_abandon("logout", False) is False)
ok("abandon: other is NOT",      m._end_is_abandon("other", False) is False)
ok("abandon: empty is NOT",      m._end_is_abandon("", False) is False)

# ---- _working_extra: non-lossy attention carry ----
# a working right after a raw waiting tags the waiting episode (so the app shows amber even if it overwrote it)
e = m._working_extra({"state": "waiting", "ts": 100.0}, 100.2)
ok("extra: after waiting tags attn", e.get("attn_state") == "waiting" and e.get("attn_ts") == 100.0)
# after a raw error → tags error
e = m._working_extra({"state": "error", "ts": 50.0}, 50.1)
ok("extra: after error tags attn", e.get("attn_state") == "error" and e.get("attn_ts") == 50.0)
# carried forward from a prior working that still holds a RECENT attn episode (app may have missed the raw one)
e = m._working_extra({"state": "working", "ts": 100.0, "attn_state": "waiting", "attn_ts": 99.5}, 100.0)
ok("extra: carries recent attn forward", e.get("attn_state") == "waiting" and e.get("attn_ts") == 99.5)
# carry EXPIRES past ATTN_CARRY (no stale amber re-trigger)
e = m._working_extra({"state": "working", "attn_state": "waiting", "attn_ts": 90.0}, 100.0)
ok("extra: stale carry dropped", "attn_state" not in e)
# plain working (no attention anywhere) → empty extra
e = m._working_extra({"state": "working", "ts": 100.0}, 100.2)
ok("extra: plain working has no attn", e == {})
# from idle → no attn
e = m._working_extra({"state": "idle", "ts": 100.0}, 100.2)
ok("extra: from idle no attn", "attn_state" not in e)

# ---- TIMELINE contract: a permission-approval turn never loses the amber blip ----
# Simulate the file-state the emitter would write across one realistic turn, feeding each write's dict as the
# `prev` of the next. The KEY guarantee: after a `waiting`, the following `working`(s) carry attn within
# ATTN_CARRY, so the app reducer is guaranteed to show amber once even if its 0.4s poll missed the raw waiting.
def working_file(prev, now):
    f = {"state": "working", "ts": now}
    f.update(m._working_extra(prev, now))
    return f

def attn_file(state, now):
    return {"state": state, "ts": now, "attn_state": state, "attn_ts": now}

t = 0.0
prev = {}
# new user turn + a couple of tool heartbeats (no attention yet → no attn fields)
prev = working_file(prev, t); t += 0.1
prev = working_file(prev, t); t += 0.1
prev = working_file(prev, t); t += 0.1
ok("timeline: plain working has no attn", "attn_state" not in prev)
# permission prompt → amber
prev = attn_file("waiting", t); t += 0.1
# user approves → the approved tool's PreToolUse fires working (the one the OLD code DISCARDED)
w1 = working_file(prev, t); t += 0.1
ok("timeline: working after approve carries amber", w1.get("attn_state") == "waiting")
# a follow-up heartbeat still within ATTN_CARRY also carries it (so a late poll still sees amber)
w2 = working_file(w1, t); t += 0.1
ok("timeline: amber carried to next heartbeat", w2.get("attn_state") == "waiting")
# long after the episode, the carry is gone (no stuck amber)
w3 = working_file(w2, t + m.ATTN_CARRY + 1)
ok("timeline: amber carry expires (no stick)", "attn_state" not in w3)

print()
print("EMIT TESTS PASS" if not fails else f"EMIT TESTS FAIL ({len(fails)})")
sys.exit(0 if not fails else 1)
