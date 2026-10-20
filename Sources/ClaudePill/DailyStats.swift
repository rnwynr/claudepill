import Foundation

/// What the agents got through today, built from turns the pill saw finish.
struct DayStats: Codable, Equatable {
    struct Session: Codable, Equatable {
        var title: String
        var agent: String
        var seconds: Double
        var turns: Int
    }

    var turns = 0
    var seconds: Double = 0
    var sessions: [String: Session] = [:]
    /// "<session>@<turn start>" of every turn already counted, so none is counted twice.
    var counted: Set<String> = []

    var busiest: Session? { sessions.values.max { $0.seconds < $1.seconds } }

    func seconds(for agent: Agent) -> Double {
        sessions.values.filter { $0.agent == agent.rawValue }.reduce(0) { $0 + $1.seconds }
    }
}

@MainActor
final class DailyStatsStore: ObservableObject {
    static let shared = DailyStatsStore()

    @Published private(set) var today = DayStats()
    private var dayKey = DailyStatsStore.key(for: Date())
    private static let defaultsKey = "stats.days"

    private init() { load() }

    static func key(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Records a finished turn: from its start until the session went quiet.
    func recordTurn(of session: SessionInfo) {
        rollOverIfNeeded()
        let id = "\(session.id)@\(Int(session.turnStartedAt.timeIntervalSince1970))"
        guard !today.counted.contains(id) else { return }
        let seconds = session.updatedAt.timeIntervalSince(session.turnStartedAt)
        guard seconds > 0, seconds < 12 * 3600 else { return }
        today.counted.insert(id)
        today.turns += 1
        today.seconds += seconds
        var s = today.sessions[session.id] ?? .init(title: session.title, agent: session.agent.rawValue, seconds: 0, turns: 0)
        s.title = session.title
        s.seconds += seconds
        s.turns += 1
        today.sessions[session.id] = s
        save()
    }

    func rollOverIfNeeded() {
        let key = Self.key(for: Date())
        guard key != dayKey else { return }
        dayKey = key
        today = DayStats()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let days = try? JSONDecoder().decode([String: DayStats].self, from: data) else { return }
        today = days[dayKey] ?? DayStats()
    }

    private func save() {
        var days = (UserDefaults.standard.data(forKey: Self.defaultsKey))
            .flatMap { try? JSONDecoder().decode([String: DayStats].self, from: $0) } ?? [:]
        days[dayKey] = today
        // Two weeks is plenty.
        let keep = Set(days.keys.sorted().suffix(14))
        days = days.filter { keep.contains($0.key) }
        if let data = try? JSONEncoder().encode(days) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }

    /// "14 turns · 3hr 40min of agent time"
    var summary: String {
        "\(today.turns) turn\(today.turns == 1 ? "" : "s") · \(UsageStore.duration(today.seconds)) of agent time"
    }
}
