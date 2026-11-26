import SwiftUI
import LLMKit

/// Stocks tab: watchlist, holdings, alerts, market awareness + Ask Applebot.
struct StocksView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var showAddSymbol = false
    @State private var showAddHolding = false
    @State private var showAddAlert = false
    @State private var editingHolding: HoldingInfo?
    @State private var symbolDraft = ""
    @State private var nameDraft = ""
    @State private var groupDraft = ""
    @State private var holdingSymbol = ""
    @State private var holdingShares = ""
    @State private var holdingCost = ""
    @State private var alertSymbol = ""
    @State private var alertKind: StockAlertKind = .above
    @State private var alertThreshold = ""
    @State private var alertEventDate = Date()

    private var stocks: StocksDashboardController { environment.stocks }
    private var watchlist: WatchlistStore { environment.watchlist }
    private var holdings: HoldingsStore { environment.holdings }
    private var alerts: StockAlertStore { environment.stockAlerts }

    var body: some View {
        NavigationStack {
            Group {
                if !stocks.isConnectorEnabled {
                    enablePrompt
                } else {
                    dashboard
                }
            }
            .applebotCanvas()
            .navigationTitle("Stocks")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if stocks.isConnectorEnabled {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button {
                                showAddSymbol = true
                            } label: {
                                Label("Add to watchlist", systemImage: "plus")
                            }
                            Button {
                                showAddHolding = true
                            } label: {
                                Label("Add holding", systemImage: "chart.pie")
                            }
                            Button {
                                showAddAlert = true
                            } label: {
                                Label("Add alert", systemImage: "bell")
                            }
                            Button {
                                Task { await refresh(includeInsight: true) }
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityIdentifier("stocks-options")
                    }
                }
            }
            .task {
                await stocks.refreshStatus()
                if stocks.isConnectorEnabled {
                    await refresh(includeInsight: stocks.insightNarrative == nil)
                }
            }
            .refreshable {
                await refresh(includeInsight: true)
            }
            .sheet(isPresented: $showAddSymbol) {
                addSymbolSheet
            }
            .sheet(isPresented: $showAddHolding) {
                addHoldingSheet
            }
            .sheet(item: $editingHolding) { holding in
                holdingEditor(initial: holding)
            }
            .sheet(isPresented: $showAddAlert) {
                addAlertSheet
            }
        }
    }

    private var enablePrompt: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ApplebotTheme.spaceL) {
                ApplebotHeroEmpty(
                    symbol: "chart.line.uptrend.xyaxis",
                    title: "Your markets, on this iPhone",
                    message: "Turn on Stocks to refresh your watchlist, track holdings you enter, and get delayed quotes. Nothing is broker-synced. Not financial advice.",
                    primaryTitle: "Enable Stocks",
                    primarySystemImage: "chart.line.uptrend.xyaxis",
                    primaryAction: {
                        Task {
                            await environment.connectors.setEnabled("stocks", true)
                            await stocks.refreshStatus()
                            await refresh(includeInsight: true)
                        }
                    }
                )
                .accessibilityIdentifier("stocks-enable")

                disclaimerFooter
            }
            .padding(.bottom, ApplebotTheme.spaceXL)
        }
    }

    private var dashboard: some View {
        List {
            Section {
                Text(StocksInsightBuilder.userFacingDisclaimer)
                    .font(ApplebotTheme.caption())
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 4, trailing: 20))
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(stocks.session.displayName)
                            .font(ApplebotTheme.footnote().weight(.semibold))
                        Spacer()
                        if stocks.isLoading {
                            ProgressView()
                        }
                    }
                    Text(stocks.moversSummary)
                        .font(ApplebotTheme.display(22))
                        .foregroundStyle(ApplebotTheme.ink)
                        .accessibilityIdentifier("stocks-movers")
                    if let refreshed = stocks.lastRefreshed {
                        Text("Updated \(refreshed.formatted(date: .omitted, time: .shortened))")
                            .font(ApplebotTheme.caption())
                            .foregroundStyle(.tertiary)
                    }
                    if !stocks.failures.isEmpty {
                        Text("Couldn’t load: \(stocks.failures.joined(separator: ", "))")
                            .font(ApplebotTheme.caption())
                            .foregroundStyle(ApplebotTheme.warning)
                    }
                    if let error = stocks.errorMessage {
                        Text(error)
                            .font(ApplebotTheme.caption())
                            .foregroundStyle(ApplebotTheme.warning)
                    }
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
                .listRowBackground(Color.clear)
            } header: {
                Text("Today")
            }

            if stocks.isRefreshingInsight || stocks.insightNarrative != nil {
                Section {
                    if stocks.isRefreshingInsight && stocks.insightNarrative == nil {
                        ProgressView("Writing awareness…")
                    } else if let narrative = stocks.insightNarrative {
                        Text(narrative)
                            .font(ApplebotTheme.footnote())
                            .foregroundStyle(ApplebotTheme.ink)
                            .accessibilityIdentifier("stocks-awareness")
                    }
                } header: {
                    Text("Awareness")
                }
            }

            Section {
                askButton("Summarize movers", kind: .movers)
                askButton("Walk my watchlist", kind: .watchlist)
                askButton("Holdings P&L", kind: .holdings)
                askButton("What moved and why?", kind: .whyMoved)
            } header: {
                Text("Ask Applebot")
            }

            if !watchlist.pendingAdds.isEmpty {
                Section {
                    ForEach(watchlist.pendingAdds) { pending in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Add \(pending.symbol)?")
                                .font(ApplebotTheme.footnote().weight(.semibold))
                            if !pending.reason.isEmpty {
                                Text(pending.reason)
                                    .font(ApplebotTheme.caption())
                                    .foregroundStyle(.secondary)
                            }
                            HStack {
                                Button("Add") { watchlist.confirmAdd(pending.id) }
                                    .buttonStyle(.borderedProminent)
                                Button("Dismiss") { watchlist.dismissAdd(pending.id) }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                } header: {
                    Text("Suggested adds")
                }
            }

            if !alerts.pendingAlerts.isEmpty {
                Section {
                    ForEach(alerts.pendingAlerts) { pending in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(pending.rule.displayLine)
                                .font(ApplebotTheme.footnote().weight(.semibold))
                            if !pending.reason.isEmpty {
                                Text(pending.reason)
                                    .font(ApplebotTheme.caption())
                                    .foregroundStyle(.secondary)
                            }
                            HStack {
                                Button("Create alert") { alerts.confirmAlert(pending.id) }
                                    .buttonStyle(.borderedProminent)
                                Button("Dismiss") { alerts.dismissAlert(pending.id) }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                } header: {
                    Text("Suggested alerts")
                }
            }

            Section {
                if watchlist.items.isEmpty {
                    Text("No symbols yet. Add a ticker to track.")
                        .font(ApplebotTheme.footnote())
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(watchlist.items) { item in
                        watchlistRow(item)
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            watchlist.delete(watchlist.items[index].id)
                        }
                    }
                }
            } header: {
                Text("Watchlist")
            }

            Section {
                if holdings.holdings.isEmpty {
                    Text("Optional: enter shares and average cost. Not broker-synced.")
                        .font(ApplebotTheme.footnote())
                        .foregroundStyle(.secondary)
                } else {
                    if let concentration = stocks.concentrationLine {
                        Text(concentration)
                            .font(ApplebotTheme.caption())
                            .foregroundStyle(.secondary)
                    }
                    ForEach(holdings.holdings) { holding in
                        Button {
                            editingHolding = holding
                        } label: {
                            holdingRow(holding)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            holdings.delete(holdings.holdings[index].id)
                        }
                    }
                }
            } header: {
                Text("Holdings")
            }

            Section {
                if alerts.rules.isEmpty {
                    Text("Price and event alerts stay on this iPhone. Evaluation is best-effort in the background.")
                        .font(ApplebotTheme.footnote())
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(alerts.rules) { rule in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rule.displayLine)
                                .font(ApplebotTheme.footnote().weight(.semibold))
                            Text(rule.isEnabled ? "On" : "Paused")
                                .font(ApplebotTheme.caption())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            alerts.delete(alerts.rules[index].id)
                        }
                    }
                }
            } header: {
                Text("Alerts")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func watchlistRow(_ item: WatchlistItemInfo) -> some View {
        let quote = stocks.quoteMap[item.symbol]
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.symbol)
                    .font(ApplebotTheme.footnote().weight(.semibold))
                if !item.groupTag.isEmpty {
                    Text(item.groupTag)
                        .font(ApplebotTheme.caption())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let quote {
                    Text(String(format: "%.2f", quote.price))
                        .font(ApplebotTheme.footnote().monospacedDigit())
                }
            }
            if let quote, let percent = quote.changePercent, let change = quote.change {
                Text(String(format: "%@%.2f (%@%.2f%%)", change >= 0 ? "+" : "", change, percent >= 0 ? "+" : "", percent))
                    .font(ApplebotTheme.caption().monospacedDigit())
                    .foregroundStyle(change >= 0 ? Color.green : Color.red)
            } else if !item.name.isEmpty {
                Text(item.name)
                    .font(ApplebotTheme.caption())
                    .foregroundStyle(.secondary)
            }
            if let quote, let low = quote.dayLow, let high = quote.dayHigh {
                Text(String(format: "Day %.2f–%.2f", low, high))
                    .font(ApplebotTheme.caption())
                    .foregroundStyle(.tertiary)
            }
            HStack {
                Button("Suggest alert") {
                    for rule in stocks.suggestAlerts(for: item.symbol).prefix(2) {
                        alerts.proposeAlert(PendingStockAlert(
                            rule: rule,
                            reason: "Based on recent range for \(item.symbol). Confirm to create."
                        ))
                    }
                }
                .font(ApplebotTheme.caption())
                Spacer()
            }
        }
        .accessibilityIdentifier("watchlist-\(item.symbol)")
    }

    private func holdingRow(_ holding: HoldingInfo) -> some View {
        let quote = stocks.quoteMap[holding.symbol]
        return VStack(alignment: .leading, spacing: 4) {
            Text(holding.displayLine)
                .font(ApplebotTheme.footnote().weight(.semibold))
                .foregroundStyle(ApplebotTheme.ink)
            if let quote {
                let pl = holding.unrealizedPL(price: quote.price)
                Text(String(format: "Mkt %.2f · P&L %@%.2f", quote.price, pl >= 0 ? "+" : "", pl))
                    .font(ApplebotTheme.caption().monospacedDigit())
                    .foregroundStyle(pl >= 0 ? Color.green : Color.red)
            }
        }
    }

    private func askButton(_ title: String, kind: StocksAskKind) -> some View {
        Button {
            let prompt = stocks.askPrompt(kind: kind, holdings: holdings.holdings)
            environment.askInChat(prompt)
        } label: {
            Label(title, systemImage: "bubble.left")
        }
        .accessibilityIdentifier("ask-stocks-\(kind.rawValue)")
    }

    private var disclaimerFooter: some View {
        Text(StocksInsightBuilder.userFacingDisclaimer)
            .font(ApplebotTheme.caption())
            .foregroundStyle(.secondary)
            .padding(.horizontal, ApplebotTheme.spaceM)
    }

    private var addSymbolSheet: some View {
        NavigationStack {
            Form {
                TextField("Symbol", text: $symbolDraft)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                TextField("Name (optional)", text: $nameDraft)
                TextField("Group (optional)", text: $groupDraft)
            }
            .navigationTitle("Add symbol")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showAddSymbol = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let info = WatchlistItemInfo(
                            symbol: symbolDraft,
                            name: nameDraft,
                            groupTag: groupDraft
                        )
                        _ = watchlist.upsert(info)
                        showAddSymbol = false
                        symbolDraft = ""
                        nameDraft = ""
                        groupDraft = ""
                        Task { await refresh(includeInsight: true) }
                    }
                    .disabled(WatchlistItemInfo.normalizeSymbol(symbolDraft).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var addHoldingSheet: some View {
        holdingEditor(initial: nil)
    }

    private func holdingEditor(initial: HoldingInfo?) -> some View {
        NavigationStack {
            Form {
                TextField("Symbol", text: $holdingSymbol)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .disabled(initial != nil)
                TextField("Shares", text: $holdingShares)
                    .keyboardType(.decimalPad)
                TextField("Average cost", text: $holdingCost)
                    .keyboardType(.decimalPad)
            }
            .navigationTitle(initial == nil ? "Add holding" : "Edit holding")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if let initial {
                    holdingSymbol = initial.symbol
                    holdingShares = String(initial.shares)
                    holdingCost = String(initial.avgCost)
                } else if holdingSymbol.isEmpty {
                    holdingShares = ""
                    holdingCost = ""
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showAddHolding = false
                        editingHolding = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let shares = Double(holdingShares.replacingOccurrences(of: ",", with: "")) ?? 0
                        let cost = Double(holdingCost.replacingOccurrences(of: ",", with: "")) ?? 0
                        var info = HoldingInfo(
                            id: initial?.id ?? UUID(),
                            symbol: holdingSymbol,
                            shares: shares,
                            avgCost: cost
                        )
                        if let initial { info.id = initial.id }
                        _ = holdings.upsert(info)
                        // Also ensure symbol is on the watchlist for quotes.
                        if !watchlist.items.contains(where: { $0.symbol == info.symbol }) {
                            _ = watchlist.upsert(WatchlistItemInfo(symbol: info.symbol))
                        }
                        showAddHolding = false
                        editingHolding = nil
                        Task { await refresh(includeInsight: true) }
                    }
                    .disabled(
                        WatchlistItemInfo.normalizeSymbol(holdingSymbol).isEmpty
                            || (Double(holdingShares) ?? 0) <= 0
                    )
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var addAlertSheet: some View {
        NavigationStack {
            Form {
                TextField("Symbol", text: $alertSymbol)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Picker("Kind", selection: $alertKind) {
                    ForEach(StockAlertKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                if alertKind == .eventDate {
                    DatePicker("Event date", selection: $alertEventDate, displayedComponents: .date)
                } else {
                    TextField(alertKind == .dayPercent || alertKind == .near52w ? "Percent" : "Price", text: $alertThreshold)
                        .keyboardType(.decimalPad)
                }
            }
            .navigationTitle("Add alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showAddAlert = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let threshold = Double(alertThreshold.replacingOccurrences(of: ",", with: "")) ?? 0
                        let rule = StockAlertRuleInfo(
                            symbol: alertSymbol,
                            kind: alertKind,
                            threshold: threshold,
                            eventDate: alertKind == .eventDate ? alertEventDate : nil
                        )
                        _ = alerts.upsert(rule)
                        showAddAlert = false
                        alertSymbol = ""
                        alertThreshold = ""
                    }
                    .disabled(WatchlistItemInfo.normalizeSymbol(alertSymbol).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func refresh(includeInsight: Bool) async {
        await stocks.refresh(
            watchlist: watchlist.items,
            holdings: holdings.holdings,
            includeInsight: includeInsight
        )
        await alerts.evaluateAndNotify(quotes: stocks.quoteMap)
        // Backfill names from quotes.
        for item in watchlist.items {
            if item.name.isEmpty, let name = stocks.quoteMap[item.symbol]?.name, !name.isEmpty {
                var copy = item
                copy.name = name
                _ = watchlist.upsert(copy)
            }
        }
    }
}
