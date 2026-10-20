import AppKit
import Foundation
import Security

/// Saved Codex logins, shared with Codex Account Menu: the same Keychain service and the
/// same index file, so accounts saved in either app show up in both.
///
/// Each login is a full copy of `~/.codex/auth.json` kept in the Keychain. Switching writes
/// a saved copy back to `auth.json` while Codex is closed. Before anything is overwritten,
/// the live login is copied back into its own saved slot (a "checkpoint"), because Codex
/// rotates its refresh token and an old copy would stop working.
struct CodexAccount: Identifiable, Equatable {
    let id: String
    var label: String
    var email: String?
    var accountID: String?
    var lastUsedAt: Date?
}

enum CodexAccountError: LocalizedError {
    case message(String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .message(let m): m
        case .keychain(let s):
            "Keychain: " + ((SecCopyErrorMessageString(s, nil) as String?) ?? "error \(s)")
        }
    }
}

final class CodexAccountStore: @unchecked Sendable {
    static let shared = CodexAccountStore()

    static let keychainService = "local.codex-account-menu.account"

    let authURL: URL
    let configURL: URL
    let storeURL: URL
    private let indexURL: URL
    private let lock = NSLock()

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codex = home.appendingPathComponent(".codex", isDirectory: true)
        authURL = codex.appendingPathComponent("auth.json")
        configURL = codex.appendingPathComponent("config.toml")
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        storeURL = support.appendingPathComponent("CodexAccountMenu", isDirectory: true)
        indexURL = storeURL.appendingPathComponent("accounts.plist")
    }

    var codexInstalled: Bool { FileManager.default.fileExists(atPath: authURL.deletingLastPathComponent().path) }

    // MARK: Index

    private func loadIndex() -> [String: Any] {
        guard let data = try? Data(contentsOf: indexURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return ["accounts": [[String: Any]]()] }
        var index = plist
        index["accounts"] = plist["accounts"] as? [[String: Any]] ?? []
        return index
    }

    private func saveIndex(_ index: [String: Any]) throws {
        try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try PropertyListSerialization.data(fromPropertyList: index, format: .xml, options: 0)
        try data.write(to: indexURL, options: .atomic)
        chmod(indexURL.path, 0o600)
    }

    func accounts() -> [CodexAccount] {
        lock.lock(); defer { lock.unlock() }
        return (loadIndex()["accounts"] as? [[String: Any]] ?? []).compactMap { e in
            guard let id = e["id"] as? String else { return nil }
            return CodexAccount(id: id, label: e["label"] as? String ?? "Account",
                                email: e["email"] as? String, accountID: e["accountID"] as? String,
                                lastUsedAt: e["lastUsedAt"] as? Date)
        }
    }

    // MARK: Live login

    func readAuth() throws -> Data {
        guard let data = try? Data(contentsOf: authURL) else {
            throw CodexAccountError.message("Codex is not signed in.")
        }
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw CodexAccountError.message("The Codex login file is not valid JSON.")
        }
        return data
    }

    /// The email and ChatGPT account id inside a login, read from its id token's claims.
    func identity(_ auth: Data) -> (email: String?, accountID: String?) {
        guard let root = try? JSONSerialization.jsonObject(with: auth) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any] else { return (nil, nil) }
        var accountID = tokens["account_id"] as? String
        var email: String?
        if let token = (tokens["id_token"] as? String) ?? (tokens["access_token"] as? String) {
            let parts = token.split(separator: ".")
            if parts.count > 1 {
                var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                while payload.count % 4 != 0 { payload += "=" }
                if let decoded = Data(base64Encoded: payload),
                   let claims = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any] {
                    email = claims["email"] as? String
                    if accountID == nil, let auth = claims["https://api.openai.com/auth"] as? [String: Any] {
                        accountID = auth["chatgpt_account_id"] as? String
                    }
                }
            }
        }
        return (email, accountID)
    }

    /// The saved account that matches the live login, if any.
    func liveAccountId() -> String? {
        guard let live = try? readAuth(), let liveId = identity(live).accountID else { return nil }
        return accounts().first { $0.accountID == liveId }?.id
    }

    func liveIdentity() -> (email: String?, accountID: String?)? {
        guard let live = try? readAuth() else { return nil }
        return identity(live)
    }

    // MARK: Changes

    /// Saves the live login under `label`, replacing an entry for the same account.
    func saveCurrent(label: String) throws {
        lock.lock(); defer { lock.unlock() }
        let auth = try readAuth()
        let who = identity(auth)
        var index = loadIndex()
        var accounts = index["accounts"] as? [[String: Any]] ?? []
        var entry: [String: Any] = ["id": UUID().uuidString, "createdAt": Date()]
        if let i = accounts.firstIndex(where: { e in
            (who.accountID != nil && e["accountID"] as? String == who.accountID)
                || (who.email != nil && e["email"] as? String == who.email)
        }) {
            entry = accounts.remove(at: i)
        }
        entry["label"] = label
        entry["lastUsedAt"] = Date()
        if let e = who.email { entry["email"] = e }
        if let a = who.accountID { entry["accountID"] = a }
        try setSnapshot(auth, for: entry["id"] as! String, shareWithKeychain: true)
        accounts.append(entry)
        index["accounts"] = accounts
        index["currentID"] = entry["id"]
        try saveIndex(index)
    }

    /// Copies the live login back into its saved slot so a newer refresh token isn't lost.
    func checkpointCurrent() throws {
        lock.lock(); defer { lock.unlock() }
        guard let live = try? readAuth(), let liveId = identity(live).accountID else { return }
        var index = loadIndex()
        for e in index["accounts"] as? [[String: Any]] ?? [] where e["accountID"] as? String == liveId {
            try setSnapshot(live, for: e["id"] as! String)
            index["currentID"] = e["id"]
            try saveIndex(index)
            return
        }
    }

    /// Makes a saved login the live one. Codex must not be running.
    func activate(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        var index = loadIndex()
        var accounts = index["accounts"] as? [[String: Any]] ?? []
        guard let pos = accounts.firstIndex(where: { $0["id"] as? String == id }) else {
            throw CodexAccountError.message("That saved account no longer exists.")
        }
        // Work out the live account from auth.json itself, never from the saved pointer,
        // which a manual login can leave stale.
        if let live = try? readAuth(), let liveId = identity(live).accountID,
           let owner = accounts.first(where: { $0["accountID"] as? String == liveId && $0["id"] as? String != id }) {
            try setSnapshot(live, for: owner["id"] as! String)
        }
        let snapshot = try snapshot(for: id)
        guard (try? JSONSerialization.jsonObject(with: snapshot)) != nil else {
            throw CodexAccountError.message("The saved login is damaged.")
        }
        try atomicWriteAuth(snapshot)
        accounts[pos]["lastUsedAt"] = Date()
        index["accounts"] = accounts
        index["currentID"] = id
        try saveIndex(index)
    }

    /// Forgets a saved login. The OpenAI account itself is untouched.
    func remove(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        var index = loadIndex()
        var accounts = index["accounts"] as? [[String: Any]] ?? []
        accounts.removeAll { $0["id"] as? String == id }
        index["accounts"] = accounts
        if index["currentID"] as? String == id { index.removeValue(forKey: "currentID") }
        if let file = loginFile(id) { try? FileManager.default.removeItem(at: file) }
        SecItemDelete(query(id) as CFDictionary)
        try saveIndex(index)
    }

    /// Stores credentials Codex refreshed while reading usage, but only if they still
    /// belong to the same account.
    func updateSnapshot(_ data: Data, for id: String) {
        lock.lock(); defer { lock.unlock() }
        let who = identity(data)
        guard let entry = (loadIndex()["accounts"] as? [[String: Any]])?.first(where: { $0["id"] as? String == id }) else { return }
        if let saved = entry["accountID"] as? String, saved != who.accountID { return }
        try? setSnapshot(data, for: id)
    }

    // MARK: Adding an account

    var stagedAuthURL: URL { storeURL.appendingPathComponent("auth-before-login.json") }

    /// Moves the live login aside so `codex login` starts clean; restored if login fails.
    func stageForNewLogin() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: storeURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard fm.fileExists(atPath: authURL.path) else { return }
        if fm.fileExists(atPath: stagedAuthURL.path) { try fm.removeItem(at: stagedAuthURL) }
        try fm.copyItem(at: authURL, to: stagedAuthURL)
        chmod(stagedAuthURL.path, 0o600)
        try fm.removeItem(at: authURL)
    }

    func restoreStagedIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: stagedAuthURL.path) else { return }
        if !fm.fileExists(atPath: authURL.path) {
            try? fm.moveItem(at: stagedAuthURL, to: authURL)
            chmod(authURL.path, 0o600)
        } else {
            try? fm.removeItem(at: stagedAuthURL)
        }
    }

    /// Codex must keep its login in auth.json (not its own Keychain item) for switching to work.
    func ensureFileCredentialMode() throws {
        var config = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let wanted = "cli_auth_credentials_store = \"file\""
        let ns = config as NSString
        let root = try NSRegularExpression(pattern: "(?m)^\\s*cli_auth_credentials_store\\s*=.*$")
        if let m = root.firstMatch(in: config, range: NSRange(location: 0, length: ns.length)) {
            if ns.substring(with: m.range).trimmingCharacters(in: .whitespaces) == wanted { return }
            config = root.stringByReplacingMatches(in: config, range: NSRange(location: 0, length: ns.length), withTemplate: wanted)
        } else {
            let table = try NSRegularExpression(pattern: "(?m)^\\s*\\[")
            let at = table.firstMatch(in: config, range: NSRange(location: 0, length: ns.length))?.range.location ?? ns.length
            var prefix = ns.substring(to: at)
            if !prefix.isEmpty, !prefix.hasSuffix("\n") { prefix += "\n" }
            config = prefix + wanted + "\n" + ns.substring(from: at)
        }
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try config.write(to: configURL, atomically: true, encoding: .utf8)
        chmod(configURL.path, 0o600)
    }

    // MARK: Keychain

    private func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.keychainService,
         kSecAttrAccount as String: id]
    }

    // Saved logins live in files next to Codex's own auth.json (0600, in a 0700 folder),
    // because macOS asks for the Keychain password on every read by a rebuilt, ad-hoc
    // signed app. Codex Account Menu's Keychain copies are read once, then cached here.
    private var loginsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudePill/codex-logins", isDirectory: true)
    }

    private func loginFile(_ id: String) -> URL? {
        // Ids are UUIDs; refuse anything that could step outside the folder.
        guard id.range(of: #"^[A-Za-z0-9-]+$"#, options: .regularExpression) != nil else { return nil }
        return loginsDir.appendingPathComponent("\(id).json")
    }

    private func writeLoginFile(_ data: Data, for id: String) throws {
        guard let file = loginFile(id) else { throw CodexAccountError.message("Bad account id.") }
        try FileManager.default.createDirectory(at: loginsDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(loginsDir.path, 0o700)
        // No file protection class: a "complete" file can't be read while the Mac is locked,
        // which made the read after sleep fall back to the Keychain and prompt.
        try data.write(to: file, options: .atomic)
        chmod(file.path, 0o600)
    }

    private func setSnapshot(_ data: Data, for id: String, shareWithKeychain: Bool = false) throws {
        try writeLoginFile(data, for: id)
        // Give Codex Account Menu a copy of a newly added login. Only done when the user adds an
        // account: any Keychain call from a background refresh (e.g. the token refresh after
        // waking from sleep) can bring up the Keychain password prompt.
        guard shareWithKeychain else { return }
        if SecItemCopyMatching(query(id).merging([kSecReturnAttributes as String: true]) { $1 } as CFDictionary, nil) == errSecItemNotFound {
            let add = query(id).merging([kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]) { $1 }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    func snapshot(for id: String) throws -> Data {
        guard let file = loginFile(id) else { throw CodexAccountError.message("Bad account id.") }
        if FileManager.default.fileExists(atPath: file.path) {
            // Never fall back to the Keychain for a login that's cached but unreadable right now.
            do { return try Data(contentsOf: file) } catch {
                throw CodexAccountError.message("Couldn't read the saved login; try again in a moment.")
            }
        }
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { throw CodexAccountError.message("The saved login for this account is missing.") }
        guard status == errSecSuccess, let data = out as? Data else { throw CodexAccountError.keychain(status) }
        try? writeLoginFile(data, for: id)
        return data
    }

    private func atomicWriteAuth(_ data: Data) throws {
        let fm = FileManager.default
        let dir = authURL.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = dir.appendingPathComponent(".auth.\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: .atomic)
        chmod(tmp.path, 0o600)
        if fm.fileExists(atPath: authURL.path) {
            _ = try fm.replaceItemAt(authURL, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: authURL)
        }
        chmod(authURL.path, 0o600)
    }
}

// MARK: - The Codex app

enum CodexApp {
    static let bundleId = "com.openai.codex"

    /// The desktop app is named ChatGPT.app now but keeps Codex's bundle id.
    static func running() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleId
                || $0.localizedName?.caseInsensitiveCompare("Codex") == .orderedSame
                || $0.localizedName?.caseInsensitiveCompare("ChatGPT") == .orderedSame
        }
    }

    static var appURL: URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) { return url }
        for path in ["/Applications/Codex.app", "/Applications/ChatGPT.app", NSHomeDirectory() + "/Applications/Codex.app"]
        where FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        return nil
    }

    /// The command-line tool bundled inside the desktop app.
    static var cliURL: URL? {
        guard let app = appURL else { return nil }
        let res = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        for rel in ["codex-cli/CodexCLI.app/Contents/MacOS/codex", "codex-cli/bin/codex", "codex"] {
            let c = res.appendingPathComponent(rel)
            if FileManager.default.isExecutableFile(atPath: c.path) { return c }
        }
        return nil
    }

    /// Asks Codex to quit and waits up to 8 seconds. Returns false if it's still running.
    static func quit() async -> Bool {
        let apps = running()
        apps.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, apps.contains(where: { !$0.isTerminated }) {
            try? await Task.sleep(for: .milliseconds(150))
        }
        return !apps.contains { !$0.isTerminated }
    }

    static func launch(_ url: URL?) {
        guard let url = url ?? appURL else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }
}
