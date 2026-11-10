import SwiftUI

/// A small deterministic PRNG (SplitMix64). Every particle's angle, speed and lifetime
/// is drawn from one of these seeded per shell, so a frame can be computed from
/// (seed, elapsed time) alone - nothing has to be stepped forward or stored.
struct Sparkle {
    private var state: UInt64

    init(_ seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0..<1
    mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }

    mutating func range(_ low: Double, _ high: Double) -> Double { low + (high - low) * unit() }
}

/// One firework: climbs from the bottom of the window, bursts at its apex.
struct Shell: Equatable {
    var seed: UInt64
    /// Seconds into the run before it launches.
    var launchAt: Double
    /// Horizontal position, 0...1 across the width.
    var x: Double
    /// Burst height, 0...1 down from the top.
    var apex: Double
    var hue: Double
    var particles: Int
    /// Seconds spent climbing.
    var rise: Double
    /// Burst speed in points per second.
    var speed: Double
    /// Seconds the sparks live.
    var life: Double
    /// A ring burst reads as a clean circle; otherwise the sparks fill a disc.
    var ring: Bool
}

/// A whole celebration: the shells, and how long the overlay should stay up.
struct CelebrationRun: Identifiable, Equatable {
    let id = UUID()
    var kind: Celebration
    var shells: [Shell]
    var duration: Double

    static func make(for kind: Celebration) -> CelebrationRun {
        var rng = Sparkle(UInt64.random(in: UInt64.min...UInt64.max))

        let count: Int
        let window: Double      // seconds over which shells launch
        switch kind {
        case .goalReached: count = 9;  window = 2.3
        case .encore:      count = 5;  window = 1.2
        }

        var shells: [Shell] = []
        for i in 0..<count {
            // Spread launches across the window with a little jitter, and spread the
            // shells across the width in bands so they don't all pile up in the middle.
            let slot = Double(i) / Double(max(count - 1, 1))
            let band = (Double(i % 3) + rng.range(0.15, 0.85)) / 3.0
            shells.append(Shell(
                seed: rng.next(),
                launchAt: slot * window + rng.range(-0.09, 0.09),
                x: 0.1 + band * 0.8,
                apex: rng.range(0.16, 0.46),
                hue: rng.unit(),
                particles: rng.unit() < 0.35 ? 92 : 70,
                rise: rng.range(0.52, 0.78),
                speed: rng.range(155, 235),
                life: rng.range(1.35, 1.9),
                ring: rng.unit() < 0.4
            ))
        }

        let last = shells.map { $0.launchAt + $0.rise + $0.life }.max() ?? 2
        return CelebrationRun(kind: kind, shells: shells, duration: last + 0.35)
    }
}

/// Draws the whole run. Purely a function of the elapsed time, so it can be dropped
/// in and out of the view tree freely - and it stops ticking the moment it's removed.
///
/// What it costs to draw matters as much as how it looks. Crossing the goal on the phone
/// on 2026-10-27 froze the whole phone - not just the app, the power-off slider too - and
/// these were the only heavy thing running. That is what a screen-sized effect that outruns
/// the GPU does, because the system draws its own screens on that same GPU, though nothing
/// the phone recorded proves it was this. Every spark was its own shape then: over a
/// thousand separate draws a frame at the peak, at 120 frames a second on a ProMotion
/// screen, under a frosted banner that had to be blurred again on every one of them. Now
/// a burst is a couple of dozen draws whatever it throws, the run is held to 60 frames a
/// second, and the banner is solid. Anything added here wants counting the same way.
struct FireworksOverlay: View {
    let run: CelebrationRun
    let start: Date

    @Environment(\.colorScheme) private var scheme
    @State private var frames = FrameCount()

    // Linear drag plus gravity has a closed-form solution, which is what lets a
    // particle's position at any time be computed directly instead of integrated.
    private let drag = 1.25
    private let gravity = 150.0

    /// The steps a spark's colour and fade take as it cools. Sparks sharing a step, and a
    /// half of the twinkle, share one path - so a burst is at most twice this many fills
    /// and as many strokes, however many sparks it throws.
    private static let stages = 6

    var body: some View {
        // Taken here, on the main thread, because the canvas draws on another one.
        let counter = frames
        // Sixty a second is as smooth as fireworks need to be, and half of what a
        // ProMotion screen would otherwise ask for.
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
            Canvas(rendersAsynchronously: true) { context, size in
                counter.tick()
                let t = timeline.date.timeIntervalSince(start)

                // The sparks are drawn additively, which is what makes them glow - but
                // adding light to white achieves nothing, so on a pale background they
                // wash out to confetti. A scrim that fades in with the launch and out
                // with the last spark gives them something to glow against. Dark mode
                // needs only a touch of it; light mode needs a good deal.
                let scrim = scrimOpacity(at: t)
                if scrim > 0.002 {
                    context.fill(Path(CGRect(origin: .zero, size: size)),
                                 with: .color(.black.opacity(scrim)))
                }

                context.blendMode = .plusLighter
                for shell in run.shells {
                    draw(shell, at: t, size: size, into: &context)
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
        // Nothing in it to read. The banner says what it's for.
        .accessibilityHidden(true)
        // How many frames the run really managed goes in the log, so a phone falling behind
        // says so - and a run with no line saying it finished is one the app didn't outlive.
        .task(id: run.id) {
            let began = Date()
            let first = frames.count
            Diagnostics.log(.app, "fireworks: \(run.shells.count) shells over \(Diagnostics.seconds(run.duration))")
            // Ends early, and still reports, when the run is replaced or taken down.
            try? await Task.sleep(nanoseconds: UInt64(run.duration * 1_000_000_000))
            let took = Date().timeIntervalSince(began)
            let drawn = frames.count - first
            Diagnostics.log(.app, "fireworks done: \(drawn) frames in \(Diagnostics.seconds(took)), \(Int((Double(drawn) / max(took, 0.01)).rounded())) a second")
        }
    }

    /// Rises over the first moments, holds, and clears as the last sparks die, so the
    /// window is never left dimmed a frame longer than the celebration lasts.
    private func scrimOpacity(at t: Double) -> Double {
        guard t > 0 else { return 0 }
        let peak = scheme == .dark ? 0.20 : 0.46
        let rising = min(t / 0.35, 1)
        let clearing = min(max((run.duration - t) / 0.7, 0), 1)
        return peak * rising * clearing
    }

    private func draw(_ shell: Shell, at t: Double, size: CGSize, into context: inout GraphicsContext) {
        let elapsed = t - shell.launchAt
        guard elapsed > 0 else { return }

        let originX = shell.x * size.width
        let apexY = shell.apex * size.height
        let ground = size.height + 24
        let color = Color(hue: shell.hue, saturation: 0.72, brightness: 1)

        if elapsed < shell.rise {
            climb(shell, elapsed: elapsed, originX: originX, apexY: apexY,
                  ground: ground, color: color, into: &context)
            return
        }

        let age = elapsed - shell.rise
        guard age <= shell.life else { return }

        flash(age: age, at: CGPoint(x: originX, y: apexY), color: color, into: &context)
        burst(shell, age: age, originX: originX, apexY: apexY, into: &context)
    }

    /// The climb: decelerating, with a short flickering tail behind it.
    private func climb(_ shell: Shell, elapsed: Double, originX: Double, apexY: Double,
                       ground: Double, color: Color, into context: inout GraphicsContext) {
        let p = elapsed / shell.rise
        let eased = 1 - pow(1 - p, 2)
        let y = ground + (apexY - ground) * eased
        let x = originX + sin(elapsed * 17) * 2.2

        var tail = Path()
        tail.move(to: CGPoint(x: x, y: y))
        tail.addLine(to: CGPoint(x: x, y: min(ground, y + 30 * (1 - p) + 10)))
        context.stroke(tail, with: .color(color.opacity(0.5)),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round))

        let r = 2.3
        context.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                     with: .color(.white.opacity(0.92)))
    }

    /// The white-hot bloom at the moment of the burst.
    private func flash(age: Double, at point: CGPoint, color: Color, into context: inout GraphicsContext) {
        let k = age / 0.26
        guard k < 1 else { return }
        let radius = 24 + 96 * k
        let alpha = (1 - k) * (1 - k) * 0.55
        let box = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: box),
                     with: .radialGradient(Gradient(colors: [color.opacity(alpha), .clear]),
                                           center: point, startRadius: 0, endRadius: radius))
    }

    private func burst(_ shell: Shell, age: Double, originX: Double, apexY: Double,
                       into context: inout GraphicsContext) {
        var rng = Sparkle(shell.seed)
        let terminal = gravity / drag
        let decay = exp(-drag * age)
        // Position 45ms ago, for the trailing streak behind each spark.
        let past = max(0, age - 0.045)
        let pastDecay = exp(-drag * past)

        // One path per step of cooling, each split into its bright and dim half of the
        // twinkle. A spark keeps its own place and size; only its colour is shared.
        var sparks = [Path](repeating: Path(), count: Self.stages * 2)
        var streaks = [Path](repeating: Path(), count: Self.stages * 2)

        for i in 0..<shell.particles {
            // Every random value is drawn before anything can skip the particle, so
            // the sequence stays identical from frame to frame.
            let jitter = rng.range(-0.06, 0.06)
            let angleRoll = rng.unit()
            let depthRoll = rng.unit()
            let lifeScale = rng.range(0.68, 1.0)
            let twinkle = rng.range(15, 32)

            let life = shell.life * lifeScale
            if age > life { continue }

            // A real shell throws sparks over a sphere. Projecting that sphere onto the
            // screen puts more of them near the rim than the centre, which is what makes
            // a burst read as a ball of light rather than a flat disc. Angle and radius
            // must come from separate rolls - sharing one winds the burst into a spiral.
            let theta = shell.ring
                ? (Double(i) / Double(shell.particles)) * 2 * .pi + jitter
                : angleRoll * 2 * .pi
            let z = 2 * depthRoll - 1
            let scale = shell.ring ? (0.94 + 0.1 * depthRoll) : sqrt(max(0, 1 - z * z))
            let speed = shell.speed * scale
            let vx = cos(theta) * speed
            let vy = sin(theta) * speed

            let x = originX + vx * (1 - decay) / drag
            let y = apexY + (vy - terminal) * (1 - decay) / drag + terminal * age
            let px = originX + vx * (1 - pastDecay) / drag
            let py = apexY + (vy - terminal) * (1 - pastDecay) / drag + terminal * past

            let k = age / life
            let stage = min(Int(k * Double(Self.stages)), Self.stages - 1)
            let slot = stage * 2 + (sin(age * twinkle + Double(i)) > 0 ? 1 : 0)
            let r = 2.5 * (1 - 0.42 * k)

            streaks[slot].move(to: CGPoint(x: px, y: py))
            streaks[slot].addLine(to: CGPoint(x: x, y: y))
            sparks[slot].addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }

        for slot in sparks.indices where !sparks[slot].isEmpty {
            // The middle of the step stands for all of it.
            let k = (Double(slot / 2) + 0.5) / Double(Self.stages)
            let alpha = (1 - k * k) * (slot % 2 == 1 ? 0.92 : 0.64)
            // Sparks start near-white and settle into their colour as they cool.
            let spark = Color(hue: shell.hue, saturation: min(0.2 + k * 1.4, 0.9), brightness: 1)
            context.stroke(streaks[slot], with: .color(spark.opacity(alpha * 0.5)),
                           style: StrokeStyle(lineWidth: 2.5 * (1 - 0.42 * k) * 1.25, lineCap: .round))
            context.fill(sparks[slot], with: .color(spark.opacity(alpha)))
        }
    }
}

/// The headline that rides along with the fireworks.
struct CelebrationBanner: View {
    let kind: Celebration

    private var headline: String {
        switch kind {
        case .goalReached: return "Goal reached"
        case .encore: return "Still going"
        }
    }

    private var detail: String {
        "\(kind.count) up on the board"
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(headline)
                .scaledFont(size: 30, weight: .bold, design: .rounded)
                .foregroundStyle(
                    LinearGradient(colors: [Color(hue: 0.12, saturation: 0.85, brightness: 1),
                                            Color(hue: 0.05, saturation: 0.75, brightness: 1)],
                                   startPoint: .top, endPoint: .bottom))
            Text(detail)
                .scaledFont(size: 14, weight: .medium, design: .rounded)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 16)
        // Solid, not frosted: frosted glass over fireworks has to be blurred afresh on
        // every frame they draw. The shadow belongs to the card's shape alone, which is
        // far cheaper to cast than one taken from everything drawn inside it.
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Palette.raised)
                .shadow(color: .black.opacity(0.18), radius: 18, y: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1))
        // It's gone in two and a half seconds, before VoiceOver could be moved onto it, so it's
        // spoken as it arrives instead of left on screen to be found.
        .accessibilityHidden(true)
        .onAppear { AccessibilityNotification.Announcement("\(headline). \(detail)").post() }
    }
}

/// Frames a run has drawn. Counted from the canvas, which draws off the main thread.
final class FrameCount: @unchecked Sendable {
    private let lock = NSLock()
    private var drawn = 0

    func tick() {
        lock.lock()
        drawn += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return drawn
    }
}
