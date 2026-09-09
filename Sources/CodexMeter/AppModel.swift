import AppKit
import SwiftUI
import CodexMeterCore

enum Period: String, CaseIterable, Identifiable {
    case today = "Aujourd’hui", week = "7 jours", month = "Ce mois", all = "Tout"
    var id: String { rawValue }
    var start: Date {
        let c = Calendar.current
        return switch self {
        case .today: c.startOfDay(for: Date())
        case .week: c.date(byAdding: .day, value: -6, to: c.startOfDay(for: Date()))!
        case .month: c.dateInterval(of: .month, for: Date())!.start
        case .all: .distantPast
        }
    }
}

enum Grouping: String, CaseIterable, Identifiable {
    case client = "Client", repository = "Dépôt / dossier", model = "Modèle"
    var id: String { rawValue }
}

struct SummaryRow: Identifiable {
    var id: String
    var usage = Usage()
    var sessions: Set<String> = []
    var cost: Double = 0
    var unpriced = false
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: CodexMeterCore.Settings
    @Published var events: [Consumption] = []
    @Published var period: Period = .month
    @Published var grouping: Grouping = .client
    @Published var search = ""
    @Published var isScanning = false
    @Published var paused = false
    @Published var result: ScanResult?
    @Published var error: String?
    @Published var notice: String?
    private let settingsURL: URL
    private let scanner: CodexMeterCore.Scanner
    private var watchTask: Task<Void, Never>?
    let support: URL

    init() {
        if let override = ProcessInfo.processInfo.environment["CODEXMETER_DATA_DIR"] {
            support = URL(fileURLWithPath: override)
        } else {
            support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CodexMeter")
        }
        settingsURL = support.appendingPathComponent("settings.json")
        var initial = CodexMeterCore.Settings()
        var initialError: String?
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty { initial.codexHome = home }
        if let data = try? Data(contentsOf: settingsURL) {
            do { initial = try JSONDecoder().decode(CodexMeterCore.Settings.self, from: data) }
            catch { initialError = "Les réglages enregistrés sont illisibles. Les valeurs par défaut ont été chargées." }
        }
        settings = initial
        scanner = CodexMeterCore.Scanner(cacheURL: support.appendingPathComponent("ledger-v1.json"))
        error = initialError
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self, !self.paused { await self.refresh() }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func refresh(rebuild: Bool = false) async {
        guard !isScanning else { return }
        isScanning = true
        let snapshot = await scanner.scan(home: settings.codexHome, rebuild: rebuild)
        events = snapshot.events; result = snapshot; isScanning = false
    }
    func save() {
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try JSONEncoder().encode(settings).write(to: settingsURL, options: .atomic)
        } catch { self.error = "Impossible d’enregistrer les réglages : \(error.localizedDescription)" }
    }
    func chooseHome() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.showsHiddenFiles = true; panel.message = "Sélectionnez le dossier .codex contenant sessions."
        panel.directoryURL = URL(fileURLWithPath: settings.codexHome)
        if panel.runModal() == .OK, let url = panel.url {
            settings.codexHome = url.path; save()
            Task { await refresh() }
        }
    }
    func chooseRulePath() -> String? {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Choisissez le dossier d’un client ou d’un projet."
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
    var filtered: [Consumption] {
        let start = period.start
        return events.filter { e in
            e.timestamp >= start && (settings.includeSubagents || !e.isSubagent) &&
            (search.isEmpty || [e.cwd, e.repository, e.model, ClientRule.client(for: e, rules: settings.rules)].contains { $0.localizedCaseInsensitiveContains(search) })
        }
    }
    var total: Usage { filtered.reduce(Usage()) { $0 + $1.usage } }
    var rows: [SummaryRow] {
        var groups: [String: SummaryRow] = [:]
        for e in filtered {
            let key: String
            switch grouping {
            case .client: key = ClientRule.client(for: e, rules: settings.rules)
            case .repository: key = e.repository.isEmpty ? (e.cwd.isEmpty ? "Dossier inconnu" : e.cwd) : e.repository
            case .model: key = e.model
            }
            var row = groups[key] ?? SummaryRow(id: key)
            row.usage = row.usage + e.usage; row.sessions.insert(e.sessionID)
            if let rate = settings.rates.first(where: { $0.model == e.model }) { row.cost += rate.cost(e.usage) }
            else { row.unpriced = true }
            groups[key] = row
        }
        return groups.values.sorted { $0.usage.total > $1.usage.total }
    }
    func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "codex-consommation-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try CSV.export(filtered, settings: settings).write(to: url, atomically: true, encoding: .utf8)
                notice = "Export enregistré : \(url.lastPathComponent)"
            } catch { self.error = "Export impossible : \(error.localizedDescription)" }
        }
    }
}

func number(_ value: Int64) -> String { value.formatted(.number.locale(Locale(identifier: "fr_FR"))) }
func compact(_ value: Int64) -> String {
    if value >= 1_000_000 { return String(format: "%.2f M", Double(value) / 1_000_000) }
    if value >= 1_000 { return String(format: "%.1f k", Double(value) / 1_000) }
    return String(value)
}
