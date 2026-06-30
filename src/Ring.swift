// Ring.swift — faithful Detroit: Become Human "ring", UNIFIED from both in-game references
// (image-measured vs /tmp/dbh-ref/spinner.png and led.png). The real ring is a set of ROTATING
// rounded capsule-SEGMENTS wrapped in a heavy glow:
//   - big → reads as the CyberLife loading spinner (distinct deep-blue capsules, two offset layers
//     for depth shimmer, white-hot inner filament, round caps);
//   - small (the 40px strip) → the strong, px-floored bloom FUSES the segments into one glowing temple
//     LED — same object, different zoom. (v4's smooth ring matched led.png but lost the iconic spin;
//     v5 restores the segments while keeping the glow.)
//   - canonical color language (LED wiki): BLUE = stable/calm, YELLOW = processing/strain, RED =
//     distress; constant = stable, FLICKER = rapid/unbalanced. Mapped: blue working / amber waiting /
//     red error. DONE has no in-game state → a clean full GREEN ring (unmistakable "complete" — the one
//     deliberate non-canon color, for an at-a-glance status indicator). Idle = dim blue.
//   - deterministic SplitMix64 partition → live TimelineView and offscreen renders are identical.
import SwiftUI

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

enum RingState: String, CaseIterable { case hidden, idle, working, waiting, done, error }

struct RingStyle {
    var core: Color    // bright segment color
    var bloom: Color   // wide halo color (the at-a-glance state color)
    var hot: Color     // white-hot inner filament tint
    var fill: Double   // lit fraction of the ring (rest = real dark gaps between capsules)
    var spin: Double   // ring revolutions/sec (the CyberLife rotation)
    var flickerHz: Double
    var breatheHz: Double
    var dim: Double    // overall brightness (idle dimmer)
    var settled: Bool  // done/idle steady; done = clean full ring

    static func of(_ s: RingState) -> RingStyle {
        switch s {
        // blue WORKING — stable processing: bright blue capsules slowly rotating
        case .working: return .init(core: .hex(0x2C93DE), bloom: .hex(0x1E78C8), hot: .hex(0xDCF0FF), fill: 0.64, spin: 0.16, flickerHz: 0, breatheHz: 0,    dim: 1.0, settled: false)
        // amber WAITING — your move: amber capsules, slower rotation + light flicker
        case .waiting: return .init(core: .hex(0xEEC53A), bloom: .hex(0xCF9E22), hot: .hex(0xFFF3CC), fill: 0.62, spin: 0.10, flickerHz: 3, breatheHz: 0,    dim: 1.0, settled: false)
        // green DONE — complete & at rest: clean FULL green ring, gentle breathe (non-canon color, for legibility)
        case .done:    return .init(core: .hex(0x35DF95), bloom: .hex(0x18A86A), hot: .hex(0xDFFFEF), fill: 1.0,  spin: 0.0,  flickerHz: 0, breatheHz: 0.35, dim: 1.0, settled: true)
        // dim blue IDLE / hidden
        case .idle, .hidden: return .init(core: .hex(0x2C93DE), bloom: .hex(0x1E6FA8), hot: .hex(0xBCD4E6), fill: 1.0, spin: 0.0, flickerHz: 0, breatheHz: 0.2, dim: 0.5, settled: true)
        // red ERROR — SOFTENED distress cue: dimmer red, calm slow spin + gentle breathe, NO hard strobe. CC
        // fires PostToolUseFailure on ANY non-zero tool exit (often a benign grep-no-match / false test), so the
        // red must be recognizable but not alarming/扎眼; it still auto-clears on the next working/done.
        case .error:   return .init(core: .hex(0xE05A5A), bloom: .hex(0xB83232), hot: .hex(0xF2CACA), fill: 0.62, spin: 0.12, flickerHz: 0, breatheHz: 0.3,  dim: 0.7, settled: false)
        }
    }
}

extension Color {
    static func hex(_ v: UInt32) -> Color {
        Color(.sRGB, red: Double((v >> 16) & 0xFF)/255.0, green: Double((v >> 8) & 0xFF)/255.0, blue: Double(v & 0xFF)/255.0, opacity: 1)
    }
}

private func irregularFlicker(_ t: Double, _ hz: Double) -> Double {
    let a = 0.5 * (sin(2 * .pi * t * hz) + 1)
    let b = 0.5 * (sin(2 * .pi * t * hz * 2.3 + 1.1) + 1)
    return 0.62 + 0.38 * (0.6 * a + 0.4 * b)
}

enum RingMath {
    /// One partition of `n` uneven rounded capsules summing to `fill` of the turn (rest = dark gaps).
    static func partition(seed: UInt64, n: Int, fill: Double) -> [(Double, Double)] {
        var rng = SplitMix64(seed: seed)
        var w = (0..<n).map { _ in 0.45 + pow(Double.random(in: 0...1, using: &rng), 1.3) }
        let ws = w.reduce(0, +); w = w.map { $0 / ws * fill }
        let gapB = max(0, 1 - fill)
        var g = (0..<n).map { _ in 0.5 + Double.random(in: 0...1, using: &rng) }
        let gs = g.reduce(0, +); g = g.map { $0 / gs * gapB }
        var arcs: [(Double, Double)] = []; var cur = 0.0
        for i in 0..<n { arcs.append((cur, cur + w[i])); cur += w[i] + g[i] }
        return arcs
    }
}

// MARK: - "Alive" micro-variation (DETERMINISTIC function of t — offscreen == live preserved)
// The in-game CyberLife spinner doesn't merely rotate rigidly: its segment layout periodically RESHUFFLES,
// each segment easing ("clicking") into a new place. We reproduce that organically WITHOUT runtime RNG —
// every `period` seconds a fresh deterministic partition is derived from the integer time-bucket and the
// segments MORPH from the previous bucket's layout into it over a short snap window, then hold. Plus a tiny
// continuous width-breathe + rotation wobble so even between reshuffles it never reads as a rigid loop.
// Everything is closed-form in t (no Date, no stateful RNG) → a given t always reproduces the same frame.
enum Alive {
    static let period: Double = 2.8         // seconds between segment-layout reshuffles
    static let snap: Double = 0.45          // ease-into-place window after each reshuffle
    static let breatheAmp: Double = 0.018   // per-segment width breathe (fraction of the segment's width)
    static let breatheHz: Double = 0.23
    static let spinWobbleAmp: Double = 0.22 // rotation wobble (scaled by spin → slow states wobble less)

    /// Mix an integer bucket index into a layer's base seed → a distinct deterministic partition per bucket.
    static func bucketSeed(_ bucket: Int64, _ base: UInt64) -> UInt64 {
        base ^ (UInt64(bitPattern: bucket) &* 0x100000001B3)
    }
    static func easeExpOut(_ s: Double) -> Double { s >= 1 ? 1 : 1 - pow(2, -10 * s) }

    /// Partition for a bucket, sorted ascending by start so index i morphs to its NEAREST neighbour
    /// (segments slide/resize into place, never sweep across the whole ring).
    static func sortedPartition(_ seed: UInt64, _ n: Int, _ fill: Double) -> [(Double, Double)] {
        RingMath.partition(seed: seed, n: n, fill: fill).sorted { $0.0 < $1.0 }
    }

    /// The morphing segment layout at time t for one layer (base seed). Reshuffles every `period`, easing
    /// from the previous bucket's layout into the current one over `snap`, then holding. Continuous across
    /// bucket boundaries because next(b-1) == prev(b).
    static func segments(_ t: Double, base: UInt64, n: Int, fill: Double) -> [(Double, Double)] {
        let b = Int64((t / period).rounded(.down))
        let prev = sortedPartition(bucketSeed(b - 1, base), n, fill)
        let next = sortedPartition(bucketSeed(b, base), n, fill)
        let local = t - Double(b) * period
        let s = easeExpOut(min(1.0, local / snap))
        return (0..<n).map { i in
            let a = prev[i], c = next[i]
            return (a.0 + (c.0 - a.0) * s, a.1 + (c.1 - a.1) * s)
        }
    }

    /// Subtle width-breathe about each segment's own midpoint (phase-staggered by index, incommensurate
    /// terms so the breathing itself doesn't loop).
    static func breathed(_ seg: (Double, Double), _ t: Double, _ i: Int) -> (Double, Double) {
        let mid = (seg.0 + seg.1) / 2, half = (seg.1 - seg.0) / 2
        let ph = Double(i) * 0.7
        let f = 1 + breatheAmp * (0.6 * sin(2 * .pi * breatheHz * t + ph) + 0.4 * sin(2 * .pi * breatheHz * 1.61 * t + ph))
        return (mid - half * f, mid + half * f)
    }

    /// Rotation = steady spin + a small incommensurate wobble (scaled by spin → settled states stay still).
    static func rot(_ t: Double, spin: Double) -> Double {
        t * spin + spin * spinWobbleAmp * (sin(2 * .pi * 0.07 * t) + 0.6 * sin(2 * .pi * 0.113 * t)) / 1.6
    }
}

struct RingCanvas: View {
    var state: RingState
    var t: Double
    private static let n = 7

    var body: some View {
        Canvas { ctx, size in
            let z = min(size.width, size.height)
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let st = RingStyle.of(state)
            let outerR = z / 2 * 0.82
            let band = z * 0.116
            let midR = outerR - band / 2

            var gb = st.dim
            if st.breatheHz > 0 { gb *= 0.82 + 0.18 * (0.5 * (sin(2 * .pi * t * st.breatheHz) + 1)) }
            if st.flickerHz > 0 { gb *= irregularFlicker(t, st.flickerHz) }

            let rotF = Alive.rot(t, spin: st.spin)
            // settled (done/idle) = a single clean full/near-full ring; active = two offset capsule layers
            // whose layout periodically reshuffles + breathes (Alive) so the ring reads organic, not a rigid loop.
            let front: [(Double, Double)] = st.settled ? [(0.0, st.fill)]
                : Alive.segments(t, base: 0xA11CE, n: Self.n, fill: st.fill).enumerated().map { Alive.breathed($1, t, $0) }

            func arc(_ r: CGFloat, _ a: (Double, Double), _ rot: Double) -> Path {
                if a.1 - a.0 >= 0.999 { return Path { p in p.addArc(center: c, radius: r, startAngle: .zero, endAngle: .degrees(360), clockwise: false) } }
                var p = Path()
                p.addArc(center: c, radius: r, startAngle: .radians((a.0 + rot) * 2 * .pi), endAngle: .radians((a.1 + rot) * 2 * .pi), clockwise: false)
                return p
            }
            func strokeArcs(_ g: inout GraphicsContext, _ arcs: [(Double, Double)], _ r: CGFloat, _ col: Color, _ w: CGFloat, _ rot: Double) {
                for a in arcs { g.stroke(arc(r, a, rot), with: .color(col), style: StrokeStyle(lineWidth: w, lineCap: .round)) }
            }

            // 1) WIDE bloom from the segments (px-floored) → at 40px fuses segments into a glowing LED
            ctx.drawLayer { l in
                l.addFilter(.blur(radius: max(3.0, z * 0.085))); l.blendMode = .plusLighter
                strokeArcs(&l, front, midR, st.bloom.opacity(0.55 * gb), band * 2.0, rotF)
            }
            // (back-ghost depth layer removed in the v10.3 perf pass: it cost a full extra blur drawLayer per
            //  ACTIVE frame, but at the 40px strip the heavy front bloom already fuses it away — barely-visible
            //  at the only size the app renders. settled states never had it (back was [] when st.settled).)
            // 3) bright front segment cores (+ tight glow)
            ctx.drawLayer { l in
                l.addFilter(.blur(radius: max(1.5, z * 0.02))); l.blendMode = .plusLighter
                strokeArcs(&l, front, midR, st.bloom.opacity(0.70 * gb), band * 1.25, rotF)
            }
            strokeArcs(&ctx, front, midR, st.core.opacity(min(1.0, 0.98 * gb)), band, rotF)
            // 4) white-hot inner filament along the front segments (the LED pop)
            strokeArcs(&ctx, front, midR, st.hot.opacity(min(1.0, 0.50 * gb)), band * 0.34, rotF)
            // 5) faint inner spill — seats the ring, hollow stays dark
            let innerR = midR - band / 2
            let inner = GraphicsContext.Shading.radialGradient(
                Gradient(colors: [st.bloom.opacity(0.08 * gb), .clear]), center: c, startRadius: innerR * 0.2, endRadius: innerR * 1.05)
            var cc = ctx; cc.blendMode = .plusLighter
            cc.fill(Path(ellipseIn: CGRect(x: c.x - innerR, y: c.y - innerR, width: innerR * 2, height: innerR * 2)), with: inner)
        }
    }
}

extension RingState {
    /// Per-state redraw cadence cap (used when a ring drives its own timeline). Rotating/flicker states
    /// need 30fps; the slow breathe of settled states reads fine at 12fps; hidden is not drawn.
    var frameInterval: Double {
        switch self {
        case .hidden:        return 1.0
        case .done, .idle:   return 1.0 / 12.0    // slow breathe only
        case .error:         return 1.0 / 12.0    // softened red = gentle breathe only (no hard flicker) → 12fps is plenty
        default:             return 1.0 / 18.0    // working/waiting: slow spin + ≤3Hz flicker read smooth at 18fps; each
                                                  // frame recomposites blur on the GPU, so 24→18 cuts ~25% of that hot cost
        }
    }
}

/// Single-ring live view (render-harness helper). In the app each RingButton owns its own scoped
/// TimelineView around the ring Canvas (see StripView), so the chrome isn't rebuilt every animation frame.
struct LiveRing: View {
    var state: RingState
    var startDate: Date
    var body: some View {
        TimelineView(.animation(minimumInterval: state.frameInterval, paused: state == .hidden)) { tl in
            RingCanvas(state: state, t: tl.date.timeIntervalSince(startDate))
        }
    }
}

// MARK: - State-transition crossfade + done completion pulse — composed ABOVE RingCanvas so RingCanvas stays
// a pure (state, t) function and the offscreen==live determinism oracle is left completely untouched. Every
// weight here is closed-form in the shared render clock t, so a transition frame is reproducible too.
enum Trans {
    static let fadeDur: Double = 0.38     // crossfade duration between two states
    static let pulseDur: Double = 0.70    // one-shot completion pulse on entering .done
    static func smoothstep(_ x: Double) -> Double { let c = min(1, max(0, x)); return c * c * (3 - 2 * c) }
}

/// A one-shot bright green ring that expands past the rim and fades — the satisfying "complete" pop when a
/// session enters .done. `age` = seconds since entering done (closed-form → deterministic).
struct DonePulse: View {
    var age: Double
    var body: some View {
        Canvas { ctx, size in
            let z = min(size.width, size.height)
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let p = min(1, max(0, age / Trans.pulseDur))
            let ease = 1 - pow(1 - p, 3)                     // easeOutCubic
            let r = z / 2 * (0.52 + 0.5 * ease)              // expands outward past the ring
            let alpha = (1 - p) * 0.85                       // fades out
            guard alpha > 0.001 else { return }
            ctx.drawLayer { l in
                l.addFilter(.blur(radius: max(2.0, z * 0.05))); l.blendMode = .plusLighter
                l.stroke(Path { $0.addArc(center: c, radius: r, startAngle: .zero, endAngle: .degrees(360), clockwise: false) },
                         with: .color(Color.hex(0x35DF95).opacity(alpha)), lineWidth: z * 0.055)
            }
        }
    }
}

/// One session's ring with a state-transition crossfade (cross-dissolve the outgoing and incoming states,
/// which gracefully handles even the segments↔full-ring topology change) plus the done pulse. Driven by the
/// shared clock t and the per-session changeAt the controller stamps when the displayed state last changed.
struct TransitioningRing: View {
    var state: RingState
    var prev: RingState?
    var changeAt: Double
    var t: Double
    var body: some View {
        let age = t - changeAt
        let w = Trans.smoothstep(age / Trans.fadeDur)
        let fading = prev != nil && prev != state && age < Trans.fadeDur
        ZStack {
            if fading, let p = prev { RingCanvas(state: p, t: t).opacity(1 - w) }
            RingCanvas(state: state, t: t).opacity(fading ? w : 1)
            if state == .done && age >= 0 && age < Trans.pulseDur { DonePulse(age: age).allowsHitTesting(false) }
        }
    }
}

// MARK: - DBH easter-egg overlays — ALL composed ABOVE RingCanvas (never inside it), every weight closed-form
// in an `age` (no Date, no RNG), so RingCanvas stays the untouched offscreen==live determinism oracle and these
// overlays are themselves byte-reproducible (asserted in --selftest). Purely decorative + non-interactive
// (allowsHitTesting(false) at the call site) → they cannot affect window focus, the state machine, or aggregation.

/// CyberLife "power-on self-test": a one-shot white-hot filament that races once around the ring and settles —
/// played when a ring FIRST appears (login auto-start / a new session). `age` = seconds since first shown.
struct PowerOnSweep: View {
    var age: Double
    var body: some View {
        Canvas { ctx, size in
            let z = min(size.width, size.height)
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let p = min(1, max(0, age / EasterEgg.powerOnDur))
            guard p < 1 else { return }
            let ease = 1 - pow(1 - p, 2)                       // easeOutQuad — fast then settle into place
            let r = z / 2 * 0.82 - (z * 0.116) / 2            // mid-radius of the ring band (matches RingCanvas)
            let head = ease                                    // 0..1 charge fraction around the circle (from top)
            // bright while the scan races, then the whole white overlay fades over the last 35% → "self-test
            // complete", revealing the ring's own color underneath. (closed-form in age → deterministic.)
            let fade = p < 0.65 ? 1.0 : Swift.max(0, 1 - (p - 0.65) / 0.35)
            guard fade > 0.01 else { return }
            // 1) the white "charge" arc filling from the top up to the head — the ignition glow that lights the ring
            let arc = Path { pth in
                pth.addArc(center: c, radius: r,
                           startAngle: .radians(-.pi / 2),
                           endAngle: .radians(head * 2 * .pi - .pi / 2), clockwise: false)
            }
            ctx.drawLayer { l in
                l.addFilter(.blur(radius: Swift.max(1.5, z * 0.05))); l.blendMode = .plusLighter
                l.stroke(arc, with: .color(.white.opacity(0.55 * fade)), style: StrokeStyle(lineWidth: z * 0.075, lineCap: .round))
            }
            // 2) bright leading head — the scan point racing ahead of the charge
            let ha = head * 2 * .pi - .pi / 2
            let hp = CGPoint(x: c.x + r * cos(ha), y: c.y + r * sin(ha))
            ctx.drawLayer { l in
                l.addFilter(.blur(radius: Swift.max(1.0, z * 0.03))); l.blendMode = .plusLighter
                l.fill(Path(ellipseIn: CGRect(x: hp.x - z * 0.06, y: hp.y - z * 0.06, width: z * 0.12, height: z * 0.12)),
                       with: .color(.white.opacity(0.95 * fade)))
            }
        }
    }
}

/// Deterministic 0..1 hash of a real (for the eggs' digital-stutter offsets) — closed-form, NO Date/RNG, so it
/// keeps the overlays oracle-safe and passes the build's egg-overlay grep gate. A given input always returns the
/// same value, so a given `age` always reproduces the same glitch frame.
private func eggHash(_ n: Double) -> Double { let s = sin(n * 12.9898 + 7.13) * 43758.5453; return s - floor(s) }

/// rA9 — the "deviant" marking from Detroit: Become Human. Now AMBIENT (revealed on a rare glitch, not a
/// gesture): a big, chromatic-split "rA9" stutters up in the ring's glow over a darkening plate (so it reads at
/// 40px), holds, then fades. `age` = seconds since the glitch fired; everything is closed-form in `age`.
struct RA9Glyph: View {
    var age: Double
    var body: some View {
        Canvas { ctx, size in
            let z = min(size.width, size.height)
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let inA = min(1, age / 0.22)
            let outA = age > EasterEgg.ra9Dur - 0.5 ? Swift.max(0, 1 - (age - (EasterEgg.ra9Dur - 0.5)) / 0.5) : 1
            let alpha = inA * outA
            guard alpha > 0.01 else { return }
            // digital-stutter chromatic offset (≈18 steps/sec), closed-form via eggHash
            let step = (age * 18).rounded(.down)
            let dx = (eggHash(step) - 0.5) * z * 0.09
            let dy = (eggHash(step + 9) - 0.5) * z * 0.045
            // darkening plate behind the glyph so white text reads over the bright ring
            var pc = ctx; pc.opacity = alpha * 0.5; pc.blendMode = .multiply
            pc.fill(Path(ellipseIn: CGRect(x: c.x - z * 0.36, y: c.y - z * 0.24, width: z * 0.72, height: z * 0.48)),
                    with: .color(.black))
            func scrawl(_ color: Color, _ ox: CGFloat, _ oy: CGFloat, _ a: Double) {
                let txt = Text("rA9").font(.system(size: z * 0.42, weight: .black, design: .monospaced)).foregroundColor(color)
                var rc = ctx; rc.opacity = alpha * a; rc.blendMode = .plusLighter
                rc.draw(rc.resolve(txt), at: CGPoint(x: c.x + ox, y: c.y + oy), anchor: .center)
            }
            scrawl(.hex(0xFF2D2D), dx, dy, 0.85)           // red chromatic ghost
            scrawl(.hex(0x2DFFE6), -dx, -dy, 0.85)         // cyan chromatic ghost, opposite offset
            scrawl(.white, 0, 0, 1.0)                      // white front, centered
        }
    }
}

/// Deviant "software instability" GLITCH — the centerpiece ambient egg. The ring briefly destabilizes: its band
/// splits into red/cyan chromatic ghosts that stutter, horizontal scanline tears flicker across, a white flash
/// kicks it off — then it snaps back to the true ring. ~0.5s, closed-form in `age` (stutter via eggHash, no RNG).
struct GlitchOverlay: View {
    var age: Double
    var body: some View {
        Canvas { ctx, size in
            let z = min(size.width, size.height)
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let p = min(1, max(0, age / EasterEgg.glitchDur))
            guard p < 1 else { return }
            let env = p < 0.12 ? p / 0.12 : (p > 0.7 ? Swift.max(0, 1 - (p - 0.7) / 0.3) : 1)   // ramp/sustain/ramp
            guard env > 0.01 else { return }
            let midR = z / 2 * 0.82 - (z * 0.116) / 2
            let band = z * 0.116
            let step = (age * 24).rounded(.down)                       // ~24 stutter steps/sec
            let amp = z * 0.06 * env
            let dx = (eggHash(step) - 0.5) * 2 * amp
            let dy = (eggHash(step + 5) - 0.5) * amp
            func ghostRing(_ col: Color, _ ox: CGFloat, _ oy: CGFloat) {
                let cc = CGPoint(x: c.x + ox, y: c.y + oy)
                ctx.drawLayer { l in
                    l.addFilter(.blur(radius: Swift.max(1.0, z * 0.02))); l.blendMode = .plusLighter
                    l.stroke(Path { $0.addArc(center: cc, radius: midR, startAngle: .zero, endAngle: .degrees(360), clockwise: false) },
                             with: .color(col.opacity(0.5 * env)), style: StrokeStyle(lineWidth: band * 0.7))
                }
            }
            ghostRing(.hex(0xFF1A4B), dx, dy)                          // red/magenta chromatic ghost
            ghostRing(.hex(0x1AF0FF), -dx, -dy)                        // cyan chromatic ghost (opposite)
            // scanline tears — a few flickering, horizontally-jumping bright slices
            for i in 0..<3 {
                let yy = c.y + (eggHash(step + Double(i) * 3.7) - 0.5) * z * 0.7
                if eggHash(step * 1.3 + Double(i) * 7.1) > 0.45 {
                    let off = (eggHash(step + Double(i)) - 0.5) * z * 0.12
                    ctx.drawLayer { l in
                        l.blendMode = .plusLighter
                        l.fill(Path(CGRect(x: off, y: yy, width: z, height: z * 0.02)), with: .color(.white.opacity(0.45 * env)))
                    }
                }
            }
            // a quick white flash at the very start (the "snap" of destabilizing)
            if p < 0.12 {
                ctx.drawLayer { l in
                    l.addFilter(.blur(radius: z * 0.06)); l.blendMode = .plusLighter
                    l.stroke(Path { $0.addArc(center: c, radius: midR, startAngle: .zero, endAngle: .degrees(360), clockwise: false) },
                             with: .color(.white.opacity(0.4 * (1 - p / 0.12))), style: StrokeStyle(lineWidth: band))
                }
            }
        }
    }
}

/// Whole-strip "all done" celebration salvo — a bright green ring expands past the rim with a faster white inner
/// pulse. Fired with one shared start time across every ring, so the burst is SYNCHRONIZED. ~0.95s, closed-form.
struct DoneSalvo: View {
    var age: Double
    var body: some View {
        Canvas { ctx, size in
            let z = min(size.width, size.height)
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let p = min(1, max(0, age / EasterEgg.salvoDur))
            guard p < 1 else { return }
            let ease = 1 - pow(1 - p, 3)
            let a = (1 - p) * 0.9
            ctx.drawLayer { l in
                l.addFilter(.blur(radius: Swift.max(2, z * 0.05))); l.blendMode = .plusLighter
                l.stroke(Path { $0.addArc(center: c, radius: z / 2 * (0.5 + 0.7 * ease), startAngle: .zero, endAngle: .degrees(360), clockwise: false) },
                         with: .color(Color.hex(0x35DF95).opacity(a)), lineWidth: z * 0.06 * (1 - p * 0.5))
            }
            ctx.drawLayer { l in
                l.addFilter(.blur(radius: Swift.max(1, z * 0.03))); l.blendMode = .plusLighter
                l.stroke(Path { $0.addArc(center: c, radius: z / 2 * (0.4 + 0.9 * ease), startAngle: .zero, endAngle: .degrees(360), clockwise: false) },
                         with: .color(.white.opacity(a * 0.5)), lineWidth: z * 0.02)
            }
        }
    }
}

/// Idle micro-glimmer — a soft pale sweep that drifts once around a long-idle ring, like a standby breath.
/// Very subtle. ~1.3s, closed-form in `age`.
struct IdleGlimmer: View {
    var age: Double
    var body: some View {
        Canvas { ctx, size in
            let z = min(size.width, size.height)
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let p = min(1, max(0, age / EasterEgg.glimmerDur))
            guard p < 1 else { return }
            let midR = z / 2 * 0.82 - (z * 0.116) / 2
            let head = p, tail = Swift.max(0, p - 0.38)
            let a = sin(.pi * p) * 0.72                             // bell-shaped ease in/out (brighter, still gentle)
            guard a > 0.01 else { return }
            ctx.drawLayer { l in
                l.addFilter(.blur(radius: Swift.max(1.5, z * 0.05))); l.blendMode = .plusLighter
                l.stroke(Path { $0.addArc(center: c, radius: midR,
                                          startAngle: .radians(tail * 2 * .pi - .pi / 2),
                                          endAngle: .radians(head * 2 * .pi - .pi / 2), clockwise: false) },
                         with: .color(Color.hex(0xCFE6FF).opacity(a)), style: StrokeStyle(lineWidth: z * 0.075, lineCap: .round))
            }
        }
    }
}

/// Connor's COIN — the iconic DBH tic (he flips a quarter to calibrate). A small silver coin flips in place
/// (squashing vertically as it rotates) with a gentle bob and a face-on glint. ~1.0s, closed-form in `age`.
struct CoinFlip: View {
    var age: Double
    var body: some View {
        Canvas { ctx, size in
            let z = min(size.width, size.height)
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let p = min(1, max(0, age / EasterEgg.coinDur))
            guard p < 1 else { return }
            let env = sin(.pi * p)                                  // fade in/out bell
            let cy = c.y - sin(.pi * p) * z * 0.14                  // upward bob
            let face = abs(cos(age * 15))                          // 1 = face-on, 0 = edge-on (flipping)
            let cw = z * 0.22
            let ch = z * 0.22 * (0.14 + 0.86 * face)
            let a = env * 0.97
            guard a > 0.02 else { return }
            // soft glow halo so the coin reads clearly against the ring
            ctx.drawLayer { l in
                l.addFilter(.blur(radius: z * 0.05)); l.blendMode = .plusLighter
                l.fill(Path(ellipseIn: CGRect(x: c.x - cw * 0.6, y: cy - ch * 0.6, width: cw * 1.2, height: ch * 1.2)),
                       with: .color(Color.hex(0xCFE0F0).opacity(a * 0.5)))
            }
            ctx.drawLayer { l in
                l.addFilter(.blur(radius: Swift.max(0.6, z * 0.012))); l.blendMode = .plusLighter
                l.fill(Path(ellipseIn: CGRect(x: c.x - cw / 2, y: cy - ch / 2, width: cw, height: ch)),
                       with: .color(Color.hex(0xEAF1F8).opacity(a)))
            }
            if face > 0.6 {                                        // bright glint when near face-on
                let g = a * (face - 0.6) / 0.4
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - cw * 0.16, y: cy - ch * 0.3, width: cw * 0.32, height: ch * 0.6)),
                         with: .color(.white.opacity(g)))
            }
        }
    }
}

/// Connor's PRECONSTRUCTION scan — his calm blue analysis. A blue crosshair reticle + corner brackets appear
/// and a scan line sweeps top→bottom. The cool, analytical counterpoint to the chaotic red glitch. ~1.0s.
struct ScanSweep: View {
    var age: Double
    var body: some View {
        Canvas { ctx, size in
            let z = min(size.width, size.height)
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let p = min(1, max(0, age / EasterEgg.scanDur))
            guard p < 1 else { return }
            let env = p < 0.15 ? p / 0.15 : (p > 0.8 ? Swift.max(0, 1 - (p - 0.8) / 0.2) : 1)
            guard env > 0.01 else { return }
            let blue = Color.hex(0x4FC3FF)
            // sweeping horizontal scan line, top → bottom
            ctx.drawLayer { l in
                l.addFilter(.blur(radius: z * 0.02)); l.blendMode = .plusLighter
                l.fill(Path(CGRect(x: 0, y: size.height * p - z * 0.01, width: size.width, height: z * 0.02)),
                       with: .color(blue.opacity(0.85 * env)))
            }
            ctx.drawLayer { l in
                l.blendMode = .plusLighter
                let r = z * 0.30
                var cross = Path()
                cross.move(to: CGPoint(x: c.x - r, y: c.y));     cross.addLine(to: CGPoint(x: c.x - r * 0.4, y: c.y))
                cross.move(to: CGPoint(x: c.x + r * 0.4, y: c.y)); cross.addLine(to: CGPoint(x: c.x + r, y: c.y))
                cross.move(to: CGPoint(x: c.x, y: c.y - r));     cross.addLine(to: CGPoint(x: c.x, y: c.y - r * 0.4))
                cross.move(to: CGPoint(x: c.x, y: c.y + r * 0.4)); cross.addLine(to: CGPoint(x: c.x, y: c.y + r))
                l.stroke(cross, with: .color(blue.opacity(0.7 * env)), lineWidth: z * 0.012)
                let b = z * 0.34
                for sx in [-1.0, 1.0] { for sy in [-1.0, 1.0] {
                    let cx = c.x + CGFloat(sx) * b, cyy = c.y + CGFloat(sy) * b
                    var t = Path()
                    t.move(to: CGPoint(x: cx, y: cyy)); t.addLine(to: CGPoint(x: cx - CGFloat(sx) * z * 0.06, y: cyy))
                    t.move(to: CGPoint(x: cx, y: cyy)); t.addLine(to: CGPoint(x: cx, y: cyy - CGFloat(sy) * z * 0.06))
                    l.stroke(t, with: .color(blue.opacity(0.6 * env)), lineWidth: z * 0.01)
                } }
            }
        }
    }
}

/// Connor's mind-palace ZEN RIPPLE — a soft central breath of light plus calm rings that radiate OUTWARD past
/// the rim, like a stone dropped in the Zen Garden's water. (Drawn outward, not inside, so it never reads as a
/// hollow vortex.) Meditative, for a long-idle ring. ~1.3s, closed-form in `age`.
struct ZenRipple: View {
    var age: Double
    var body: some View {
        Canvas { ctx, size in
            let z = min(size.width, size.height)
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let p = min(1, max(0, age / EasterEgg.rippleDur))
            guard p < 1 else { return }
            // a soft central breath of pale light that swells and fades
            let bloomA = sin(.pi * p) * 0.42
            if bloomA > 0.01 {
                ctx.drawLayer { l in
                    l.blendMode = .plusLighter
                    let g = GraphicsContext.Shading.radialGradient(
                        Gradient(colors: [Color.hex(0xCFEBFF).opacity(bloomA), .clear]), center: c, startRadius: 0, endRadius: z * 0.42)
                    l.fill(Path(ellipseIn: CGRect(x: c.x - z * 0.42, y: c.y - z * 0.42, width: z * 0.84, height: z * 0.84)), with: g)
                }
            }
            // two clean ripple rings radiating OUTWARD past the rim, staggered
            for i in 0..<2 {
                let lp = p - Double(i) * 0.3
                if lp <= 0 || lp >= 1 { continue }
                let a = (1 - lp) * 0.72
                ctx.drawLayer { l in
                    l.addFilter(.blur(radius: z * 0.02)); l.blendMode = .plusLighter
                    l.stroke(Path { $0.addArc(center: c, radius: z / 2 * (0.46 + 0.54 * lp), startAngle: .zero, endAngle: .degrees(360), clockwise: false) },
                             with: .color(Color.hex(0xCFEBFF).opacity(a)), lineWidth: z * 0.034)
                }
            }
        }
    }
}

/// Markus the PAINTER — his expressive deviation. A few vivid colored brush strokes sweep across the ring and
/// fade, like Markus painting. The most colorful egg (a deliberate splash). ~0.9s, closed-form in `age`.
struct PaintSweep: View {
    var age: Double
    var body: some View {
        Canvas { ctx, size in
            let z = min(size.width, size.height)
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let p = min(1, max(0, age / EasterEgg.paintDur))
            guard p < 1 else { return }
            let env = p < 0.5 ? 1.0 : Swift.max(0, 1 - (p - 0.5) / 0.5)    // paint, hold, fade
            guard env > 0.01 else { return }
            let prog = min(1, p / 0.45)                                    // stroke draws over the first ~half
            let x0 = c.x - z * 0.42, x1 = c.x + z * 0.42
            let endX = x0 + (x1 - x0) * prog
            let cols: [UInt32] = [0xFF4D6D, 0xFFC24D, 0x4DE0A0, 0x4FB8FF]
            for (i, hex) in cols.enumerated() {
                let oy = (Double(i) - 1.5) * z * 0.055
                var path = Path()
                path.move(to: CGPoint(x: x0, y: c.y + oy))
                path.addQuadCurve(to: CGPoint(x: endX, y: c.y + oy - z * 0.03),
                                  control: CGPoint(x: (x0 + endX) / 2, y: c.y + oy - z * 0.13))
                ctx.drawLayer { l in
                    l.addFilter(.blur(radius: z * 0.015)); l.blendMode = .plusLighter
                    l.stroke(path, with: .color(Color.hex(hex).opacity(0.55 * env)), style: StrokeStyle(lineWidth: z * 0.03, lineCap: .round))
                }
            }
        }
    }
}

/// Kara & Alice — a small warm COMPANION light drifts beside the ring while a tender warm halo glows over it,
/// for the android who protects a child. Warm amber, set apart from the ring's cool tones. ~1.4s, closed-form.
struct CompanionLight: View {
    var age: Double
    var body: some View {
        Canvas { ctx, size in
            let z = min(size.width, size.height)
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let p = min(1, max(0, age / EasterEgg.companionDur))
            guard p < 1 else { return }
            let env = sin(.pi * p)
            guard env > 0.01 else { return }
            let warm = Color.hex(0xFFD9A0)
            // soft protective warm halo over the whole ring
            ctx.drawLayer { l in
                l.blendMode = .plusLighter
                let grad = GraphicsContext.Shading.radialGradient(
                    Gradient(colors: [warm.opacity(0.32 * env), .clear]), center: c, startRadius: z * 0.1, endRadius: z * 0.55)
                l.fill(Path(ellipseIn: CGRect(x: c.x - z * 0.55, y: c.y - z * 0.55, width: z * 1.1, height: z * 1.1)), with: grad)
            }
            // a small companion light orbiting gently beside the ring (Alice alongside Kara) — glow + bright core
            let ang = -.pi / 2 + age * 1.7
            let pos = CGPoint(x: c.x + cos(ang) * z * 0.42, y: c.y + sin(ang) * z * 0.42)
            ctx.drawLayer { l in
                l.addFilter(.blur(radius: Swift.max(0.8, z * 0.03))); l.blendMode = .plusLighter
                l.fill(Path(ellipseIn: CGRect(x: pos.x - z * 0.075, y: pos.y - z * 0.075, width: z * 0.15, height: z * 0.15)),
                       with: .color(warm.opacity(0.98 * env)))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: pos.x - z * 0.03, y: pos.y - z * 0.03, width: z * 0.06, height: z * 0.06)),
                     with: .color(.white.opacity(0.85 * env)))
        }
    }
}

/// Detroit SNOW — a brief, rare drift of snowflakes over the WHOLE strip (the game's winter / snowy-ending
/// mood). Strip-wide atmosphere, never tied to a ring's status. Each flake's lane/speed/size come from eggHash
/// (no RNG), so it's closed-form in `age`. Drawn by SnowLayer over the capsule. ~EasterEgg.snowDur seconds.
struct SnowFall: View {
    var age: Double
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let p = min(1, max(0, age / EasterEgg.snowDur))
            guard p < 1 else { return }
            let fade = (p < 0.18 ? p / 0.18 : 1) * (p > 0.75 ? Swift.max(0, 1 - (p - 0.75) / 0.25) : 1)
            guard fade > 0.01 else { return }
            for i in 0..<16 {
                let fi = Double(i)
                let baseX = eggHash(fi * 1.7)
                let speed = 0.6 + eggHash(fi * 2.3) * 0.9
                let yNorm = (age * speed * 0.16 + eggHash(fi * 3.1)).truncatingRemainder(dividingBy: 1.0)
                let y = yNorm * (h + 16) - 8
                let x = baseX * w + sin(age * 0.7 + fi * 1.3) * w * 0.07     // gentle horizontal drift
                let r = (0.5 + eggHash(fi * 4.7) * 0.7) * w * 0.02
                let a = fade * (0.45 + eggHash(fi * 5.3) * 0.5)
                ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                         with: .color(.white.opacity(a)))
            }
        }
    }
}
