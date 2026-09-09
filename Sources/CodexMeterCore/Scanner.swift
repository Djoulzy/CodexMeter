import Foundation
import CryptoKit

public struct SessionParser: Codable, Sendable {
    var sessionID = ""
    var turnID = ""
    var cwd = ""
    var model = "Inconnu"
    var source = "Inconnue"
    var subagent = false
    var previous: Usage?
    var pendingModern = Usage()
    var pendingModernTotal: Usage?
    public private(set) var resets = 0
    public private(set) var malformed = 0
    public init() {}

    public mutating func consume(_ data: Data, origin: String, repository: (String) -> String = { _ in "" }) -> Consumption? {
        guard let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = row["type"] as? String, let p = row["payload"] as? [String: Any] else {
            malformed += 1; return nil
        }
        if type == "session_meta" {
            sessionID = p["id"] as? String ?? sessionID
            cwd = p["cwd"] as? String ?? cwd
            source = p["source"] as? String ?? "Sous-agent"
            subagent = (p["source"] as? [String: Any])?["subagent"] != nil
            return nil
        }
        if type == "turn_context" {
            model = p["model"] as? String ?? model
            cwd = p["cwd"] as? String ?? cwd
            turnID = p["turn_id"] as? String ?? turnID
            return nil
        }
        let isLegacy = type == "event_msg" && p["type"] as? String == "token_count"
        guard type == "token_usage_record" || isLegacy else { return nil }
        guard let stamp = row["timestamp"] as? String, let date = Self.date(stamp) else { malformed += 1; return nil }
        var usage: Usage
        var identity: String
        var eventSession = sessionID
        var eventTurn = turnID
        if type == "token_usage_record" {
            guard let u = Usage(p["usage"]), let response = p["response_id"] as? String, !response.isEmpty else { malformed += 1; return nil }
            usage = u
            identity = "response:" + response
            eventSession = p["thread_id"] as? String ?? sessionID
            eventTurn = p["turn_id"] as? String ?? turnID
            pendingModern = pendingModern + u
            pendingModernTotal = Usage(p["thread_token_usage"])
        } else {
            guard let info = p["info"] as? [String: Any], let total = Usage(info["total_token_usage"]) else { return nil }
            let last = Usage(info["last_token_usage"])
            let reset = previous.map { total.input < $0.input || total.output < $0.output } ?? false
            if reset { resets += 1 }
            let delta = reset ? (last ?? total) : total.delta(from: previous ?? Usage())
            previous = total
            // Modern records are followed by a legacy mirror in current Codex versions.
            // Update the baseline even when suppressing that mirror.
            if let modernTotal = pendingModernTotal, modernTotal == total {
                pendingModern = Usage(); pendingModernTotal = nil; return nil
            }
            usage = delta.delta(from: pendingModern)
            pendingModern = Usage(); pendingModernTotal = nil
            guard usage.total > 0 else { return nil }
            let fingerprint = [stamp, turnID.isEmpty ? sessionID : turnID, String(total.input), String(total.cached), String(total.output)].joined(separator: "|")
            identity = "legacy:" + SHA256.hash(data: Data(fingerprint.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        guard usage.total > 0 else { return nil }
        return Consumption(id: identity, timestamp: date, sessionID: eventSession, turnID: eventTurn, cwd: cwd,
                           repository: repository(cwd), model: model, source: source, isSubagent: subagent,
                           usage: usage, estimated: isLegacy, origin: origin)
    }
    private static func date(_ value: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: value) { return date }
        f.formatOptions = [.withInternetDateTime]; return f.date(from: value)
    }
}

private struct Cursor: Codable, Sendable {
    var offset: UInt64 = 0
    var inode: UInt64
    var observedSize: UInt64 = 0
    var modified: Date = .distantPast
    var parser = SessionParser()
}

private struct Ledger: Codable, Sendable {
    var version = 1
    var home: String
    var cursors: [String: Cursor] = [:]
    var events: [String: Consumption] = [:]
}

public struct ScanResult: Sendable {
    public var events: [Consumption]
    public var files: Int
    public var resets: Int
    public var malformed: Int
    public var messages: [String]
    public var checkedAt: Date
}

public actor Scanner {
    private var ledger: Ledger?
    private let cacheURL: URL
    private var repositoryCache: [String: String] = [:]
    private var cacheLoadWarning: String?
    private var needsSave = false
    public init(cacheURL: URL) { self.cacheURL = cacheURL }

    public func scan(home: String, rebuild: Bool = false) -> ScanResult {
        let root = URL(fileURLWithPath: (home as NSString).expandingTildeInPath).standardizedFileURL
        var messages: [String] = []
        if ledger == nil && !rebuild && FileManager.default.fileExists(atPath: cacheURL.path) {
            do {
                let decoded = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: cacheURL))
                if decoded.version == 1 { ledger = decoded }
            } catch { cacheLoadWarning = "Le cache était illisible ; l’historique a été relu." }
        }
        if rebuild || ledger?.home != root.path {
            ledger = Ledger(home: root.path); repositoryCache = [:]; needsSave = true
        }
        var state = ledger ?? Ledger(home: root.path)
        let fm = FileManager.default
        var files: [(URL, UInt64, UInt64, Date)] = []
        let sessions = root.appendingPathComponent("sessions")
        if !fm.isReadableFile(atPath: sessions.path) { messages.append("Le dossier sessions est absent ou inaccessible. Choisissez le dossier .codex dans les réglages.") }
        for name in ["sessions", "archived_sessions"] {
            let folder = root.appendingPathComponent(name)
            guard fm.fileExists(atPath: folder.path) else { continue }
            guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else {
                messages.append("Impossible de parcourir \(name)."); continue
            }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                do {
                    let a = try fm.attributesOfItem(atPath: url.path)
                    guard a[.type] as? FileAttributeType == .typeRegular else { continue }
                    files.append((url, (a[.size] as? NSNumber)?.uint64Value ?? 0,
                                  (a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0, a[.modificationDate] as? Date ?? .distantPast))
                } catch { messages.append("Un fichier de session est inaccessible : \(url.lastPathComponent).") }
            }
        }
        // A replaced/truncated rollout invalidates its parsing state; rebuild atomically.
        if files.contains(where: { url, size, inode, modified in
            guard let old = state.cursors[url.path] else { return false }
            return old.inode != inode || size < old.observedSize || (size == old.observedSize && modified != old.modified)
        }) {
            state = Ledger(home: root.path); repositoryCache = [:]; needsSave = true
            messages.append("Un fichier a été remplacé ou réécrit ; l’historique a été recalculé.")
        }
        for (url, size, inode, modified) in files.sorted(by: { $0.0.path < $1.0.path }) {
            var cursor = state.cursors[url.path] ?? Cursor(inode: inode)
            guard size > cursor.offset else { continue }
            do {
                let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                try handle.seek(toOffset: cursor.offset)
                var remaining = size - cursor.offset
                var buffer = Data()
                while remaining > 0 {
                    guard let chunk = try handle.read(upToCount: Int(min(remaining, 1_048_576))), !chunk.isEmpty else { break }
                    remaining -= UInt64(chunk.count); buffer.append(chunk)
                    var start = buffer.startIndex
                    while let end = buffer[start...].firstIndex(of: 10) {
                        let line = Data(buffer[start..<end])
                        if !line.isEmpty, let event = cursor.parser.consume(line, origin: url.path, repository: { self.repositoryRoot($0) }) {
                            // Stable response identities also deduplicate copies in archived files or forks.
                            if state.events[event.id] == nil { state.events[event.id] = event }
                        }
                        let next = buffer.index(after: end)
                        cursor.offset += UInt64(next - start); start = next
                    }
                    buffer = Data(buffer[start...])
                }
                // An unfinished JSON line remains unread until the next poll.
                cursor.observedSize = size; cursor.modified = modified
                state.cursors[url.path] = cursor; needsSave = true
            } catch { messages.append("Lecture impossible : \(url.lastPathComponent). Réessai au prochain passage.") }
        }
        if let warning = cacheLoadWarning { messages.append(warning); cacheLoadWarning = nil }
        let present = Set(files.map { $0.0.path })
        if state.cursors.keys.contains(where: { !present.contains($0) }) {
            messages.append("Certaines sessions ont disparu du disque ; leur consommation déjà importée est conservée.")
        }
        ledger = state
        if needsSave {
            do {
                try fm.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(state).write(to: cacheURL, options: .atomic)
                needsSave = false
            } catch { messages.append("Le cache ne peut pas être enregistré. Les données restent disponibles dans cette fenêtre.") }
        }
        return ScanResult(events: Array(state.events.values), files: files.count,
                          resets: state.cursors.values.reduce(0) { $0 + $1.parser.resets },
                          malformed: state.cursors.values.reduce(0) { $0 + $1.parser.malformed },
                          messages: Array(Set(messages)).sorted(), checkedAt: Date())
    }

    private func repositoryRoot(_ cwd: String) -> String {
        guard !cwd.isEmpty else { return "" }
        if let value = repositoryCache[cwd] { return value }
        var url = URL(fileURLWithPath: cwd).standardizedFileURL
        let fm = FileManager.default
        while url.path != "/" {
            let git = url.appendingPathComponent(".git")
            var directory: ObjCBool = false
            if fm.fileExists(atPath: git.path, isDirectory: &directory) {
                var root = url.path
                if !directory.boolValue, let text = try? String(contentsOf: git, encoding: .utf8), text.hasPrefix("gitdir:") {
                    let path = String(text.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
                    let gitdir = URL(fileURLWithPath: path, relativeTo: url).standardizedFileURL
                    if let common = try? String(contentsOf: gitdir.appendingPathComponent("commondir"), encoding: .utf8) {
                        let shared = URL(fileURLWithPath: common.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: gitdir).standardizedFileURL
                        if shared.lastPathComponent == ".git" { root = shared.deletingLastPathComponent().path }
                    }
                }
                repositoryCache[cwd] = root; return root
            }
            url.deleteLastPathComponent()
        }
        repositoryCache[cwd] = ""; return ""
    }
}
