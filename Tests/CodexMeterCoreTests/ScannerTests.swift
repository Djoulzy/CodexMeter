import XCTest
@testable import CodexMeterCore

final class ScannerTests: XCTestCase {
    private func row(_ type: String, _ payload: [String: Any], at: String = "2026-09-09T10:00:00.000Z") -> Data {
        try! JSONSerialization.data(withJSONObject: ["timestamp": at, "type": type, "payload": payload], options: [.sortedKeys])
    }
    private func usage(_ input: Int, _ output: Int, _ cached: Int = 0) -> [String: Int] {
        ["input_tokens": input, "output_tokens": output, "cached_input_tokens": cached, "total_tokens": input + output]
    }
    private func legacy(_ total: [String: Int], last: [String: Int]? = nil, at: String = "2026-09-09T10:00:00.000Z") -> Data {
        row("event_msg", ["type": "token_count", "info": ["total_token_usage": total, "last_token_usage": last ?? total]], at: at)
    }
    private func parser() -> SessionParser {
        var p = SessionParser()
        _ = p.consume(row("session_meta", ["id": "session-1", "cwd": "/projects/client", "source": "vscode"]), origin: "fixture")
        _ = p.consume(row("turn_context", ["model": "test-model", "turn_id": "turn-1"]), origin: "fixture")
        return p
    }
    func testLegacyDeltasRepeatedTotalsAndReset() {
        var p = parser()
        XCTAssertEqual(p.consume(legacy(usage(100, 10, 60)), origin: "fixture")?.usage.total, 110)
        XCTAssertNil(p.consume(legacy(usage(100, 10, 60)), origin: "fixture"))
        let increment = p.consume(legacy(usage(160, 20, 100)), origin: "fixture")!
        XCTAssertEqual(increment.usage, Usage(input: 60, cached: 40, output: 10))
        XCTAssertEqual(p.consume(legacy(usage(30, 4, 10), last: usage(30, 4, 10)), origin: "fixture")?.usage.total, 34)
        XCTAssertEqual(p.resets, 1)
    }
    func testModernRecordSuppressesMirrorAndResumesLegacy() {
        var p = parser()
        _ = p.consume(legacy(usage(900, 90)), origin: "fixture")
        let u = usage(100, 10, 60)
        let e = p.consume(row("token_usage_record", ["response_id": "r1", "usage": u, "thread_token_usage": u, "thread_id": "session-1", "turn_id": "t2"]), origin: "fixture")!
        XCTAssertEqual(e.id, "response:r1")
        XCTAssertFalse(e.estimated)
        XCTAssertNil(p.consume(legacy(u), origin: "fixture"))
        XCTAssertEqual(p.consume(legacy(usage(150, 15, 80)), origin: "fixture")?.usage.total, 55)
    }
    func testCacheIsNotAddedTwiceAndPriceUsesUncachedInput() {
        let u = Usage(input: 1000, cached: 800, output: 100, reasoning: 50)
        XCTAssertEqual(u.total, 1100)
        XCTAssertEqual(ModelRate(model: "x", input: 10, cached: 1, output: 20).cost(u), 0.0048, accuracy: 0.0000001)
    }
    func testLongestRuleAndPathBoundary() {
        var p = parser()
        let event = p.consume(legacy(usage(1, 1)), origin: "fixture")!
        let rules = [ClientRule(client: "General", path: "/projects"), ClientRule(client: "Specific", path: "/projects/client")]
        XCTAssertEqual(ClientRule.client(for: event, rules: rules), "Specific")
        XCTAssertFalse(ClientRule(client: "x", path: "/projects/client").matches("/projects/client-other"))
    }
    func testCSVQuotesAndNeutralizesFormulaCells() {
        var p = parser()
        let event = p.consume(legacy(usage(1, 1)), origin: "fixture")!
        var settings = Settings(); settings.rules = [ClientRule(client: "=SUM(1,2)", path: "/projects")]
        let csv = CSV.export([event], settings: settings)
        XCTAssertTrue(csv.contains("\"'=SUM(1,2)\""))
    }
    func testIncrementalPartialLineRestartAndGlobalDeduplication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let f = sessions.appendingPathComponent("rollout.jsonl")
        let cache = root.appendingPathComponent("cache/ledger.json")
        let meta = row("session_meta", ["id": "s", "cwd": "/tmp", "source": "vscode"])
        let u = usage(100, 10, 60)
        let modern = row("token_usage_record", ["response_id": "same-response", "usage": u, "thread_token_usage": u])
        var initial = meta; initial.append(10); initial.append(modern.prefix(25))
        try initial.write(to: f)
        let scanner = Scanner(cacheURL: cache)
        let first = await scanner.scan(home: root.path)
        XCTAssertEqual(first.events.count, 0)
        let handle = try FileHandle(forWritingTo: f); try handle.seekToEnd()
        try handle.write(contentsOf: modern.dropFirst(25)); try handle.write(contentsOf: Data([10]))
        try handle.write(contentsOf: legacy(u)); try handle.write(contentsOf: Data([10])); try handle.close()
        let second = await scanner.scan(home: root.path)
        XCTAssertEqual(second.events.count, 1)
        XCTAssertEqual(second.events.first?.usage.total, 110)
        let restarted = Scanner(cacheURL: cache)
        let third = await restarted.scan(home: root.path)
        XCTAssertEqual(third.events.count, 1)
        try Data(contentsOf: f).write(to: sessions.appendingPathComponent("copy.jsonl"))
        let fourth = await restarted.scan(home: root.path)
        XCTAssertEqual(fourth.events.count, 1)
        XCTAssertEqual(fourth.files, 2)
    }
    func testTruncationRebuildsInsteadOfKeepingStaleTotals() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("sessions/test.jsonl")
        var data = legacy(usage(1000, 10)); data.append(10); try data.write(to: file)
        let scanner = Scanner(cacheURL: root.appendingPathComponent("cache.json"))
        let before = await scanner.scan(home: root.path)
        XCTAssertEqual(before.events.first?.usage.total, 1010)
        data = legacy(usage(10, 1)); data.append(10); try data.write(to: file)
        let after = await scanner.scan(home: root.path)
        XCTAssertEqual(after.events.count, 1)
        XCTAssertEqual(after.events.first?.usage.total, 11)
    }
    func testReadOnlyLocalIntegrationWhenRequested() async throws {
        guard let home = ProcessInfo.processInfo.environment["CODEXMETER_VERIFY_HOME"] else {
            throw XCTSkip("Définir CODEXMETER_VERIFY_HOME pour vérifier un historique réel en lecture seule.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scanner = Scanner(cacheURL: root.appendingPathComponent("cache.json"))
        let scan = await scanner.scan(home: home)
        XCTAssertGreaterThan(scan.files, 0)
        XCTAssertGreaterThan(scan.events.count, 0)
        XCTAssertEqual(Set(scan.events.map(\.id)).count, scan.events.count)
        XCTAssertEqual(scan.malformed, 0)
        XCTAssertTrue(scan.messages.isEmpty, scan.messages.joined(separator: "; "))
        print("Vérification locale : \(scan.files) fichiers, \(scan.events.count) événements uniques, \(scan.resets) remises à zéro, \(scan.events.filter { !$0.estimated }.count) réponses modernes.")
    }
}
