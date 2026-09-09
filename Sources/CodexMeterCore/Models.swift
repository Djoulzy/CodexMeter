import Foundation

public struct Usage: Codable, Hashable, Sendable {
    public var input: Int64 = 0
    public var cached: Int64 = 0
    public var output: Int64 = 0
    public var reasoning: Int64 = 0
    public var cacheWrite: Int64 = 0
    public var total: Int64 { input + output }
    public init(input: Int64 = 0, cached: Int64 = 0, output: Int64 = 0, reasoning: Int64 = 0, cacheWrite: Int64 = 0) {
        self.input = input; self.cached = cached; self.output = output
        self.reasoning = reasoning; self.cacheWrite = cacheWrite
    }
    init?(_ object: Any?) {
        guard let d = object as? [String: Any], d["input_tokens"] is NSNumber, d["output_tokens"] is NSNumber else { return nil }
        input = max(0, (d["input_tokens"] as? NSNumber)?.int64Value ?? 0)
        cached = max(0, (d["cached_input_tokens"] as? NSNumber)?.int64Value ?? 0)
        output = max(0, (d["output_tokens"] as? NSNumber)?.int64Value ?? 0)
        reasoning = max(0, (d["reasoning_output_tokens"] as? NSNumber)?.int64Value ?? 0)
        cacheWrite = max(0, (d["cache_write_input_tokens"] as? NSNumber)?.int64Value ?? 0)
    }
    public static func + (l: Self, r: Self) -> Self {
        .init(input: l.input + r.input, cached: l.cached + r.cached, output: l.output + r.output,
              reasoning: l.reasoning + r.reasoning, cacheWrite: l.cacheWrite + r.cacheWrite)
    }
    func delta(from previous: Self) -> Self {
        .init(input: max(0, input - previous.input), cached: max(0, cached - previous.cached),
              output: max(0, output - previous.output), reasoning: max(0, reasoning - previous.reasoning),
              cacheWrite: max(0, cacheWrite - previous.cacheWrite))
    }
}

public struct Consumption: Codable, Identifiable, Sendable {
    public let id: String
    public let timestamp: Date
    public let sessionID: String
    public let turnID: String
    public let cwd: String
    public let repository: String
    public let model: String
    public let source: String
    public let isSubagent: Bool
    public let usage: Usage
    public let estimated: Bool
    public let origin: String
}

public struct ClientRule: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var client: String
    public var path: String
    public init(client: String, path: String) { self.client = client; self.path = path }
    public func matches(_ candidate: String) -> Bool {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        let value = URL(fileURLWithPath: candidate).standardizedFileURL.path
        return value == root || value.hasPrefix(root == "/" ? "/" : root + "/")
    }
    public static func client(for event: Consumption, rules: [Self]) -> String {
        rules.sorted { $0.path.count > $1.path.count }
            .first { $0.matches(event.cwd) || (!event.repository.isEmpty && $0.matches(event.repository)) }?.client ?? "Non affecté"
    }
}

public struct ModelRate: Codable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var model: String
    public var input: Double
    public var cached: Double
    public var output: Double
    public init(model: String, input: Double = 0, cached: Double = 0, output: Double = 0) {
        self.model = model; self.input = input; self.cached = cached; self.output = output
    }
    public func cost(_ u: Usage) -> Double {
        (Double(max(0, u.input - u.cached)) * input + Double(u.cached) * cached + Double(u.output) * output) / 1_000_000
    }
}

public struct Settings: Codable, Sendable {
    public var codexHome: String = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
    public var rules: [ClientRule] = []
    public var rates: [ModelRate] = []
    public var includeSubagents = false
    public init() {}
}

public enum CSV {
    private static func cell(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    // Prefix potentially executable spreadsheet cells. Quoting alone is insufficient.
    private static func textCell(_ value: String) -> String {
        let unsafe = ["=", "+", "-", "@", "\t", "\r", "\n"].contains { value.hasPrefix($0) }
        return cell(unsafe ? "'" + value : value)
    }
    public static func export(_ events: [Consumption], settings: Settings) -> String {
        var lines = ["date_utc,client,dossier,depot,modele,session,tour,source,sous_agent,input_tokens,cached_input_tokens,output_tokens,total_tokens,reasoning_output_tokens,cache_write_input_tokens,estimation_eur,compteur_ancien"]
        let format = ISO8601DateFormatter()
        for e in events.sorted(by: { $0.timestamp < $1.timestamp }) {
            let cost = settings.rates.first { $0.model == e.model }.map { String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), $0.cost(e.usage)) } ?? ""
            let values = [format.string(from: e.timestamp), ClientRule.client(for: e, rules: settings.rules), e.cwd, e.repository, e.model, e.sessionID, e.turnID, e.source].map(textCell)
            lines.append((values + [e.isSubagent ? "true" : "false", String(e.usage.input), String(e.usage.cached), String(e.usage.output), String(e.usage.total), String(e.usage.reasoning), String(e.usage.cacheWrite), cost, e.estimated ? "true" : "false"]).joined(separator: ","))
        }
        return "\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n"
    }
}
