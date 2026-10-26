import AppKit
import Combine
import SwiftUI

/// A music app the pill can follow. Only apps with AppleScript and a "track changed"
/// broadcast qualify: macOS 15.4+ keeps the system-wide Now Playing info to Apple's own apps.
enum MusicPlayer: String, CaseIterable {
    case spotify, music

    var bundleId: String { self == .spotify ? "com.spotify.client" : "com.apple.Music" }
    var appName: String { self == .spotify ? "Spotify" : "Music" }
    var notification: String { self == .spotify ? "com.spotify.client.PlaybackStateChanged" : "com.apple.Music.playerInfo" }
    var tint: Color { self == .spotify ? Color(red: 0.11, green: 0.73, blue: 0.33) : Color(red: 0.98, green: 0.25, blue: 0.35) }

    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty }
    var icon: NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}

struct NowPlaying: Equatable {
    var player: MusicPlayer
    var trackId: String
    var title: String
    var artist: String
    var album: String
    var playing: Bool
    var duration: TimeInterval
    /// Position at `positionAt`; it moves on from there while playing.
    var position: TimeInterval
    var positionAt: Date
    var artworkURL: String

    func position(at now: Date) -> TimeInterval {
        let p = playing ? position + now.timeIntervalSince(positionAt) : position
        return duration > 0 ? min(max(p, 0), duration) : max(p, 0)
    }
}

extension Animation {
    /// Shape changes: hiding, showing, shrinking around a session. Soft, with a hint of overshoot.
    static let musicMorph = Animation.spring(duration: 0.6, bounce: 0.16)
    /// Things settling back after the new-song moment.
    static let musicSettle = Animation.smooth(duration: 0.7)
}

/// Follows Spotify and Apple Music. Their broadcasts say when a track or state changes; a
/// short AppleScript read then fills in position and artwork. Apps that aren't running are
/// never scripted, since `tell application` would launch them.
@MainActor
final class NowPlayingStore: ObservableObject {
    static let shared = NowPlayingStore()

    @Published private(set) var current: NowPlaying?
    @Published private(set) var artwork: NSImage? {
        didSet { artworkColor = artwork.flatMap(Self.averageColor) }
    }
    /// The cover's overall colour, washed behind the pill while you hover it.
    @Published private(set) var artworkColor: Color?
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "pill.nowPlaying")
            if enabled { refreshAll() } else { current = nil }
        }
    }

    /// True for a few seconds after the song changes, while the pill shows it off.
    @Published private(set) var announcing = false
    /// Tucked away into a little disc next to the handle.
    @Published private(set) var collapsed = UserDefaults.standard.bool(forKey: "pill.musicCollapsed")

    private var tracks: [MusicPlayer: NowPlaying] = [:]
    private var songKey: String?
    private var announceGeneration = 0
    private var artworkKey: String?
    private var observers: [Any] = []
    private var timer: Timer?

    private init() {
        enabled = UserDefaults.standard.object(forKey: "pill.nowPlaying") as? Bool ?? true
    }

    func start() {
        let dnc = DistributedNotificationCenter.default()
        for player in MusicPlayer.allCases {
            observers.append(dnc.addObserver(forName: .init(player.notification), object: nil, queue: .main) { [weak self] note in
                let info = note.userInfo ?? [:]
                Task { @MainActor in self?.received(player, info) }
            })
        }
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor in
                guard let self, let player = MusicPlayer.allCases.first(where: { $0.bundleId == id }) else { return }
                self.tracks[player] = nil
                self.publish()
            }
        })
        // Catches seeking, which sends no broadcast, and corrects drift.
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.current?.playing == true else { return }
                self.refreshAll()
            }
        }
        refreshAll()
    }

    // MARK: Controls

    func playPause() {
        guard let c = current else { return }
        // Flip right away; the app's broadcast confirms it a moment later.
        var t = c
        t.position = c.position(at: .now)
        t.positionAt = .now
        t.playing.toggle()
        tracks[c.player] = t
        publish()
        run(c.player, "playpause")
    }

    func seek(to seconds: TimeInterval) {
        guard let c = current, c.duration > 0 else { return }
        var t = c
        t.position = min(max(seconds, 0), c.duration)
        t.positionAt = .now
        tracks[c.player] = t
        publish()
        run(c.player, "set player position to \(String(format: "%.2f", t.position))")
    }

    func setCollapsed(_ on: Bool) {
        guard on != collapsed else { return }
        UserDefaults.standard.set(on, forKey: "pill.musicCollapsed")
        withAnimation(.musicMorph) {
            collapsed = on
            announcing = false
        }
    }

    func next() { if let p = current?.player { run(p, "next track") } }
    func previous() { if let p = current?.player { run(p, "previous track") } }

    func openApp() {
        guard let p = current?.player, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: p.bundleId) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    private func run(_ player: MusicPlayer, _ command: String) {
        guard player.isRunning else { return }
        _ = script("tell application \"\(player.appName)\" to \(command)")
    }

    // MARK: Reading

    private func received(_ player: MusicPlayer, _ info: [AnyHashable: Any]) {
        guard enabled else { return }
        let state = (info["Player State"] as? String ?? "").lowercased()
        if state == "stopped" || !player.isRunning {
            tracks[player] = nil
            publish()
            return
        }
        // The broadcast alone is enough to show something if scripting isn't allowed.
        if let title = info["Name"] as? String {
            var t = tracks[player] ?? NowPlaying(player: player, trackId: "", title: "", artist: "", album: "",
                                                 playing: false, duration: 0, position: 0, positionAt: .now, artworkURL: "")
            let id = info["Track ID"] as? String ?? info["PersistentID"].map { "\($0)" } ?? title
            if id != t.trackId { t.artworkURL = ""; t.position = 0 }
            t.trackId = id
            t.title = title
            t.artist = info["Artist"] as? String ?? ""
            t.album = info["Album"] as? String ?? ""
            t.playing = state == "playing"
            if let ms = (info["Duration"] ?? info["Total Time"]) as? Double { t.duration = ms / 1000 }
            if let pos = info["Playback Position"] as? Double { t.position = pos }
            t.positionAt = .now
            tracks[player] = t
            publish()
        }
        refresh(player)
    }

    private func refreshAll() {
        guard enabled else { return }
        for player in MusicPlayer.allCases { refresh(player) }
    }

    private func refresh(_ player: MusicPlayer) {
        guard enabled else { return }
        guard player.isRunning else {
            if tracks.removeValue(forKey: player) != nil { publish() }
            return
        }
        let art = player == .spotify ? "artwork url of t" : "\"\""
        let id = player == .spotify ? "id of t" : "persistent ID of t"
        let duration = player == .spotify ? "(duration of t) / 1000" : "duration of t"
        let source = """
        tell application "\(player.appName)"
            set s to player state as string
            if s is "stopped" then return {s}
            set t to current track
            return {s, name of t, artist of t, album of t, \(duration), player position, \(art), \(id)}
        end tell
        """
        guard let r = script(source), r.numberOfItems >= 1 else { return } // not allowed, or no answer
        let state = r.atIndex(1)?.stringValue ?? "stopped"
        guard state != "stopped", r.numberOfItems >= 8 else {
            tracks[player] = nil
            publish()
            return
        }
        func str(_ i: Int) -> String { r.atIndex(i)?.stringValue ?? "" }
        func num(_ i: Int) -> Double { r.atIndex(i)?.doubleValue ?? Double(str(i)) ?? 0 }
        tracks[player] = NowPlaying(player: player, trackId: str(8), title: str(2), artist: str(3), album: str(4),
                                    playing: state == "playing", duration: num(5), position: num(6),
                                    positionAt: .now, artworkURL: str(7))
        publish()
    }

    private func publish() {
        // The one playing wins; otherwise whichever app is still paused on a track.
        let pick = tracks.values.first { $0.playing } ?? tracks[.spotify] ?? tracks[.music]
        let next = enabled ? pick : nil
        AudioPulse.shared.follow(next?.playing == true ? next?.player.bundleId : nil)
        if next != current {
            withAnimation(.musicMorph) { current = next }
        }
        loadArtwork(for: next)

        // A new song (not the first one seen at launch) gets a moment in the spotlight.
        let key = next.map { "\($0.player.rawValue):\($0.title)|\($0.artist)" }
        if let key, let old = songKey, key != old {
            if !collapsed { announce() }
            // The player is tucked into the disc next to the handle: say it in the island instead.
            else if let next, PanelController.shared.isShown {
                let text = next.artist.isEmpty ? next.title : "\(next.title) — \(next.artist)"
                Island.shared.post(IslandNotice(symbol: "music.note", name: "Now playing", text: text,
                                                level: .info, seconds: 4))
            }
        }
        if key != nil { songKey = key }
    }

    private func announce() {
        announceGeneration += 1
        let generation = announceGeneration
        withAnimation(.spring(duration: 0.55, bounce: 0.22)) { announcing = true }
        Task {
            try? await Task.sleep(for: .seconds(3.2))
            guard generation == self.announceGeneration else { return }
            withAnimation(.musicSettle) { self.announcing = false }
        }
    }

    private func loadArtwork(for track: NowPlaying?) {
        guard let track else { artworkKey = nil; artwork = nil; return }
        // Keyed on what's shown: the broadcast and the script name Music's tracks differently.
        let key = "\(track.player.rawValue):\(track.title)|\(track.artist)|\(track.album)"
        guard key != artworkKey, !track.title.isEmpty else { return }
        artworkKey = key
        artwork = nil
        switch track.player {
        case .spotify:
            guard let url = URL(string: track.artworkURL), !track.artworkURL.isEmpty else { artworkKey = nil; return }
            Task {
                guard let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) else { return }
                if self.artworkKey == key { self.artwork = image }
            }
        case .music:
            let r = script("tell application \"Music\" to get raw data of artwork 1 of current track")
            if let data = r?.data, let image = NSImage(data: data) { artwork = image }
        }
    }

    /// The cover shrunk to one pixel, with its saturation nudged up so the wash doesn't go grey.
    private static func averageColor(_ image: NSImage) -> Color? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let px = ctx.data?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let c = NSColor(srgbRed: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
        var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
        return Color(hue: h, saturation: min(sat * 1.35, 1), brightness: max(b, 0.45))
    }

    private func script(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result : nil
    }
}

// MARK: - Pill

/// What Spotify or Music is playing, with play/pause and skip. Click the cover or title to
/// bring the app forward.
struct NowPlayingPill: View {
    let track: NowPlaying
    let hovering: Bool
    /// A session needs you: shrink to just the cover so the question isn't pushed down.
    var compact = false
    /// Shared with the disc by the handle, so the cover flies between them.
    let space: Namespace.ID
    @ObservedObject var store = NowPlayingStore.shared

    /// Bigger cover and more detail: while hovered, and briefly when a new song starts.
    private var expanded: Bool { hovering || (store.announcing && !compact) }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: compact && !hovering ? 14 : 22, style: .continuous) }

    var body: some View {
        Group {
            if compact && !hovering {
                cover(size: 34, corner: 9)
                    .padding(6)
                    .glassEffect(.regular.tint(.pillBase).interactive(), in: shape)
                    .help("\(track.title) · \(track.artist)")
                    .frame(width: pillWidth, alignment: .leading)
                    .transition(.opacity)
            } else {
                full.transition(.opacity)
            }
        }
        .animation(.musicMorph, value: compact)
    }

    private var full: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 11) {
                cover(size: expanded ? 54 : 36, corner: expanded ? 12 : 9)
                VStack(alignment: .leading, spacing: 1) {
                    if store.announcing && !hovering {
                        Text("Now playing")
                            .font(.system(size: 9.5, weight: .semibold))
                            .textCase(.uppercase)
                            .kerning(0.6)
                            .foregroundStyle(store.artworkColor ?? track.player.tint)
                            .transition(.blurReplace(.downUp))
                    }
                    Text(track.title)
                        .font(.system(size: expanded ? 13.5 : 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(track.artist.isEmpty ? track.album : track.artist)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if hovering, !track.album.isEmpty, !track.artist.isEmpty {
                        Text(track.album)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .transition(.opacity)
                    }
                }
                .id(track.title + track.artist) // the new song's text slides in instead of swapping in place
                .transition(.blurReplace(.downUp))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { store.openApp() }
                .help("Open \(track.player.appName)")

                HStack(spacing: 2) {
                    control("backward.fill", 10.5, "Previous track") { store.previous() }
                    control(track.playing ? "pause.fill" : "play.fill", 14, track.playing ? "Pause" : "Play") { store.playPause() }
                    control("forward.fill", 10.5, "Next track") { store.next() }
                }
            }

            if hovering, track.duration > 0 {
                Scrubber(track: track, tint: store.artworkColor ?? track.player.tint)
                    .transition(.blurReplace.combined(with: .scale(0.97, anchor: .top)))
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.top, expanded ? 11 : 8)
        .padding(.bottom, expanded ? 10 : 8)
        .frame(width: pillWidth, alignment: .leading)
        .background {
            // A soft wash of the cover's colour, from behind the art outward.
            if expanded, let color = store.artworkColor {
                RadialGradient(colors: [color.opacity(0.32), color.opacity(0.08)],
                               center: .init(x: 0.12, y: 0.3), startRadius: 4, endRadius: 260)
                    .clipShape(shape)
                    .transition(.opacity)
            }
        }
        .glassEffect(.regular.tint(.pillBase).interactive(), in: shape)
        .overlay(alignment: .bottom) {
            if !hovering, track.duration > 0 {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    PlaybackBar(fraction: track.position(at: ctx.date) / track.duration, tint: track.player.tint)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 3.5)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.8), value: store.artworkColor)
    }

    private func cover(size: CGFloat, corner: CGFloat) -> some View {
        CoverArt(track: track, artwork: store.artwork)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .matchedGeometryEffect(id: "cover", in: space)
            .animation(.smooth(duration: 0.5), value: store.artwork)
            .modifier(BeatPop(playing: track.playing))
            .contentShape(Rectangle())
            .onTapGesture {
                // Hovered: tuck the player away into the handle. Otherwise bring the app forward.
                if hovering { store.setCollapsed(true) } else { store.openApp() }
            }
            .help(hovering ? "Hide the player" : "Open \(track.player.appName)")
    }

    private func control(_ symbol: String, _ size: CGFloat, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Elapsed time, a bar you can click or drag to jump around the track, and time left.
private struct Scrubber: View {
    let track: NowPlaying
    let tint: Color
    @State private var dragging: Double?
    @State private var over = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let fraction = dragging ?? track.position(at: ctx.date) / track.duration
            HStack(spacing: 8) {
                Text(clock(fraction * track.duration))
                    .frame(width: 34, alignment: .leading)
                GeometryReader { geo in
                    let w = geo.size.width
                    let thick: CGFloat = over || dragging != nil ? 6 : 4
                    ZStack(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.12)).frame(height: thick)
                        Capsule().fill(tint).frame(width: max(thick, w * min(max(fraction, 0), 1)), height: thick)
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onHover { over = $0 }
                    // Beats the window-drag gesture, so dragging here seeks instead of moving the pill.
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { dragging = min(max($0.location.x / max(w, 1), 0), 1) }
                            .onEnded { v in
                                let f = min(max(v.location.x / max(w, 1), 0), 1)
                                NowPlayingStore.shared.seek(to: f * track.duration)
                                dragging = nil
                            }
                    )
                    .animation(.spring(duration: 0.25), value: thick)
                }
                .frame(height: 14)
                Text("-" + clock((1 - fraction) * track.duration))
                    .frame(width: 38, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.trailing, 4)
    }

    private func clock(_ t: Double) -> String {
        let s = max(0, Int(t.rounded()))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct PlaybackBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.1))
                Capsule().fill(tint.opacity(0.85))
                    .frame(width: max(3, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 2.5)
        .animation(.linear(duration: 1), value: fraction)
    }
}

/// Makes the cover jump out of the pill on each kick of the music. Without audio access it
/// just breathes gently while playing.
private struct BeatPop: ViewModifier {
    let playing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        TimelineView(.animation(paused: !playing || reduceMotion)) { ctx in
            let pulse = AudioPulse.shared
            let kick: Double = !playing || reduceMotion ? 0
                : pulse.live ? Double(min(pulse.kick, 1.2)) / 1.2
                : 0.1 * (1 + sin(ctx.date.timeIntervalSinceReferenceDate * 2.4))
            content
                .scaleEffect(1 + 0.08 * kick)
                .shadow(color: .black.opacity(0.15 + 0.12 * kick), radius: 2 + 3 * kick, y: 1 + 1.5 * kick)
        }
        .animation(.smooth(duration: 0.5), value: playing)
    }
}

private struct CoverArt: View {
    let track: NowPlaying
    let artwork: NSImage?

    var body: some View {
        ZStack {
            if let artwork {
                Image(nsImage: artwork).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    .id(ObjectIdentifier(artwork)) // each new cover blurs in over the last
                    .transition(.blurReplace)
            } else if let icon = track.player.icon {
                Image(nsImage: icon).resizable().interpolation(.high).padding(3)
                    .transition(.blurReplace)
            }
        }
    }
}

/// The hidden player: a little record next to the handle that spins while the song plays
/// and bounces to the beat. Click it to bring the player back.
struct MiniDisc: View {
    let track: NowPlaying
    let space: Namespace.ID
    @ObservedObject var store = NowPlayingStore.shared
    @State private var spin = Spin()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { ctx in
            ZStack {
                CoverArt(track: track, artwork: store.artwork)
                // Grooves and the spindle hole, so it reads as a record.
                Circle().strokeBorder(.black.opacity(0.18), lineWidth: 0.6).padding(4)
                Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.6).padding(7)
                Circle().fill(.black.opacity(0.55)).frame(width: 5, height: 5)
                    .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 0.6))
            }
            .rotationEffect(.degrees(reduceMotion ? 0 : spin.angle(at: ctx.date, playing: track.playing)))
            .frame(width: 24, height: 24)
            .clipShape(Circle())
        }
        .matchedGeometryEffect(id: "cover", in: space)
        .modifier(BeatPop(playing: track.playing))
        .padding(4)
        .glassEffect(.regular.tint(.pillBase).interactive(), in: Circle())
        .contentShape(Circle())
        .onTapGesture { store.setCollapsed(false) }
        .help("\(track.title) · \(track.artist) — click to show the player")
        .accessibilityLabel("Show the music player")
    }
}

/// A record's spin that winds up when the music starts and coasts to a stop when it pauses,
/// like a turntable, rather than starting and stopping dead.
private final class Spin {
    private var angle: Double = 0
    private var speed: Double = 0 // degrees per second
    private var last: Date?

    func angle(at now: Date, playing: Bool) -> Double {
        let dt = min(now.timeIntervalSince(last ?? now), 0.1)
        last = now
        let target: Double = playing ? 72 : 0
        speed += (target - speed) * (1 - exp(-dt / (playing ? 0.35 : 0.6)))
        angle = (angle + speed * dt).truncatingRemainder(dividingBy: 360)
        return angle
    }
}
