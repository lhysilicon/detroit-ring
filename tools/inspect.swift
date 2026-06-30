// inspect harness — renders EXACTLY what the user sees, using the REAL StripView.capsule() chrome (no
// duplicated constants → the harness can never drift from the app) across BOTH light & dark + a couple of
// accent colors. Plus large per-state detail, a cross-bucket "alive" reshuffle sweep, and a determinism
// pair (same t rendered twice → bytes must be identical). Compile with Ring.swift + AppCore.swift (this
// file, renamed main.swift, provides the entry point):
//   cp tools/inspect.swift /tmp/insp/main.swift && swiftc -O src/Ring.swift src/AppCore.swift /tmp/insp/main.swift -o /tmp/ring-inspect-bin
import SwiftUI
import AppKit

@MainActor func writePNG<V: View>(_ view: V, _ path: String, scale: CGFloat = 2.0) {
    let r = ImageRenderer(content: view); r.scale = scale
    guard let cg = r.cgImage else { print("no cg \(path)"); return }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) [\(cg.width)x\(cg.height)]")
}

// Real capsule chrome — calls StripView.capsule(dark:accent:) directly so the harness mirrors the app exactly.
struct CapsuleMock: View {
    let rings: [(RingState, Double)]
    let dark: Bool
    let accent: Color
    var body: some View {
        VStack(spacing: Cfg.ringSpacing) {
            ForEach(Array(rings.enumerated()), id: \.offset) { _, r in
                RingCanvas(state: r.0, t: r.1).frame(width: Cfg.ringSize, height: Cfg.ringSize)
            }
            MinimizeButton(action: {}, accent: accent)
        }
        .padding(Cfg.capsulePad)
        .background(StripView.capsule(dark: dark, accent: accent))
    }
}

// desktop-ish backdrop (light or dark) so glass/contrast reads true
struct OnDesktop<V: View>: View {
    let inner: V; let dark: Bool
    var body: some View {
        ZStack {
            dark
              ? LinearGradient(colors: [Color(.sRGB,red:0.10,green:0.13,blue:0.18,opacity:1),
                                        Color(.sRGB,red:0.04,green:0.05,blue:0.07,opacity:1)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
              : LinearGradient(colors: [Color(.sRGB,red:0.93,green:0.95,blue:0.98,opacity:1),
                                        Color(.sRGB,red:0.78,green:0.82,blue:0.88,opacity:1)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            inner.padding(24)
        }.frame(width: 180, height: 380)
    }
}

let out = "/tmp/ring-inspect"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

MainActor.assumeIsolated {
    let app = NSApplication.shared; app.setActivationPolicy(.accessory)
    let blue   = Color(.sRGB, red: 0.0,  green: 0.48, blue: 1.0,  opacity: 1)   // macOS default blue accent
    let purple = Color(.sRGB, red: 0.66, green: 0.33, blue: 0.78, opacity: 1)   // a different accent (follow-test)

    // 1) REAL-SIZE strip in BOTH appearances (incl. a calm idle standby ring at the bottom)
    for (dark, tag) in [(true,"dark"),(false,"light")] {
        writePNG(OnDesktop(inner: CapsuleMock(rings: [
            (.working, 0.45), (.waiting, 1.7), (.done, 0.5), (.idle, 0.5),
        ], dark: dark, accent: blue), dark: dark), "\(out)/strip-\(tag).png", scale: 3.0)
    }
    // accent-follow check: dark strip with a different accent — border/glow should re-tint
    writePNG(OnDesktop(inner: CapsuleMock(rings: [(.working,0.45),(.idle,0.5)], dark: true, accent: purple), dark: true),
             "\(out)/strip-accent2.png", scale: 3.0)

    // 2) single real-size states (40px) on a neutral dark backdrop
    for (st, t, name) in [(RingState.working,0.45,"working"),(.waiting,1.7,"waiting"),(.done,0.5,"done"),(.idle,0.5,"idle"),(.error,0.3,"error")] {
        writePNG(ZStack { Color(.sRGB,red:0.06,green:0.08,blue:0.10,opacity:1)
            RingCanvas(state: st, t: t).frame(width: Cfg.ringSize, height: Cfg.ringSize) }
            .frame(width: 72, height: 72), "\(out)/small-\(name).png", scale: 3.0)
    }

    // 3) LARGE per-state detail (fidelity vs game refs)
    let px: CGFloat = 300
    for (st, t, name) in [(RingState.working,0.45,"working"),(.waiting,1.7,"waiting"),(.done,0.5,"done"),(.idle,0.5,"idle"),(.error,0.3,"error")] {
        writePNG(ZStack { Color(.sRGB,red:0.05,green:0.07,blue:0.09,opacity:1)
            RingCanvas(state: st, t: t).frame(width: px*0.78, height: px*0.78) }
            .frame(width: px, height: px), "\(out)/big-\(name).png")
    }

    // 4) ALIVE reshuffle sweep — cross bucket boundaries (period=2.8s, snap=0.45s) to see the click-into-place
    for t in [0.15, 0.45, 1.7, 2.7, 2.9, 3.2, 5.6, 5.85] {
        writePNG(ZStack { Color(.sRGB,red:0.05,green:0.07,blue:0.09,opacity:1)
            RingCanvas(state: .working, t: t).frame(width: px*0.78, height: px*0.78) }
            .frame(width: px, height: px), "\(out)/motion-t\(t).png")
    }

    // 5) DETERMINISM oracle — same t twice → bytes must be identical (offscreen==live guarantee)
    for i in [0,1] {
        writePNG(ZStack { Color.black
            RingCanvas(state: .working, t: 1.234).frame(width: px*0.78, height: px*0.78) }
            .frame(width: px, height: px), "\(out)/determinism-\(i).png")
    }

    // 6) TRANSITION crossfade working→done at increasing age (changeAt=0, so age==t), incl. the done pulse
    for t in [0.0, 0.12, 0.25, 0.4, 0.6] {
        writePNG(ZStack { Color(.sRGB,red:0.05,green:0.07,blue:0.09,opacity:1)
            TransitioningRing(state: .done, prev: .working, changeAt: 0, t: t).frame(width: px*0.78, height: px*0.78) }
            .frame(width: px, height: px), "\(out)/trans-done-t\(t).png")
    }

    // 7) APP ICON — the Detroit ring glowing on a macOS-style dark squircle (1024px master for iconutil)
    let S: CGFloat = 1024
    let icon = ZStack {
        RoundedRectangle(cornerRadius: S * 0.2237, style: .continuous)
            .fill(LinearGradient(colors: [Color(.sRGB, red: 0.11, green: 0.15, blue: 0.21, opacity: 1),
                                          Color(.sRGB, red: 0.02, green: 0.04, blue: 0.07, opacity: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: S * 0.2237, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: S * 0.01))
        RingCanvas(state: .working, t: 0.55).frame(width: S * 0.62, height: S * 0.62)
    }.frame(width: S, height: S)
    writePNG(icon, "\(out)/appicon-1024.png", scale: 1.0)

    // 8) DBH AMBIENT EASTER EGGS (all composed above RingCanvas, closed-form in age) ----------------------
    let eggBg = Color(.sRGB, red: 0.05, green: 0.07, blue: 0.09, opacity: 1)
    @MainActor func eggOver<V: View>(_ ring: RingState, _ rt: Double, _ overlay: V, _ name: String, big: Bool = true) {
        let s: CGFloat = big ? px * 0.78 : Cfg.ringSize
        let frame: CGFloat = big ? px : 72
        writePNG(ZStack { eggBg
            RingCanvas(state: ring, t: rt).frame(width: s, height: s)
            overlay.frame(width: s, height: s) }
            .frame(width: frame, height: frame), "\(out)/egg-\(name).png", scale: big ? 1.0 : 3.0)
    }
    // 8a) power-on sweep
    for age in [0.0, 0.2, 0.45] { eggOver(.working, 0.45, PowerOnSweep(age: age), "poweron-\(age)") }
    eggOver(.working, 0.45, PowerOnSweep(age: 0.3), "poweron-40px", big: false)
    // 8b) deviant glitch — the centerpiece, across its 0.5s life, big + real 40px
    for age in [0.05, 0.18, 0.30, 0.42] { eggOver(.working, 0.45, GlitchOverlay(age: age), "glitch-\(age)") }
    eggOver(.working, 0.45, GlitchOverlay(age: 0.2), "glitch-40px", big: false)
    // 8c) rA9 reveal riding a glitch (the rare deep egg), big + real 40px
    for age in [0.3, 0.8, 1.3] {
        writePNG(ZStack { eggBg
            RingCanvas(state: .working, t: 0.45).frame(width: px*0.78, height: px*0.78)
            GlitchOverlay(age: age).frame(width: px*0.78, height: px*0.78)
            RA9Glyph(age: age).frame(width: px*0.78, height: px*0.78) }
            .frame(width: px, height: px), "\(out)/egg-ra9-\(age).png")
    }
    writePNG(ZStack { eggBg
        RingCanvas(state: .working, t: 0.45).frame(width: Cfg.ringSize, height: Cfg.ringSize)
        RA9Glyph(age: 0.7).frame(width: Cfg.ringSize, height: Cfg.ringSize) }
        .frame(width: 72, height: 72), "\(out)/egg-ra9-40px.png", scale: 3.0)
    // 8d) whole-strip done-celebration salvo (on a done ring)
    for age in [0.1, 0.35, 0.6] { eggOver(.done, 0.5, DoneSalvo(age: age), "salvo-\(age)") }
    // 8e) idle micro-glimmer (on an idle ring)
    for age in [0.3, 0.65, 1.0] { eggOver(.idle, 0.5, IdleGlimmer(age: age), "glimmer-\(age)") }
    // 8f) Connor's coin flip (on idle), big + real 40px
    for age in [0.25, 0.5, 0.78] { eggOver(.idle, 0.5, CoinFlip(age: age), "coin-\(age)") }
    eggOver(.idle, 0.5, CoinFlip(age: 0.5), "coin-40px", big: false)
    // 8g) Connor's preconstruction scan (on working), big + real 40px
    for age in [0.2, 0.5, 0.8] { eggOver(.working, 0.45, ScanSweep(age: age), "scan-\(age)") }
    eggOver(.working, 0.45, ScanSweep(age: 0.5), "scan-40px", big: false)
    // 8h) Connor's zen-garden ripple (on idle)
    for age in [0.3, 0.6, 0.95] { eggOver(.idle, 0.5, ZenRipple(age: age), "zen-\(age)") }
    // 8i) Markus's paint sweep (on working), big + real 40px
    for age in [0.25, 0.5, 0.8] { eggOver(.working, 0.45, PaintSweep(age: age), "paint-\(age)") }
    eggOver(.working, 0.45, PaintSweep(age: 0.4), "paint-40px", big: false)
    // 8j) Kara's companion light (on idle), big + real 40px
    for age in [0.4, 0.75, 1.15] { eggOver(.idle, 0.5, CompanionLight(age: age), "companion-\(age)") }
    eggOver(.idle, 0.5, CompanionLight(age: 0.7), "companion-40px", big: false)
    // 8k) Detroit snow — strip-wide, over a tall capsule-shaped dark frame
    for age in [0.6, 1.8, 3.2] {
        writePNG(ZStack { eggBg; SnowFall(age: age).frame(width: 58, height: 220) }
            .frame(width: 58, height: 220), "\(out)/egg-snow-\(age).png", scale: 3.0)
    }
}
print("done")
exit(0)
