import SwiftUI

/// The "working" indicator: a 3×3 grid of rounded rectangles or dots, or a ring of dots, that
/// light up in a sequence.
/// Each turn of each session gets its own seed, which picks the order, how it plays
/// (a head with a fading tail, filling and draining, a moving gap…), the grid's rotation or
/// mirror, the tempo and the corner roundness, so the loader is rarely the same twice.
struct Loader: View {
    enum Style { case sequence, compacting }

    let seed: UInt64
    var style: Style = .sequence
    var tint: Color = .claude
    var animation: DotAnimation? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let spec = GridSequence.cached(seed, animation: animation)
        TimelineView(.animation(paused: reduceMotion)) { ctx in
            Canvas { gc, size in
                let t = reduceMotion ? spec.restTime : ctx.date.timeIntervalSinceReferenceDate
                switch style {
                case .sequence: spec.draw(&gc, size: size, t: t, tint: tint)
                case .compacting: Self.drawCompacting(&gc, size: size, t: t, tint: tint)
                }
            }
        }
    }

    /// Eight dots squeezing into the middle and springing back out, the ring turning as it goes.
    private static func drawCompacting(_ gc: inout GraphicsContext, size: CGSize, t: Double, tint: Color) {
        let side = min(size.width, size.height)
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let dot = side * 0.2
        let f = (t / 1.6).truncatingRemainder(dividingBy: 1)
        let squeeze = 0.5 - 0.5 * cos(2 * .pi * f)              // 0 → 1 → 0
        let radius = (side / 2 - dot / 2) * (1 - 0.62 * squeeze)
        let spin = t * 1.1
        for k in 0..<8 {
            let a = spin + Double(k) * .pi / 4
            let wave = 0.5 + 0.5 * sin(2 * .pi * f * 2 - Double(k) * .pi / 4)
            let r = dot * (0.62 + 0.38 * wave)
            let rect = CGRect(x: c.x + cos(a) * radius - r / 2, y: c.y + sin(a) * radius - r / 2, width: r, height: r)
            gc.fill(Path(ellipseIn: rect), with: .color(tint.opacity(0.45 + 0.55 * wave)))
        }
    }

    /// Stable seed for a session's current turn.
    static func seed(_ id: String, _ turn: Date) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in "\(id)|\(Int(turn.timeIntervalSince1970))".utf8 {
            h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3
        }
        return h
    }
}

// MARK: - Randomness

private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * unit() }
    mutating func int(_ r: ClosedRange<Int>) -> Int { r.lowerBound + Int(next() % UInt64(r.count)) }
    mutating func bool() -> Bool { next() & 1 == 1 }
    mutating func pick<T>(_ a: [T]) -> T { a[Int(next() % UInt64(a.count))] }

    mutating func shuffled<T>(_ a: [T]) -> [T] {
        var a = a
        for i in stride(from: a.count - 1, to: 0, by: -1) { a.swapAt(i, Int(next() % UInt64(i + 1))) }
        return a
    }
}

// MARK: - Orders

/// Cells are numbered row by row:
///
///     0 1 2
///     3 4 5
///     6 7 8
///
/// A sequence is a list of steps; each step is the cells that light together.
private enum Order {
    /// Orders that read well as a moving head, a fill, or a moving gap.
    static let paths: [[[Int]]] = [
        [[0], [1], [2], [3], [4], [5], [6], [7], [8]],                  // reading order
        [[0], [1], [2], [5], [4], [3], [6], [7], [8]],                  // snake
        [[0], [3], [6], [7], [4], [1], [2], [5], [8]],                  // column snake
        [[0], [1], [2], [5], [8], [7], [6], [3], [4]],                  // spiral in
        [[4], [3], [6], [7], [8], [5], [2], [1], [0]],                  // spiral out
        [[0], [1], [2], [5], [8], [7], [6], [3]],                       // ring
        [[0], [5], [6], [1], [8], [3], [2], [7]],                       // knight's tour
        [[0], [4], [8], [5], [2], [4], [6], [3]],                       // figure eight
        [[1], [4], [7], [0], [3], [6], [2], [5], [8]],                  // falling columns
        [[0], [1, 3], [2, 4, 6], [5, 7], [8]],                          // diagonal wave
        [[4], [1, 3, 5, 7], [0, 2, 6, 8]],                              // center out
        [[0, 2, 6, 8], [1, 3, 5, 7], [4]],                              // outside in
        [[0, 1, 2], [3, 4, 5], [6, 7, 8]],                              // rows
        [[0, 1, 2], [3, 4, 5], [6, 7, 8], [3, 4, 5]],                   // rows, ping-pong
        [[0, 3, 6], [1, 4, 7], [2, 5, 8], [1, 4, 7]],                   // columns, ping-pong
        [[0], [2], [8], [6]],                                           // corners
        [[1], [5], [7], [3]],                                           // edges
        [[0, 8], [1, 7], [2, 6], [5, 3]],                               // pinwheel
        [[0, 4, 8], [1, 4, 7], [2, 4, 6], [3, 4, 5]],                   // spinning bar
        [[0], [1], [2], [4], [6], [7], [8], [4]],                       // hourglass
        [[3], [4], [5], [2], [4], [6], [7], [4], [1], [0], [4], [8]],   // windmill strokes
    ]

    /// Patterns that are whole frames rather than an order.
    static let frames: [[[Int]]] = [
        [[0, 2, 4, 6, 8], [1, 3, 5, 7]],                                // checkerboard
        [[1, 3, 4, 5, 7], [0, 2, 4, 6, 8]],                             // plus / cross
        [[4], [1, 3, 4, 5, 7], [0, 1, 2, 3, 4, 5, 6, 7, 8], [0, 2, 6, 8], []], // bloom
        [[0, 1, 2, 3, 5, 6, 7, 8], [4]],                                // ring and core
        [[0, 3, 6], [1, 4, 7], [2, 5, 8], []],                          // column sweep
    ]

    /// Orders for a ring of 8 dots numbered clockwise from the top (8 is the centre dot).
    static let ringPaths: [[[Int]]] = [
        [[0], [1], [2], [3], [4], [5], [6], [7]],                       // chase
        [[0, 4], [1, 5], [2, 6], [3, 7]],                               // twin chase
        [[0], [1], [2], [3], [4], [3], [2], [1]],                       // swing
        [[0], [1, 7], [2, 6], [3, 5], [4]],                             // pour down both sides
        [[0], [3], [6], [1], [4], [7], [2], [5]],                       // star skip
        [[8], [0, 2, 4, 6], [1, 3, 5, 7]],                              // burst from the centre
        [[0], [2], [4], [6], [1], [3], [5], [7]],                       // leapfrog
    ]

    static let ringFrames: [[[Int]]] = [
        [[0, 2, 4, 6], [1, 3, 5, 7]],                                   // alternate
        [[8], [0, 1, 2, 3, 4, 5, 6, 7], []],                            // heartbeat
        [[0, 4, 8], [1, 5, 8], [2, 6, 8], [3, 7, 8]],                   // propeller
    ]

    /// One of the ring's 16 symmetries (8 rotations, each optionally mirrored).
    static func ringSymmetry(rotation: Int, mirror: Bool) -> [Int] {
        (0..<9).map { i in
            guard i < 8 else { return 8 }
            let k = mirror ? (8 - i) % 8 : i
            return (k + rotation) % 8
        }
    }

    /// One of the grid's 8 symmetries (4 rotations, each optionally mirrored), as a cell map.
    static func symmetry(rotation: Int, mirror: Bool) -> [Int] {
        (0..<9).map { i in
            var r = i / 3, c = i % 3
            if mirror { c = 2 - c }
            for _ in 0..<rotation { (r, c) = (c, 2 - r) }
            return r * 3 + c
        }
    }
}

// MARK: - Sequence

private enum Mode: CaseIterable { case trail, fill, fillBack, gap }

private final class GridSequence {
    private static var cache: [UInt64: GridSequence] = [:]

    static func cached(_ seed: UInt64, animation: DotAnimation? = nil) -> GridSequence {
        if let animation { return GridSequence(seed: seed, animation: animation) }
        if let s = cache[seed] { return s }
        if cache.count > 64 { cache.removeAll() }
        let s = GridSequence(seed: seed)
        cache[seed] = s
        return s
    }

    /// Brightness of the 9 cells (0…1) for each frame of one loop.
    private let frames: [[Double]]
    private let stepDuration: Double
    private let crisp: Bool
    private let roundness: Double
    /// Cells laid out as a 3×3 grid, or as a ring of 8 dots around a centre dot.
    private let ring: Bool
    /// Grid cells drawn as dots instead of rounded rectangles.
    private let dots: Bool
    private let animation: DotAnimation?
    var restTime: Double { animation.map { 0.35 * $0.period } ?? 0 }

    private init(seed: UInt64, animation selected: DotAnimation? = nil) {
        var rng = SplitMix64(state: seed)
        animation = selected ?? (rng.bool() ? rng.pick(DotAnimation.allCases) : nil)
        ring = animation == nil && rng.int(0...2) == 0
        dots = !ring && rng.int(0...2) == 0
        let map = ring ? Order.ringSymmetry(rotation: rng.int(0...7), mirror: rng.bool())
                       : Order.symmetry(rotation: rng.int(0...3), mirror: rng.bool())
        func mapped(_ steps: [[Int]]) -> [[Int]] { steps.map { $0.map { map[$0] } } }

        roundness = rng.range(0.22, 0.34)
        crisp = rng.bool()

        let kind = rng.int(0...9)
        if kind == 0 {
            // A whole-frame pattern, played slower.
            frames = mapped(rng.pick(ring ? Order.ringFrames : Order.frames)).map(Self.lit)
            stepDuration = rng.range(0.32, 0.46)
        } else if kind == 1 {
            // Sparkle: a fresh random handful each step.
            let cells = Array(0..<(ring ? 8 : 9))
            frames = (0..<14).map { _ in Self.lit(Array(rng.shuffled(cells).prefix(rng.int(2...3)))) }
            stepDuration = rng.range(0.16, 0.22)
        } else {
            var steps = rng.int(0...5) == 0 ? rng.shuffled(Array(0..<(ring ? 8 : 9))).map { [$0] }
                                             : rng.pick(ring ? Order.ringPaths : Order.paths)
            steps = mapped(steps)
            if rng.bool() { steps.reverse() }
            switch rng.pick(Mode.allCases) {
            case .trail:
                frames = Self.trail(steps, length: rng.range(0.8, 2.8))
                stepDuration = rng.range(0.08, 0.14)
            case .gap:
                frames = Self.trail(steps, length: rng.range(0.8, 1.8)).map { $0.map { 1 - $0 } }
                stepDuration = rng.range(0.1, 0.15)
            case .fill:
                frames = Self.fill(steps, drainForward: true)
                stepDuration = rng.range(0.08, 0.12)
            case .fillBack:
                frames = Self.fill(steps, drainForward: false)
                stepDuration = rng.range(0.08, 0.12)
            }
        }
    }

    private static func lit(_ cells: [Int]) -> [Double] {
        (0..<9).map { cells.contains($0) ? 1 : 0 }
    }

    /// A head moving through the steps, leaving a tail that fades over `length` steps.
    private static func trail(_ steps: [[Int]], length: Double) -> [[Double]] {
        let keep = exp(-1 / length)
        var b = [Double](repeating: 0, count: 9), out: [[Double]] = []
        for pass in 0..<3 { // run until the tail wraps round smoothly, then record one loop
            for step in steps {
                b = b.map { $0 * keep < 0.05 ? 0 : $0 * keep }
                for c in step { b[c] = 1 }
                if pass == 2 { out.append(b) }
            }
        }
        return out
    }

    /// Light the steps one by one, hold, then switch them off forward or in reverse.
    private static func fill(_ steps: [[Int]], drainForward: Bool) -> [[Double]] {
        let n = steps.count
        var out: [[Double]] = [lit([])]
        for i in 1...n { out.append(lit(steps[0..<i].flatMap { $0 })) }
        out.append(out.last!) // hold the full grid for a beat
        for i in 1..<n {
            out.append(lit(drainForward ? steps[i..<n].flatMap { $0 } : steps[0..<(n - i)].flatMap { $0 }))
        }
        return out
    }

    // MARK: Drawing

    func draw(_ gc: inout GraphicsContext, size: CGSize, t: Double, tint: Color = .claude) {
        let side = min(size.width, size.height)
        let gap = side * 0.1
        let cell = (side - 2 * gap) / 3
        let origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
        let mid = CGPoint(x: size.width / 2, y: size.height / 2)
        let dot = side * 0.21
        let orbit = side / 2 - dot / 2

        let pos = t / stepDuration
        let i = Int(floor(pos)) % frames.count
        let j = (i + 1) % frames.count
        let f = pos - floor(pos)

        for c in 0..<9 {
            let v: Double
            if let animation {
                v = animation.brightness(cell: c, time: t)
            } else {
                let a = frames[i][c], b = frames[j][c]
                // Switch on quickly, fade out at the sequence's own pace.
                let e = b > a ? easeOut(min(f * 1.8, 1)) : (crisp ? easeInOut(f) : f)
                v = a + (b - a) * e
            }
            let color = tint.opacity(0.16 + 0.84 * v)

            if ring {
                // The centre dot only shows when a pattern uses it.
                if c == 8, !frames.contains(where: { $0[8] > 0 }) { continue }
                let angle = -Double.pi / 2 + Double(c) * .pi / 4
                let dx: Double = cos(angle) * orbit, dy: Double = sin(angle) * orbit
                let center = c == 8 ? mid : CGPoint(x: mid.x + dx, y: mid.y + dy)
                let s = dot * (0.7 + 0.3 * v)
                gc.fill(Path(ellipseIn: CGRect(x: center.x - s / 2, y: center.y - s / 2, width: s, height: s)), with: .color(color))
                continue
            }

            let s = cell * (dots && animation != nil ? 0.70 + 0.30 * v : 0.74 + 0.26 * v)
            let cx = origin.x + Double(c % 3) * (cell + gap) + cell / 2
            let cy = origin.y + Double(c / 3) * (cell + gap) + cell / 2
            let rect = CGRect(x: cx - s / 2, y: cy - s / 2, width: s, height: s)
            let path = dots ? Path(ellipseIn: rect) : Path(roundedRect: rect, cornerRadius: s * roundness, style: .continuous)
            gc.fill(path, with: .color(color))
        }
    }
}

private func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
private func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }

// MARK: - Gallery (development aid: launch with --gallery)

struct LoaderGallery: View {
    private static func sample(_ id: String, _ agent: Agent, _ state: PillState, _ title: String, _ line: String,
                               attention: Attention? = nil, options: [String] = [], warning: Bool = false,
                               agents: Int = 0) -> SessionInfo {
        SessionInfo(id: id, agent: agent, title: title, subtitle: line, detail: line, state: state, folder: "demo",
                    options: options, attention: attention, warning: warning, agents: agents,
                    updatedAt: Date(), turnStartedAt: Date().addingTimeInterval(-74))
    }

    private let samples: [SessionInfo] = [
        sample("g1", .codex, .working, "Add dark mode to settings", "Running rg --files", agents: 2),
        sample("g2", .codex, .waiting, "Fix the flaky test", "Allow? Running npm test", attention: .permission),
        sample("g3", .codex, .waiting, "Pick a layout", "Which layout should the board use?", attention: .question,
               options: ["Grid", "Columns", "Timeline"]),
        sample("g4", .codex, .compacting, "Long refactor", "Compacting the conversation…"),
        sample("g5", .codex, .done, "Add dark mode to settings", "What would you like me to do next?"),
        sample("g6", .claude, .working, "Weather widget", "Editing ContentView.swift", warning: false),
        sample("g7", .claude, .error, "Ship the new wheel", "Rate limited. Try again in a moment"),
        sample("g8", .claude, .interrupted, "Rename the columns", "Interrupted"),
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(70), spacing: 12), count: 6), spacing: 12) {
                ForEach(0..<24, id: \.self) { i in
                    let seed = UInt64(i) &* 0x9e37_79b9_7f4a_7c15 &+ 11
                    VStack(spacing: 6) {
                        let animation = i < DotAnimation.allCases.count ? DotAnimation.allCases[i] : nil
                        Loader(seed: seed, tint: i % 2 == 0 ? .claude : .codex, animation: animation).frame(width: 44, height: 44)
                        Loader(seed: seed, tint: i % 2 == 0 ? .claude : .codex, animation: animation).frame(width: 22, height: 22)
                    }
                    .frame(width: 70, height: 80)
                }
            }
            GlassEffectContainer(spacing: 0) {
                VStack(spacing: 8) {
                    IdlePill(hooksInstalled: true)
                    ForEach(samples) { SessionPill(session: $0, hovering: false) }
                }
            }
        }
        .padding(24)
        .background(
            LinearGradient(colors: [Color(red: 0.93, green: 0.78, blue: 0.45), Color(red: 0.35, green: 0.36, blue: 0.42)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }
}
