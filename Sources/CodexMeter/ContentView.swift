import SwiftUI
import Charts
import CodexMeterCore

private enum Page: String, CaseIterable, Identifiable {
    case dashboard = "Vue d’ensemble", clients = "Clients", settings = "Réglages"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .dashboard: "chart.bar.xaxis"; case .clients: "person.2"; case .settings: "slider.horizontal.3" }
    }
}

struct ContentView: View {
    @EnvironmentObject var app: AppModel
    @State private var page: Page? = .dashboard
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) {
                    Image(systemName: "chart.bar.fill").font(.title2).foregroundStyle(.white)
                        .frame(width: 42, height: 42).background(.blue.gradient, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Codex Meter").font(.headline)
                        Text("Votre activité, par client").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 16).padding(.top, 24)
                List(Page.allCases, selection: $page) { item in
                    Label(item.rawValue, systemImage: item.symbol).tag(item).padding(.vertical, 5)
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 9) {
                    Label(app.paused ? "Suivi en pause" : "Lecture locale active", systemImage: app.paused ? "pause.circle" : "checkmark.shield")
                        .foregroundStyle(app.paused ? .orange : .green).font(.callout.weight(.medium))
                    Text("Vos sessions restent sur ce Mac.").font(.caption).foregroundStyle(.secondary)
                    Button(app.paused ? "Reprendre le suivi" : "Mettre en pause") { app.paused.toggle() }.buttonStyle(.link)
                }.padding(18)
            }.navigationSplitViewColumnWidth(240)
        } detail: {
            Group {
                switch page ?? .dashboard {
                case .dashboard: DashboardView()
                case .clients: ClientsView()
                case .settings: PreferencesView()
                }
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .alert("Codex Meter", isPresented: Binding(get: { app.error != nil }, set: { if !$0 { app.error = nil } })) {
            Button("OK") { app.error = nil }
        } message: { Text(app.error ?? "") }
    }
}

private struct Metric: View {
    var title: String
    var value: String
    var detail: String
    var color: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.system(size: 30, weight: .semibold, design: .rounded)).foregroundStyle(color).monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20).card()
    }
}

private struct DayUsage: Identifiable { var date: Date; var total: Int64; var id: Date { date } }

struct DashboardView: View {
    @EnvironmentObject var app: AppModel
    private var days: [DayUsage] {
        let c = Calendar.current
        let start = max(app.period.start, c.date(byAdding: .day, value: -13, to: c.startOfDay(for: Date()))!)
        let grouped = Dictionary(grouping: app.filtered) { c.startOfDay(for: $0.timestamp) }
        return (0..<14).compactMap { i in
            let date = c.date(byAdding: .day, value: i, to: start)!
            guard date <= Date() else { return nil }
            return DayUsage(date: date, total: grouped[date, default: []].reduce(0) { $0 + $1.usage.total })
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Votre consommation Codex").font(.largeTitle.weight(.bold))
                        Text("Suivez vos tokens et attribuez chaque projet à un client.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { app.export() } label: { Label("Exporter CSV", systemImage: "square.and.arrow.up") }.controlSize(.large)
                }
                HStack {
                    Picker("Période", selection: $app.period) { ForEach(Period.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).frame(width: 400)
                    Spacer()
                    if app.isScanning { ProgressView().controlSize(.small) }
                    Text(app.result.map { "Mis à jour à " + $0.checkedAt.formatted(date: .omitted, time: .standard) } ?? "Lecture de l’historique…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 14) {
                    Metric(title: "Tokens au total", value: compact(app.total.total), detail: "Entrée + sortie", color: .blue)
                    Metric(title: "Tokens d’entrée", value: compact(app.total.input), detail: "Cache inclus")
                    Metric(title: "Entrée en cache", value: compact(app.total.cached), detail: "Déjà comprise dans l’entrée", color: .teal)
                    Metric(title: "Tokens de sortie", value: compact(app.total.output), detail: "Raisonnement inclus")
                }
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Activité quotidienne").font(.headline)
                        Spacer(); Text("14 derniers jours maximum · heure locale").font(.caption).foregroundStyle(.secondary)
                    }
                    Chart(days) { day in
                        BarMark(x: .value("Jour", day.date, unit: .day), y: .value("Tokens", day.total))
                            .foregroundStyle(.blue.gradient).cornerRadius(4)
                    }.chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine()
                            AxisValueLabel { if let amount = value.as(Double.self) { Text(compact(Int64(amount))) } }
                        }
                    }.frame(height: 150)
                    .accessibilityLabel("Consommation quotidienne en tokens")
                }.padding(20).card()
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Répartition").font(.headline)
                        Picker("Regrouper par", selection: $app.grouping) { ForEach(Grouping.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 260)
                        Spacer()
                        TextField("Rechercher un client, dossier, modèle", text: $app.search).textFieldStyle(.roundedBorder).frame(width: 260)
                    }
                    if app.rows.isEmpty {
                        ContentUnavailableView(app.isScanning ? "Lecture des sessions…" : "Aucune consommation sur cette période", systemImage: "chart.bar", description: Text("Essayez « Tout » ou vérifiez le dossier .codex dans les réglages."))
                            .frame(height: 170)
                    } else {
                        Table(app.rows) {
                            TableColumn(app.grouping.rawValue) { row in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(row.id).lineLimit(1).truncationMode(.middle).help(row.id)
                                    Text("\(row.sessions.count) session(s)").font(.caption).foregroundStyle(.secondary)
                                }
                            }.width(min: 170, ideal: 240)
                            TableColumn("Entrée") { Text(number($0.usage.input)).monospacedDigit() }
                            TableColumn("Dont cache") { Text(number($0.usage.cached)).monospacedDigit().foregroundStyle(.secondary) }
                            TableColumn("Sortie") { Text(number($0.usage.output)).monospacedDigit() }
                            TableColumn("Total") { Text(number($0.usage.total)).monospacedDigit().fontWeight(.semibold) }
                            TableColumn("Estim. €") { row in
                                Text(row.unpriced ? "—" : row.cost.formatted(.currency(code: "EUR")))
                                    .help(row.unpriced ? "Renseignez un tarif pour chaque modèle de cette ligne." : "Estimation selon vos tarifs, pas une facture OpenAI.")
                            }.width(85)
                        }.frame(height: max(140, min(360, CGFloat(app.rows.count * 48 + 35))))
                    }
                }.padding(20).card()
                VStack(alignment: .leading, spacing: 7) {
                    Text("\(app.result?.files ?? 0) fichiers suivis · \(app.filtered.count) événements affichés · Sous-agents \(app.settings.includeSubagents ? "inclus" : "exclus")")
                    Text("Les estimations utilisent vos tarifs. Les compteurs locaux ne constituent pas une facture ChatGPT Business.")
                    if let result = app.result, result.resets > 0 {
                        Text("\(result.resets) remise(s) à zéro détectée(s) : les anciens compteurs sont reconstitués par différences.")
                    }
                    if let result = app.result, result.malformed > 0 { Text("\(result.malformed) ligne(s) non interprétée(s). Le suivi peut être incomplet.").foregroundStyle(.orange) }
                    ForEach(app.result?.messages ?? [], id: \.self) { Text($0).foregroundStyle(.orange) }
                    if let notice = app.notice { Text(notice).foregroundStyle(.green) }
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }.navigationTitle("Vue d’ensemble")
    }
}

struct ClientsView: View {
    @EnvironmentObject var app: AppModel
    @State private var client = ""
    @State private var path = ""
    @State private var editingID: UUID?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Un projet, un client").font(.largeTitle.bold())
                Text("Associez un dossier à un client. Ses sous-dossiers sont inclus ; la règle la plus précise est prioritaire. Les worktrees Git sont rattachés au dépôt principal lorsqu’il est accessible.").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 14) {
                    Text("Nouvelle affectation").font(.headline)
                    TextField("Nom du client", text: $client).textFieldStyle(.roundedBorder)
                    HStack {
                        TextField("Chemin absolu du dossier", text: $path).textFieldStyle(.roundedBorder)
                        Button("Choisir…") { if let chosen = app.chooseRulePath() { path = chosen } }
                    }
                    HStack {
                        Spacer()
                        Button(editingID == nil ? "Ajouter la règle" : "Enregistrer la règle") {
                            let normalized = URL(fileURLWithPath: (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath).standardizedFileURL.path
                            app.settings.rules.removeAll { $0.path == normalized || $0.id == editingID }
                            app.settings.rules.append(ClientRule(client: client.trimmingCharacters(in: .whitespacesAndNewlines), path: normalized))
                            app.save(); client = ""; path = ""; editingID = nil
                        }.buttonStyle(.borderedProminent)
                            .disabled(client.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(path.hasPrefix("/") || path.hasPrefix("~/")))
                    }
                }.padding(22).card()
                ForEach(app.settings.rules) { rule in
                    HStack {
                        Image(systemName: "folder.badge.person.crop").font(.title2).foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 5) { Text(rule.client).font(.headline); Text(rule.path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                        Spacer()
                        Button("Modifier") { client = rule.client; path = rule.path; editingID = rule.id }
                        Button(role: .destructive) { app.settings.rules.removeAll { $0.id == rule.id }; app.save() } label: { Image(systemName: "trash") }.help("Supprimer l’affectation")
                    }.padding(18).card()
                }
                if app.settings.rules.isEmpty { ContentUnavailableView("Aucun client configuré", systemImage: "person.2", description: Text("Les consommations apparaissent sous « Non affecté » jusqu’à l’ajout d’une règle.")) }
                let paths = Set(app.events.map(\.cwd)).filter { !$0.isEmpty }.sorted()
                if !paths.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Dossiers détectés").font(.headline)
                        ForEach(paths, id: \.self) { folder in
                            HStack { Text(folder).font(.callout).textSelection(.enabled); Spacer(); Button("Affecter") { path = folder } }
                        }
                    }.padding(22).card()
                }
            }.padding(28)
        }.navigationTitle("Clients")
    }
}

struct PreferencesView: View {
    @EnvironmentObject var app: AppModel
    @State private var confirmRebuild = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Réglages").font(.largeTitle.bold())
                VStack(alignment: .leading, spacing: 14) {
                    Label("Source locale", systemImage: "folder").font(.headline)
                    Text(app.settings.codexHome).textSelection(.enabled).font(.system(.callout, design: .monospaced))
                    HStack {
                        Button("Choisir le dossier .codex…") { app.chooseHome() }.disabled(app.isScanning)
                        Button("Relire tout l’historique…") { confirmRebuild = true }.disabled(app.isScanning)
                    }
                    Text("Vérification toutes les 2 secondes. Seules les nouvelles lignes sont lues. Aucun fichier Codex n’est modifié.").foregroundStyle(.secondary)
                    Toggle("Inclure les sous-agents internes", isOn: $app.settings.includeSubagents).onChange(of: app.settings.includeSubagents) { _, _ in app.save() }
                    Text("Les sous-agents peuvent avoir des règles de facturation différentes. Leur inclusion concerne les tokens observés.").font(.caption).foregroundStyle(.secondary)
                }.padding(22).card()
                VStack(alignment: .leading, spacing: 16) {
                    Text("Votre grille de refacturation").font(.headline)
                    Text("Montants en euros par million de tokens. Aucun tarif OpenAI n’est prérempli. L’entrée hors cache et l’entrée en cache sont facturées séparément dans cette estimation.").foregroundStyle(.secondary)
                    HStack {
                        Text("Modèle").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Entrée hors cache").frame(width: 140)
                        Text("Cache").frame(width: 110)
                        Text("Sortie").frame(width: 110)
                        Spacer().frame(width: 30)
                    }.font(.caption).foregroundStyle(.secondary)
                    ForEach($app.settings.rates) { $rate in
                        HStack {
                            Text(rate.model).frame(maxWidth: .infinity, alignment: .leading)
                            TextField("0", value: $rate.input, format: .number).frame(width: 140)
                            TextField("0", value: $rate.cached, format: .number).frame(width: 110)
                            TextField("0", value: $rate.output, format: .number).frame(width: 110)
                            Button { app.settings.rates.removeAll { $0.id == rate.id }; app.save() } label: { Image(systemName: "trash") }.frame(width: 30)
                        }.textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Button("Ajouter les modèles détectés") {
                            for name in Set(app.events.map(\.model)).sorted() where !app.settings.rates.contains(where: { $0.model == name }) {
                                app.settings.rates.append(ModelRate(model: name))
                            }
                            app.save()
                        }
                        Spacer()
                        Button("Enregistrer les tarifs") {
                            for i in app.settings.rates.indices {
                                app.settings.rates[i].input = max(0, app.settings.rates[i].input)
                                app.settings.rates[i].cached = max(0, app.settings.rates[i].cached)
                                app.settings.rates[i].output = max(0, app.settings.rates[i].output)
                            }
                            app.save(); app.notice = "Tarifs enregistrés."
                        }.buttonStyle(.borderedProminent)
                    }
                }.padding(22).card()
                VStack(alignment: .leading, spacing: 12) {
                    Label("Données et confidentialité", systemImage: "lock.shield").font(.headline)
                    Text("L’app n’utilise pas le réseau et ne lit pas auth.json. Son cache contient uniquement des métadonnées de consommation : dates, identifiants, chemins, modèles et compteurs. Les messages et les réponses ne sont pas conservés.")
                    Text("Cache et réglages : \(app.support.path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Les anciens événements sont des estimations par différences de cumuls. Une session copiée sans identifiant de tour, un format nouveau ou des sessions distantes absentes de ce Mac peuvent rendre le suivi incomplet.").font(.caption).foregroundStyle(.secondary)
                }.padding(22).card()
            }.padding(28)
        }.navigationTitle("Réglages")
        .confirmationDialog("Relire toutes les sessions présentes sur le disque ?", isPresented: $confirmRebuild) {
            Button("Recalculer le cache", role: .destructive) { Task { await app.refresh(rebuild: true) } }
        } message: { Text("Les consommations de fichiers supprimés ne seront plus conservées. Les sessions Codex et les règles clients restent intactes.") }
    }
}

private extension View {
    func card() -> some View {
        background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.06)))
    }
}
