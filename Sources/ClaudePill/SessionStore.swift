import AppKit
import Combine
import Foundation
import SwiftUI

/// Ordered by urgency: the stack sorts on this.
enum PillState: Int, Comparable {
    case waiting = 0, error, working, compacting, stalled, interrupted, done

    /// Finished one way or another; clicking the pill clears it.
    var isFinished: Bool { self == .done || self == .interrupted }
    var isBusy: Bool { self == .working || self == .compacting }

    static func < (a: PillState, b: PillState) -> Bool { a.rawValue < b.rawValue }
}

/// Which coding agent a session belongs to.
enum Agent: String {
    case claude, codex

    var name: String { self == .claude ? "Claude" : "Codex" }
}

/// Why a session is waiting on you.
enum Attention: Equatable {
    case permission, question, plan, input
}

/// One step of an agent's task list (Claude's todos or tasks, Codex's plan).
struct TaskItem: Equatable {
    var title: String
    /// Present-tense label Claude shows while the step runs ("Running the tests").
    var active: String?
    var status: String // pending, in_progress, completed

    var isDone: Bool { status == "completed" }
    var isActive: Bool { status == "in_progress" }
}

struct SessionInfo: Identifiable, Equatable {
    var isDesktop: Bool { desktopSessionId != nil }
    var isQuestion: Bool { attention == .question }

    let id: String
    var agent: Agent = .claude
    var title: String
    var subtitle: String   // one line, shown collapsed
    var detail: String     // longer text, shown on hover
    var state: PillState
    var folder: String
    var options: [String] = []          // choices when Claude asked a question
    var attention: Attention?
    var warning = false                 // a tool just failed or was denied
    var agents = 0                      // sub-agents running right now
    var desktopSessionId: String?       // "local_…" id in the Claude app, when it runs there
    var hostApp: String?                // app hosting a terminal session
    var tty: String?
    var updatedAt: Date
    var turnStartedAt: Date
    var tasks: [TaskItem] = []

    var tasksDone: Int { tasks.filter(\.isDone).count }
    /// The step being worked on, if the agent has a task list with steps left.
    var currentTask: TaskItem? { tasks.first(where: \.isActive) ?? tasks.first { !$0.isDone } }
}

// MARK: - Hook record (written by hooks/pill-hook.sh)

private struct HookRecord: Decodable {
    let session_id: String
    let agent: String?
    let cwd: String?
    let transcript_path: String?
    let event: String?
    let tool: String?
    let detail: String?
    let options: [String]?
    let message: String?
    let notification_type: String?
    let prompt: String?
    let error: String?
    let error_details: String?
    let is_interrupt: Bool?
    let reason: String?
    let trigger: String?
    let last_message: String?
    let agents: Int?
    let turn_ts: Double?
    let host_app: String?
    let tty: String?
    let ts: Double
}

// MARK: - Transcript reading

private struct TranscriptInfo {
    var title: String?
    var lastText: String?
    /// A Codex question (`request_user_input`) that hasn't been answered yet.
    var pendingQuestion: (question: String, options: [String])?
    /// Claude Code logged that its Stop hooks ran after the newest message: the turn is over.
    var turnEnded = false
    /// The latest task list in the transcript.
    var tasks: [TaskItem] = []
    var mtime: Date = .distantPast
    var recordTs: Double = 0
}

private enum Transcript {
    static let tailBytes: UInt64 = 768 * 1024

    static func read(path: String, wantFullTitleScan: Bool) -> TranscriptInfo {
        var info = TranscriptInfo()
        info.mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
        guard let fh = FileHandle(forReadingAtPath: path) else { return info }
        defer { try? fh.close() }

        let size = (try? fh.seekToEnd()) ?? 0
        let start = wantFullTitleScan ? 0 : (size > tailBytes ? size - tailBytes : 0)
        try? fh.seek(toOffset: start)
        guard let data = try? fh.readToEnd() else { return info }

        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() } // partial line

        var custom: String?, ai: String?, agent: String?
        var codexSettled = false // the latest Codex call or reply has been seen
        var claudeSettled = false // the newest turn-relevant Claude line has been seen
        for raw in lines.reversed() {
            guard let line = String(data: Data(raw), encoding: .utf8) else { continue }

            // Codex rollouts: a question is pending while the newest call is request_user_input
            // and nothing (its answer, or a new user message) has come after it.
            if !codexSettled, line.hasPrefix("{\"timestamp\""), line.contains("\"type\":\"response_item\"") {
                if line.contains("\"type\":\"function_call_output\"") || line.contains("\"role\":\"user\"") {
                    codexSettled = true
                } else if line.contains("\"type\":\"function_call\"") || line.contains("\"type\":\"custom_tool_call\"") {
                    codexSettled = true
                    if line.contains("\"name\":\"request_user_input\"") { info.pendingQuestion = codexQuestion(line) }
                }
            }

            if !claudeSettled {
                if line.contains("\"subtype\":\"stop_hook_summary\"") {
                    info.turnEnded = true
                    claudeSettled = true
                } else if line.contains("\"type\":\"user\"") || line.contains("\"type\":\"assistant\"") {
                    claudeSettled = true
                }
            }

            if custom == nil, line.contains("\"custom-title\"") { custom = string(line, "customTitle") }
            else if ai == nil, line.contains("\"ai-title\"") { ai = string(line, "aiTitle") }
            else if agent == nil, line.contains("\"agent-name\"") { agent = string(line, "agentName") }

            if info.lastText == nil, !line.contains("\"isSidechain\":true") {
                info.lastText = assistantText(line)
            }
            if custom != nil, info.lastText != nil { break }
        }
        info.title = custom ?? ai ?? agent
        info.tasks = taskList(lines)
        return info
    }

    /// Replays the task tools in order: Claude's TodoWrite (a full list each time),
    /// TaskCreate/TaskUpdate (one task at a time) and Codex's update_plan (a full plan).
    private static func taskList(_ lines: [Data.SubSequence]) -> [TaskItem] {
        var list: [TaskItem] = []
        var tasks: [String: TaskItem] = [:], order: [String] = []
        var creating: [String: TaskItem] = [:] // tool_use id → task waiting for its number
        var useTasks = false
        let keys = ["TodoWrite", "TaskCreate", "TaskUpdate", "update_plan", "tool_use_id"]

        for raw in lines {
            guard let line = String(data: Data(raw), encoding: .utf8),
                  keys.contains(where: { line.contains($0) }), let obj = json(line) else { continue }

            // Codex: {"payload":{"type":"function_call","name":"update_plan","arguments":"{…}"}}
            if let payload = obj["payload"] as? [String: Any], payload["name"] as? String == "update_plan",
               let args = (payload["arguments"] as? String)?.data(using: .utf8),
               let plan = ((try? JSONSerialization.jsonObject(with: args)) as? [String: Any])?["plan"] as? [[String: Any]] {
                list = plan.compactMap { p in
                    (p["step"] as? String).map { TaskItem(title: $0, active: nil, status: p["status"] as? String ?? "pending") }
                }
                useTasks = false
                continue
            }

            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for block in content {
                switch block["type"] as? String {
                case "tool_use":
                    let input = block["input"] as? [String: Any] ?? [:]
                    switch block["name"] as? String {
                    case "TodoWrite":
                        list = (input["todos"] as? [[String: Any]] ?? []).compactMap { t in
                            (t["content"] as? String).map {
                                TaskItem(title: $0, active: t["activeForm"] as? String, status: t["status"] as? String ?? "pending")
                            }
                        }
                        useTasks = false
                    case "TaskCreate":
                        if let id = block["id"] as? String, let subject = input["subject"] as? String {
                            creating[id] = TaskItem(title: subject, active: input["activeForm"] as? String, status: "pending")
                        }
                    case "TaskUpdate":
                        guard let id = (input["taskId"] as? String) ?? (input["taskId"] as? Int).map(String.init),
                              var t = tasks[id] else { break }
                        if let status = input["status"] as? String {
                            if status == "deleted" { tasks[id] = nil; order.removeAll { $0 == id }; break }
                            t.status = status
                        }
                        if let subject = input["subject"] as? String { t.title = subject }
                        if let active = input["activeForm"] as? String { t.active = active }
                        tasks[id] = t
                        useTasks = true
                    default: break
                    }
                case "tool_result":
                    // "Task #3 created successfully: …" gives the new task its number.
                    guard let useId = block["tool_use_id"] as? String, let t = creating.removeValue(forKey: useId) else { break }
                    let text = (block["content"] as? String)
                        ?? (block["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
                    if let r = text.range(of: #"#(\d+)"#, options: .regularExpression) {
                        let id = String(text[r].dropFirst())
                        if tasks[id] == nil { order.append(id) }
                        tasks[id] = t
                        useTasks = true
                    }
                default: break
                }
            }
        }
        return useTasks ? order.compactMap { tasks[$0] } : list
    }

    private static func codexQuestion(_ line: String) -> (question: String, options: [String])? {
        guard let payload = json(line)?["payload"] as? [String: Any],
              let args = (payload["arguments"] as? String)?.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: args)) as? [String: Any],
              let first = (obj["questions"] as? [[String: Any]])?.first,
              let q = first["question"] as? String else { return nil }
        let options = (first["options"] as? [[String: Any]] ?? []).compactMap { ($0["label"] as? String).map { String($0.prefix(60)) } }
        let count = (obj["questions"] as? [Any])?.count ?? 1
        return (count > 1 ? "\(q) (1 of \(count))" : q, Array(options.prefix(6)))
    }

    private static func json(_ line: String) -> [String: Any]? {
        guard let d = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private static func string(_ line: String, _ key: String) -> String? {
        guard let s = json(line)?[key] as? String, !s.isEmpty else { return nil }
        return s
    }

    private static func assistantText(_ line: String) -> String? {
        guard let obj = json(line) else { return nil }
        if let payload = obj["payload"] as? [String: Any] {
            if obj["type"] as? String == "event_msg", payload["type"] as? String == "task_complete",
               let text = payload["last_agent_message"] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
            guard obj["type"] as? String == "response_item",
                  payload["type"] as? String == "message", payload["role"] as? String == "assistant",
                  payload["phase"] == nil || payload["phase"] as? String == "final_answer",
                  let content = payload["content"] as? [[String: Any]] else { return nil }
            let text = content.filter { $0["type"] as? String == "output_text" }
                .compactMap { $0["text"] as? String }.joined(separator: "\n")
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        }
        guard obj["type"] as? String == "assistant", obj["isSidechain"] as? Bool != true,
              let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return nil }
        let text = content.filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }.joined(separator: "\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}

// MARK: - Text helpers

enum TextTidy {
    private static let linkPattern = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\([^)]*\)"#)
    private static let prefixPattern = try! NSRegularExpression(pattern: #"^(#{1,6}\s+|[-*+]\s+|>\s*|\d+[.)]\s+)"#)

    static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        let full = NSRange(t.startIndex..., in: t)
        t = linkPattern.stringByReplacingMatches(in: t, range: full, withTemplate: "$1")
        t = prefixPattern.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
        for token in ["**", "__", "`"] { t = t.replacingOccurrences(of: token, with: "") }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Readable lines of a markdown reply, skipping code, tables and rules.
    static func lines(_ text: String) -> [String] {
        var out: [String] = []
        var inFence = false
        for raw in text.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle(); continue }
            if inFence || trimmed.hasPrefix("|") || trimmed.allSatisfy({ "-=*_ ".contains($0) }) { continue }
            let c = clean(trimmed)
            if !c.isEmpty { out.append(c) }
        }
        return out
    }

    static func oneLine(_ s: String, max: Int = 160) -> String {
        let flat = s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
    }

    static func basename(_ path: String) -> String { (path as NSString).lastPathComponent }
}

// MARK: - Describing what Claude is doing

private func describeTool(_ tool: String?, _ detail: String?) -> (short: String, long: String) {
    let d = detail.map { TextTidy.oneLine($0, max: 400) } ?? ""
    let firstLine = detail?.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? ""
    let file = TextTidy.basename(d)

    func pair(_ s: String) -> (String, String) { (s, d.isEmpty ? s : d) }

    let name = tool ?? ""
    let action = name.hasPrefix("mcp__") ? name : (name.components(separatedBy: ".").last ?? name)
    switch action {
    case "Bash", "exec_command", "shell", "shell_command": return pair("Running \(firstLine.isEmpty ? "a command" : firstLine)")
    case "Read", "read_file": return pair("Reading \(file)")
    case "Edit", "MultiEdit", "NotebookEdit": return pair("Editing \(file)")
    case "Write": return pair("Writing \(file)")
    case "Grep", "Glob": return pair("Searching for \(d)")
    case "WebFetch": return pair("Reading \(URL(string: d)?.host ?? "a web page")")
    case "WebSearch": return pair("Searching the web for \(d)")
    case "Task", "Agent": return pair(d.isEmpty ? "Running an agent" : "Agent: \(d)")
    case "TodoWrite", "TaskCreate", "TaskUpdate": return ("Updating the task list", "Updating the task list")
    case "update_plan": return ("Updating the plan", "Updating the plan")
    case "apply_patch":
        let paths = (detail ?? "").components(separatedBy: .newlines).compactMap { line -> String? in
            for prefix in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where line.hasPrefix(prefix) {
                return TextTidy.basename(String(line.dropFirst(prefix.count)))
            }
            return nil
        }
        let label = paths.first.map { "Editing \($0)" } ?? "Editing files"
        return (label, paths.isEmpty ? label : "Editing " + paths.joined(separator: ", "))
    case "write_stdin": return ("Checking a running command", "Checking a running command")
    case "spawn_agent": return pair(d.isEmpty ? "Starting an agent" : "Agent: \(d)")
    case "wait_agent", "wait": return ("Waiting for results", "Waiting for results")
    case "send_message", "followup_task": return ("Coordinating agents", "Coordinating agents")
    case "request_user_input", "request_user_input_async": return ("Asking a question", d.isEmpty ? "Asking a question" : d)
    case "view_image": return pair("Viewing \(file.isEmpty ? "an image" : file)")
    case "Skill": return pair(d.isEmpty ? "Loading a skill" : "Using the \(d) skill")
    case "ToolSearch": return ("Loading tools", "Loading tools")
    case let t where t.hasPrefix("mcp__"):
        let parts = t.components(separatedBy: "__")
        let action = (parts.last ?? t).replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        var server = parts.count > 2 ? parts[1] : ""
        if server.count > 24 || server.contains("-") && server.count > 16 { server = "" } // opaque connector ids
        server = server.replacingOccurrences(of: "_", with: " ")
        let label = server.isEmpty ? "Using \(action)" : "\(server): \(action)"
        return (label, d.isEmpty ? label : "\(label) — \(d)")
    case "": return ("Working", "Working")
    case let t: return pair("Using \(t)")
    }
}

// MARK: - Scanner (runs off the main thread)

private final class Scanner: @unchecked Sendable {
    let dir: URL
    private let codexAttention = CodexAttentionMonitor()
    private var transcripts: [String: TranscriptInfo] = [:]
    private var fullScanned: Set<String> = []
    private var desktop: [String: DesktopSession] = [:]
    private var codexTitles: [String: String] = [:]
    private var codexIndexMtime: Date = .distantPast

    private static let codexIndex = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/session_index.jsonl")

    /// Codex keeps thread names in ~/.codex/session_index.jsonl, one JSON line per rename.
    private func codexTitle(for id: String) -> String? {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: Self.codexIndex.path)[.modificationDate] as? Date) ?? .distantPast
        if mtime != codexIndexMtime, let text = try? String(contentsOf: Self.codexIndex, encoding: .utf8) {
            codexIndexMtime = mtime
            var titles: [String: String] = [:]
            for line in text.split(separator: "\n") {
                guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      let tid = obj["id"] as? String, let name = obj["thread_name"] as? String, !name.isEmpty else { continue }
                titles[tid] = name
            }
            codexTitles = titles
        }
        return codexTitles[id]
    }
    private var desktopMisses: [String: Date] = [:]

    private struct DesktopSession {
        let localId: String
        let file: URL
        var title: String?
        var mtime: Date
    }

    private static let desktopRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)

    /// The Claude app keeps one `local_<id>.json` per Code session, holding the Claude Code
    /// session id (`cliSessionId`) and the title shown in the sidebar.
    private func desktopSession(for cliId: String, now: Date) -> DesktopSession? {
        let fm = FileManager.default
        if var known = desktop[cliId] {
            let mtime = (try? fm.attributesOfItem(atPath: known.file.path)[.modificationDate] as? Date) ?? known.mtime
            if mtime != known.mtime, let fresh = Self.readDesktop(known.file) {
                known.title = fresh.title
                known.mtime = mtime
                desktop[cliId] = known
            }
            return known
        }
        if let miss = desktopMisses[cliId], now.timeIntervalSince(miss) < 120 { return nil }

        var candidates: [(URL, Date)] = []
        let accounts = (try? fm.contentsOfDirectory(at: Self.desktopRoot, includingPropertiesForKeys: nil)) ?? []
        for account in accounts {
            let spaces = (try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? []
            for space in spaces {
                let files = (try? fm.contentsOfDirectory(at: space, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                for f in files where f.lastPathComponent.hasPrefix("local_") && f.pathExtension == "json" {
                    let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    candidates.append((f, m))
                }
            }
        }
        let needle = Data(cliId.utf8)
        for (file, mtime) in candidates.sorted(by: { $0.1 > $1.1 }) {
            guard let data = try? Data(contentsOf: file), data.range(of: needle) != nil,
                  let found = Self.readDesktop(file), found.cliId == cliId else { continue }
            let session = DesktopSession(localId: found.localId, file: file, title: found.title, mtime: mtime)
            desktop[cliId] = session
            return session
        }
        desktopMisses[cliId] = now
        return nil
    }

    private static func readDesktop(_ file: URL) -> (localId: String, cliId: String, title: String?)? {
        guard let data = try? Data(contentsOf: file),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let localId = obj["sessionId"] as? String, let cliId = obj["cliSessionId"] as? String
        else { return nil }
        let title = (obj["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (localId, cliId, title)
    }

    init(dir: URL) { self.dir = dir }

    func scan(now: Date) -> [SessionInfo] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var records: [HookRecord] = []
        var seen: Set<String> = []

        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let rec = try? JSONDecoder().decode(HookRecord.self, from: data) else { continue }
            let age = now.timeIntervalSince1970 - rec.ts
            if age > 24 * 3600 { try? fm.removeItem(at: url); continue }
            if age > 6 * 3600 { continue }
            seen.insert(rec.session_id)
            records.append(rec)
        }
        codexAttention.refresh(ids: Set(records.filter { $0.agent == "codex" }.map(\.session_id)))
        transcripts = transcripts.filter { seen.contains($0.key) }
        desktop = desktop.filter { seen.contains($0.key) }
        return records.map { build($0, now: now) }
    }

    private func transcript(for rec: HookRecord) -> TranscriptInfo {
        guard let path = rec.transcript_path else { return TranscriptInfo() }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
        if let cached = transcripts[rec.session_id], cached.mtime == mtime, cached.recordTs == rec.ts {
            return cached
        }
        var info = Transcript.read(path: path, wantFullTitleScan: false)
        if info.title == nil {
            if !fullScanned.contains(rec.session_id) {
                fullScanned.insert(rec.session_id)
                info.title = Transcript.read(path: path, wantFullTitleScan: true).title
            } else {
                info.title = transcripts[rec.session_id]?.title
            }
        }
        info.recordTs = rec.ts
        transcripts[rec.session_id] = info
        return info
    }

    private func build(_ rec: HookRecord, now: Date) -> SessionInfo {
        let agent = Agent(rawValue: rec.agent ?? "") ?? .claude
        let t = transcript(for: rec)
        let app = agent == .claude ? desktopSession(for: rec.session_id, now: now) : nil
        let folder = rec.cwd.map(TextTidy.basename) ?? ""
        let promptTitle = rec.prompt.map { TextTidy.oneLine($0, max: 60) }
        let named = agent == .codex ? codexTitle(for: rec.session_id) : (app?.title ?? t.title)
        let title = named ?? (promptTitle?.isEmpty == false ? promptTitle! : (folder.isEmpty ? agent.name : folder))

        var state = PillState.working
        var subtitle = "Thinking…"
        var detail = rec.prompt.map { "“\(TextTidy.oneLine($0, max: 300))”" } ?? "Thinking…"
        var attention: Attention?
        var options: [String] = []
        var warning = false

        func wait(_ why: Attention, _ line: String, _ more: String? = nil) {
            state = .waiting
            attention = why
            subtitle = line
            detail = more ?? line
        }

        func finished() {
            state = .done
            let text = rec.last_message.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? t.lastText
            let lines = text.map(TextTidy.lines) ?? []
            subtitle = lines.last ?? "Done"
            let tail = lines.suffix(4).joined(separator: " ")
            detail = tail.isEmpty ? "Done" : TextTidy.oneLine(tail, max: 420)
            // A reply that merely ends with a question ("How's your day going?") is still a
            // finished turn. Real questions arrive as AskUserQuestion / request_user_input.
        }

        switch rec.event ?? "" {
        case "PreToolUse":
            switch rec.tool {
            case "AskUserQuestion":
                options = rec.options ?? []
                let q = rec.detail.map { TextTidy.oneLine($0) } ?? "Claude has a question for you"
                wait(.question, q, rec.detail.map { TextTidy.oneLine($0, max: 400) })
            case "ExitPlanMode":
                wait(.plan, "Plan ready for your review")
            default:
                (subtitle, detail) = describeTool(rec.tool, rec.detail)
            }

        case "PermissionRequest":
            let (doing, full) = describeTool(rec.tool, rec.detail)
            // Codex reports approvals it grants by itself too. While it really waits for you
            // its rollout file stops changing, so if the file moved on, it's still working.
            if agent == .codex, let why = Self.codexStillWorking(rec, transcriptMtime: t.mtime, now: now) {
                (subtitle, detail) = (why == .reviewing ? "Reviewing: \(doing)" : doing, full)
            } else {
                wait(.permission, "Allow? \(doing)", "Waiting for your permission: \(full)")
            }

        case "Elicitation":
            wait(.input, rec.message.map { TextTidy.oneLine($0) } ?? "A tool needs your input")

        case "Notification":
            switch rec.notification_type {
            case "idle_prompt": finished()
            case "permission_prompt":
                wait(.permission, rec.message.map { TextTidy.oneLine($0) } ?? "Claude needs your permission")
            default:
                wait(.input, rec.message.map { TextTidy.oneLine($0) } ?? "Claude needs your attention")
            }

        case "PostToolUseFailure":
            let (doing, _) = describeTool(rec.tool, rec.detail)
            if rec.is_interrupt == true {
                state = .interrupted
                subtitle = "Interrupted"
                detail = "Stopped while \(doing.prefix(1).lowercased() + doing.dropFirst())"
            } else {
                warning = true
                let firstLine = rec.error.flatMap { TextTidy.lines($0).first } ?? "failed"
                subtitle = "Failed: \(firstLine)"
                detail = "\(doing) failed. \(TextTidy.oneLine(rec.error ?? "", max: 300))"
            }

        case "PermissionDenied":
            let (doing, _) = describeTool(rec.tool, rec.detail)
            warning = true
            subtitle = "Denied: \(doing)"
            detail = rec.reason.map { "\(doing) was denied. \($0)" } ?? subtitle

        case "PreCompact":
            state = .compacting
            subtitle = "Compacting the conversation…"
            detail = rec.trigger == "auto"
                ? "The context is full, so Claude is summarizing the conversation so far."
                : "Summarizing the conversation so far."

        case "Interrupt":
            state = .interrupted
            subtitle = "Interrupted"
            detail = "You stopped this turn"

        case "PostCompact" where rec.trigger != "auto":
            // A manual /compact runs outside a turn, so no Stop follows it.
            state = .done
            subtitle = "Conversation compacted"
            detail = "The conversation was summarized. Ready for your next message."

        case "SubagentStart":
            subtitle = rec.detail.map { "Started the \($0) agent" } ?? "Started an agent"

        case "Stop":
            finished()

        case "StopFailure":
            state = .error
            subtitle = Self.describeError(rec.error)
            detail = [subtitle, rec.error_details].compactMap { $0 }.joined(separator: ". ")

        default: // UserPromptSubmit, PostToolUse, PostCompact, SubagentStop…
            break
        }

        // A Stop hook can be missed (or its record overwritten); the transcript says for sure.
        if agent == .claude, state.isBusy, t.turnEnded { finished() }

        // Codex has no hook for its questions; they show up in the rollout file instead.
        if agent == .codex, state.isBusy, let pending = t.pendingQuestion {
            options = pending.options
            wait(.question, TextTidy.oneLine(pending.question), TextTidy.oneLine(pending.question, max: 400))
        }

        if agent == .codex, let pending = codexAttention.attention(for: rec.session_id) {
            wait(pending.kind, TextTidy.oneLine(pending.text), pending.text)
        }

        // A long silence while busy usually means an interrupted turn or a long command.
        let lastSign = max(rec.ts, t.mtime.timeIntervalSince1970)
        let quiet = now.timeIntervalSince1970 - lastSign
        if state.isBusy, quiet > 5 * 60 {
            state = .stalled
            let mins = Int(quiet / 60)
            detail = "Last update \(mins)m ago: \(subtitle)"
            subtitle = "No updates for \(mins)m"
        }

        return SessionInfo(
            id: rec.session_id,
            agent: agent,
            title: TextTidy.oneLine(title, max: 80),
            subtitle: TextTidy.oneLine(subtitle),
            detail: detail,
            state: state,
            folder: folder,
            options: options,
            attention: attention,
            warning: warning,
            agents: rec.agents ?? 0,
            desktopSessionId: app?.localId,
            hostApp: rec.host_app.flatMap { $0.isEmpty ? nil : $0 },
            tty: rec.tty.flatMap { $0.isEmpty ? nil : $0 },
            updatedAt: max(Date(timeIntervalSince1970: rec.ts), agent == .codex ? codexAttention.updatedAt(for: rec.session_id) ?? .distantPast : .distantPast),
            turnStartedAt: Date(timeIntervalSince1970: rec.turn_ts ?? rec.ts),
            // Progress only matters while the agent is on it and has steps left.
            tasks: !state.isFinished && t.tasks.contains { !$0.isDone } ? t.tasks : []
        )
    }

    private enum CodexProgress { case reviewing, running }

    /// Codex sends PermissionRequest for every command its auto-reviewer looks at, and most
    /// are approved without you. It only counts as waiting on you once the reviewer has had
    /// time to decide, the command isn't running, and the rollout file has gone quiet.
    private static func codexStillWorking(_ rec: HookRecord, transcriptMtime: Date, now: Date) -> CodexProgress? {
        if transcriptMtime.timeIntervalSince1970 > rec.ts + 1 { return .running }
        if let cmd = rec.detail.flatMap({ TextTidy.lines($0).first }), cmd.count >= 4,
           runningCommands().contains(where: { $0.contains(String(cmd.prefix(60))) }) {
            return .running
        }
        return now.timeIntervalSince1970 - rec.ts < 12 ? .reviewing : nil
    }

    /// Command lines of the user's processes, to see whether an approved command is running.
    private static func runningCommands() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-xo", "command="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    private static func describeError(_ kind: String?) -> String {
        switch kind {
        case "rate_limit": "Rate limited. Try again in a moment"
        case "overloaded": "Claude is overloaded. Try again shortly"
        case "server_error": "The API is unavailable. Try again"
        case "authentication_failed": "Signed out. Log in to Claude again"
        case "billing_error": "Usage limit reached. Check your plan"
        case "verification_required": "Verification is required"
        case "invalid_request": "The request was rejected"
        case "model_not_found": "That model isn't available"
        case "max_output_tokens": "The reply hit the output limit"
        case "cloud_credential_error": "Cloud credentials failed"
        default: "The turn stopped with an error"
        }
    }
}

// MARK: - Store

@MainActor
final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    static let maxVisible = 5
    static let finishedLifetime: TimeInterval = 30 * 60

    @Published private(set) var visible: [SessionInfo] = []
    @Published private(set) var overflow = 0
    @Published private(set) var overflowSessions: [SessionInfo] = []
    @Published private(set) var hooksInstalled = true

    @Published var soundOnFinish: Bool {
        didSet { UserDefaults.standard.set(soundOnFinish, forKey: "pill.soundOnFinish") }
    }
    @Published var hideWhenIdle: Bool {
        didSet { UserDefaults.standard.set(hideWhenIdle, forKey: "pill.hideWhenIdle") }
    }

    let dir: URL
    private let scanner: Scanner
    private let queue = DispatchQueue(label: "claudepill.scan", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var all: [SessionInfo] = []
    private var dismissed: [String: Date] = [:]
    private var lastStates: [String: PillState] = [:]
    private var scanPending = false

    private init() {
        dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/pill/sessions", isDirectory: true)
        scanner = Scanner(dir: dir)
        soundOnFinish = UserDefaults.standard.bool(forKey: "pill.soundOnFinish")
        hideWhenIdle = UserDefaults.standard.bool(forKey: "pill.hideWhenIdle")
    }

    func start() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        watch()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        checkHooks()
        scan()
    }

    private func watch() {
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in self?.scan() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    func scan() {
        guard !scanPending else { return }
        scanPending = true
        let scanner = scanner
        queue.async {
            let sessions = scanner.scan(now: Date())
            DispatchQueue.main.async {
                self.scanPending = false
                self.apply(sessions)
            }
        }
    }

    private func apply(_ sessions: [SessionInfo]) {
        let now = Date()
        var finishedNow = false, failedNow = false
        for s in sessions {
            if let prev = lastStates[s.id], prev != s.state {
                if s.state == .done { finishedNow = true }
                if s.state == .error { failedNow = true }
                if s.state.isFinished, !prev.isFinished { DailyStatsStore.shared.recordTurn(of: s) }
            }
            lastStates[s.id] = s.state
        }
        lastStates = lastStates.filter { id, _ in sessions.contains { $0.id == id } }
        if soundOnFinish {
            if failedNow { NSSound(named: "Basso")?.play() } else if finishedNow { NSSound(named: "Glass")?.play() }
        }

        all = sessions
        let shown = sessions
            .filter { s in
                if let d = dismissed[s.id], s.updatedAt <= d { return false }
                if s.state.isFinished, now.timeIntervalSince(s.updatedAt) > Self.finishedLifetime { return false }
                return true
            }
            .sorted { a, b in a.state != b.state ? a.state < b.state : a.updatedAt > b.updatedAt }

        let newVisible = Array(shown.prefix(Self.maxVisible))
        let newOverflow = max(0, shown.count - Self.maxVisible)
        let newOverflowSessions = Array(shown.dropFirst(Self.maxVisible))
        if newVisible != visible || newOverflowSessions != overflowSessions {
            withAnimation(.spring(duration: 0.5, bounce: 0.28)) {
                visible = newVisible
                overflow = newOverflow
                overflowSessions = newOverflowSessions
            }
        }
    }

    func dismiss(_ id: String) {
        dismissed[id] = all.first { $0.id == id }?.updatedAt ?? Date()
        apply(all)
    }

    func clearFinished() {
        for s in all where s.state.isFinished { dismissed[s.id] = s.updatedAt }
        apply(all)
    }

    func checkHooks() {
        let settings = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        let text = (try? String(contentsOf: settings, encoding: .utf8)) ?? ""
        hooksInstalled = text.contains("pill-hook.sh")
    }
}
