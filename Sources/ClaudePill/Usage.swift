import AppKit
import Foundation

/// One rate-limit window: how much of it is used and when it starts over.
struct UsageWindow: Equatable {
    var usedPercent: Double
    var resetsAt: Date?
    /// Length of the window: 300 for the 5-hour one, 10080 for the weekly one.
    var minutes: Double?
    /// When it runs out at the current pace, if that's before it resets.
    var emptyAt: Date?
}

/// The 5-hour and weekly limits of one account.
struct UsageReport: Equatable {
    var fiveHour: UsageWindow?
    var weekly: UsageWindow?
    var plan: String?
    var updatedAt: Date
    /// Set when the numbers couldn't be read; the windows may still hold older values.
    var problem: String?
}

/// Claude's and every saved Codex account's limits, for the panel above the pills.
@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published private(set) var claude: UsageReport? {
        didSet {
            guard let claude else { return }
            let paced = pace("claude", claude)
            if paced != claude { self.claude = paced }
            watch("claude", agent: .claude, name: "Claude", paced)
        }
    }
    @Published private(set) var codexAccounts: [CodexAccount] = []
    @Published private(set) var codexUsage: [String: UsageReport] = [:] {
        didSet {
            for (id, report) in codexUsage where oldValue[id] != report {
                let paced = pace("codex.\(id)", report)
                if paced != report { codexUsage[id] = paced }
                let label = codexAccounts.first { $0.id == id }?.label
                watch("codex.\(id)", agent: .codex, name: label.map { "Codex · \($0)" } ?? "Codex", paced)
            }
        }
    }
    /// Usage of the signed-in Codex login when it isn't one of the saved accounts.
    @Published private(set) var codexLive: UsageReport? {
        didSet {
            guard let codexLive else { return }
            let paced = pace("codex.live", codexLive)
            if paced != codexLive { self.codexLive = paced }
            watch("codex.live", agent: .codex, name: "Codex", paced)
        }
    }

    @Published private(set) var codexLiveEmail: String?
    @Published private(set) var liveAccountId: String?
    @Published private(set) var refreshing = false
    /// What the account switcher is doing right now, shown in place of the account rows.
    @Published var busy: String?
    /// Clears itself a minute after it's shown.
    @Published var lastError: String? {
        didSet {
            errorClear?.cancel()
            guard let lastError else { return }
            // The panel shows it when open; otherwise the island does, so it isn't missed.
            if !PanelController.shared.usageOpen {
                push(IslandNotice(agent: .codex, name: "Codex accounts", text: lastError, level: .critical))
            }
            errorClear = Task { @MainActor in
                try? await Task.sleep(for: .seconds(60))
                if !Task.isCancelled { UsageStore.shared.lastError = nil }
            }
        }
    }
    private var errorClear: Task<Void, Never>?

    private var lastRefresh = Date.distantPast
    private var timer: Timer?

    func start() {
        // Development aid: `defaults write local.boywithalo.claudepill pill.demoAlerts -bool true`.
        if UserDefaults.standard.bool(forKey: "pill.demoAlerts") {
            push(IslandNotice(agent: .codex, name: "Codex · work", window: "5hr", text: "12% left", level: .low))
            push(IslandNotice(agent: .claude, name: "Claude", window: "Weekly", text: "4% left", level: .critical))
            push(IslandNotice(agent: .codex, name: "Codex · rahikm", window: "5hr", text: "limit reset", level: .reset))
        }
        refresh()
        // The status line can update Claude's numbers at any time, and reading them is cheap.
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in
                let store = UsageStore.shared
                store.takeClaudeFile()
                store.recapIfDue()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { _ in
            Task { @MainActor in UsageStore.shared.refresh() }
        }
    }

    /// Called when the panel opens; skips the work if the numbers are fresh.
    func refreshIfStale() {
        if Date().timeIntervalSince(lastRefresh) > 60 { refresh() }
        else { takeClaudeFile() }
    }

    /// Uses the status line's numbers when they're newer than what's shown.
    private func takeClaudeFile() {
        if let fresh = ClaudeUsage.read(), fresh.updatedAt > (claude?.updatedAt ?? .distantPast) { claude = fresh }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        lastRefresh = Date()
        takeClaudeFile()
        reloadAccounts()
        Task.detached(priority: .utility) {
            let result = ClaudeUsage.fetchFromAPI()
            await MainActor.run {
                let store = UsageStore.shared
                switch result {
                case .success(let live):
                    // Keep whichever reading is newer: the API's or the status line's.
                    if let c = store.claude, c.updatedAt > live.updatedAt, c.problem == nil { return }
                    store.claude = live
                case .failure(let why):
                    // Keep the last numbers but say why they aren't moving.
                    var r = store.claude ?? UsageReport(updatedAt: .distantPast)
                    r.problem = why.message
                    if r != store.claude { store.claude = r }
                }
            }
        }

        let accounts = codexAccounts
        let live = liveAccountId
        Task.detached(priority: .utility) {
            let liveReport = CodexUsage.fetch(home: nil)
            await MainActor.run {
                if let live { UsageStore.shared.codexUsage[live] = liveReport } else { UsageStore.shared.codexLive = liveReport }
            }
            for account in accounts where account.id != live {
                let report = CodexUsage.fetch(savedAccount: account.id)
                await MainActor.run { UsageStore.shared.codexUsage[account.id] = report }
            }
            await MainActor.run { UsageStore.shared.refreshing = false }
        }
    }

    func reloadAccounts() {
        let store = CodexAccountStore.shared
        codexAccounts = store.accounts().sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        liveAccountId = store.liveAccountId()
        codexLiveEmail = store.liveIdentity()?.email
    }

    // MARK: Switching accounts

    /// Closes Codex, swaps the login and opens Codex again, like Codex Account Menu does.
    func switchTo(_ account: CodexAccount) {
        guard busy == nil, account.id != liveAccountId else { return }
        busy = "Switching to \(account.label)…"
        lastError = nil
        Task {
            let wasRunning = CodexApp.running().first?.bundleURL
            let stopped = await CodexApp.quit()
            var failure: String?
            if !stopped {
                failure = "Codex didn't quit, so the login was left alone."
            } else {
                do { try CodexAccountStore.shared.activate(account.id) } catch { failure = error.localizedDescription }
            }
            busy = nil
            lastError = failure
            reloadAccounts()
            if failure == nil { refresh(force: true) }
            // Reopen Codex either way: it was closed for us.
            if stopped { CodexApp.launch(wasRunning) }
        }
    }

    /// Saves the signed-in login so it can be switched back to later.
    func saveCurrent() {
        let label = codexLiveEmail ?? "Account \(codexAccounts.count + 1)"
        do { try CodexAccountStore.shared.saveCurrent(label: label); lastError = nil } catch { lastError = error.localizedDescription }
        reloadAccounts()
        refresh(force: true)
    }

    /// Signs in to another account: Codex closes, the browser opens, the new login is saved.
    func addAccount() {
        guard busy == nil else { return }
        guard let cli = CodexApp.cliURL else { lastError = "Codex's login helper wasn't found in the desktop app."; return }
        let store = CodexAccountStore.shared
        do {
            try store.ensureFileCredentialMode()
            try store.checkpointCurrent()
            try store.stageForNewLogin()
        } catch {
            store.restoreStagedIfNeeded()
            lastError = error.localizedDescription
            return
        }
        busy = "Finish signing in in your browser…"
        lastError = nil
        Task {
            let appURL = CodexApp.running().first?.bundleURL ?? CodexApp.appURL
            guard await CodexApp.quit() else {
                store.restoreStagedIfNeeded()
                busy = nil
                lastError = "Codex didn't quit, so no account was added."
                return
            }
            let ok = await Task.detached { CodexUsage.login(cli: cli) }.value
            var failure: String?
            if ok {
                let label = store.liveIdentity()?.email ?? "Account \(codexAccounts.count + 1)"
                do { try store.saveCurrent(label: label) } catch { failure = error.localizedDescription }
            } else {
                failure = "Sign-in didn't finish, so your previous login was put back."
            }
            if failure == nil { try? FileManager.default.removeItem(at: store.stagedAuthURL) } else { store.restoreStagedIfNeeded() }
            busy = nil
            lastError = failure
            reloadAccounts()
            refresh(force: true)
            CodexApp.launch(appURL)
        }
    }

    func remove(_ account: CodexAccount) {
        do { try CodexAccountStore.shared.remove(account.id); lastError = nil } catch { lastError = error.localizedDescription }
        codexUsage[account.id] = nil
        reloadAccounts()
    }

    // MARK: Daily recap

    /// Once a day, from 9 pm, the island sums up what the agents did.
    func recapIfDue() {
        let stats = DailyStatsStore.shared
        stats.rollOverIfNeeded()
        let today = DailyStatsStore.key(for: Date())
        guard Calendar.current.component(.hour, from: Date()) >= 21,
              UserDefaults.standard.string(forKey: "stats.recapShown") != today,
              stats.today.turns > 0 else { return }
        UserDefaults.standard.set(today, forKey: "stats.recapShown")
        push(IslandNotice(symbol: "sun.horizon.fill", name: "Today", text: stats.summary, level: .info))
    }

    // MARK: Pace

    /// Recent readings per account and window, to work out how fast each one is being used.
    private var samples: [String: [(at: Date, used: Double, reset: Double)]] = [:]

    /// Fills in `emptyAt`: when each window runs out at the current pace, if before it resets.
    private func pace(_ key: String, _ report: UsageReport) -> UsageReport {
        var r = report
        r.fiveHour = project("\(key).5h", r.fiveHour, at: r.updatedAt)
        r.weekly = project("\(key).week", r.weekly, at: r.updatedAt)
        return r
    }

    private func project(_ key: String, _ window: UsageWindow?, at now: Date) -> UsageWindow? {
        guard var w = window else { return nil }
        w.emptyAt = nil
        guard let reset = w.resetsAt, reset > now, w.usedPercent < 100 else {
            if w.usedPercent >= 100 { w.emptyAt = nil }
            return w
        }
        let resetTs = reset.timeIntervalSince1970

        // Keep the last few hours of readings from this same window.
        var list = (samples[key] ?? []).filter { abs($0.reset - resetTs) < 120 && now.timeIntervalSince($0.at) < 3 * 3600 }
        if list.last.map({ now.timeIntervalSince($0.at) > 30 || $0.used != w.usedPercent }) ?? true {
            list.append((now, w.usedPercent, resetTs))
        }
        samples[key] = list

        // Percent used per second. For the 5-hour window, recent readings when they span 15
        // minutes or more; otherwise, and always for the week (where an hour of heavy use says
        // little about the next six days), the average since the window started.
        var rate: Double?
        let shortWindow = (w.minutes ?? 300) <= 1440
        if shortWindow, let first = list.first, now.timeIntervalSince(first.at) >= 15 * 60, w.usedPercent > first.used {
            rate = (w.usedPercent - first.used) / now.timeIntervalSince(first.at)
        } else if let minutes = w.minutes {
            let elapsed = minutes * 60 - reset.timeIntervalSince(now)
            if elapsed > max(10 * 60, minutes * 60 * 0.05), w.usedPercent >= 2 { rate = w.usedPercent / elapsed }
        }
        if let rate, rate > 0 {
            let empty = now.addingTimeInterval((100 - w.usedPercent) / rate)
            if empty < reset { w.emptyAt = empty }
        }
        return w
    }

    // MARK: Alerts

    /// Remembers, per account and window, the lowest warning already shown and the reset
    /// time it belonged to, so each warning appears once per window, even across relaunches.
    private var alerted: [String: [String: Double]] =
        UserDefaults.standard.dictionary(forKey: "usage.alerted") as? [String: [String: Double]] ?? [:]

    private func watch(_ key: String, agent: Agent, name: String, _ report: UsageReport) {
        guard report.problem == nil || report.fiveHour != nil else { return }
        check("\(key).5h", agent: agent, name: name, window: "5hr", report.fiveHour)
        check("\(key).week", agent: agent, name: name, window: "Weekly", report.weekly)
        UserDefaults.standard.set(alerted, forKey: "usage.alerted")
    }

    private func check(_ key: String, agent: Agent, name: String, window: String, _ w: UsageWindow?) {
        guard let w else { return }
        let left = max(0, 100 - w.usedPercent)
        let reset = w.resetsAt?.timeIntervalSince1970 ?? 0
        var seen = alerted[key] ?? [:]

        // A new window: the reset time jumped ahead (or the old one has passed).
        if let lastReset = seen["reset"], lastReset > 0, reset > lastReset + 60 || (reset == 0 && lastReset < Date().timeIntervalSince1970) {
            if let lastLeft = seen["left"], lastLeft < 100, left > lastLeft {
                push(IslandNotice(agent: agent, name: name, window: window, text: "limit reset", level: .reset))
            }
            seen["level"] = nil
            seen["pace"] = nil
        }

        let level: Double? = left <= 0 ? 0 : left <= 5 ? 5 : left <= 15 ? 15 : nil
        if let level, level < (seen["level"] ?? 101) {
            let text = level == 0 ? "limit reached" : "\(Int(left.rounded(.down)))% left"
            push(IslandNotice(agent: agent, name: name, window: window, text: text, level: level == 15 ? .low : .critical))
            seen["level"] = level
        }
        if level == nil { seen["level"] = nil }
        // Heading for empty within the hour, before the window resets: say so once.
        if let empty = w.emptyAt, level == nil, seen["pace"] == nil, empty.timeIntervalSinceNow < 3600 {
            push(IslandNotice(agent: agent, name: name, window: window,
                              text: "runs out in ~\(Self.duration(empty.timeIntervalSinceNow))", level: .low))
            seen["pace"] = 1
        }
        seen["reset"] = reset
        seen["left"] = left
        alerted[key] = seen
    }

    /// "1hr 20min", "45min", "2d 3hr": zero units left out, minutes dropped past a day.
    static func duration(_ seconds: TimeInterval) -> String {
        let mins = max(1, Int((seconds / 60).rounded(.up)))
        let d = mins / 1440, h = (mins % 1440) / 60, m = mins % 60
        var parts: [String] = []
        if d > 0 { parts.append("\(d)d") }
        if h > 0 { parts.append("\(h)hr") }
        if m > 0, d == 0 { parts.append("\(m)min") }
        return parts.joined(separator: " ")
    }

    private func push(_ notice: IslandNotice) {
        Island.shared.post(notice)
    }

    private func refresh(force: Bool) {
        if force { refreshing = false }
        refresh()
    }
}

// MARK: - Claude

/// Why the numbers couldn't be read, worded for the panel.
struct UsageFailure: Error, Equatable { let message: String }

enum ClaudeUsage {
    /// Claude Code hands its limits to the status line script, which saves them here.
    static let cacheURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/pill/claude-usage.json")

    static func read() -> UsageReport? {
        guard let data = try? Data(contentsOf: cacheURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = root["rate_limits"] as? [String: Any] else { return nil }
        func window(_ key: String) -> UsageWindow? {
            guard let w = limits[key] as? [String: Any] else { return nil }
            let used = (w["used_percentage"] as? Double) ?? (w["utilization"] as? Double) ?? 0
            return UsageWindow(usedPercent: used, resetsAt: date(w["resets_at"]), minutes: key == "five_hour" ? 300 : 10080)
        }
        let ts = (root["ts"] as? Double).map { Date(timeIntervalSince1970: $0) }
            ?? ((try? FileManager.default.attributesOfItem(atPath: cacheURL.path)[.modificationDate]) as? Date) ?? Date()
        var report = UsageReport(fiveHour: window("five_hour"), weekly: window("seven_day"), plan: nil, updatedAt: ts)
        // A window that has since started over is back at zero.
        for kp in [\UsageReport.fiveHour, \UsageReport.weekly] {
            if let w = report[keyPath: kp], let reset = w.resetsAt, reset < Date() {
                report[keyPath: kp] = UsageWindow(usedPercent: 0, resetsAt: nil)
            }
        }
        return report
    }

    typealias Failure = UsageFailure

    /// Asks Anthropic directly, using the Claude Code CLI's own login when it has one.
    /// Desktop-app sessions never run the CLI, so its token expires and nothing renews it;
    /// when that happens this refreshes it the same way the CLI does and saves the new login
    /// back to the Keychain, so the CLI stays signed in.
    nonisolated static func fetchFromAPI() -> Result<UsageReport, Failure> {
        guard var login = CLILogin.load() else {
            return .failure(Failure(message: "The Claude Code CLI isn't signed in. Run `claude` in a terminal, then /login."))
        }
        if login.expired {
            switch CLILogin.refresh() {
            case .success(let fresh): login = fresh
            case .failure(let why): return .failure(why)
            }
        }
        var status = 0
        var body = request(token: login.accessToken, status: &status)
        if status == 401 {
            // Revoked early, or the clock is off: one refresh, then give up.
            guard case .success(let fresh) = CLILogin.refresh(force: true) else {
                return .failure(Failure(message: "The Claude Code login was rejected. Run `claude` in a terminal to sign in again."))
            }
            login = fresh
            body = request(token: login.accessToken, status: &status)
        }
        guard let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return .failure(Failure(message: status == 0 ? "Couldn't reach Anthropic to check usage." : "Anthropic's usage check failed (\(status))."))
        }
        func window(_ key: String) -> UsageWindow? {
            guard let w = json[key] as? [String: Any] else { return nil }
            return UsageWindow(usedPercent: (w["utilization"] as? Double) ?? 0, resetsAt: date(w["resets_at"]),
                               minutes: key == "five_hour" ? 300 : 10080)
        }
        let report = UsageReport(fiveHour: window("five_hour"), weekly: window("seven_day"),
                                 plan: login.plan, updatedAt: Date())
        if report.fiveHour == nil && report.weekly == nil {
            return .failure(Failure(message: "Anthropic's usage check returned no limits."))
        }
        return .success(report)
    }

    private nonisolated static func request(token: String, status: inout Int) -> Data? {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 15
        let (data, code) = send(req)
        status = code
        return code == 200 ? data : nil
    }

    nonisolated static func send(_ req: URLRequest) -> (Data?, Int) {
        let done = DispatchSemaphore(value: 0)
        var result: (Data?, Int) = (nil, 0)
        URLSession.shared.dataTask(with: req) { d, r, _ in
            result = (d, (r as? HTTPURLResponse)?.statusCode ?? 0)
            done.signal()
        }.resume()
        done.wait()
        return result
    }

    nonisolated static func date(_ value: Any?) -> Date? {
        if let n = value as? Double { return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n) }
        if let s = value as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        }
        return nil
    }
}

// MARK: - Codex

enum CodexUsage {
    /// Reads a saved account's limits through a throwaway Codex home holding its login.
    static func fetch(savedAccount id: String) -> UsageReport {
        let store = CodexAccountStore.shared
        let snapshot: Data
        do { snapshot = try store.snapshot(for: id) } catch {
            return UsageReport(updatedAt: Date(), problem: error.localizedDescription)
        }
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("ClaudePill-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: home) }
        do {
            try fm.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let auth = home.appendingPathComponent("auth.json")
            try snapshot.write(to: auth, options: .atomic)
            chmod(auth.path, 0o600)
            try "cli_auth_credentials_store = \"file\"\n".write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        } catch {
            return UsageReport(updatedAt: Date(), problem: "Couldn't prepare the usage check.")
        }
        let report = fetch(home: home)
        // Codex may have refreshed the login while answering; keep the newer copy.
        if report.problem == nil, let refreshed = try? Data(contentsOf: home.appendingPathComponent("auth.json")), refreshed != snapshot {
            store.updateSnapshot(refreshed, for: id)
        }
        return report
    }

    /// Asks `codex app-server` for the account's limits. `home` nil uses the live login.
    static func fetch(home: URL?) -> UsageReport {
        guard let cli = CodexApp.cliURL else {
            return UsageReport(updatedAt: Date(), problem: "Codex isn't installed.")
        }
        let p = Process()
        p.executableURL = cli
        p.arguments = ["app-server"]
        var env = ProcessInfo.processInfo.environment
        if let home { env["CODEX_HOME"] = home.path }
        p.environment = env
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice

        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var buffer = Data()
        var account: [String: Any]?
        var limits: [String: Any]?
        var problem: String?
        var finished = false

        func send(_ msg: [String: Any]) {
            guard var line = try? JSONSerialization.data(withJSONObject: msg) else { return }
            line.append(0x0A)
            try? input.fileHandleForWriting.write(contentsOf: line)
        }
        func finish(_ why: String? = nil) {
            if finished { return }
            finished = true
            if let why { problem = why }
            done.signal()
        }
        func needsLogin(_ err: Any?) -> Bool {
            let text = ((err as? [String: Any])?["message"] as? String ?? "\(err ?? "")").lowercased()
            return ["unauthorized", "authentication", "sign in", "login", "token expired", "401"].contains { text.contains($0) }
        }

        output.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty { return }
            lock.lock(); defer { lock.unlock() }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = msg["id"] as? Int else { continue }
                switch id {
                case 0:
                    send(["method": "initialized", "params": [String: Any]()])
                    send(["method": "account/read", "id": 1, "params": ["refreshToken": false]])
                case 1:
                    if let err = msg["error"] {
                        finish(needsLogin(err) ? "Sign in again to this account" : "Codex couldn't check this login")
                    } else if let a = (msg["result"] as? [String: Any])?["account"] as? [String: Any] {
                        account = a
                        send(["method": "account/rateLimits/read", "id": 2])
                    } else {
                        finish("Sign in again to this account")
                    }
                case 2:
                    if let r = msg["result"] as? [String: Any] { limits = r; finish() }
                    else { finish(needsLogin(msg["error"]) ? "Sign in again to this account" : "Usage isn't available") }
                default: break
                }
            }
        }

        do { try p.run() } catch {
            output.fileHandleForReading.readabilityHandler = nil
            return UsageReport(updatedAt: Date(), problem: "Couldn't start Codex.")
        }
        send(["method": "initialize", "id": 0,
              "params": ["clientInfo": ["name": "claude_pill", "title": "Claude Pill", "version": "1.0"]]])
        if done.wait(timeout: .now() + 20) == .timedOut {
            lock.lock(); finish("Timed out"); lock.unlock()
        }
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if p.isRunning { p.terminate() }
        p.waitUntilExit()

        lock.lock(); defer { lock.unlock() }
        var report = limits.map(normalize) ?? UsageReport(updatedAt: Date())
        report.problem = problem
        if let plan = account?["planType"] as? String { report.plan = plan }
        return report
    }

    private static func normalize(_ result: [String: Any]) -> UsageReport {
        var limits = result["rateLimits"] as? [String: Any]
        if let byId = result["rateLimitsByLimitId"] as? [String: Any] {
            limits = (byId["codex"] as? [String: Any]) ?? limits ?? (byId.values.first as? [String: Any])
        }
        var report = UsageReport(updatedAt: Date())
        report.plan = limits?["planType"] as? String
        for key in ["primary", "secondary"] {
            guard let w = limits?[key] as? [String: Any] else { continue }
            let used = (w["usedPercent"] as? Double) ?? Double(w["usedPercent"] as? Int ?? 0)
            let reset = (w["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
            let minutes = (w["windowDurationMins"] as? Int) ?? 0
            let window = UsageWindow(usedPercent: used, resetsAt: reset, minutes: minutes > 0 ? Double(minutes) : nil)
            if minutes > 1440 { report.weekly = window }
            else if report.fiveHour == nil { report.fiveHour = window }
            else if report.weekly == nil { report.weekly = window }
        }
        return report
    }

    /// Runs `codex login`, which opens the browser and waits for the sign-in to finish.
    static func login(cli: URL) -> Bool {
        let p = Process()
        p.executableURL = cli
        p.arguments = ["-c", "cli_auth_credentials_store=\"file\"", "login"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
