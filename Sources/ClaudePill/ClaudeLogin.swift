import Foundation

/// The Claude Code CLI's login, as it keeps it in the Keychain item "Claude Code-credentials".
struct CLILogin {
    static let service = "Claude Code-credentials"
    // The CLI's own OAuth client and token endpoint.
    private static let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!

    let accessToken: String
    let refreshToken: String?
    /// Milliseconds since 1970, like the CLI writes it.
    let expiresAt: Double?
    let plan: String?

    /// Expired, or about to be: a minute's margin so it doesn't lapse mid-request.
    var expired: Bool {
        guard let expiresAt, expiresAt > 0 else { return false }
        return expiresAt / 1000 < Date().timeIntervalSince1970 + 60
    }

    nonisolated static func load() -> CLILogin? {
        guard let root = readItem(), let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return CLILogin(accessToken: token, refreshToken: oauth["refreshToken"] as? String,
                        expiresAt: oauth["expiresAt"] as? Double, plan: oauth["subscriptionType"] as? String)
    }

    // MARK: Refresh

    private nonisolated(unsafe) static let lock = NSLock()
    private nonisolated(unsafe) static var lastFailure: (at: Date, why: UsageFailure)?

    /// Trades the refresh token for a new login and saves it where the CLI will find it.
    /// `force` refreshes even a login that looks current (the API just rejected it).
    nonisolated static func refresh(force: Bool = false) -> Result<CLILogin, UsageFailure> {
        lock.lock()
        defer { lock.unlock() }
        // Don't keep hammering the token endpoint after it said no.
        if let last = lastFailure, Date().timeIntervalSince(last.at) < 10 * 60 { return .failure(last.why) }

        // The CLI may have refreshed it meanwhile; read it again right before using it,
        // because a refresh token only works once.
        guard let current = load() else { return fail("The Claude Code CLI isn't signed in. Run `claude` in a terminal, then /login.") }
        if !force && !current.expired { return .success(current) }
        guard let refreshToken = current.refreshToken, !refreshToken.isEmpty else {
            return fail("The Claude Code login has expired. Run `claude` in a terminal to renew it.")
        }

        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientId,
        ])
        req.timeoutInterval = 15
        let (data, status) = ClaudeUsage.send(req)
        guard status == 200, let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty else {
            if status == 0 { return .failure(UsageFailure(message: "Couldn't reach Anthropic to renew the Claude Code login.")) }
            return fail("The Claude Code login couldn't be renewed (\(status)). Run `claude` in a terminal to sign in again.")
        }

        // Merge into the item so everything else in it (MCP logins…) is kept.
        guard var root = readItem(), var oauth = root["claudeAiOauth"] as? [String: Any] else {
            return fail("The Claude Code login changed while renewing it.")
        }
        oauth["accessToken"] = access
        if let r = json["refresh_token"] as? String, !r.isEmpty { oauth["refreshToken"] = r }
        if let secs = json["expires_in"] as? Double { oauth["expiresAt"] = ((Date().timeIntervalSince1970 + secs) * 1000).rounded() }
        if let scope = json["scope"] as? String { oauth["scopes"] = scope.split(separator: " ").map(String.init) }
        root["claudeAiOauth"] = oauth
        guard writeItem(root), let saved = load(), saved.accessToken == access else {
            return fail("Renewed the Claude Code login but couldn't save it. Run `claude` in a terminal, then /login.")
        }
        lastFailure = nil
        return .success(saved)
    }

    private static func fail(_ message: String) -> Result<CLILogin, UsageFailure> {
        let why = UsageFailure(message: message)
        lastFailure = (Date(), why)
        return .failure(why)
    }

    // MARK: Keychain, through /usr/bin/security like the CLI, so its access list applies

    private nonisolated static func readItem() -> [String: Any]? {
        guard let (out, ok) = security(["find-generic-password", "-s", service, "-w"]), ok else { return nil }
        return try? JSONSerialization.jsonObject(with: out) as? [String: Any]
    }

    private nonisolated static func writeItem(_ root: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: root) else { return false }
        let hex = data.map { String(format: "%02x", $0) }.joined()
        return security(["add-generic-password", "-U", "-a", account(), "-s", service, "-X", hex])?.1 == true
    }

    /// The item's account name, which the CLI sets to the login user.
    private nonisolated static func account() -> String {
        if let (out, _) = security(["find-generic-password", "-s", service]),
           let text = String(data: out, encoding: .utf8),
           let line = text.split(separator: "\n").first(where: { $0.contains("\"acct\"<blob>=\"") }),
           let start = line.range(of: "<blob>=\"")?.upperBound, line.hasSuffix("\"") {
            return String(line[start..<line.index(before: line.endIndex)])
        }
        return NSUserName()
    }

    private nonisolated static func security(_ args: [String]) -> (Data, Bool)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (data, p.terminationStatus == 0)
    }
}
