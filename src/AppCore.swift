// AppCore.swift — watches ~/.claude/ring/sessions, shows ONE LED ring PER live Claude session in a
// freely DRAGGABLE glass capsule (default top-right; dragged position is persisted and clamped to a
// visible screen so it can never strand off-screen). Per-task notifications name which window
// finished; "needs you" is left to Claude Code's own banner (the amber ring is the at-a-glance cue)
// to avoid double banners.
import SwiftUI
import AppKit
import Darwin   // kill(pid,0) / errno — instant ghost eviction when a CC process dies
import UserNotifications   // done banners that carry the app's ring icon (falls back to osascript)

// MARK: - Tunables
enum Cfg {
    static let ringDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/ring")
    static var sessionsDir: String { (ringDir as NSString).appendingPathComponent("sessions") }
    static let staleSec: Double = 14400    // full-eviction fallback (4h) for a session that died WITHOUT a
                                           // SessionEnd (crash / kill -9). Clean closes are removed promptly by
                                           // the SessionEnd→final:done path, so a long-idle standby ring survives.
    static let doneLingerSec: Double = 8   // an ENDED (final) session shows "done" this long, then clears
    static let notifyMinWorkSec: Double = 15
    static let notifyDebounceSec: Double = 8
    static let bannerConfirmSec: Double = 10   // a non-final (Stop) done must STICK this long with no resumed
                                               // work before the audible ✅ banner fires, so a mid-turn sub-stop
                                               // (CC fires Stop between tool batches, then work resumes seconds
                                               // later) never rings a false completion. The GREEN RING still
                                               // commits at RingReducer.doneGrace(3s); only the SOUND waits.
                                               // A final:done (real SessionEnd) rings immediately.
    static let doneIdleSec: Double = 180       // a finished (non-final) session's bright-green ring fades to the
                                               // calm dim-blue idle after this long with no re-engagement, so a
                                               // strip of long-finished-but-open terminals isn't a wall of green
                                               // (green = recently done; dim-blue = done & idle).
    static let workingIdleSec: Double = 900    // a non-final "working" session whose heartbeat ts has been frozen
                                               // this long (15min, pid still ALIVE) is treated as parked/stalled —
                                               // calmed to dim-blue idle instead of a perpetual bright "working"
                                               // LIE (interrupted turn / no Stop fired / hung tool). Set FAR above
                                               // the longest realistic no-tool turn (PreToolUse refreshes ts on
                                               // every tool call) so genuine work is never false-dimmed — the safe
                                               // successor to the over-eager 180s activeStale removed in b76a7af.
    static let errorClearSec: Double = 8       // a raw "error" (red distress) ring auto-clears to calm idle this
                                               // long after its ts. PostToolUseFailure is matcher-less so any benign
                                               // non-zero exit (grep no-match / test / diff --exit-code) flips red,
                                               // and the file STAYS error until the next working/done overwrites it
                                               // — observed sticking ~5min mid-work. This caps red to a brief FLASH
                                               // (active work's next-tool heartbeat usually overwrites it in 1-2s
                                               // anyway; the cap only bites when the session ended/paused at error).
    static let pollActive: Double = 0.4    // was 0.12 (8Hz fs-poll burned CPU continuously during work);
    static let pollIdle: Double = 0.4      // was 0.6: an all-idle strip then took up to 0.6s to notice a NEW
                                           // working session AND lost a beat re-scheduling 0.6→0.4 (≈1.2s felt
                                           // "laggy"). Equal to pollActive → idle→active shows within 0.4s and
                                           // the cadence switch becomes a no-op (no reschedule, no lost beat).
                                           // fs-stat of a handful of files at 0.4 vs 0.6 idle is negligible CPU.
    static let ringSize: CGFloat = 40
    static let ringSpacing: CGFloat = 8
    static let capsulePad: CGFloat = 9
    static let minimizeBarHeight: CGFloat = 22   // always-visible "minimize all terminals" tap zone (subtle)
    static let edgeMargin: CGFloat = 16
    static let maxRings = 10
    static var capsuleWidth: CGFloat { ringSize + 2 * capsulePad }
}

// MARK: - DBH easter eggs (decoration only — NEVER touches focus/state-machine/aggregation). All eggs are
// AMBIENT: the controller decides WHEN they fire (random scheduling lives there, off the render path), and each
// overlay view (Ring.swift) stays closed-form in `age` so the determinism oracle (RingCanvas) is untouched and
// the build's egg-overlay grep gate stays green. Visual constants live here as the single source of truth.
// one transient ambient overlay a ring can be playing. glitch/glitchRA9 = the centerpiece; the rest are
// character-themed "flavor" eggs (Connor's coin/scan/zen, Markus's paint, Kara's companion) + the idle glimmer.
enum AmbientKind { case glitch, glitchRA9, glimmer, coin, scan, ripple, paint, companion }

enum EasterEgg {
    static let powerOnDur: Double = 0.75   // CyberLife power-on self-test sweep — one-shot on a ring's first appearance
    // Deviant "software instability" glitch (the centerpiece): a brief RGB-split + scanline-tear shudder, then
    // the ring snaps back to its true state. Rarely it also reveals the "rA9" deviant marking.
    static let glitchDur: Double = 0.5
    static let ra9Dur: Double   = 1.7      // the rA9 reveal rides the glitch, then lingers a beat and fades
    static let glitchMinGap: Double = 45   // seconds between ambient glitches (controller picks a random gap in [min,max])
    static let glitchMaxGap: Double = 120
    static let ra9Chance: Double = 0.18    // fraction of glitches that also reveal rA9 (rare — the deep egg)
    static let salvoDur: Double = 0.95     // whole-strip "all done" green celebration salvo
    static let snowDur: Double = 4.5       // strip-wide Detroit snow drift (rare atmosphere)
    static let snowMinGap: Double = 300    // snow is rare — every ~5-12 min
    static let snowMaxGap: Double = 700
    // character-themed "flavor" eggs + their durations
    static let glimmerDur: Double = 1.3    // idle micro-glimmer (gentle standby breath/sweep)
    static let coinDur: Double = 1.0       // Connor's coin flip
    static let scanDur: Double = 1.0       // Connor's preconstruction scan
    static let rippleDur: Double = 1.3     // Connor's zen-garden ripple
    static let paintDur: Double = 0.9      // Markus's paint sweep
    static let companionDur: Double = 1.4  // Kara's companion light
    static let flavorMinGap: Double = 55   // seconds between flavor eggs (a separate, gentler track from glitch)
    static let flavorMaxGap: Double = 130
    /// Eligible for ANY ambient egg = a CALM state we won't confuse with a real attention cue. NEVER disturb a
    /// waiting(amber)/error(red) ring — those are "needs you" signals that must stay trustworthy.
    static func ambientEligible(_ s: RingState) -> Bool { s == .working || s == .idle || s == .done }
    /// The flavor eggs valid for a ring's state. Idle rings get the contemplative set (coin/ripple/glimmer + the
    /// expressive ones); active/done get the analytical/expressive set. (Glitch is scheduled separately.)
    static func flavorKinds(_ s: RingState) -> [AmbientKind] {
        switch s {
        case .idle:           return [.coin, .ripple, .glimmer, .companion, .paint, .scan]
        case .working, .done: return [.scan, .paint, .companion]
        default:              return []
        }
    }
    /// On-screen lifetime of an ambient overlay (so the view stops drawing it past its animation).
    static func dur(_ k: AmbientKind) -> Double {
        switch k {
        case .glitch, .glitchRA9: return glitchDur
        case .glimmer:   return glimmerDur
        case .coin:      return coinDur
        case .scan:      return scanDur
        case .ripple:    return rippleDur
        case .paint:     return paintDur
        case .companion: return companionDur
        }
    }
}

// MARK: - One live session's display info
struct SessionInfo: Identifiable {
    let id: String
    var state: RingState
    var project: String
    var ts: Double
    var final: Bool = false
    var prev: RingState? = nil    // state we are crossfading FROM (held for the transition window)
    var changeAt: Double = 0      // render-clock (model.start-relative) time the displayed state last changed
    var firstShownAt: Double = 0  // render-clock time this ring FIRST appeared → drives the power-on sweep (NOT in ==)
    var termProgram: String = ""  // TERM_PROGRAM of the owning terminal (click-to-focus)
    var tty: String = ""          // controlling tty of the CC process (Terminal.app exact-tab raise)
    var pid: Int32 = 0            // owning CC process pid — used to collapse superseded session_ids of ONE process
    // non-lossy attention hint the emitter stamps onto a `working` write: the most-recent waiting/error
    // episode (so the reducer can guarantee the amber/red "needs you" cue is shown once even if its poll
    // missed the raw waiting/error file). Inputs to RingReducer; NOT part of the displayed-equality check.
    var prevAttn: RingState? = nil
    var prevAttnTs: Double = 0
    // Equality drives the @Published republish: compare what is VISIBLE plus changeAt (which moves only on a
    // real state change, so it never churns per poll tick) — the constantly rewritten `ts` is ignored.
    static func == (a: SessionInfo, b: SessionInfo) -> Bool {
        a.id == b.id && a.state == b.state && a.project == b.project && a.changeAt == b.changeAt
    }
}
extension SessionInfo: Equatable {}

final class AppModel: ObservableObject {
    @Published var sessions: [SessionInfo] = []
    // hover/press feedback for the tappable rings. Single optionals (only one ring is hovered/pressed at a
    // time) → cheap to publish. Held here because this build uses bare swiftc, which lacks the SwiftUI macro
    // plugin that @State now requires; @Published property wrappers compile fine.
    @Published var hoveredID: String? = nil
    @Published var pressedID: String? = nil
    // Ambient easter eggs: the controller stamps a (kind, render-clock start) per ring when an egg fires; the
    // @Published write republishes so the ring's view picks it up and its overlay animates closed-form in `t`.
    // salvoAt is the strip-wide "all done" celebration start (render-clock; 0 = none). These are the ONLY egg
    // state — purely decorative, never read by the state machine / aggregator.
    @Published var ambient: [String: (kind: AmbientKind, at: Double)] = [:]
    @Published var salvoAt: Double = 0
    @Published var snowAt: Double = 0   // strip-wide snow start (render-clock; 0 = none, which pauses SnowLayer)
    // ambient-eggs master switch (right-click toggle), persisted across launches. Default ON.
    @Published var eggsOn: Bool = (UserDefaults.standard.object(forKey: "eggsOn") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(eggsOn, forKey: "eggsOn") }
    }
    // false while the strip panel is fully occluded (covered by an opaque window / display asleep) → each
    // RingButton pauses its TimelineView so no GPU blur frames composite for something nobody can see. Default
    // true so a never-firing occlusion signal can never wrongly freeze a visible ring.
    @Published var panelVisible = true
    let start = Date()
}

/// Is a recorded CC process still alive? kill(pid,0) probes without signaling: 0 = alive, ESRCH = dead,
/// EPERM = alive-but-not-ours (treat alive). PID-reuse can only make a dead pid look alive → that merely
/// DELAYS eviction to the staleSec timer fallback, never causes a wrong removal.
func ccProcessAlive(_ pid: Int32) -> Bool {
    if pid <= 1 { return true }                 // unknown/unsafe pid → never evict on this signal
    return kill(pid, 0) == 0 || errno == EPERM
}

/// Wall-clock epoch (sec) at which the process NOW holding `pid` started — read via sysctl KERN_PROC_PID
/// (in-process, no fork; readable across uids, unlike kill). nil if it can't be read. Sole use: PID-reuse
/// detection. Called only after ccProcessAlive(pid)==true (short-circuit), so it runs at most once per live ring.
func processStartEpoch(_ pid: Int32) -> Double? {
    if pid <= 1 { return nil }
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var kp = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    let r = sysctl(&mib, UInt32(mib.count), &kp, &size, nil, 0)
    if r != 0 || size == 0 { return nil }
    let tv = kp.kp_proc.p_starttime
    let sec = Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000.0
    return sec > 0 ? sec : nil
}

/// True when the live process at this pid started AFTER the session file's last write (+tol). The process that
/// WROTE the file existed at write time, so its start ≤ ts ALWAYS; a live pid whose start is later is therefore
/// a RECYCLED pid (a ghost), not the original session → evict its ring. Pure (tested in --selftest). A nil start
/// (sysctl failed) or unknown ts → cannot prove reuse → false (never evict a live session on a guess).
/// tol is deliberately GENEROUS (30s): the only way a GENUINE live session trips this is a forward wall-clock
/// STEP larger than tol landing in the sub-second window between fork and the session-start write (then idle, so
/// ts stays frozen) — a >30s step means someone reset the clock / a VM resumed, not normal NTP slew. A real
/// pid-reuse ghost, by contrast, starts minutes-to-hours past the dead file's frozen ts (pid wrap is far slower
/// than 30s), so the generous tol still catches it. Erring large trades a near-impossible spurious idle-evict
/// (self-heals on next write) for zero risk of dropping a live session — the safe direction.
func pidLooksReused(liveStart: Double?, fileTs: Double, tol: Double = 30) -> Bool {
    guard let s = liveStart, fileTs > 0 else { return false }
    return s > fileTs + tol
}

// MARK: - Read every live session (raw, unfiltered)
enum Aggregator {
    static func readAll(dir: String = Cfg.sessionsDir, now: Double, cleanup: Bool = true) -> [SessionInfo] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [SessionInfo] = []
        // skip dotfiles: mkstemp temp files are ".tmp-XXXX.tmp" (and any legacy ".tmp-XXXX.json"); both are
        // dot-led, whereas real session files are "<uuid>.json" (never dot-led). Excluding them stops a
        // half-written / signal-orphaned temp (which carries the real session_id) being read as a duplicate ring.
        for name in entries where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let path = (dir as NSString).appendingPathComponent(name)
            guard let data = fm.contents(atPath: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let stateStr = obj["state"] as? String,
                  let st = RingState(rawValue: stateStr) else { continue }
            let ts = (obj["ts"] as? Double) ?? 0
            let id = (obj["session_id"] as? String) ?? (name as NSString).deletingPathExtension
            let final = (obj["final"] as? Bool) ?? false
            let pid = (obj["cc_pid"] as? Int).map { Int32(truncatingIfNeeded: $0) } ?? 0
            // Ghost eviction: drop a NON-final ring whose CC process is GONE — either dead (kill(pid,0)==ESRCH)
            // OR the pid was RECYCLED by an unrelated process (its live start is after this file's last write).
            // final:done is exempt so the ✅ can linger out doneLingerSec. Short-circuit keeps processStartEpoch
            // off the hot path (runs only when the pid is alive).
            let processGone = pid > 1 && (!ccProcessAlive(pid) || pidLooksReused(liveStart: processStartEpoch(pid), fileTs: ts))
            // Eviction policy — the staleSec(4h) fallback is for a session that died WITHOUT a SessionEnd:
            //   • non-final + process gone  → evict NOW (don't wait out staleSec).
            //   • non-final + pid alive     → KEEP regardless of age. A long-idle interactive session (dim-blue
            //     standby) is alive and must keep its ring per the documented intent (Cfg.staleSec comment +
            //     DisplayLogic idle-persistence). The OLD code evicted purely on ts-age and wrongly dropped a
            //     LIVE idle ring after 4h (the strip then under-reported a running session).
            //   • non-final + pid<=1 (legacy file, no captured pid) → keep the pure-age fallback so an un-pid'd
            //     ghost still ages out (can't liveness-check it).
            //   • final:done → only the long staleSec fallback ever removes it (doneLinger does the normal drop).
            if Aggregator.shouldEvict(final: final, pid: pid, ts: ts, now: now, staleSec: Cfg.staleSec, processGone: processGone) {
                if cleanup { try? fm.removeItem(atPath: path) }; continue
            }
            let cwd = (obj["cwd"] as? String) ?? ""
            let proj = cwd.isEmpty ? "—" : (cwd as NSString).lastPathComponent
            let term = (obj["term_program"] as? String) ?? ""
            let tty = (obj["tty"] as? String) ?? ""
            // A ring tracks an INTERACTIVE CLI session a human is watching. A headless `claude -p` invocation
            // (an LLM call buried inside a pipeline/automation — e.g. a script that shells out to `claude -p`)
            // fires the same GLOBAL hooks but runs with NO controlling terminal (tty
            // empty). Those are not user terminals → don't surface a ring, else every pipeline LLM call piles on
            // a phantom "extra" ring. Interactive Terminal/iTerm/VSCode/ssh/tmux sessions always have a tty.
            // (The emitter also skips these at the source; this is the display-side guard for any that slip in.)
            if tty.isEmpty { continue }
            // non-lossy attention hint (emitter stamps the most-recent waiting/error onto a working write)
            let attn = (obj["attn_state"] as? String).flatMap { RingState(rawValue: $0) }
            let attnTs = (obj["attn_ts"] as? Double) ?? 0
            out.append(SessionInfo(id: id, state: st, project: proj, ts: ts, final: final,
                                   termProgram: term, tty: tty, pid: pid, prevAttn: attn, prevAttnTs: attnTs))
        }
        // collapse superseded session_ids of ONE process, THEN guard ForEach identity (dedup by id)
        return dedupById(collapseByPid(out))
    }
    /// Collapse files that share one cc_pid down to the FRESHEST (max ts). A single live `claude` PROCESS hosts
    /// exactly one session at a time, so two files with the same cc_pid mean that process CHANGED its session_id
    /// (`/clear` mid-work leaves the old id as a lingering final:done while the new id is already live; the
    /// activeStale downgrade that used to mask this was dropped in b76a7af). The older file is a SUPERSEDED
    /// ghost — drop it so one terminal shows one ring. Two DISTINCT live processes can never share a pid, so this
    /// can never merge two genuinely-live sessions; keeping the freshest also gives a recycled-pid ghost the boot.
    /// pid<=1 (legacy file with no captured pid) is left untouched → it falls back to the staleSec timer. Pure
    /// (tested in --selftest); preserves first-seen order of survivors.
    static func collapseByPid(_ infos: [SessionInfo]) -> [SessionInfo] {
        var bestIdx: [Int32: Int] = [:]     // pid -> index of the freshest same-pid file seen so far
        var drop = Set<Int>()               // indices superseded by a fresher file for the same pid
        for (i, s) in infos.enumerated() {
            guard s.pid > 1 else { continue }
            if let j = bestIdx[s.pid] {
                if s.ts > infos[j].ts { drop.insert(j); bestIdx[s.pid] = i } else { drop.insert(i) }
            } else { bestIdx[s.pid] = i }
        }
        return infos.enumerated().filter { !drop.contains($0.offset) }.map { $0.element }
    }
    /// Hard guard for SwiftUI ForEach's identity contract: never hand back two SessionInfo sharing an id (a
    /// duplicate Identifiable.id makes ForEach render undefined). A no-op now that temp files are filtered out,
    /// but it makes the one-ring-per-id invariant unconditional: if two files ever resolve to one id, keep the
    /// freshest (max ts) and preserve first-seen order. Pure (tested in --selftest).
    static func dedupById(_ infos: [SessionInfo]) -> [SessionInfo] {
        var best: [String: SessionInfo] = [:]
        var order: [String] = []
        for s in infos {
            if let prev = best[s.id] { if s.ts > prev.ts { best[s.id] = s } }
            else { best[s.id] = s; order.append(s.id) }
        }
        return order.map { best[$0]! }
    }
    /// When more live rings than `max` exist, keep the most-RECENTLY-first-seen `max` (the sessions you most
    /// likely just opened / are actively in) instead of the `max` OLDEST. The old code did `display.prefix(max)`
    /// on a first-seen-ASCENDING list → it kept the oldest and silently dropped the newest (most-active) ring.
    /// `firstSeen` is the controller's stable per-session first-seen clock. Survivors are returned in their
    /// INPUT order (callers pass `display` already in stable first-seen order) so a kept ring never jumps slots.
    /// Pure (tested in --selftest).
    static func capByRecency(_ display: [SessionInfo], firstSeen: [String: Double], max: Int) -> [SessionInfo] {
        guard max >= 0 else { return display }
        guard display.count > max else { return display }
        // rank by first-seen DESC (newest first); id tiebreak for determinism. Keep the top `max` ids.
        let keep = Set(display.sorted {
            (firstSeen[$0.id] ?? $0.ts, $0.id) > (firstSeen[$1.id] ?? $1.ts, $1.id)
        }.prefix(max).map { $0.id })
        return display.filter { keep.contains($0.id) }   // preserves the caller's stable first-seen order
    }
    static func removeFile(id: String) {
        let p = (Cfg.sessionsDir as NSString).appendingPathComponent(id + ".json")
        try? FileManager.default.removeItem(atPath: p)
    }
    /// Eviction decision (pure + unit-tested via --selftest). `processGone` is computed by the caller
    /// (ccProcessAlive / pidLooksReused). Policy:
    ///   • non-final + pid>1  → evict IFF the process is gone (a LIVE long-idle session keeps its ring
    ///     regardless of age — the documented standby intent; the old code aged it out wrongly after 4h).
    ///   • non-final + pid<=1 → legacy file with no captured pid: pure staleSec age fallback.
    ///   • final:done         → only the long staleSec fallback ever removes it (doneLinger does the normal drop).
    static func shouldEvict(final: Bool, pid: Int32, ts: Double, now: Double, staleSec: Double, processGone: Bool) -> Bool {
        if !final && pid > 1 { return processGone }
        return now - ts > staleSec
    }
}

// MARK: - Display decision (pure + unit-tested via --selftest) — maps a raw session state to what the
// strip should SHOW (or nil = drop it).
enum DisplayLogic {
    static func display(state st: RingState, ts: Double, now: Double, final: Bool,
                        doneAt: Double?, doneLinger: Double, doneIdleSec: Double = .infinity,
                        workingIdleSec: Double = .infinity, errorClearSec: Double = .infinity) -> RingState? {
        switch st {
        case .working:
            // A live session whose heartbeat ts has been frozen FAR longer than any realistic no-tool turn is not
            // actually working — it was interrupted (Esc → no Stop fired), parked at a prompt, or hung. Its pid is
            // alive (dead pids are already evicted by the pid-liveness check in readAll), so we don't drop the
            // ring; we calm it to the dim-blue idle standby instead of painting "actively working" forever. The
            // threshold (Cfg.workingIdleSec) is deliberately LONG — far above the longest real tool-silent stretch,
            // since the PreToolUse heartbeat refreshes ts every tool call — so this never false-dims genuine work
            // the way the old 180s activeStale downgrade did (removed in b76a7af; safe coarse successor, working-only).
            if now - ts > workingIdleSec { return .idle }
            return st
        case .waiting:
            // waiting (amber "needs you") must persist for the WHOLE wait — you may be away for hours and the cue
            // must still be there. No time-based downgrade.
            return st
        case .error:
            // red distress auto-clears to calm idle after errorClearSec so a benign non-zero exit (matcher-less
            // PostToolUseFailure) is a brief FLASH, not a multi-minute stuck-red lie. A session still actively
            // working overwrites the error file with a fresh working within seconds (so it never reaches the cap);
            // the cap only fires for a session that ended/paused at error — where calm idle is the honest read.
            if now - ts > errorClearSec { return .idle }
            return st
        case .done:
            // live finished session keeps "done" until re-engage/SessionEnd; an ENDED (final) one lingers
            // briefly so the ✅ ping is seen, then is dropped (caller removes the file).
            if final && now - (doneAt ?? now) > doneLinger { return nil }
            // a non-final (still-open) finished session fades green → calm dim-blue idle after doneIdleSec, so a
            // strip of long-finished-but-open terminals isn't a wall of green (green = recently done).
            if !final && now - (doneAt ?? now) > doneIdleSec { return .idle }
            return .done
        case .idle, .hidden:
            // standby: calm dim-blue LED for the WHOLE life of the session (cleared only by SessionEnd or
            // staleSec eviction) — never by a short idle timer, so the strip never under-reports sessions.
            return .idle
        }
    }
}

// MARK: - Per-session display TIMING reducer (pure + unit-tested via --selftest). Layers two debounces on top
// of the raw file state so the strip never shows a misleading color. Kept PURE (all time via `now`, no Date/RNG)
// so a whole event timeline can be unit-tested deterministically — the timing bugs the prior audit missed lived
// in the stateful tick() exactly because that logic was untestable.
//   (1) DONE-DEBOUNCE: CC fires Stop→done then frequently RESUMES work within milliseconds-to-seconds (an
//       internal "sub-stop" between steps). A non-final done is therefore PROVISIONAL: keep showing the prior
//       active color (blue) and only COMMIT the green done (ring + pulse + completion banner) once it has
//       survived `doneGrace` with no resumed work, or it is a real SessionEnd (final), or it predates our watch
//       (first sight = a persisted completion), or it is ALREADY committed (stay green — don't re-debounce a
//       steady done across polls, which would flicker green→blue→green on relaunch). Kills "工作中闪绿" + the
//       false "✅ 完成" mid-work banner. doneGrace is deliberately a few seconds: green is a PERSISTENT
//       "come back, it's done" cue (not time-critical), so delaying it a little to absorb multi-second
//       sub-stops is invisible, while showing it early during a sub-stop is the exact bug we're killing.
//   (2) ATTENTION-DWELL: a waiting/error episode (the amber/red "needs you" cue) is guaranteed to show for at
//       least `attnDwell`, even when the next `working` heartbeat would overwrite it before a poll could sample
//       it — driven by the non-lossy attn hint the emitter stamps onto the working file — then promptly returns
//       to blue. Replaces the old lossy emitter discard that made amber lag and STICK ("黄→蓝慢/卡").
enum RingReducer {
    static let doneGrace: Double = 3.0   // a non-final done must persist this long (no resumed work) to show green
    static let attnDwell: Double = 0.5   // min time an amber/red attention color shows before returning to blue

    struct Book {
        var seen = false                     // false until the first step — first sight commits a done immediately
        var pendingDoneSince: Double? = nil  // wall-clock when a non-final done was first observed (debounce)
        var attnHoldUntil: Double = 0        // wall-clock until which to force the attention color
        var attnState: RingState = .waiting  // which attention color to hold (waiting/error)
        var honoredAttnTs: Double = 0        // attn_ts already accounted (one episode arms the dwell once)
        var inDone = false                   // currently displaying a committed done (edge-detect for notify)
    }

    /// Returns (effective display state, committedDoneEdge). committedDoneEdge is true on the SINGLE tick we
    /// first commit a real done — the caller fires the completion banner + stamps doneAt then. Pure.
    static func step(_ b: inout Book, raw: RingState, ts: Double, final: Bool,
                     attn: RingState?, attnTs: Double, now: Double) -> (RingState, Bool) {
        let firstSight = !b.seen
        b.seen = true

        // (1) arm the attention dwell — from a raw waiting/error, or from a working that carries an as-yet
        //     unhonored attention episode (the emitter's non-lossy hint). honoredAttnTs makes one episode arm
        //     the dwell exactly once (a carried hint repeats across heartbeats until honored).
        if raw == .waiting || raw == .error {
            b.attnState = raw; b.attnHoldUntil = now + attnDwell; b.honoredAttnTs = Swift.max(b.honoredAttnTs, ts)
        } else if raw == .working, let a = attn, a == .waiting || a == .error, attnTs > b.honoredAttnTs {
            b.attnState = a; b.attnHoldUntil = now + attnDwell; b.honoredAttnTs = attnTs
        }

        // (2) done-debounce → effective state
        var eff: RingState
        if raw == .done {
            if final || firstSight || b.inDone {
                // SessionEnd (final) is a real terminal done; a done on the FIRST sight predates our watch (a
                // session that finished before this app launched) → a real persisted completion; an ALREADY-
                // committed done (b.inDone) must STAY green across subsequent polls — without this, a steady
                // persisted done re-entered the grace branch every relaunch and flickered green→blue→green for
                // doneGrace. Either way show green now, no (re-)debounce.
                b.pendingDoneSince = nil; eff = .done
            } else {
                if b.pendingDoneSince == nil { b.pendingDoneSince = now }
                // during the grace show BLUE working (not the last attention color): a done that follows a
                // waiting/error must NOT freeze on amber/red for the 3s grace then jump to green — it should
                // read "wrapping up" (blue) → green. The amber/red was already shown once via the attn-dwell
                // below; holding it through the grace was the "黄→蓝卡 / stuck amber" (and stuck-red) bug.
                eff = (now - (b.pendingDoneSince ?? now) >= doneGrace) ? .done : .working
            }
        } else {
            b.pendingDoneSince = nil   // any non-done raw resolves a pending done (work resumed → it was a sub-stop)
            eff = raw
        }

        // (3) apply the attention dwell: a (debounced) working shows the attention color until the hold expires
        if eff == .working && now < b.attnHoldUntil { eff = b.attnState }

        // (4) commit-done edge (caller fires banner + stamps doneAt once); track the last active color
        var committed = false
        if eff == .done {
            if !b.inDone { committed = true; b.inDone = true }
        } else {
            b.inDone = false
        }
        return (eff, committed)
    }
}

/// Human duration for the done notification: "45s", "3m12s".
func fmtDur(_ s: Double) -> String {
    let sec = max(0, Int(s.rounded()))
    return sec >= 60 ? "\(sec / 60)m\(sec % 60)s" : "\(sec)s"
}

// MARK: - Notifications. Prefer UserNotifications (the banner carries the app's ring icon); if the user
// hasn't authorized (or UN is unavailable), fall back to the osascript banner so a completion is NEVER
// silent. The generic-icon osascript path is the safety net, not the default.
enum Notifier {
    /// Ask once at launch so done banners can show the ring icon. Declining just means the osascript fallback.
    static func requestAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    static func post(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { s in
            switch s.authorizationStatus {
            case .authorized, .provisional:
                let c = UNMutableNotificationContent(); c.title = title; c.body = body
                center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)) { err in
                    if err != nil { postOsascript(title: title, body: body) }   // never silent, even on a rare UN error
                }
            default:
                postOsascript(title: title, body: body)
            }
        }
    }
    static func postOsascript(title: String, body: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""]
        try? p.run()
    }
}

// MARK: - System theme + accent (live) — capsule chrome harmonizes with macOS appearance & accent color.
// The ring's SEMANTIC colors (blue=working, amber=waiting …) NEVER change; only the glass tint, border and
// glow follow the system. effectiveAppearance is watched via KVO (robust for a never-key panel where SwiftUI
// @Environment(\.colorScheme) can stall) plus the distributed theme notification as a belt-and-suspenders.
// The accent arrives over DistributedNotificationCenter (it is not a SwiftUI environment change).
@MainActor final class Appearance: ObservableObject {
    @Published var isDark: Bool = Appearance.resolve()
    private var kvo: NSKeyValueObservation?
    private var token: NSObjectProtocol?
    init() {
        kvo = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        token = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }
    deinit { kvo?.invalidate(); if let t = token { DistributedNotificationCenter.default().removeObserver(t) } }
    private func refresh() { let v = Appearance.resolve(); if v != isDark { isDark = v } }
    private static func resolve() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

@MainActor final class SystemAccent: ObservableObject {
    @Published private(set) var color: Color = SystemAccent.read()
    private var token: NSObjectProtocol?
    init() {
        token = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleColorPreferencesChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.color = SystemAccent.read() } }
    }
    deinit { if let t = token { DistributedNotificationCenter.default().removeObserver(t) } }
    // NSColor(Color.accentColor) resolves the user's System Settings accent and avoids the Multicolor
    // stale-cache bug seen with direct NSColor.controlAccentColor.
    private static func read() -> Color { Color(nsColor: NSColor(Color.accentColor)) }
}

// MARK: - Click a ring → SUMMON that session's terminal window (show it + bring to front) WITHOUT touching any
// other window — every other window keeps its state. "Hide all" orderOuts every Terminal window via
// `set visible … to false` (ONE atomic command — INSTANT, no Dock genie, no serial drain). So: hide all, then
// click a ring → only that one appears (the rest were hidden and `activate` does NOT re-show hidden windows —
// verified live); a second click adds that one without hiding the first. This replaced the old Dock-`miniaturize`
// design whose fire-and-forget serial genie raced the click and popped several windows. All Terminal control is
// serialized (one queue, synchronous) so commands never interleave. First Terminal control = one-time Automation prompt.
enum Focus {
    // Funnel ALL Terminal control through one serial queue, each osascript run to completion (waitUntilExit)
    // before the next starts → a "minimize all" and a "click" can never interleave into two competing event
    // streams (the old fire-and-forget race). Off the main thread so the now-synchronous AppleScript never
    // freezes the UI; orderOut/show are instant, so serialization adds no perceptible latency.
    private static let queue = DispatchQueue(label: "com.detroitring.app.focus")

    // escape everything interpolated into AppleScript (backslash + quote, strip newlines) so a value from the
    // shell env / tty can never break out of the string literal and inject script.
    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }
    private static func run(_ script: String) {
        queue.async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            try? p.run()
            p.waitUntilExit()   // serialize: the next queued command starts only after this one finishes
        }
    }

    /// Click a ring → SUMMON that session's terminal: show its window (if hidden) and bring it to the front.
    /// It does NOT touch any other window — every other window keeps its current state (hidden ones stay hidden,
    /// shown ones stay shown). After a "hide all", clicking a ring therefore reveals exactly that one (the rest
    /// were hidden and `activate` does NOT re-show hidden windows — verified live); clicking another ring then
    /// adds it without hiding the first (cumulative). Terminal.app: target the exact tab by its tty, addressed
    /// by a STABLE `window id` specifier (a positional/loop reference goes stale once windows are toggled).
    /// Verified live on the user's real windows: hide-all → click → only that one; second click → cumulative.
    static func raise(termProgram: String, tty: String) {
        let script: String
        if termProgram == "Apple_Terminal" && !tty.isEmpty {
            let t = esc(tty)
            script = [
                "tell application \"Terminal\"",
                "set targetId to missing value",
                "repeat with w in windows",                  // find the target window's id by its tab's tty
                "repeat with tb in tabs of w",
                "if tty of tb is \"\(t)\" then",
                "set targetId to id of w",
                "set selected of tb to true",                // select the exact tab while we have it
                "exit repeat",
                "end if",
                "end repeat",
                "if targetId is not missing value then exit repeat",
                "end repeat",
                "if targetId is missing value then return",
                "set visible of (window id targetId) to true", // show ONLY this window (all others untouched)
                "set index of (window id targetId) to 1",      // bring it to the front of Terminal's windows
                "activate",                                    // foreground Terminal — won't re-show hidden siblings
                "end tell"
            ].joined(separator: "\n")
        } else if !termProgram.isEmpty {
            // non-Terminal terminals: app-level activate is the honest ceiling (can't target one window/tab).
            script = "tell application \"\(esc(appName(termProgram)))\" to activate"
        } else { return }
        run(script)
    }

    /// Hide ALL terminal windows of the terminal apps running tracked sessions. The floating ring strip itself
    /// is not a terminal window, so it stays visible. Apple_Terminal: `set visible of every window to false`
    /// (orderOut) — INSTANT and atomic (one command hides every window at once; no Dock genie, no serial
    /// drain), and a later ring click re-shows ONLY the clicked one (verified). Other terminals: System Events
    /// app-hide.
    static func minimizeAll(_ termPrograms: Set<String>) {
        let progs = termPrograms.isEmpty ? ["Apple_Terminal"] : Array(termPrograms)
        for tp in progs {
            if tp == "Apple_Terminal" {
                run("tell application \"Terminal\" to set visible of every window to false")
            } else {
                // app-level hide (AppleScript can't orderOut a single foreign window uniformly); a later raise()
                // of that app activates it and all its windows return — the honest non-Terminal ceiling.
                run("tell application \"System Events\" to set visible of process \"\(esc(appName(tp)))\" to false")
            }
        }
    }

    /// Show ALL Terminal windows again (right-click safety net for getting everything back at once).
    static func showAll() {
        run("tell application \"Terminal\"\nset visible of every window to true\nactivate\nend tell")
    }
    private static func appName(_ tp: String) -> String {
        switch tp {
        case "Apple_Terminal": return "Terminal"
        case "iTerm.app":      return "iTerm"
        case "vscode":         return "Visual Studio Code"
        case "ghostty":        return "Ghostty"
        case "WezTerm":        return "WezTerm"
        default:               return tp
        }
    }
}

// MARK: - One tappable ring with hover + press feedback (good click feel). A plain tap raises the session's
// terminal; because it uses onTapGesture (fires only on a stationary tap), a DRAG still falls through to the
// window so the capsule stays freely repositionable. Hit area is the ring circle, not the square corners.
struct RingButton: View {
    @ObservedObject var model: AppModel
    let session: SessionInfo
    let start: Date
    var body: some View {
        let hovering = model.hoveredID == session.id
        let pressed = model.pressedID == session.id
        // The TimelineView wraps ONLY the animated Canvas → each tick redraws this one small ring, never the
        // surrounding chrome/menu/handlers. Per-state fps: active states 30fps, settled idle/done 12fps.
        // pause when hidden OR the whole strip is occluded/off-screen (don't composite blur nobody can see);
        // model.start keeps running so a paused ring resumes mid-animation with no jump when un-occluded.
        return TimelineView(.animation(minimumInterval: session.state.frameInterval, paused: session.state == .hidden || !model.panelVisible)) { tl in
            let t = tl.date.timeIntervalSince(start)
            ZStack {
                TransitioningRing(state: session.state, prev: session.prev, changeAt: session.changeAt, t: t)
                // CyberLife power-on sweep — only on a ring's first appearance, time-boxed. Decorative overlay.
                let pa = t - session.firstShownAt
                if session.firstShownAt > 0 && pa >= 0 && pa < EasterEgg.powerOnDur {
                    PowerOnSweep(age: pa).allowsHitTesting(false)
                }
                // ambient egg this ring is currently playing (controller-scheduled): deviant glitch (optionally
                // revealing rA9), or an idle glimmer. Each is a pure overlay, closed-form in `age`.
                if let fire = model.ambient[session.id] {
                    let age = t - fire.at
                    if age >= 0 {
                        switch fire.kind {
                        case .glitch, .glitchRA9:
                            if age < EasterEgg.glitchDur { GlitchOverlay(age: age).allowsHitTesting(false) }
                            if fire.kind == .glitchRA9 && age < EasterEgg.ra9Dur { RA9Glyph(age: age).allowsHitTesting(false) }
                        case .glimmer:   if age < EasterEgg.glimmerDur   { IdleGlimmer(age: age).allowsHitTesting(false) }
                        case .coin:      if age < EasterEgg.coinDur      { CoinFlip(age: age).allowsHitTesting(false) }
                        case .scan:      if age < EasterEgg.scanDur      { ScanSweep(age: age).allowsHitTesting(false) }
                        case .ripple:    if age < EasterEgg.rippleDur    { ZenRipple(age: age).allowsHitTesting(false) }
                        case .paint:     if age < EasterEgg.paintDur     { PaintSweep(age: age).allowsHitTesting(false) }
                        case .companion: if age < EasterEgg.companionDur { CompanionLight(age: age).allowsHitTesting(false) }
                        }
                    }
                }
                // whole-strip "all done" celebration salvo — synchronized across rings via the shared salvoAt.
                let sa = t - model.salvoAt
                if model.salvoAt > 0 && sa >= 0 && sa < EasterEgg.salvoDur { DoneSalvo(age: sa).allowsHitTesting(false) }
            }
        }
            .frame(width: Cfg.ringSize, height: Cfg.ringSize)
            .scaleEffect(pressed ? 0.9 : (hovering ? 1.08 : 1.0))
            .brightness(hovering ? 0.05 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.62), value: hovering)
            .animation(.spring(response: 0.16, dampingFraction: 0.5), value: pressed)
            .contentShape(Circle())
            // hover tooltip = which project this ring is; in the error state, surface the DBH-flavored label
            .help(session.state == .error ? "⚠ ^Software Instability — \(session.project)" : session.project)
            .onHover { h in
                if h { model.hoveredID = session.id; NSCursor.pointingHand.set() }
                else { if model.hoveredID == session.id { model.hoveredID = nil }; NSCursor.arrow.set() }
            }
            .onTapGesture {
                Focus.raise(termProgram: session.termProgram, tty: session.tty)   // click → show this terminal window
                model.pressedID = session.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
                    if model.pressedID == session.id { model.pressedID = nil }
                }
            }
    }
}

extension Notification.Name {
    static let drResetPosition = Notification.Name("DetroitRingResetPosition")
    static let drPreviewEgg = Notification.Name("DetroitRingPreviewEgg")   // right-click → fire one ambient egg now
}

// MARK: - Big, always-visible "minimize all terminal windows" button (wide accent pill = easy tap target).
// Uses onTapGesture (proven to fire on this non-activating panel, unlike a plain Button which may need key
// focus), so a stationary tap acts while a drag still falls through to move the capsule.
struct MinimizeButton: View {
    let action: () -> Void
    let accent: Color
    var body: some View {
        VStack(spacing: 3) {
            // hairline that fades at the edges — separates the rings from the control without a hard bar
            Rectangle()
                .fill(LinearGradient(colors: [.clear, accent.opacity(0.30), .clear], startPoint: .leading, endPoint: .trailing))
                .frame(height: 0.75)
                .padding(.horizontal, 3)
            // glowing accent glyph — reads like the LED rings (neon on glass), not a heavy button
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(accent.opacity(0.92))
                .shadow(color: accent.opacity(0.55), radius: 2.5)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Cfg.minimizeBarHeight)
        .contentShape(Rectangle())   // whole bottom zone is the tap target (easy to hit)
        .help("Hide all terminal windows")
        .onTapGesture { action() }
    }
}

// MARK: - Strip-wide snow layer. Has its OWN scoped TimelineView (the chrome is built once per model change,
// never animated) and PAUSES whenever no snow is active or the panel is occluded — so it costs nothing the
// >99% of the time there's no snow, preserving the build-once-chrome perf. Closed-form SnowFall in age.
struct SnowLayer: View {
    @ObservedObject var model: AppModel
    let start: Date
    var body: some View {
        let active = model.snowAt > 0
        return TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !active || !model.panelVisible)) { tl in
            let age = tl.date.timeIntervalSince(start) - model.snowAt
            if active && age >= 0 && age < EasterEgg.snowDur { SnowFall(age: age) } else { Color.clear }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - SwiftUI: a vertical glass capsule holding one LED ring per session.
// The chrome (capsule, context menu, per-ring hover/tap) is built ONCE per model change; each ring
// self-animates via its OWN scoped TimelineView inside RingButton (per-state fps), so the animation clock
// never re-runs the whole view-graph transaction — that per-frame tree rebuild was the measured CPU hog.
struct StripView: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject var appearance: Appearance
    @EnvironmentObject var accent: SystemAccent
    var body: some View {
        // Chrome (capsule + context menu + each ring's hover/tap handlers) is built ONCE per model change —
        // NOT inside a TimelineView — so the animation clock no longer re-runs the whole view-graph
        // transaction every frame (the measured CPU hog). Each ring self-animates via its own scoped
        // TimelineView in RingButton, redrawing only its small Canvas at its own per-state fps.
        VStack(spacing: Cfg.ringSpacing) {
            ForEach(model.sessions) { s in
                RingButton(model: model, session: s, start: model.start)
            }
            // big, always-visible button → minimize ALL terminal windows. The ring strip is a floating panel
            // (not a terminal window) so it stays visible: tuck the CLIs away, keep the status light.
            MinimizeButton(action: {
                Focus.minimizeAll(Set(model.sessions.compactMap { $0.termProgram.isEmpty ? nil : $0.termProgram }))
            }, accent: accent.color)
        }
        .padding(Cfg.capsulePad)
        .background(StripView.capsule(dark: appearance.isDark, accent: accent.color))
        .overlay(SnowLayer(model: model, start: model.start))   // rare strip-wide snow (paused when none)
        .id(appearance.isDark)   // belt-and-suspenders: force a rebuild if appearance propagation lagged
        .contextMenu {           // right-click: control without the Terminal
            Button("Hide all terminal windows") {
                Focus.minimizeAll(Set(model.sessions.compactMap { $0.termProgram.isEmpty ? nil : $0.termProgram }))
            }
            Button("Show all terminal windows") { Focus.showAll() }
            Divider()
            // DBH ambient easter eggs: toggle them on/off, or fire one now to preview.
            Button(model.eggsOn ? "✓ Easter eggs (ambient effects)" : "Easter eggs (ambient effects)") { model.eggsOn.toggle() }
            Button("Preview an Easter egg") { NotificationCenter.default.post(name: .drPreviewEgg, object: nil) }
            Divider()
            Button("Reset position") { NotificationCenter.default.post(name: .drResetPosition, object: nil) }
            Button("Quit Detroit Ring (restarts at next login)") { NSApp.terminate(nil) }
        }
    }

    /// Glass capsule chrome that harmonizes with macOS appearance + accent. The material auto-adapts; only
    /// the tint, accent border and inner accent glow are themed — the rings inside keep their semantic colors.
    @ViewBuilder static func capsule(dark: Bool, accent: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: Cfg.capsuleWidth / 2, style: .continuous)
        shape
            .fill(.ultraThinMaterial)
            .overlay(shape.fill(dark ? Color(.sRGB, red: 0.03, green: 0.05, blue: 0.07, opacity: 0.30)
                                     : Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.30)))
            .overlay(shape.inset(by: 0.5).strokeBorder(accent.opacity(dark ? 0.50 : 0.62), lineWidth: 1))
            .overlay(shape.inset(by: 1.75).strokeBorder(accent.opacity(0.16), lineWidth: 2.5).blur(radius: 2))
    }
}

// MARK: - The fixed top-right, click-through strip window
@MainActor
final class StripWindow {
    let panel: NSPanel
    private var shown = false
    private var positioned = false
    private var lastCount = -1
    private let defaultsKey = "stripTopLeft"   // persisted TOP-LEFT corner (grows downward)

    init(model: AppModel, appearance: Appearance, accent: SystemAccent) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Cfg.capsuleWidth, height: Cfg.capsuleWidth),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true   // freely draggable anywhere on the capsule
        panel.ignoresMouseEvents = false           // receive drags (capsule is small + can be moved out of the way)
        panel.alphaValue = 0
        let host = NSHostingView(rootView: StripView(model: model)
            .environmentObject(appearance).environmentObject(accent))
        host.frame = panel.contentView!.bounds
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    private func savedTopLeft() -> CGPoint? {
        let d = UserDefaults.standard
        guard d.object(forKey: defaultsKey) != nil,
              let a = d.array(forKey: defaultsKey) as? [Double], a.count == 2 else { return nil }
        return CGPoint(x: a[0], y: a[1])
    }
    func saveTopLeft() {
        let f = panel.frame
        UserDefaults.standard.set([Double(f.minX), Double(f.maxY)], forKey: defaultsKey)
    }

    /// At least half of `rect` on some screen's visible area? (so a remembered position from an
    /// unplugged display can't strand the capsule off-screen).
    private func onScreen(_ rect: NSRect) -> Bool {
        for s in NSScreen.screens {
            let i = s.visibleFrame.intersection(rect)
            if i.width * i.height >= 0.5 * rect.width * rect.height { return true }
        }
        return false
    }

    /// Shift `rect` by the minimum amount so it sits FULLY inside the visibleFrame of whichever screen it most
    /// overlaps. The 50%-area `onScreen` gate alone let a capsule that grew TALLER than fits below its saved
    /// low anchor hang its bottom rings off-screen; clamping the returned frame pins them back on.
    private func clampOnScreen(_ rect: NSRect) -> NSRect {
        var best: NSScreen? = nil; var bestArea: CGFloat = -1
        for s in NSScreen.screens {
            let i = s.visibleFrame.intersection(rect); let a = i.width * i.height
            if a > bestArea { bestArea = a; best = s }
        }
        guard let vf = (best ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return rect }
        var r = rect
        if r.width  <= vf.width  { r.origin.x = min(max(r.minX, vf.minX), vf.maxX - r.width) }
        if r.height <= vf.height { r.origin.y = min(max(r.minY, vf.minY), vf.maxY - r.height) }
        return r
    }

    /// Frame for `count` rings: at the user's saved top-left if still on-screen, else default top-RIGHT
    /// of the current main screen. Height grows downward from the anchor.
    private func frameFor(count: Int) -> NSRect {
        let n = max(1, min(count, Cfg.maxRings))
        // rings + spacing + the always-visible minimize bar (its own spacing) + padding
        let h = CGFloat(n) * Cfg.ringSize + CGFloat(n - 1) * Cfg.ringSpacing
              + Cfg.ringSpacing + Cfg.minimizeBarHeight + 2 * Cfg.capsulePad
        let w = Cfg.capsuleWidth
        if let tl = savedTopLeft() {
            let cand = NSRect(x: tl.x, y: tl.y - h, width: w, height: h)
            if onScreen(cand) { return clampOnScreen(cand) }   // keep remembered spot but pin fully on-screen
        }
        if let sc = NSScreen.main ?? NSScreen.screens.first {
            let inset = max(sc.safeAreaInsets.top, NSStatusBar.system.thickness)
            let top = CGPoint(x: sc.frame.maxX - w - Cfg.edgeMargin, y: sc.frame.maxY - inset - Cfg.edgeMargin)
            return NSRect(x: top.x, y: top.y - h, width: w, height: h)
        }
        return NSRect(x: 1200, y: 700 - h, width: w, height: h)
    }

    /// Re-apply the frame ONLY when the ring count changed (or first show / forced) — never every tick,
    /// so it cannot fight an in-progress drag.
    func layout(count: Int, force: Bool = false) {
        guard force || count != lastCount || !positioned else { return }
        // Don't re-frame mid-drag: if a mouse button is held (the user is dragging the capsule), a setFrame
        // would snap its height/origin under the cursor. Defer — lastCount stays stale so the next tick after
        // release re-applies. `force` paths (revalidate / reset-position) are user-initiated, never mid-drag.
        if !force && NSEvent.pressedMouseButtons != 0 { return }
        lastCount = count; positioned = true
        panel.setFrame(frameFor(count: count), display: true)
    }

    /// Re-validate placement after a display change (re-home if the saved spot went off-screen).
    func revalidate() { layout(count: max(1, lastCount), force: true) }

    /// Forget the saved spot and re-home to the default top-right (right-click → Reset Position).
    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        positioned = false
        layout(count: max(1, lastCount), force: true)
    }

    func show(count: Int) {
        layout(count: count)
        guard !shown else { return }
        shown = true
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.3; panel.animator().alphaValue = 1 }
    }

    func hide() {
        guard shown else { return }
        shown = false
        NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.45; panel.animator().alphaValue = 0 },
            completionHandler: { [weak self] in
                MainActor.assumeIsolated { guard let self = self, self.shown == false else { return }; self.panel.orderOut(nil) }
            })
    }
}

// MARK: - Controller: poll → per-session display + notifications → drive the strip
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    let appearance = Appearance()     // live light/dark — retained for the app lifetime so its KVO survives
    let accent = SystemAccent()       // live system accent — retained so its notification observer survives
    var window: StripWindow!
    var timer: Timer?

    // per-session bookkeeping
    var book: [String: RingReducer.Book] = [:]   // the pure reducer's per-session timing state (done-debounce, attn-dwell)
    var effState: [String: RingState] = [:]      // last EFFECTIVE (debounced) state — drives workAccum transitions
    var firstSeen: [String: Double] = [:]    // stable sort key (NOT the churning ts)
    var pidFirstSeen: [Int32: Double] = [:]  // earliest first-seen per cc_pid → a /clear (new id, same pid) inherits its slot
    var pidLastSeen: [Int32: Double] = [:]   // last tick a cc_pid had a live session → prune pidFirstSeen only after a grace
    var workStart: [String: Double] = [:]
    var workAccum: [String: Double] = [:]    // working seconds this span, EXCLUDING waiting time
    var armed: [String: Bool] = [:]
    var doneAt: [String: Double] = [:]
    var lastNotify: [String: Double] = [:]
    var prevDisplay: [String: RingState] = [:]   // last DISPLAYED state (detect change → stamp changeAt)
    var transFrom: [String: RingState] = [:]     // state being crossfaded FROM (held during the transition)
    var changedAt: [String: Double] = [:]        // render-clock time the displayed state last changed
    var firstShownRender: [String: Double] = [:] // render-clock time a ring first became visible (power-on sweep)
    // ambient-egg scheduling (wall-clock; lazily seeded on first tick). Random WHEN is decided HERE, off the
    // render path — the overlays themselves stay closed-form in age, so the determinism oracle is untouched.
    var nextGlitchAt: Double = 0                 // the centerpiece deviant-glitch track
    var nextFlavorAt: Double = 0                 // the gentler character-flavor track (coin/scan/zen/paint/companion/glimmer)
    var nextSnowAt: Double = 0                   // rare strip-wide snow track
    var snowStartedWall: Double = 0              // wall-clock the current snow began → reset model.snowAt after the drift
    var wasAllDone = false                       // edge-detect the whole-strip "all done" celebration salvo

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = StripWindow(model: model, appearance: appearance, accent: accent)
        window.panel.delegate = self
        // re-home the capsule if a display change leaves its saved spot off-screen
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.window.revalidate() }
        }
        // right-click → Reset Position
        NotificationCenter.default.addObserver(forName: .drResetPosition, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.window.resetPosition() }
        }
        // right-click → preview one ambient easter egg right now
        NotificationCenter.default.addObserver(forName: .drPreviewEgg, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.firePreviewEgg(now: Date().timeIntervalSince1970) }
        }
        // Heal the occlusion-pause optimization (windowDidChangeOcclusionState) against a DROPPED wake event.
        // On display/system wake the panel is definitely on-screen again, so force-resume animation. We do NOT
        // re-derive from panel.occlusionState here: if the wake .visible event was dropped, occlusionState
        // itself is stale-false, so re-reading it would re-freeze. Forcing true is the safe direction — a
        // genuine later occlusion change re-pauses via the delegate if something actually covers the panel.
        for n in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.model.panelVisible = true }
            }
        }
        Notifier.requestAuth()   // one-time prompt so done banners can carry the ring icon
        scheduleTimer(Cfg.pollIdle)
        tick()
    }

    func windowDidMove(_ notification: Notification) { window.saveTopLeft() }
    // Pause ring animation when the panel is fully occluded (an opaque window covers the corner capsule) or the
    // display sleeps — occlusionState loses .visible. Saves the per-frame GPU blur cost while nothing is seen.
    // Inert-but-harmless if this borderless all-Spaces statusBar panel never reports occlusion (stays visible).
    func windowDidChangeOcclusionState(_ notification: Notification) {
        model.panelVisible = window.panel.occlusionState.contains(.visible)
    }

    func scheduleTimer(_ interval: Double) {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func notify(_ id: String, kind: String, now: Double, body: String) {
        let key = id + ":" + kind
        if now - (lastNotify[key] ?? 0) < Cfg.notifyDebounceSec { return }
        lastNotify[key] = now
        Notifier.post(title: "Detroit Ring", body: body)
    }

    /// Fire one deviant-glitch egg now on a random eligible (CALM: working/idle/done) ring — the scheduled
    /// centerpiece. Never a waiting/error ring, so a real "needs you" cue is never masked by a playful glitch.
    func fireAmbientGlitch(now: Double) {
        let renderNow = now - model.start.timeIntervalSince1970
        guard let pick = model.sessions.filter({ EasterEgg.ambientEligible($0.state) }).randomElement() else { return }
        let ra9 = Double.random(in: 0..<1) < EasterEgg.ra9Chance
        model.ambient[pick.id] = (kind: ra9 ? .glitchRA9 : .glitch, at: renderNow)
    }

    /// Fire one character-flavor egg (coin/scan/zen/paint/companion/glimmer) on a random eligible ring, choosing
    /// a kind suited to that ring's state. Calm rings only — a real waiting/error cue is never disturbed.
    func fireFlavorEgg(now: Double) {
        let renderNow = now - model.start.timeIntervalSince1970
        guard let pick = model.sessions.filter({ EasterEgg.ambientEligible($0.state) }).randomElement(),
              let kind = EasterEgg.flavorKinds(pick.state).randomElement() else { return }
        model.ambient[pick.id] = (kind: kind, at: renderNow)
    }

    /// Start a strip-wide snow drift (only when there are rings to snow over). snowStartedWall lets tick() reset
    /// model.snowAt after the drift so the SnowLayer's TimelineView pauses again (no idle cost).
    func fireSnow(now: Double) {
        guard !model.sessions.isEmpty else { return }
        model.snowAt = now - model.start.timeIntervalSince1970
        snowStartedWall = now
    }

    /// Right-click "preview" — fire a RANDOM egg (including the rare rA9, or sometimes the strip-wide snow) so the
    /// user can sample any of them on demand. Relaxes to any ring if none happen to be in a calm state.
    func firePreviewEgg(now: Double) {
        if Double.random(in: 0..<1) < 0.2 { fireSnow(now: now); return }   // sometimes preview the strip-wide snow
        let renderNow = now - model.start.timeIntervalSince1970
        guard let pick = model.sessions.filter({ EasterEgg.ambientEligible($0.state) }).randomElement()
              ?? model.sessions.randomElement() else { return }
        let all: [AmbientKind] = [.glitch, .glitchRA9, .coin, .scan, .ripple, .paint, .companion, .glimmer]
        model.ambient[pick.id] = (kind: all.randomElement()!, at: renderNow)
    }

    func tick() {
        let now = Date().timeIntervalSince1970
        let all = Aggregator.readAll(now: now)
        let liveIDs = Set(all.map { $0.id })

        // forget bookkeeping for sessions that ended (incl. reducer book / firstSeen / workAccum / notify keys)
        for k in Array(effState.keys) where !liveIDs.contains(k) {
            effState[k] = nil; book[k] = nil; firstSeen[k] = nil; workStart[k] = nil; workAccum[k] = nil
            armed[k] = nil; doneAt[k] = nil
            prevDisplay[k] = nil; transFrom[k] = nil; changedAt[k] = nil; firstShownRender[k] = nil
            lastNotify[k + ":waiting"] = nil; lastNotify[k + ":done"] = nil
            if model.ambient[k] != nil { model.ambient[k] = nil }   // guard avoids a spurious @Published republish
        }
        // prune pid→first-seen, but only after a GRACE since the pid was last live. A /clear ends the old
        // session and starts a new one with the SAME pid ~0.5-1s later; pruning the instant the pid has no live
        // session (poll 0.4s < that gap) would wipe the slot before the new id appears, so the ring would still
        // jump. A genuine pid RECYCLE (an unrelated new process reusing the number) takes minutes-to-hours, so a
        // 60s grace cleanly keeps the /clear slot while still dropping a truly-departed pid's stale entry.
        let livePids = Set(all.map { $0.pid }.filter { $0 > 1 })
        for p in livePids { pidLastSeen[p] = now }
        for p in Array(pidFirstSeen.keys) where !livePids.contains(p) && now - (pidLastSeen[p] ?? 0) > 60 {
            pidFirstSeen[p] = nil; pidLastSeen[p] = nil
        }

        var display: [SessionInfo] = []
        var anyActive = false
        // STABLE order: by first-seen time (a session keeps its slot for its whole life), then id.
        for s in all.sorted(by: { (firstSeen[$0.id] ?? $0.ts, $0.id) < (firstSeen[$1.id] ?? $1.ts, $1.id) }) {
            let id = s.id
            // Stable slot across /clear: a brand-new id inherits the EARLIEST first-seen of its cc_pid, so a
            // /clear (same process, new session_id) keeps the terminal's ring in place instead of jumping to the
            // bottom of the strip (or being the one dropped by the cap). pidFirstSeen is pruned above when a pid
            // has no live session, so this only ever inherits from a genuinely-superseded same-process session.
            if firstSeen[id] == nil {
                let fs = (s.pid > 1 ? pidFirstSeen[s.pid] : nil) ?? now
                firstSeen[id] = fs
                if s.pid > 1 { pidFirstSeen[s.pid] = Swift.min(pidFirstSeen[s.pid] ?? fs, fs) }
            }

            // Pure timing reducer: raw file state → effective (debounced) display state + a commit-done edge.
            // Debounces the spurious mid-work Stop→done (no green flicker / no false banner) and guarantees the
            // amber/red attention cue is shown once then returns to blue (no lag / no stick).
            var bk = book[id] ?? RingReducer.Book()
            let (eff, committedDone) = RingReducer.step(&bk, raw: s.state, ts: s.ts, final: s.final,
                                                        attn: s.prevAttn, attnTs: s.prevAttnTs, now: now)
            book[id] = bk

            // accumulate REAL work time off the EFFECTIVE state (a debounce-suppressed sub-stop done stays
            // "working", so the turn timer is NOT reset by a spurious mid-work stop), EXCLUDING waiting time.
            let prevEff = effState[id]
            if prevEff == .working && eff != .working { workAccum[id, default: 0] += now - (workStart[id] ?? now) }
            if eff == .working && prevEff != .working {
                if !(armed[id] ?? false) { armed[id] = true; workAccum[id] = 0 }
                workStart[id] = now
            }
            // stamp the green-commit time, but do NOT ring the audible ✅ here: a non-final (Stop) done commits
            // green after just doneGrace(3s) and CC fires Stop MID-turn, so ringing now would false-ring on a
            // sub-stop. The sound is deferred to the confirmed-completion check below.
            if committedDone { doneAt[id] = now }
            // CONFIRMED-completion banner (decoupled from the green ring): ring the ✅ at most once per turn when
            // the done is FINAL (real SessionEnd) OR has STUCK for bannerConfirmSec with no resumed work — so a
            // mid-turn sub-stop (done → working seconds later, which flips eff off .done and skips this) never
            // rings. Duration is de-inflated by doneGrace (the grace window is held as work, over-counting it).
            if eff == .done && (armed[id] ?? false) {
                if s.final || now - (doneAt[id] ?? now) >= Cfg.bannerConfirmSec {
                    let realWorked = max(0, (workAccum[id] ?? 0) - RingReducer.doneGrace)
                    if realWorked >= Cfg.notifyMinWorkSec {
                        notify(id, kind: "done", now: now, body: "✅ \(s.project) done · \(fmtDur(realWorked))")
                    }
                    armed[id] = false; workAccum[id] = 0   // fired (or below threshold) → ring at most once per turn
                }
            }
            effState[id] = eff
            // NOTE: no "waiting" banner — Claude Code already shows its own permission banner; the
            // amber ring is the at-a-glance cue (avoids a duplicate OS notification).

            // map the effective state to what to SHOW (idle persistence / final-done linger / drop)
            let disp = DisplayLogic.display(state: eff, ts: s.ts, now: now, final: s.final,
                                            doneAt: doneAt[id], doneLinger: Cfg.doneLingerSec, doneIdleSec: Cfg.doneIdleSec,
                                            workingIdleSec: Cfg.workingIdleSec, errorClearSec: Cfg.errorClearSec)
            if disp == nil && eff == .done { Aggregator.removeFile(id: id) }   // final-done past linger → clear file
            // drive poll cadence off the DISPLAYED state (what's actually animating)
            if disp == .working || disp == .waiting || disp == .error { anyActive = true }
            if let d = disp {
                let renderNow = now - model.start.timeIntervalSince1970   // same clock as StripView's t
                if firstShownRender[id] == nil { firstShownRender[id] = renderNow }   // stamp once → power-on sweep plays once
                if prevDisplay[id] != d {                 // displayed state changed → begin a crossfade
                    // First-ever sight of a session that is ALREADY .done (app relaunch / login auto-start while
                    // a finished session sits at its persisted done ring) → back-date changeAt past the pulse +
                    // fade windows so the green "just completed!" DonePulse does NOT replay for a turn that
                    // finished before this launch. A real working→done transition seen live keeps renderNow so
                    // its pulse plays once. (prev==nil already suppresses the crossfade in either case.)
                    let firstSight = prevDisplay[id] == nil
                    transFrom[id] = prevDisplay[id]
                    changedAt[id] = (firstSight && d == .done) ? renderNow - Trans.pulseDur - 0.1 : renderNow
                    prevDisplay[id] = d
                }
                display.append(SessionInfo(id: id, state: d, project: s.project, ts: s.ts, final: s.final,
                                           prev: transFrom[id], changeAt: changedAt[id] ?? renderNow,
                                           firstShownAt: firstShownRender[id] ?? renderNow,
                                           termProgram: s.termProgram, tty: s.tty))
            }
        }

        // cap to maxRings BEFORE publishing so the rendered VStack and the panel frame (sized by frameFor →
        // min(count, maxRings)) stay in lockstep — idle-persistence makes 11+ long-lived rings reachable, and
        // without this the overflow rings clip outside the capsule. Keep the NEWEST maxRings (the sessions you
        // just opened / are working in), not the oldest — `display` is first-seen-ASC so a blind prefix() kept
        // the wrong ones and dropped the ring you most likely care about.
        let shown = Aggregator.capByRecency(display, firstSeen: firstSeen, max: Cfg.maxRings)
        if shown != model.sessions { model.sessions = shown }
        if shown.isEmpty { window.hide() } else { window.show(count: shown.count) }

        // ------- ambient easter eggs: decide WHEN here (time/RNG, off the render path); the overlays stay
        // closed-form in age so the determinism oracle is untouched. Rare + brief + only on CALM rings. -------
        if model.eggsOn {
            if nextGlitchAt == 0 { nextGlitchAt = now + Double.random(in: 20...45) }    // first glitch soon-ish
            if nextFlavorAt == 0 { nextFlavorAt = now + Double.random(in: 35...80) }
            if now >= nextGlitchAt {
                fireAmbientGlitch(now: now)
                nextGlitchAt = now + Double.random(in: EasterEgg.glitchMinGap...EasterEgg.glitchMaxGap)
            }
            if now >= nextFlavorAt {
                fireFlavorEgg(now: now)
                nextFlavorAt = now + Double.random(in: EasterEgg.flavorMinGap...EasterEgg.flavorMaxGap)
            }
            if nextSnowAt == 0 { nextSnowAt = now + Double.random(in: 150...360) }     // first snow a few min in
            if now >= nextSnowAt {
                fireSnow(now: now)
                nextSnowAt = now + Double.random(in: EasterEgg.snowMinGap...EasterEgg.snowMaxGap)
            }
            // whole-strip "all done" celebration — edge-triggered when EVERY displayed ring is .done (≥2 rings, so
            // a lone session finishing — which already has its own done-pulse + banner — doesn't salvo).
            let allDone = model.sessions.count >= 2 && model.sessions.allSatisfy { $0.state == .done }
            if allDone && !wasAllDone { model.salvoAt = now - model.start.timeIntervalSince1970 }
            wasAllDone = allDone
        } else {
            wasAllDone = false   // disabling clears the edge so re-enabling won't instantly salvo an all-done strip
        }
        // stop snow after its drift (or immediately if eggs were toggled off mid-drift) → resets model.snowAt so
        // SnowLayer's TimelineView pauses again, costing nothing the rest of the time. Runs regardless of eggsOn.
        if model.snowAt > 0 && (!model.eggsOn || now - snowStartedWall > EasterEgg.snowDur + 0.5) { model.snowAt = 0 }

        let want = anyActive ? Cfg.pollActive : Cfg.pollIdle
        if let t = timer, abs(t.timeInterval - want) > 0.01 { scheduleTimer(want) }
    }
}
