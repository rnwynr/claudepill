import Darwin
import Foundation

struct CodexAttention: Equatable {
    let kind: Attention
    let text: String

    static func read(_ state: [String: Any]) -> CodexAttention? {
        for request in (state["requests"] as? [[String: Any]] ?? []).reversed() where request["completed"] as? Bool != true {
            let params = request["params"] as? [String: Any] ?? [:]
            switch request["method"] as? String {
            case "mcpServer/elicitation/request":
                let server = params["serverName"] as? String ?? ""
                let computer = server.contains("cua") || server.contains("computer")
                let text = (params["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (computer ? "Computer use needs your permission" : "A tool needs your input")
                return CodexAttention(kind: computer ? .permission : .input, text: TextTidy.oneLine(text, max: 400))
            case "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval":
                return CodexAttention(kind: .permission, text: "Codex needs your permission")
            case "item/tool/requestUserInput":
                return CodexAttention(kind: .question, text: "Codex has a question for you")
            default: break
            }
        }
        let runtime = state["threadRuntimeStatus"] as? [String: Any] ?? [:]
        guard runtime["type"] as? String == "active" else { return nil }
        let flags = runtime["activeFlags"] as? [String] ?? []
        if flags.contains("waitingOnApproval") { return CodexAttention(kind: .permission, text: "Codex needs your permission") }
        if flags.contains("waitingOnUserInput") { return CodexAttention(kind: .input, text: "Codex needs your input") }
        return nil
    }
}

// Passive local desktop subscriber. Never handles approvals or sends agent commands.
// Only requests and runtime status are retained in memory; snapshots are not persisted.
final class CodexAttentionMonitor {
    private let socketPath: String
    private var fd: Int32 = -1
    private var client: String?
    private var buffer = Data()
    private var followed: Set<String> = []
    private var wanted: Set<String> = []
    private var states: [String: [String: Any]] = [:]
    private var revisions: [String: Int] = [:]
    private var owners: [String: String] = [:]
    private var attentionDates: [String: Date] = [:]
    private var retryAt = Date.distantPast
    private let maxFrame = 16 * 1024 * 1024

    init(socketPath: String = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/ipc/ipc.sock").path) {
        self.socketPath = socketPath
    }

    deinit { if fd >= 0 { Darwin.close(fd) } }

    // Called only by the scanner's serial utility queue.
    func refresh(ids: Set<String>) {
        wanted = ids
        if fd < 0, Date() >= retryAt { connect() }
        guard fd >= 0 else { return }
        drain()
        guard client != nil else { return }
        for id in followed.subtracting(ids) {
            follow(id, false); states[id] = nil; revisions[id] = nil; owners[id] = nil; attentionDates[id] = nil
        }
        for id in ids.subtracting(followed) { follow(id, true) }
        if fd >= 0 { followed = ids }
        drain()
    }

    func attention(for id: String) -> CodexAttention? { states[id].flatMap(CodexAttention.read) }
    func updatedAt(for id: String) -> Date? { attentionDates[id] }

    private func connect() {
        retryAt = Date().addingTimeInterval(5)
        let path = socketPath
        var metadata = stat()
        guard lstat(path, &metadata) == 0, metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFSOCK, metadata.st_mode & 0o077 == 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { return }
        var noSignal: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(socket, F_SETFL, O_NONBLOCK)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { Darwin.close(socket); return }
        var peerUID: uid_t = 0, peerGID: gid_t = 0
        guard getpeereid(socket, &peerUID, &peerGID) == 0, peerUID == getuid() else { Darwin.close(socket); return }
        fd = socket
        send(["type": "request", "requestId": UUID().uuidString, "sourceClientId": "initializing-client",
              "version": 0, "method": "initialize", "params": ["clientType": "claudepill"]])
    }

    private func disconnect() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1; client = nil; buffer.removeAll(); followed.removeAll()
        states.removeAll(); revisions.removeAll(); owners.removeAll()
        attentionDates.removeAll()
        retryAt = Date().addingTimeInterval(5)
    }

    private func send(_ object: [String: Any]) {
        guard fd >= 0, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        var length = UInt32(data.count).littleEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(data)
        let count = frame.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        if count != frame.count { disconnect() }
    }

    private func follow(_ id: String, _ on: Bool) {
        guard let client else { return }
        send(["type": "broadcast", "method": "thread-stream-following-changed", "version": 1,
              "sourceClientId": client, "params": ["conversationId": id, "hostId": "local", "following": on]])
    }

    private func drain() {
        var bytes = [UInt8](repeating: 0, count: 65536)
        while fd >= 0 {
            let count = Darwin.recv(fd, &bytes, bytes.count, 0)
            if count == 0 { disconnect(); return }
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { disconnect() }
                return
            }
            buffer.append(contentsOf: bytes.prefix(count))
            while buffer.count >= 4 {
                let length = buffer.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
                guard length > 0, length <= maxFrame else { disconnect(); return }
                guard buffer.count >= length + 4 else { break }
                let data = Data(buffer.dropFirst(4).prefix(length))
                buffer = Data(buffer.dropFirst(length + 4))
                guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { disconnect(); return }
                receive(object)
            }
            if buffer.count > maxFrame + 4 { disconnect(); return }
        }
    }

    private func receive(_ object: [String: Any]) {
        if object["type"] as? String == "client-discovery-request", let id = object["requestId"] {
            send(["type": "client-discovery-response", "requestId": id, "response": ["canHandle": false]])
            return
        }
        if object["type"] as? String == "response", object["method"] as? String == "initialize",
           object["resultType"] as? String == "success", let result = object["result"] as? [String: Any] {
            client = result["clientId"] as? String
            return
        }
        guard object["type"] as? String == "broadcast", let params = object["params"] as? [String: Any] else { return }
        if object["method"] as? String == "client-status-changed", params["status"] as? String == "disconnected",
           let owner = params["clientId"] as? String {
            for id in owners.keys.filter({ owners[$0] == owner }) {
                states[id] = nil; revisions[id] = nil; owners[id] = nil; attentionDates[id] = nil; followed.remove(id)
            }
            return
        }
        guard object["method"] as? String == "thread-stream-state-changed", params["hostId"] as? String == "local",
              let id = params["conversationId"] as? String, wanted.contains(id),
              let change = params["change"] as? [String: Any], let revision = change["revision"] as? Int else { return }
        if let targets = object["targetClientIds"] as? [String], !targets.contains(client ?? "") { return }
        let previousSignature = Self.pendingSignature(states[id] ?? [:])
        switch change["type"] as? String {
        case "snapshot":
            guard let state = change["conversationState"] as? [String: Any] else { return }
            states[id] = state.filter { ["requests", "threadRuntimeStatus"].contains($0.key) }
        case "patches":
            guard revisions[id] == change["baseRevision"] as? Int, var state = states[id] else {
                states[id] = nil; revisions[id] = nil; attentionDates[id] = nil; follow(id, false); follow(id, true); return
            }
            for patch in change["patches"] as? [[String: Any]] ?? [] {
                guard let path = patch["path"] as? [Any], let key = path.first as? String,
                      ["requests", "threadRuntimeStatus"].contains(key), let op = patch["op"] as? String else { continue }
                guard let updated = Self.patch(state, path: path[...], op: op, value: patch["value"]) as? [String: Any] else {
                    states[id] = nil; revisions[id] = nil; attentionDates[id] = nil; follow(id, false); follow(id, true); return
                }
                state = updated
            }
            states[id] = state
        default: return
        }
        let pending = attention(for: id)
        if pending != nil, attentionDates[id] == nil || previousSignature != Self.pendingSignature(states[id] ?? [:]) {
            attentionDates[id] = Date()
        }
        if pending == nil { attentionDates[id] = nil }
        revisions[id] = revision
        owners[id] = object["sourceClientId"] as? String
    }

    private static func pendingSignature(_ state: [String: Any]) -> [String] {
        let requests = (state["requests"] as? [[String: Any]] ?? []).filter { $0["completed"] as? Bool != true }
        let flags = (state["threadRuntimeStatus"] as? [String: Any])?["activeFlags"] as? [String] ?? []
        return requests.map { "\($0["method"] ?? ""): \($0["id"] ?? "")" } + flags
    }

    static func patch(_ object: Any, path: ArraySlice<Any>, op: String, value: Any?) -> Any? {
        guard ["add", "replace", "remove"].contains(op) else { return nil }
        guard let head = path.first else { return op == "remove" ? nil : value }
        let tail = path.dropFirst()
        if var dict = object as? [String: Any], let key = head as? String {
            if tail.isEmpty {
                if op == "remove" { dict[key] = nil } else if let value { dict[key] = value } else { return nil }
            } else {
                guard let child = dict[key], let updated = patch(child, path: tail, op: op, value: value) else { return nil }
                dict[key] = updated
            }
            return dict
        }
        if var array = object as? [Any], let index = head as? Int, index >= 0 {
            if tail.isEmpty {
                switch op {
                case "add": guard index <= array.count, let value else { return nil }; array.insert(value, at: index)
                case "replace": guard index < array.count, let value else { return nil }; array[index] = value
                case "remove": guard index < array.count else { return nil }; array.remove(at: index)
                default: return nil
                }
            } else {
                guard index < array.count, let updated = patch(array[index], path: tail, op: op, value: value) else { return nil }
                array[index] = updated
            }
            return array
        }
        return nil
    }
}
