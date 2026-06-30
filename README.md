<div align="center">

<img src="docs/icon.png" width="120" alt="Detroit Ring icon" />

# Detroit Ring

**A _Detroit: Become Human_ android-LED status ring for [Claude Code](https://github.com/anthropics/claude-code).**

Your terminal grows a glowing ring on the desktop: it **spins blue** while the agent works,
turns **amber** when it needs you, and **pulses green** the moment it's done — so you can walk
away and know, at a glance, exactly what your session is doing.

Native macOS. No Electron, no menu-bar clutter, no web page. Just the ring.

![macOS](https://img.shields.io/badge/macOS-13%2B%20·%20Apple%20Silicon-000000?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-AppKit%20%2B%20SwiftUI-F05138?logo=swift&logoColor=white)
![Claude Code](https://img.shields.io/badge/for-Claude%20Code-D97757)
![License](https://img.shields.io/badge/license-MIT-blue)

<img src="docs/demo-states.gif" width="420" alt="Detroit Ring cycling through working, waiting, done, error and idle states" />

</div>

---

## Why

You give Claude Code a long task and tab away. Then you keep tabbing *back* — "is it still
going? is it stuck waiting on me? is it finally done?"

Detroit Ring answers that without you looking at the terminal at all. A small glass capsule
floats on your desktop with **one ring per live session**. The ring's color and motion *are*
the status, lifted straight from the androids' temple LED in _Detroit: Become Human_:

- 🔵 **spinning blue** — working
- 🟡 **amber** — waiting for you
- 🟢 **pulsing green** — just finished

And the instant real work completes, a quiet macOS **notification** fires — so even if you're
deep in another app, you know the second it's ready. The ring holds green for a few minutes, then
settles into a calm standby glow.

## Features

- **🎯 Glance-able status.** Five states — working / waiting / done / error / idle — each an
  unmistakable color and motion. No reading required.
- **🪟 One ring per session.** Run three Claude Code sessions, see three rings stacked in the
  capsule. Each tracks its own session independently.
- **🖐️ Drag it anywhere.** Free-floating glass capsule, defaults to the top-right. Drag it where
  you like — the position is remembered and always clamped on-screen.
- **🔔 Done notification.** A native banner fires only when *real* work completes (≥15s of actual
  work, idle time excluded) — no spam on tiny one-shot prompts.
- **🤫 Quiet by design.** It's an `LSUIElement` agent: no Dock icon, no menu-bar item, no window
  chrome. The capsule auto-hides when no session is live (an open-but-idle session keeps a dim
  standby ring).
- **🎨 Pixel-faithful LED.** The ring is drawn analytically (no random jitter), so what you see is
  deterministic and crisp at any size — Retina-sharp glow and all.
- **🥚 Eleven hidden Easter eggs.** Ambient _Detroit_ references that occasionally flicker across
  the ring while it works. (See below. They're the fun part.)
- **🔌 Pushed by Claude Code hooks.** No API polling, no network, no API keys. Claude Code's
  lifecycle hooks push status into tiny local state files; the app just watches that one folder.
- **♻️ Fully reversible.** Three install scripts, three uninstall paths. It never touches anything
  it can't cleanly undo.

## The five states

<table>
<tr>
<td align="center"><img src="docs/state-working.png" width="120" alt="Working state: blue rotating ring"/><br/><b>Working</b><br/><sub>blue, rotating segments</sub></td>
<td align="center"><img src="docs/state-waiting.png" width="120" alt="Waiting state: amber ring"/><br/><b>Waiting for you</b><br/><sub>amber sweep</sub></td>
<td align="center"><img src="docs/state-done.png" width="120" alt="Done state: green ring"/><br/><b>Done</b><br/><sub>green pulse → standby</sub></td>
<td align="center"><img src="docs/state-error.png" width="120" alt="Error state: red ring"/><br/><b>Error</b><br/><sub>red, softened</sub></td>
<td align="center"><img src="docs/state-idle.png" width="120" alt="Idle state: dim blue ring"/><br/><b>Idle</b><br/><sub>dim standby</sub></td>
</tr>
</table>

> The full capsule with several live rings:
>
> <img src="docs/hero-strip.png" width="170" alt="Detroit Ring capsule with multiple stacked rings" />

## Easter eggs 🥚

While the ring works, ambient _Detroit: Become Human_ moments occasionally play over it — a
deviant glitch, a flash of **rA9**, Connor's coin flip, Markus's paint sweep, Kara's guardian
light, a celebratory salvo when everything finishes, even Detroit snow. They're rare, never
interrupt a real status, and you can toggle them off with a right-click.

<img src="docs/demo-eggs.gif" width="360" alt="Easter egg montage: deviant glitch, rA9, done salvo and Detroit snow" />

<table>
<tr>
<td align="center"><img src="docs/egg-glitch.png" width="110" alt="Deviant glitch effect"/><br/><sub>Deviant glitch</sub></td>
<td align="center"><img src="docs/egg-ra9.png" width="110" alt="rA9 reveal"/><br/><sub>rA9</sub></td>
<td align="center"><img src="docs/egg-salvo.png" width="110" alt="Done celebration salvo"/><br/><sub>Done salvo</sub></td>
<td align="center"><img src="docs/egg-scan.png" width="110" alt="Preconstruction scan"/><br/><sub>Preconstruction scan</sub></td>
</tr>
<tr>
<td align="center"><img src="docs/egg-coin.png" width="110" alt="Connor coin flip"/><br/><sub>Coin flip</sub></td>
<td align="center"><img src="docs/egg-paint.png" width="110" alt="Markus paint sweep"/><br/><sub>Paint sweep</sub></td>
<td align="center"><img src="docs/egg-companion.png" width="110" alt="Kara companion light"/><br/><sub>Companion light</sub></td>
<td align="center"><img src="docs/egg-snow.png" width="110" alt="Detroit snow"/><br/><sub>Detroit snow</sub></td>
</tr>
</table>

<sub>Right-click the ring → toggle **Easter eggs**, or **Preview one now**.</sub>

## Install

**Requirements:** macOS 13+ on Apple Silicon, [Claude Code](https://github.com/anthropics/claude-code),
and the Swift toolchain (`xcode-select --install` if you don't have it). Python 3 ships with macOS.

```bash
git clone https://github.com/lhysilicon/detroit-ring.git
cd detroit-ring

# 1. compile + self-test + bundle + install the .app to ~/Applications
#    (also installs the hook emitter to ~/.claude/ring/)
./build.sh

# 2. wire Detroit Ring into your Claude Code hooks
#    (preview first — writes a staging file, your settings.json is untouched)
python3 apply_hooks.py            # dry run → settings.staging.json
python3 apply_hooks.py --apply    # applies it; backs up the original first

# 3. run at login and stay alive
./install_launchagent.sh
```

Open a new Claude Code session and the ring appears. That's it.

The app is ad-hoc signed (it's a local build), so the first launch may need a right-click → **Open**,
or **System Settings → Privacy & Security → Open Anyway**.

### How the install is wired

| Script | What it does | Touches |
|---|---|---|
| `build.sh` | Compiles the Swift app, runs the self-test, builds + signs the `.app`, copies the hook emitter | `~/Applications`, `~/.claude/ring/` |
| `apply_hooks.py` | **Additively** appends the ring hooks to your `settings.json` (existing hooks preserved; idempotent; backed up) | `~/.claude/settings.json` |
| `install_launchagent.sh` | Generates + loads a LaunchAgent so the app starts at login | `~/Library/LaunchAgents/` |

## How it works

```
Claude Code hooks ──▶ ring-emit ──▶ ~/.claude/ring/sessions/<id>.json ──▶ DetroitRing.app ──▶ 🟢
   (lifecycle)        (tiny py)        (one file per live session)         (SwiftUI ring)
```

- Each Claude Code lifecycle event (`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `Stop`,
  `Notification`, `SessionEnd`, `PostToolUseFailure`) runs **`ring-emit`**, which writes a small
  JSON state file for that session and exits immediately. Silent, no output, never blocks the agent.
- **`DetroitRing.app`** watches that directory, keeps exactly **one ring per live session**, and
  draws the capsule. The ring is a pure function of `(state, time)` — no random jitter — so an
  off-screen render is byte-identical to the live one (that's how the visuals are unit-tested).
- Headless `claude -p` calls (pipelines, automation) are detected and **suppressed**, so only the
  interactive sessions you're actually watching get a ring.

It is intentionally compact: ~2k lines of Swift plus one small Python emitter, system frameworks
only, no third-party dependencies, no background network.

## Configuration

Right-click the ring for the menu:

- **Hide all terminal windows** / **Show all terminal windows** — stash or restore your terminals
- **Easter eggs** — toggle the ambient effects on/off
- **Preview one now** — fire a random Easter egg immediately
- **Reset position** — snap the capsule back to the top-right
- **Quit**

Left-click a ring to raise its terminal window.

## Uninstall

Everything is reversible:

```bash
./install_launchagent.sh uninstall            # stop + remove the LaunchAgent
rm -rf ~/Applications/DetroitRing.app          # remove the app
rm -rf ~/.claude/ring                          # remove the emitter + state files
cp settings.json.pre-ring-bak ~/.claude/settings.json   # restore your original hooks
```

The backup `settings.json.pre-ring-bak` is the copy `apply_hooks.py --apply` saved before wiring
the hooks. (If you'd rather not do a full restore, just delete the `ring-emit` lines it added.)

## Development

```bash
swiftc -O src/Ring.swift src/AppCore.swift src/main.swift -o /tmp/dr && /tmp/dr --selftest
```

The self-test covers the state-machine reducer, display logic, session eviction, and a
determinism oracle (same time → identical pixels). `tools/inspect.swift` renders every state and
Easter egg to PNGs for visual review; `tools/test_emit.py` covers the emitter's decision logic.

## Disclaimer

This is an unofficial fan project. _Detroit: Become Human_ is a trademark of **Quantic Dream**;
this project is **not affiliated with, endorsed by, or sponsored by** Quantic Dream or Sony
Interactive Entertainment. The ring is an original recreation inspired by the game's android LED —
it ships no game assets. "Claude Code" is a product of **Anthropic**; this is a community tool and
is likewise not affiliated with Anthropic.

## License

[MIT](LICENSE) — do whatever you like. Stars and forks welcome. ⭐
