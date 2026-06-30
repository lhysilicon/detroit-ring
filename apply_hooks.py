#!/usr/bin/env python3
"""Additively wire Detroit Ring hooks into ~/.claude/settings.json.

Default: write the PROPOSED result to a staging path (real file untouched) so a
reviewer can diff the exact bytes. With --apply: back up the real file to the
project, then write the real file. Idempotent: re-running never duplicates a group.

Any hooks you already have are preserved verbatim; we only APPEND new
matcher-groups / new event keys.
"""
import json, os, sys, copy, datetime

SETTINGS = os.path.expanduser("~/.claude/settings.json")
PROJECT = os.path.dirname(os.path.abspath(__file__))
STAGING = os.path.join(PROJECT, "settings.staging.json")
BACKUP = os.path.join(PROJECT, "settings.json.pre-ring-bak")

RING = f"python3 {os.path.expanduser('~/.claude/ring/ring-emit')}"
ADDITIONS = {
    "SessionStart": "session-start",
    "UserPromptSubmit": "working",
    "PreToolUse": "working",     # heartbeat: any active tool call => this window is working (no matcher = all tools)
    "Stop": "done",
    "Notification": "waiting",
    "SessionEnd": "session-end",
    "PostToolUseFailure": "error",  # CC fires this ONLY when a tool genuinely fails → red distress ring (no matcher
                                    # = all tools, per user's "broad" choice). CC classifies the failure itself, so
                                    # no heuristic; the red auto-clears on the next working/done. (event verified
                                    # present in claude 2.1.183 binary; PreToolUse-deny + user Esc do NOT fire it.)
}


def group_for(arg):
    return {"hooks": [{"type": "command", "command": f"{RING} {arg}", "timeout": 5}]}


def already_wired(groups):
    for g in groups:
        for h in g.get("hooks", []):
            if "ring-emit" in h.get("command", ""):
                return True
    return False


def main():
    apply = "--apply" in sys.argv
    # A freshly-installed Claude Code may not have created settings.json yet — start from {}.
    if os.path.exists(SETTINGS) and os.path.getsize(SETTINGS) > 0:
        with open(SETTINGS) as f:
            data = json.load(f)
    else:
        data = {}

    before = copy.deepcopy(data)
    hooks = data.setdefault("hooks", {})
    added = []
    for event, arg in ADDITIONS.items():
        groups = hooks.setdefault(event, [])
        if already_wired(groups):
            continue
        groups.append(group_for(arg))
        added.append(event)

    out = json.dumps(data, indent=2, ensure_ascii=False) + "\n"

    # sanity: result must parse and must still contain every pre-existing hook command
    json.loads(out)
    def all_cmds(d):
        cmds = []
        for ev, gs in d.get("hooks", {}).items():
            for g in gs:
                for h in g.get("hooks", []):
                    cmds.append(h.get("command", ""))
        return cmds
    prior = [c for c in all_cmds(before) if "ring-emit" not in c]
    now = all_cmds(data)
    missing = [c for c in prior if c not in now]
    if missing:
        print("ABORT: would drop existing hook commands:", missing, file=sys.stderr)
        sys.exit(2)

    if apply:
        if not os.path.exists(BACKUP):
            with open(BACKUP, "w") as f:
                json.dump(before, f, indent=2, ensure_ascii=False)
        with open(SETTINGS, "w") as f:
            f.write(out)
        print(f"APPLIED to {SETTINGS} (added: {added or 'nothing, already wired'}); backup at {BACKUP}")
    else:
        with open(STAGING, "w") as f:
            f.write(out)
        print(f"STAGED to {STAGING} (would add: {added or 'nothing, already wired'}); real file untouched")


if __name__ == "__main__":
    main()
