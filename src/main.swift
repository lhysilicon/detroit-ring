// main.swift — entry point. Default: run the menubar-less agent app. `--probe`: print the
// aggregated ring state for the current sessions dir and exit (headless logic check).
import SwiftUI
import AppKit

if CommandLine.arguments.contains("--probe") {
    let now = Date().timeIntervalSince1970
    let all = Aggregator.readAll(now: now, cleanup: false)   // read-only probe: never mutate session files
    print("sessions=\(all.count): " + all.map { "\($0.project):\($0.state.rawValue)" }.joined(separator: ", "))
    exit(0)
}

if CommandLine.arguments.contains("--selftest") {
    // Pure assertions on the display decision (no files, no UI). Verifies idle-persistence, that stale
    // active states are NOT downgraded (pid-liveness handles ghosts), done linger, and pid-liveness — so a
    // regression is caught programmatically, not by eyeball.
    let now = 1_000_000.0
    var fail = 0
    func check(_ name: String, _ got: RingState?, _ want: RingState?) {
        if got == want { print("ok   \(name) -> \(got.map { $0.rawValue } ?? "drop")") }
        else { print("FAIL \(name): got \(got.map { $0.rawValue } ?? "drop"), want \(want.map { $0.rawValue } ?? "drop")"); fail += 1 }
    }
    // local wrapper (NOT `let D = DisplayLogic.display`: a function VALUE drops default args, which would break
    // the short calls below now that display() has trailing doneIdleSec + workingIdleSec params). Keeps defaults.
    func D(_ st: RingState, _ ts: Double, _ now: Double, _ final: Bool, _ doneAt: Double?, _ doneLinger: Double, _ doneIdleSec: Double = .infinity, _ workingIdleSec: Double = .infinity, _ errorClearSec: Double = .infinity) -> RingState? {
        DisplayLogic.display(state: st, ts: ts, now: now, final: final, doneAt: doneAt, doneLinger: doneLinger, doneIdleSec: doneIdleSec, workingIdleSec: workingIdleSec, errorClearSec: errorClearSec)
    }
    // idle PERSISTS regardless of how old it is (was: dropped after 45s)
    check("idle fresh",      D(.idle, now,        now, false, nil, 8), .idle)
    check("idle 10min old",  D(.idle, now - 600,  now, false, nil, 8), .idle)
    check("idle 3h old",     D(.idle, now - 10800,now, false, nil, 8), .idle)
    // fresh active shows its real state
    check("working fresh",   D(.working, now - 5, now, false, nil, 8), .working)
    check("waiting fresh",   D(.waiting, now - 5, now, false, nil, 8), .waiting)
    // with the default (workingIdleSec=∞) stale active is NOT downgraded here — crashed sessions are evicted by
    // pid-liveness upstream, not by this layer.
    check("working stale",   D(.working, now - 300, now, false, nil, 8), .working)
    check("error stale",     D(.error,   now - 300, now, false, nil, 8), .error)
    // BUT a "working" ring whose ts is frozen past workingIdleSec (live pid) calms to idle — not a perpetual
    // "working" lie (interrupted/parked/hung session). Only working is downgraded; waiting/error persist.
    check("working stalled→idle",   D(.working, now - 1000, now, false, nil, 8, .infinity, 900), .idle)
    check("working within thresh",  D(.working, now - 300,  now, false, nil, 8, .infinity, 900), .working)
    check("working at thresh edge", D(.working, now - 900,  now, false, nil, 8, .infinity, 900), .working)
    check("waiting not downgraded", D(.waiting, now - 1000, now, false, nil, 8, .infinity, 900), .waiting)
    check("error not downgraded",   D(.error,   now - 1000, now, false, nil, 8, .infinity, 900), .error)
    // a raw error (red distress) auto-clears to calm idle after errorClearSec — brief flash, not multi-min stuck-red.
    // waiting is NEVER capped (it must persist for the whole wait); only error and working get a time cap.
    check("error stale→idle",       D(.error,   now - 20, now, false, nil, 8, .infinity, .infinity, 8), .idle)
    check("error within thresh",    D(.error,   now - 3,  now, false, nil, 8, .infinity, .infinity, 8), .error)
    check("waiting not error-capped",D(.waiting, now - 20, now, false, nil, 8, .infinity, .infinity, 8), .waiting)
    // INTEGRATION: mirror the LIVE tick's raw→reducer→display chain with the PRODUCTION Cfg.workingIdleSec, so a
    // stale "working" session (live pid, frozen heartbeat) actually renders idle end-to-end — not just in display()
    // in isolation. (`--probe` prints RAW aggregated state and intentionally skips display(), so it cannot observe
    // this; this assertion is the real end-to-end oracle for the stuck-"working"-ghost fix.)
    func tickDisplay(_ raw: RingState, _ ts: Double, _ now: Double, _ final: Bool) -> RingState? {
        var bk = RingReducer.Book()
        let (eff, _) = RingReducer.step(&bk, raw: raw, ts: ts, final: final, attn: nil, attnTs: 0, now: now)
        return DisplayLogic.display(state: eff, ts: ts, now: now, final: final,
                                    doneAt: nil, doneLinger: Cfg.doneLingerSec, doneIdleSec: Cfg.doneIdleSec,
                                    workingIdleSec: Cfg.workingIdleSec, errorClearSec: Cfg.errorClearSec)
    }
    check("tick stale working→idle",   tickDisplay(.working, now - (Cfg.workingIdleSec + 100), now, false), .idle)
    check("tick fresh working→working", tickDisplay(.working, now - 100, now, false), .working)
    check("tick stale waiting persists", tickDisplay(.waiting, now - (Cfg.workingIdleSec + 100), now, false), .waiting)
    check("tick stale error→idle",     tickDisplay(.error, now - (Cfg.errorClearSec + 5), now, false), .idle)
    check("tick fresh error→error",    tickDisplay(.error, now - 1, now, false), .error)
    // done: live finished persists; final lingers then drops
    check("done live",       D(.done, now, now,      false, now,        8), .done)
    check("done final fresh",D(.done, now, now,      true,  now,        8), .done)
    check("done final old",  D(.done, now, now,      true,  now - 20,   8), nil)
    // non-final done fades green → dim-blue idle after doneIdleSec (the "wall of green" decay); before it, green
    check("done idle fresh green",  D(.done, now, now, false, now,       8, 180), .done)
    check("done idle 1min green",   D(.done, now, now, false, now - 60,  8, 180), .done)
    check("done idle 4min → idle",  D(.done, now, now, false, now - 240, 8, 180), .idle)
    // pid liveness (ccProcessAlive): self alive, pid<=1 skipped-alive, an absurd pid dead
    func checkB(_ name: String, _ got: Bool, _ want: Bool) {
        if got == want { print("ok   \(name) -> \(got)") } else { print("FAIL \(name): got \(got), want \(want)"); fail += 1 }
    }
    checkB("alive self",   ccProcessAlive(getpid()), true)
    checkB("alive pid<=1", ccProcessAlive(1),        true)
    checkB("dead big pid", ccProcessAlive(2_000_000_000), false)
    // pid-reuse detection (pure): the writer's start ≤ its last write(ts), so a live start AFTER ts = a
    // recycled pid (a ghost), while an unknown start / unknown ts must never flag a live session.
    checkB("reuse start>ts",   pidLooksReused(liveStart: now + 100, fileTs: now), true)
    checkB("reuse start<ts",   pidLooksReused(liveStart: now - 100, fileTs: now), false)
    checkB("reuse within tol", pidLooksReused(liveStart: now + 1,   fileTs: now), false)
    checkB("reuse start nil",  pidLooksReused(liveStart: nil,       fileTs: now), false)
    checkB("reuse ts unknown", pidLooksReused(liveStart: now + 100, fileTs: 0),   false)
    // end-to-end: this live process must NOT look reused vs a file written now (its real start ≤ now)
    checkB("self not reused",  pidLooksReused(liveStart: processStartEpoch(getpid()), fileTs: Date().timeIntervalSince1970), false)
    // dedup by id (ForEach identity guard): collapse same id keeping the freshest, preserve distinct-id order
    let dd = Aggregator.dedupById([
        SessionInfo(id: "a", state: .working, project: "p", ts: 10),
        SessionInfo(id: "a", state: .done,    project: "p", ts: 20),
        SessionInfo(id: "b", state: .idle,    project: "p", ts: 5),
    ])
    checkB("dedup collapses",  dd.count == 2, true)
    checkB("dedup freshest",   dd.first(where: { $0.id == "a" })?.state == .done, true)
    checkB("dedup order",      dd.map { $0.id } == ["a", "b"], true)
    // collapse same live cc_pid (one process changed session_id via /clear) → drop the superseded id, keep
    // the freshest; distinct pids untouched; pid<=1 untouched; survivor order preserved. (the "多一个" fix)
    let cp = Aggregator.collapseByPid([
        SessionInfo(id: "old",   state: .done,    project: "p", ts: 10, pid: 555),  // superseded final:done
        SessionInfo(id: "new",   state: .working, project: "p", ts: 20, pid: 555),  // same process, current id
        SessionInfo(id: "other", state: .idle,    project: "q", ts: 15, pid: 777),  // a DIFFERENT process
    ])
    checkB("collapse same-pid count",   cp.count == 2, true)
    checkB("collapse keeps freshest",   cp.contains { $0.id == "new" } && !cp.contains { $0.id == "old" }, true)
    checkB("collapse keeps distinct",   cp.contains { $0.id == "other" }, true)
    checkB("collapse pid<=1 untouched", Aggregator.collapseByPid([
        SessionInfo(id: "a", state: .idle, project: "p", ts: 1, pid: 0),
        SessionInfo(id: "b", state: .idle, project: "p", ts: 2, pid: 0)]).count == 2, true)
    checkB("collapse order preserved",  Aggregator.collapseByPid([
        SessionInfo(id: "x", state: .idle, project: "p", ts: 1, pid: 9),
        SessionInfo(id: "y", state: .idle, project: "p", ts: 2, pid: 8)]).map { $0.id } == ["x", "y"], true)
    // readAll INTEGRATION — exercises the WHOLE filter pipeline + ORDER against a real temp directory:
    // dotfile-skip (line 113) → staleSec evict (120) → pid-liveness/reuse evict (135-139) → tty-empty drop
    // (148) → collapseByPid → dedupById (152). Previously ZERO coverage (selftest only unit-tested the pure
    // helpers), so a regression inside readAll's body — e.g. dropping the tty guard (the '多一个圆环' root-cause
    // fix) or reordering collapse/dedup — shipped with SELFTEST PASS. cc_pid=0 skips the pid-liveness arm
    // (pid>1 gate) so the OTHER filters are tested in isolation; the collapse pair uses getpid() (alive, not
    // reused) so it survives liveness and is merged purely by pid.
    do {
        let fm = FileManager.default
        let tmp = NSTemporaryDirectory() + "dr-selftest-\(getpid())"
        try? fm.removeItem(atPath: tmp)
        try? fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let nowR = Date().timeIntervalSince1970
        let selfPid = Int(getpid())
        func wr(_ name: String, _ obj: [String: Any]) {
            if let d = try? JSONSerialization.data(withJSONObject: obj) { try? d.write(to: URL(fileURLWithPath: tmp + "/" + name)) }
        }
        wr("aaa.json",    ["state": "working", "ts": nowR,                       "session_id": "aaa",   "cwd": "/x", "cc_pid": 0,       "tty": "/dev/ttys001"]) // valid → kept
        wr("bbb.json",    ["state": "working", "ts": nowR,                       "session_id": "bbb",   "cwd": "/y", "cc_pid": 0,       "tty": ""])             // empty tty → drop
        wr(".tmp-x.json", ["state": "working", "ts": nowR,                       "session_id": "zzz",   "cwd": "/z", "cc_pid": 0,       "tty": "/dev/ttys008"]) // dotfile → skip
        wr("stale.json",  ["state": "working", "ts": nowR - Cfg.staleSec - 100,  "session_id": "stale", "cwd": "/s", "cc_pid": 0,       "tty": "/dev/ttys009"]) // stale → drop
        wr("p1.json",     ["state": "done",    "ts": nowR - 5,                   "session_id": "p1",    "cwd": "/p", "cc_pid": selfPid, "tty": "/dev/ttys002", "final": false]) // same pid, older → collapsed
        wr("p2.json",     ["state": "working", "ts": nowR,                       "session_id": "p2",    "cwd": "/p", "cc_pid": selfPid, "tty": "/dev/ttys002"]) // same pid, fresher → kept
        wr("dupA.json",   ["state": "working", "ts": nowR - 3,                   "session_id": "dup",   "cwd": "/d", "cc_pid": 0,       "tty": "/dev/ttys003"]) // same id, older → deduped
        wr("dupB.json",   ["state": "idle",    "ts": nowR,                       "session_id": "dup",   "cwd": "/d", "cc_pid": 0,       "tty": "/dev/ttys003"]) // same id, fresher → kept
        let got = Aggregator.readAll(dir: tmp, now: nowR, cleanup: false)
        let ids = Set(got.map { $0.id })
        checkB("readAll keeps valid",     ids.contains("aaa"), true)
        checkB("readAll drops empty-tty", !ids.contains("bbb"), true)
        checkB("readAll skips dotfile",   !ids.contains("zzz"), true)
        checkB("readAll drops stale",     !ids.contains("stale"), true)
        checkB("readAll collapses pid",   ids.contains("p2") && !ids.contains("p1"), true)
        checkB("readAll dedups id",       got.filter { $0.id == "dup" }.count == 1, true)
        checkB("readAll dedup freshest",  got.first(where: { $0.id == "dup" })?.state == .idle, true)
        checkB("readAll total count",     got.count == 3, true)   // aaa, p2, dup
        try? fm.removeItem(atPath: tmp)
    }
    // capByRecency: over the cap, keep the NEWEST-first-seen (most-active), drop the OLDEST; preserve the
    // caller's stable order among survivors; no-op when at/under the cap.
    let capIn = [SessionInfo(id: "old1", state: .idle, project: "p", ts: 1),
                 SessionInfo(id: "old2", state: .idle, project: "p", ts: 2),
                 SessionInfo(id: "new1", state: .working, project: "p", ts: 3)]
    let capFS = ["old1": 100.0, "old2": 200.0, "new1": 300.0]
    let capped = Aggregator.capByRecency(capIn, firstSeen: capFS, max: 2)
    checkB("cap keeps newest count", capped.count == 2, true)
    checkB("cap drops oldest",       !capped.contains { $0.id == "old1" }, true)
    checkB("cap keeps the rest",     capped.contains { $0.id == "old2" } && capped.contains { $0.id == "new1" }, true)
    checkB("cap preserves order",    capped.map { $0.id } == ["old2", "new1"], true)
    checkB("cap noop under max",     Aggregator.capByRecency(capIn, firstSeen: capFS, max: 5).count == 3, true)
    checkB("cap max=0 empties",      Aggregator.capByRecency(capIn, firstSeen: capFS, max: 0).isEmpty, true)
    // firstSeen-missing → the `?? $0.ts` fallback ranks by ts DESC (new1 ts=3 kept, old1 ts=1 dropped at max=2).
    let capFB = Aggregator.capByRecency(capIn, firstSeen: [:], max: 2)
    checkB("cap firstSeen fallback", capFB.contains { $0.id == "new1" } && !capFB.contains { $0.id == "old1" }, true)
    // staleSec eviction decision (pure): a LIVE (process NOT gone) long-idle session KEEPS its ring regardless
    // of age — the "live idle ring vanished after 4h" fix (the old code aged it out purely on ts). A gone/recycled
    // process is evicted; a legacy file with no captured pid still ages out; final:done uses the staleSec fallback.
    checkB("evict: live idle (alive,stale) KEPT", Aggregator.shouldEvict(final: false, pid: 999, ts: now - 99999, now: now, staleSec: 8, processGone: false), false)
    checkB("evict: non-final process gone",       Aggregator.shouldEvict(final: false, pid: 999, ts: now,         now: now, staleSec: 8, processGone: true),  true)
    checkB("evict: alive fresh kept",             Aggregator.shouldEvict(final: false, pid: 999, ts: now,         now: now, staleSec: 8, processGone: false), false)
    checkB("evict: legacy(no pid) fresh kept",    Aggregator.shouldEvict(final: false, pid: 0,   ts: now,         now: now, staleSec: 8, processGone: false), false)
    checkB("evict: legacy(no pid) stale aged",    Aggregator.shouldEvict(final: false, pid: 0,   ts: now - 99999, now: now, staleSec: 8, processGone: false), true)
    checkB("evict: final fresh kept",             Aggregator.shouldEvict(final: true,  pid: 999, ts: now,         now: now, staleSec: 8, processGone: false), false)
    checkB("evict: final stale evicted",          Aggregator.shouldEvict(final: true,  pid: 999, ts: now - 99999, now: now, staleSec: 8, processGone: true),  true)
    // RingReducer timeline tests — the per-session display TIMING logic the prior audit could not test because
    // it lived in the stateful tick(). Now pure → drive whole event timelines deterministically.
    do {
        func drive(_ steps: [(Double, RingState, Bool, RingState?, Double)]) -> [(RingState, Bool)] {
            var b = RingReducer.Book(); var out: [(RingState, Bool)] = []
            for (now, raw, final, attn, attnTs) in steps {
                out.append(RingReducer.step(&b, raw: raw, ts: now, final: final, attn: attn, attnTs: attnTs, now: now))
            }
            return out
        }
        // 1) spurious mid-work done (CC sub-stop) → NEVER shows green, NEVER commits (kills "工作中闪绿")
        let s1 = drive([(0, .working, false, nil, 0), (0.5, .done, false, nil, 0), (1.0, .working, false, nil, 0)])
        check("reducer substop hides green",   s1[1].0, .working)
        checkB("reducer substop no commit",    !s1[1].1 && !s1[2].1, true)
        check("reducer substop resumes blue",  s1[2].0, .working)
        // 2) genuine completion: done persists past doneGrace(3.0s) → green, EXACTLY ONE commit edge (banner once)
        let s2 = drive([(0, .working, false, nil, 0), (10, .done, false, nil, 0), (11.0, .done, false, nil, 0), (12.5, .done, false, nil, 0), (13.1, .done, false, nil, 0), (14.0, .done, false, nil, 0)])
        check("reducer done held pre-grace",   s2[1].0, .working)
        check("reducer done held mid-grace",   s2[3].0, .working)
        check("reducer done commits post-grace", s2[4].0, .done)
        checkB("reducer done one commit edge", s2[4].1 && !s2[5].1, true)
        // 2b) multi-second sub-stop (gap < doneGrace) still NEVER shows green — the residual the grace bump kills
        let s2b = drive([(0, .working, false, nil, 0), (10, .done, false, nil, 0), (12.5, .done, false, nil, 0), (12.8, .working, false, nil, 0)])
        check("reducer 2.5s substop hides green", s2b[2].0, .working)
        checkB("reducer 2.5s substop no commit",  !s2b[2].1 && !s2b[3].1, true)
        // 3) final (SessionEnd) done → green immediately
        let s3 = drive([(0, .working, false, nil, 0), (5, .done, true, nil, 0)])
        check("reducer final done immediate",  s3[1].0, .done)
        checkB("reducer final done commits",   s3[1].1, true)
        // 4) first-sight done (app relaunch onto a persisted done) → green immediately AND STAYS green on the next
        //    polls (no green→blue→green relaunch flicker — the inDone-stays-committed fix)
        let s4 = drive([(0, .done, false, nil, 0), (0.4, .done, false, nil, 0), (0.8, .done, false, nil, 0), (5.0, .done, false, nil, 0)])
        check("reducer firstsight done now",   s4[0].0, .done)
        checkB("reducer firstsight commits",   s4[0].1, true)
        check("reducer firstsight STAYS done (no flicker) t=0.4", s4[1].0, .done)
        check("reducer firstsight STAYS done (no flicker) t=0.8", s4[2].0, .done)
        check("reducer firstsight STAYS done (no flicker) t=5.0", s4[3].0, .done)
        checkB("reducer firstsight no re-commit", !s4[1].1 && !s4[2].1 && !s4[3].1, true)
        // 5) attention dwell from a raw waiting then working: amber shows + held >= attnDwell, then returns to blue
        let s5 = drive([(0, .working, false, nil, 0), (1.0, .waiting, false, nil, 0), (1.1, .working, false, .waiting, 1.0), (1.6, .working, false, .waiting, 1.0)])
        check("reducer waiting shows amber",   s5[1].0, .waiting)
        check("reducer amber held in dwell",   s5[2].0, .waiting)
        check("reducer amber back to blue",    s5[3].0, .working)
        // 6) NON-LOSSY amber: the app's poll MISSED the raw waiting; a working carrying the attn hint still shows
        //    amber once (then blue) — proves "黄→蓝" never drops the amber even when overwritten before a poll
        let s6 = drive([(0, .working, false, nil, 0), (1.0, .working, false, .waiting, 0.9), (1.2, .working, false, .waiting, 0.9), (1.6, .working, false, .waiting, 0.9)])
        check("reducer carried-attn amber",    s6[1].0, .waiting)
        check("reducer carried-attn held",     s6[2].0, .waiting)
        check("reducer carried-attn to blue",  s6[3].0, .working)
        // 7) error attention dwell (red) behaves like amber: shown then back to blue
        let s7 = drive([(0, .working, false, nil, 0), (1.0, .error, false, nil, 0), (1.2, .working, false, .error, 1.0), (1.6, .working, false, .error, 1.0)])
        check("reducer error shows red",       s7[1].0, .error)
        check("reducer red held in dwell",     s7[2].0, .error)
        check("reducer red back to blue",      s7[3].0, .working)
        // 8) STUCK-AMBER/RED FIX: a turn whose last active state is waiting (or error) then done must show BLUE
        //    during the grace — the amber/red was already shown once via the dwell — then commit green, NOT
        //    freeze on amber/red for the whole 3s grace (the old "黄→蓝卡 / stuck amber" bug; lastActive removed).
        let s8 = drive([(0, .working, false, nil, 0), (1.0, .waiting, false, nil, 0), (2.0, .done, false, nil, 0), (3.0, .done, false, nil, 0), (5.1, .done, false, nil, 0)])
        check("reducer waiting→done grace blue not amber", s8[2].0, .working)
        check("reducer waiting→done grace still blue",     s8[3].0, .working)
        check("reducer waiting→done commits green",        s8[4].0, .done)
        let s9 = drive([(0, .working, false, nil, 0), (1.0, .error, false, nil, 0), (2.0, .done, false, nil, 0), (3.0, .done, false, nil, 0)])
        check("reducer error→done grace blue not red",     s9[2].0, .working)
        check("reducer error→done grace still blue",       s9[3].0, .working)
    }
    // ambient-egg eligibility (pure): glitches/glimmers only ever land on a CALM ring (working/idle/done). A
    // waiting(amber)/error(red) ring is a real "needs you" cue and must NEVER be disturbed by a playful egg.
    checkB("egg eligible: working", EasterEgg.ambientEligible(.working), true)
    checkB("egg eligible: idle",    EasterEgg.ambientEligible(.idle), true)
    checkB("egg eligible: done",    EasterEgg.ambientEligible(.done), true)
    checkB("egg NOT on waiting",   !EasterEgg.ambientEligible(.waiting), true)
    checkB("egg NOT on error",     !EasterEgg.ambientEligible(.error), true)
    checkB("egg NOT on hidden",    !EasterEgg.ambientEligible(.hidden), true)
    // flavor-egg kind selection (pure): calm states yield kinds; waiting/error/hidden yield NONE (belt-and-
    // suspenders on the eligibility gate — even if a flavor egg were ever scheduled on them, no kind exists).
    checkB("flavor kinds idle nonempty",    !EasterEgg.flavorKinds(.idle).isEmpty, true)
    checkB("flavor kinds working nonempty", !EasterEgg.flavorKinds(.working).isEmpty, true)
    checkB("flavor kinds done nonempty",    !EasterEgg.flavorKinds(.done).isEmpty, true)
    checkB("flavor kinds waiting EMPTY",     EasterEgg.flavorKinds(.waiting).isEmpty, true)
    checkB("flavor kinds error EMPTY",       EasterEgg.flavorKinds(.error).isEmpty, true)
    // determinism oracle (programmatic): RingCanvas(state,t) must be byte-reproducible so an offscreen render
    // equals the live frame. Render .working at a fixed t twice and compare — catches any RNG/Date leak. The
    // easter-egg overlays (PowerOnSweep/RA9Glyph) are composed ABOVE RingCanvas, so assert THEY are byte-stable
    // too (closed-form in age, no Date/RNG) — that, plus RingCanvas itself being untouched, is the guarantee
    // the eggs cannot corrupt the offscreen==live contract.
    MainActor.assumeIsolated {
        NSApplication.shared.setActivationPolicy(.accessory)
        @MainActor func pngBytes<V: View>(_ v: V) -> Data? {
            let r = ImageRenderer(content: v.frame(width: 80, height: 80)); r.scale = 2
            return r.cgImage.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
        }
        // RingCanvas is the production offscreen==live oracle: it is byte-identical even COLD (very first render),
        // the strongest guarantee — assert it directly (it has never flaked across heavy stress).
        let p1 = pngBytes(ZStack { Color.black; RingCanvas(state: .working, t: 1.234) })
        let p2 = pngBytes(ZStack { Color.black; RingCanvas(state: .working, t: 1.234) })
        checkB("determinism: same t → identical bytes", p1 != nil && p1 == p2, true)
        // The egg overlays add .blur drawLayers whose FIRST render(s) after different content rasterize a few
        // sub-pixels off — a CoreGraphics/Metal blur cold-warmup TRANSIENT (a plain two-render byte-compare flaked
        // ~1/35 on it; a flaky gate is worse than no gate). This SMOKE check asserts each overlay RENDERS and its
        // output STABILIZES (converges to a repeatable frame within a few renders) — it does NOT prove "no
        // Date/RNG leak" (a slow sub-pixel leak could still settle; verified by a teeth-test). The real no-leak
        // guarantee is STATIC and enforced in build.sh: the egg overlays are grep-proven closed-form in `age`
        // (no Date/RNG/time API in their bodies). Closed-form + this stabilization smoke + the RingCanvas oracle
        // above = the determinism contract is intact.
        @MainActor func stabilizes<V: View>(_ make: @autoclosure () -> V, _ maxTries: Int = 10) -> Bool {
            var prev: Data? = nil
            for _ in 0..<maxTries {
                let cur = pngBytes(make())
                if cur != nil && cur == prev { return true }   // two consecutive identical → output has converged
                prev = cur
            }
            return false                                       // never converged → broken/empty render
        }
        checkB("smoke: PowerOnSweep renders + stabilizes", stabilizes(ZStack { Color.black; PowerOnSweep(age: 0.3) }), true)
        checkB("smoke: RA9Glyph renders + stabilizes", stabilizes(ZStack { Color.black; RA9Glyph(age: 0.5) }), true)
        checkB("smoke: GlitchOverlay renders + stabilizes", stabilizes(ZStack { Color.black; GlitchOverlay(age: 0.2) }), true)
        checkB("smoke: DoneSalvo renders + stabilizes", stabilizes(ZStack { Color.black; DoneSalvo(age: 0.3) }), true)
        checkB("smoke: IdleGlimmer renders + stabilizes", stabilizes(ZStack { Color.black; IdleGlimmer(age: 0.5) }), true)
        checkB("smoke: CoinFlip renders + stabilizes", stabilizes(ZStack { Color.black; CoinFlip(age: 0.3) }), true)
        checkB("smoke: ScanSweep renders + stabilizes", stabilizes(ZStack { Color.black; ScanSweep(age: 0.4) }), true)
        checkB("smoke: ZenRipple renders + stabilizes", stabilizes(ZStack { Color.black; ZenRipple(age: 0.5) }), true)
        checkB("smoke: PaintSweep renders + stabilizes", stabilizes(ZStack { Color.black; PaintSweep(age: 0.3) }), true)
        checkB("smoke: CompanionLight renders + stabilizes", stabilizes(ZStack { Color.black; CompanionLight(age: 0.6) }), true)
        checkB("smoke: SnowFall renders + stabilizes", stabilizes(ZStack { Color.black; SnowFall(age: 1.0).frame(width: 60, height: 200) }), true)
    }
    print(fail == 0 ? "SELFTEST PASS" : "SELFTEST FAIL (\(fail))")
    exit(fail == 0 ? 0 : 1)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)            // no Dock icon, no menu bar (also LSUIElement in plist)
    let controller = AppController()
    app.delegate = controller
    app.run()
}
