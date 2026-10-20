import AppKit

/// Brings a session's own window to the front when its pill is clicked.
enum SessionOpener {
    static func open(_ session: SessionInfo) {
        // Claude app: deep-link straight into the session.
        if session.agent == .claude, let id = session.desktopSessionId,
           let url = URL(string: "claude://code/continue?session=\(id)") {
            NSWorkspace.shared.open(url)
            return
        }

        // Codex app: open the thread. Terminal Codex sessions fall through to their tab.
        if session.agent == .codex, session.tty == nil || session.hostApp?.contains("ChatGPT.app") == true
            || session.hostApp?.contains("Codex.app") == true || session.hostApp?.contains("Claude.app") == true,
           let url = URL(string: "codex://threads/\(session.id)") {
            NSWorkspace.shared.open(url)
            return
        }

        // Terminal session: select its tab when the terminal supports it, else raise the app.
        guard let path = session.hostApp else { return }
        let app = URL(fileURLWithPath: path)
        if let tty = session.tty, selectTab(appName: app.deletingPathExtension().lastPathComponent, tty: tty) {
            return
        }
        NSWorkspace.shared.openApplication(at: app, configuration: .init())
    }

    static func hostName(_ session: SessionInfo) -> String {
        if session.agent == .codex, session.tty == nil { return "Codex" }
        if session.isDesktop { return "Claude" }
        guard let path = session.hostApp else { return session.agent == .codex ? "Codex" : "Terminal" }
        if path.contains("ChatGPT.app") { return "Codex" }
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    private static func selectTab(appName: String, tty: String) -> Bool {
        // The tty goes into AppleScript source, so accept only a real terminal device path.
        guard tty.range(of: #"^/dev/ttys?[0-9]+$"#, options: .regularExpression) != nil else { return false }

        let source: String
        switch appName {
        case "Terminal":
            source = """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected of t to true
                            set index of w to 1
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end tell
            return false
            """
        case "iTerm", "iTerm2":
            source = """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                select w
                                select t
                                select s
                                activate
                                return true
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return false
            """
        default:
            return false
        }

        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil && result?.booleanValue == true
    }
}
