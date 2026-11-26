import Foundation
import Observation
import SwiftData
import SwiftUI
import LocalAuthentication
import LLMKit
import RAGKit
import ConnectorKit

/// A document import in progress or recently finished.
struct ImportJob: Identifiable, Equatable {
    enum State: Equatable {
        case running
        case done(String)
        case failed(String)
    }

    let id = UUID()
    var name: String
    var progress: Double = 0
    var state: State = .running
}

/// App-wide services: the on-device model, the private document library, and the app lock.
@MainActor
@Observable
final class AppEnvironment {
    /// On-device (or mock) engine. Prefer `activeEngine` for chats — that honours the external-model switch.
    let onDeviceEngine: any LLMEngine
    let knowledgeBase: KnowledgeBase
    let embedderIdentifier: String
    /// OpenAI / Anthropic settings and Keychain-backed API keys.
    let externalStore: ExternalModelStore
    /// Gmail, Calendar and any other connectors the user has switched on.
    let connectors: ConnectorsModel
    /// Holds a chat while the user decides on an action the assistant proposed.
    let approvals = ApprovalCoordinator()

    private(set) var availability: EngineAvailability
    /// Short label for Settings and the chat banner (on-device vs the active external provider).
    private(set) var modelSummary: String = "Apple Intelligence (on-device)"
    private(set) var documents: [DocumentRecord] = []
    private(set) var chunkCount = 0
    private(set) var imports: [ImportJob] = []
    private(set) var startupError: String?

    var isLocked: Bool

    @ObservationIgnored private let defaults = UserDefaults.standard
    /// Injected in UI tests so Settings can exercise the external path without a network.
    @ObservationIgnored private let externalTransport: (any StreamingTransport)?

    var lockEnabled: Bool {
        didSet {
            defaults.set(lockEnabled, forKey: Keys.lockEnabled)
            if !lockEnabled { isLocked = false }
        }
    }

    var retrievalLimit: Int {
        let stored = defaults.integer(forKey: Keys.retrievalLimit)
        return stored == 0 ? 4 : min(max(stored, 2), 6)
    }

    /// How Applebot talks (Settings → Conversation style). Defaults to Warm companion.
    var chatTone: ChatTone {
        ChatTone(rawValue: defaults.string(forKey: Keys.chatTone) ?? "") ?? .productDefault
    }

    /// True when the Settings toggle is on (even if the key is still missing).
    var externalModelEnabled: Bool { externalStore.isEnabled }

    /// True when chats will actually call an external provider right now.
    var isUsingExternalModel: Bool { externalStore.activeConfig() != nil }

    /// Context window budget for the active engine. External models get a much larger window.
    var contextWindowTokens: Int { isUsingExternalModel ? 128_000 : 4096 }

    enum Keys {
        static let lockEnabled = "lockEnabled"
        static let retrievalLimit = "retrievalLimit"
        static let chatTone = "chatTone"
        static let appearanceTheme = ThemeController.Keys.appearanceTheme
        static let memoryEnabled = MemoryStore.Keys.enabled
        static let voiceAutoSpeak = VoiceController.Keys.autoSpeak
        static let voiceHandsFree = VoiceController.Keys.handsFree
        static let dailyBriefEnabled = DailyBriefController.Keys.enabled
    }

    /// Compatibility for call sites that still read `.engine` — always the engine chats should use.
    var engine: any LLMEngine { activeEngine() }

    /// Family / multi-profile (Face ID to switch).
    let family: FamilyProfileStore
    /// Cross-chat memories (Settings → What Applebot remembers).
    let memory = MemoryStore()
    /// Structured profile + confirmed preferences.
    let profile: PersonalProfileStore
    /// Learned routines / interests / stress patterns (behavioral twin card).
    let behavior: BehavioralProfileStore
    /// Optional “write like me” style card for rewrites.
    let styleCard: StyleCardStore
    /// Opt-in morning / unlock brief.
    let dailyBrief: DailyBriefController
    /// Proactive check-ins for open loops.
    let checkIns: CheckInController
    /// Per-profile retrieval weight adaptation.
    let retrievalTuner: RetrievalTunerStore
    /// Local automation recipes.
    let automations: AutomationStore
    /// On-device speech input and spoken replies.
    let voice = VoiceController()
    /// Applebot-only medications (Health tab).
    let medications = MedicationStore()
    /// Health tab dashboard (Apple Health read-only + wellness insights).
    let health = HealthDashboardController()
    /// Stocks watchlist (on-device).
    let watchlist = WatchlistStore()
    /// User-entered holdings (on-device, not broker-synced).
    let holdings = HoldingsStore()
    /// Stock price / event alerts.
    let stockAlerts = StockAlertStore()
    /// Stocks tab dashboard (quotes + awareness).
    let stocks = StocksDashboardController()
    /// Trail tab: GPS, waypoints, offline maps.
    let wilderness = WildernessDashboardController()
    /// Surroundings tab: camera scene description for accessibility.
    let surroundings = SurroundingsController()
    /// Scan tab: RoomPlan 3D room capture.
    let roomScan = RoomScanController()
    @ObservationIgnored private let roomScanStore: RoomScanFileStore
    /// Shared with `HealthKitConnector` for the Health tab.
    @ObservationIgnored private let healthProvider: any HealthKitProvider
    /// Shared Stocks connector instance for the Stocks tab batch refresh.
    @ObservationIgnored private let stocksConnector: StocksConnector
    /// Core Location controller for continuous trail recording (optional).
    @ObservationIgnored let locationController: CoreLocationController?
    /// Shared GPS provider for Trail UI and Location / Weather connectors.
    @ObservationIgnored private let locationProvider: any LocationProvider
    /// Core Motion provider for sedentary checks (optional on restricted devices).
    @ObservationIgnored private let motionProvider: any MotionProvider
    /// On-disk offline map packs (shared with MapKit overlays).
    @ObservationIgnored let offlineMapStore: OfflineMapFileStore?
    @ObservationIgnored private let trailStore: any TrailStore
    /// When set, ChatsView opens a new chat and sends this prompt (check-in / automation / Health Ask).
    var pendingChatPrompt: String?
    /// Selected root tab (Health Ask switches to Chat).
    var selectedTab: AppTab = .chat

    /// Switch to Chat and queue a prompt for a new conversation.
    func askInChat(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        selectedTab = .chat
        pendingChatPrompt = trimmed
    }

    /// Apply actions queued by notifications or App Intents / Siri.
    func processPendingActions() {
        let actions = PendingAppActionStore.shared.drain()
        guard !actions.isEmpty else { return }
        for action in actions {
            switch action {
            case .markMedicationTaken(let id):
                medications.markTaken(id)
                selectedTab = .health
            case .markMedicationTakenByName(let name):
                _ = medications.markTaken(named: name)
                selectedTab = .health
            case .askWellnessScore:
                let prompt = health.askPrompt(kind: .score, medications: medications.confirmed)
                askInChat(prompt)
            case .openHealth:
                selectedTab = .health
            case .openStocks:
                selectedTab = .stocks
            case .askAboutSymbol(let symbol):
                askInChat(
                    "What might be driving \(symbol)'s move? Use stock_quote and web search if available. "
                        + "Do not recommend trades. Not financial advice."
                )
            case .snoozeAlert(let id):
                stockAlerts.snooze(id)
                selectedTab = .stocks
            case .askPortfolioSummary:
                let prompt = stocks.askPrompt(kind: .holdings, holdings: holdings.holdings)
                askInChat(prompt)
            }
        }
    }

    /// Combined profile + ranked memory + behavioral patterns + compact health/meds + stocks for the chat pipeline.
    var personalContextBlock: String? {
        let base = memory.personalContext(profile: profile.profile)
        let behaviorBlock = behavior.promptBlock
        let healthBlock = HealthContextBudget.render(
            medications: medications.confirmed,
            score: health.score,
            activityLine: health.activityLine
        )
        let stocksBlock = StocksContextBudget.render(
            watchlist: watchlist.items,
            holdings: holdings.holdings,
            quotes: stocks.quoteMap
        )
        return [base, behaviorBlock, healthBlock, stocksBlock].compactMap { $0 }.joined(separator: "\n\n").nilIfEmpty
    }

    /// Connector tools plus Applebot medication / watchlist / holdings tools.
    func activeChatTools() async -> [ToolSpec] {
        var tools = await connectors.activeTools()
        tools.append(contentsOf: medications.tools())
        tools.append(contentsOf: watchlist.tools(quotes: stocks.quoteMap))
        tools.append(contentsOf: holdings.tools(quotes: stocks.quoteMap))
        return tools
    }

    /// Active family profile id (for chats / documents scoping).
    var activeProfileID: UUID { family.activeID }

    init(useMockEngine: Bool = ProcessInfo.processInfo.arguments.contains("-UITestMockEngine")) {
        let defaults = UserDefaults.standard
        lockEnabled = defaults.bool(forKey: Keys.lockEnabled)
        isLocked = defaults.bool(forKey: Keys.lockEnabled)

        let familyStore = FamilyProfileStore(defaults: defaults)
        family = familyStore
        let pid = familyStore.activeID
        profile = PersonalProfileStore(defaults: defaults, profileID: pid)
        behavior = BehavioralProfileStore(defaults: defaults, profileID: pid)
        styleCard = StyleCardStore(defaults: defaults, profileID: pid)
        dailyBrief = DailyBriefController(defaults: defaults, profileID: pid)
        checkIns = CheckInController(defaults: defaults, profileID: pid)
        retrievalTuner = RetrievalTunerStore(defaults: defaults, profileID: pid)
        automations = AutomationStore(defaults: defaults, profileID: pid)
        automations.installTemplatesIfEmpty()

        onDeviceEngine = useMockEngine ? Self.makeMockEngine() : AppleFMEngine()
        externalTransport = useMockEngine ? Self.makeMockExternalTransport() : nil
        #if canImport(Security)
        let secrets: any SecretStore = useMockEngine ? InMemorySecretStore() : KeychainSecretStore()
        #else
        let secrets: any SecretStore = InMemorySecretStore()
        #endif
        externalStore = ExternalModelStore(
            defaults: useMockEngine ? UserDefaults(suiteName: "applebot.uitest.external") ?? .standard : .standard,
            secrets: secrets
        )

        let embedder = EmbedderFactory.preferred()
        embedderIdentifier = embedder.identifier

        let store: ChunkStore
        do {
            let url = useMockEngine ? nil : AppPaths.dataDirectory.appendingPathComponent("knowledge.sqlite")
            store = try SQLiteChunkStore(url: url)
        } catch {
            startupError = "Could not open the document library: \(error.localizedDescription)"
            store = InMemoryChunkStore()
        }
        knowledgeBase = KnowledgeBase(store: store, embedder: embedder)

        let built = Self.makeConnectors(mock: useMockEngine)
        healthProvider = built.healthProvider
        locationController = built.locationController
        locationProvider = built.locationProvider
        motionProvider = built.motionProvider
        trailStore = built.trailStore
        offlineMapStore = built.mapStore
        let scansRoot = AppPaths.dataDirectory.appendingPathComponent(
            useMockEngine ? "room-scans-mock" : "room-scans",
            isDirectory: true
        )
        roomScanStore = RoomScanFileStore(directory: scansRoot)
        // Separate instance for the Stocks tab batch refresh (stateless HTTP; chat tools use the registry copy).
        stocksConnector = StocksConnector()
        connectors = ConnectorsModel(registry: ConnectorRegistry(
            connectors: built.connectors,
            preferences: useMockEngine ? InMemoryConnectorPreferences() : UserDefaultsConnectorPreferences()
        ))

        availability = .available
        refreshAvailability()
    }

    /// The engine chats should use right now (external when the switch is on and configured).
    func activeEngine() -> any LLMEngine {
        guard let config = externalStore.activeConfig() else { return onDeviceEngine }
        if let transport = externalTransport {
            return ExternalEngine(config: config, transport: transport)
        }
        return ExternalEngine(config: config)
    }

    // MARK: Lifecycle

    /// Bind SwiftData so memory facts can load. Call once from the root view.
    func attachModelContext(_ context: ModelContext) {
        memory.attach(context: context, profile: profile, profileID: family.activeID)
        medications.attach(context: context, profileID: family.activeID)
        watchlist.attach(context: context, profileID: family.activeID)
        holdings.attach(context: context, profileID: family.activeID)
        stockAlerts.attach(context: context, profileID: family.activeID)
        Task { await knowledgeBase.setIngestProfileID(family.activeID) }
        processPendingActions()
    }

    /// Switch family profile (Face ID when required) and reload scoped personalization.
    @discardableResult
    func switchProfile(to id: UUID) async -> Bool {
        let ok = await family.select(id)
        guard ok else { return false }
        profile.bind(profileID: id)
        behavior.bind(profileID: id)
        styleCard.bind(profileID: id)
        dailyBrief.bind(profileID: id)
        checkIns.bind(profileID: id)
        retrievalTuner.bind(profileID: id)
        automations.bind(profileID: id)
        automations.installTemplatesIfEmpty()
        memory.bind(profileID: id)
        medications.bind(profileID: id)
        watchlist.bind(profileID: id)
        holdings.bind(profileID: id)
        stockAlerts.bind(profileID: id)
        await knowledgeBase.setIngestProfileID(id)
        await refreshDocuments()
        await refreshDailyBriefIfNeeded()
        checkIns.consider(facts: memory.facts)
        automations.considerDue()
        if health.isConnected {
            await health.refresh(medications: medications.confirmed, includeInsight: true)
        }
        if stocks.isConnectorEnabled {
            await stocks.refresh(watchlist: watchlist.items, holdings: holdings.holdings, includeInsight: true)
        }
        return true
    }

    func start() async {
        health.configure(provider: healthProvider, engine: { [weak self] in
            self?.activeEngine() ?? MockEngine()
        })
        stocks.configure(
            connector: stocksConnector,
            isEnabled: { [weak self] in
                guard let self else { return false }
                return await self.connectors.registry.isEnabled("stocks")
            },
            engine: { [weak self] in
                self?.activeEngine() ?? MockEngine()
            }
        )
        if let offlineMapStore {
            wilderness.configure(
                connectors: connectors,
                locationProvider: locationProvider,
                locationController: locationController,
                motionProvider: motionProvider,
                trail: trailStore,
                maps: offlineMapStore
            )
        }
        surroundings.configure(
            engine: { [weak self] in
                self?.activeEngine() ?? MockEngine()
            },
            speak: { [weak self] text in
                self?.voice.speakForced(text)
            },
            isSpeaking: { [weak self] in
                self?.voice.isSpeaking == true
            }
        )
        surroundings.refreshCapabilities()
        surroundings.refreshCameraPermission()
        roomScan.configure(
            store: roomScanStore,
            engine: { [weak self] in
                self?.activeEngine() ?? MockEngine()
            },
            speak: { [weak self] text in
                self?.voice.speakForced(text)
            }
        )
        roomScan.refreshCapabilities()
        do {
            try await knowledgeBase.open()
        } catch {
            startupError = "Could not load the document library: \(error.localizedDescription)"
        }
        await refreshDocuments()
        refreshAvailability()
        await connectors.refresh()
        await health.refreshStatus()
        await stocks.refreshStatus()
        await wilderness.refreshStatus()
        voice.refreshOnDeviceAvailability()
        if !isUsingExternalModel, let engine = onDeviceEngine as? AppleFMEngine {
            engine.prewarm(
                instructions: PromptBuilder(tone: chatTone).instructions(
                    summary: nil, grounded: false, memories: personalContextBlock
                )
            )
        }
        await refreshDailyBriefIfNeeded()
        checkIns.consider(facts: memory.facts)
        automations.considerDue()
        processPendingActions()
        StocksBackgroundRefresh.schedule()
    }

    func unlock() async {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode or biometrics configured: nothing to protect with, so do not trap the user.
            isLocked = false
            await refreshDailyBriefIfNeeded()
            return
        }
        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthentication, localizedReason: "Unlock your private chats and documents"
            )
            if ok {
                isLocked = false
                await refreshDailyBriefIfNeeded()
            }
        } catch {
            // Cancelled or failed; stay locked.
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background, .inactive:
            voice.stopAll()
            if phase == .background, lockEnabled { isLocked = true }
        case .active:
            refreshAvailability()
            voice.refreshOnDeviceAvailability()
            processPendingActions()
            // Permissions can change in the Settings app while Applebot is in the background.
            Task {
                await connectors.refresh()
                await stocks.refreshStatus()
                if stocks.isConnectorEnabled, !watchlist.items.isEmpty || !holdings.holdings.isEmpty {
                    await stocks.refresh(
                        watchlist: watchlist.items,
                        holdings: holdings.holdings,
                        includeInsight: false
                    )
                    await stockAlerts.evaluateAndNotify(quotes: stocks.quoteMap)
                }
                await refreshDailyBriefIfNeeded()
                checkIns.consider(facts: memory.facts)
                automations.considerDue()
            }
        default:
            break
        }
    }

    /// Build today's brief once per day when the feature is on.
    func refreshDailyBriefIfNeeded() async {
        guard dailyBrief.isEnabled else { return }
        let events = await todayBriefEvents()
        let reminders = await todayBriefReminders()
        // Prefer a fresh Health snapshot when connected so the brief can mention sleep/steps/score.
        if health.isConnected || health.permission == .authorized {
            await health.refresh(medications: medications.confirmed, includeInsight: false)
        } else {
            await health.refreshStatus()
        }
        var healthLines = health.briefHealthLines
        let medNames = medications.reminderNames
        if !medNames.isEmpty {
            healthLines.append(contentsOf: DailyBriefBuilder.healthLines(dueMedications: medNames).filter { line in
                !healthLines.contains(line)
            })
        }
        // Refresh watchlist quotes when Stocks is on so the brief can mention movers.
        await stocks.refreshStatus()
        if stocks.isConnectorEnabled, !watchlist.items.isEmpty || !holdings.holdings.isEmpty {
            await stocks.refresh(
                watchlist: watchlist.items,
                holdings: holdings.holdings,
                includeInsight: false
            )
        }
        let marketLines = stocks.briefMarketLines
        dailyBrief.considerShowing(
            profile: profile.profile,
            facts: memory.facts,
            events: events,
            reminderTitles: reminders,
            healthLines: healthLines,
            marketLines: marketLines
        )
        await refreshBehavioralProfile()
    }

    func todayBriefEvents() async -> [BriefEvent] {
        guard let calendar = connectors.registry.connectors.first(where: { $0.id == "calendar" }) as? CalendarConnector
        else { return [] }
        let info = await calendar.todayEvents()
        return info.map {
            BriefEvent(title: $0.title, start: $0.start, end: $0.end, isAllDay: $0.isAllDay, location: $0.location)
        }
    }

    func todayBriefReminders() async -> [String] {
        guard let reminders = connectors.registry.connectors.first(where: { $0.id == "reminders" }) as? RemindersConnector
        else { return [] }
        let items = await reminders.openReminders(limit: 6)
        return items.map { item in
            if let due = item.due {
                return "\(item.title) (due \(due.formatted(date: .abbreviated, time: .shortened)))"
            }
            return item.title
        }
    }

    func refreshAvailability() {
        if externalStore.isEnabled {
            let config = externalStore.config(for: externalStore.selectedProvider)
            if let problem = config.problem {
                availability = .unavailable(problem)
                modelSummary = "\(config.provider.displayName) (not ready)"
            } else {
                availability = .available
                modelSummary = "\(config.provider.displayName) · \(config.effectiveModel)"
            }
            return
        }
        availability = onDeviceEngine.availability()
        modelSummary = "Apple Intelligence (on-device)"
    }

    func setExternalModelEnabled(_ enabled: Bool) {
        externalStore.isEnabled = enabled
        refreshAvailability()
    }

    func selectExternalProvider(_ provider: ExternalProvider) {
        externalStore.selectedProvider = provider
        refreshAvailability()
    }

    func saveExternalConfig(_ config: ExternalModelConfig) throws {
        try externalStore.save(config)
        refreshAvailability()
    }

    // MARK: Documents

    func refreshDocuments() async {
        let all = await knowledgeBase.documents()
        documents = DocumentPack.forProfile(all, profileID: family.activeID)
        chunkCount = await knowledgeBase.chunkCount
    }

    func setDocumentPack(_ document: DocumentRecord, pack: String?) async {
        _ = try? await knowledgeBase.setPack(documentID: document.id, pack: pack)
        await refreshDocuments()
    }

    var documentPacks: [String] {
        DocumentPack.packs(in: documents)
    }

    /// Import files picked from the Files app or Photos. Files are read and indexed; the originals
    /// are not copied.
    ///
    /// `completion` receives the library records for every file that is now in the library,
    /// including files that were already imported before (so attaching a known file still works).
    /// With `autoDismiss`, successful rows disappear a few seconds after finishing; failures stay
    /// until dismissed.
    func importFiles(
        _ urls: [URL],
        autoDismiss: Bool = false,
        completion: (@MainActor ([DocumentRecord]) -> Void)? = nil
    ) {
        let jobs = urls.map { ImportJob(name: $0.deletingPathExtension().lastPathComponent) }
        imports.append(contentsOf: jobs)
        Task {
            var records: [DocumentRecord] = []
            for (url, job) in zip(urls, jobs) {
                if let record = await runImport(url: url, jobID: job.id) { records.append(record) }
            }
            await refreshDocuments()
            completion?(records)
            if autoDismiss { await dismissCompleted(jobs.map(\.id)) }
        }
    }

    /// Index pasted text. Returns the library record (new or pre-existing), or nil on failure.
    @discardableResult
    func importText(title: String, text: String, pack: String? = nil, autoDismiss: Bool = false) async -> DocumentRecord? {
        var job = ImportJob(name: title)
        imports.append(job)
        var record: DocumentRecord?
        do {
            let composed = DocumentPack.compose(pack: pack, title: DocumentPack.parse(title).title)
            let outcome = try await knowledgeBase.ingest(title: composed, text: text)
            job.state = .done(Self.describe(outcome))
            record = Self.record(from: outcome)
            if let pack, let id = record?.id {
                _ = try? await knowledgeBase.setPack(documentID: id, pack: pack)
                record = await knowledgeBase.documents().first(where: { $0.id == id })
            }
        } catch {
            job.state = .failed(error.localizedDescription)
        }
        job.progress = 1
        update(job)
        await refreshDocuments()
        if autoDismiss { await dismissCompleted([job.id]) }
        return record
    }

    // MARK: Vault

    func buildVaultPayload(includeDocuments: Bool) async -> PersonalVaultPayload {
        var vaultDocs: [VaultDocument] = []
        if includeDocuments {
            for document in documents {
                if let text = await knowledgeBase.exportText(documentID: document.id) {
                    vaultDocs.append(VaultDocument(
                        id: document.id,
                        title: document.displayTitle,
                        pack: DocumentPack.pack(of: document),
                        text: text
                    ))
                }
            }
        }
        return PersonalVaultPayload(
            profileName: family.active.name,
            personalProfile: profile.profile,
            styleCard: styleCard.card,
            memories: memory.facts,
            documents: vaultDocs,
            retrievalWeights: retrievalTuner.weights,
            automations: automations.recipes,
            behavioralProfile: behavior.profile
        )
    }

    func exportVault(password: String, includeDocuments: Bool) async throws -> Data {
        let payload = await buildVaultPayload(includeDocuments: includeDocuments)
        return try PersonalVaultCrypto.export(payload, password: password)
    }

    func importVault(data: Data, password: String, replaceMemories: Bool) async throws {
        let payload = try PersonalVaultCrypto.importPayload(from: data, password: password)
        profile.replace(payload.personalProfile)
        styleCard.replace(payload.styleCard)
        behavior.replace(payload.behavioralProfile)
        retrievalTuner.apply(payload.retrievalWeights)
        if replaceMemories {
            memory.replaceAll(payload.memories)
        } else {
            memory.ingest(candidates: payload.memories)
        }
        automations.replace(payload.automations)
        for doc in payload.documents {
            _ = await importText(title: doc.title, text: doc.text, pack: doc.pack, autoDismiss: true)
        }
    }

    /// Pull Health week + today's calendar into the behavioral twin card.
    func refreshBehavioralProfile() async {
        guard behavior.isEnabled else { return }
        if health.isConnected || health.permission == .authorized {
            await health.refresh(medications: medications.confirmed, includeInsight: false)
        }
        var samples: [BehavioralDaySample] = health.weekPoints.map { point in
            BehavioralDaySample(
                day: point.day,
                sleepHours: point.sleepHours,
                steps: point.steps,
                workoutCount: point.workoutCount
            )
        }
        if samples.isEmpty, let today = health.today {
            samples = [
                BehavioralDaySample(
                    day: Date(),
                    sleepHours: today.sleepHours,
                    steps: today.steps,
                    workoutCount: health.workouts.count
                )
            ]
        } else if let today = health.today, !samples.isEmpty {
            // Overlay today's workout count onto the matching day sample.
            let calendar = Calendar.current
            if let index = samples.firstIndex(where: { calendar.isDate($0.day, inSameDayAs: Date()) }) {
                samples[index] = BehavioralDaySample(
                    day: samples[index].day,
                    sleepHours: today.sleepHours ?? samples[index].sleepHours,
                    steps: today.steps ?? samples[index].steps,
                    workoutCount: health.workouts.count,
                    firstEventHour: samples[index].firstEventHour,
                    lastEventHour: samples[index].lastEventHour
                )
            }
        }

        let events = await todayBriefEvents()
        if !events.isEmpty {
            let calendar = Calendar.current
            let timed = events.filter { !$0.isAllDay }
            let starts = timed.map { calendar.component(.hour, from: $0.start) }
            let ends = timed.map { calendar.component(.hour, from: $0.end) }
            let firstHour = starts.min()
            let lastHour = ends.max()
            let day = calendar.startOfDay(for: Date())
            if let index = samples.firstIndex(where: { calendar.isDate($0.day, inSameDayAs: day) }) {
                samples[index] = BehavioralDaySample(
                    day: samples[index].day,
                    sleepHours: samples[index].sleepHours,
                    steps: samples[index].steps,
                    workoutCount: samples[index].workoutCount,
                    firstEventHour: firstHour ?? samples[index].firstEventHour,
                    lastEventHour: lastHour ?? samples[index].lastEventHour
                )
            } else {
                samples.append(BehavioralDaySample(
                    day: day,
                    firstEventHour: firstHour,
                    lastEventHour: lastHour
                ))
            }
        }

        behavior.ingestDays(samples)
    }

    /// Structure a voice transcript and ingest it into the Voice notes pack.
    @discardableResult
    func importVoiceNote(
        transcript: String,
        polishWithModel: Bool = true,
        autoDismiss: Bool = true
    ) async -> DocumentRecord? {
        var note = VoiceNoteStructurer.structure(transcript)
        if polishWithModel {
            let request = VoiceNoteStructurer().polishRequest(transcript: transcript)
            if let raw = try? await activeEngine().respond(request) {
                note = VoiceNoteStructurer.parsePolished(raw, fallback: transcript)
            }
        }
        return await importText(title: note.documentTitle, text: note.documentText, autoDismiss: autoDismiss)
    }

    private func runImport(url: URL, jobID: UUID) async -> DocumentRecord? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var state: ImportJob.State
        var record: DocumentRecord?
        do {
            let blocks = try await DocumentExtractor().extract(from: url)
            let outcome = try await knowledgeBase.ingest(
                title: url.deletingPathExtension().lastPathComponent,
                sourceName: url.lastPathComponent,
                blocks: blocks
            ) { [weak self] value in
                Task { @MainActor in self?.setProgress(value, for: jobID) }
            }
            state = .done(Self.describe(outcome))
            record = Self.record(from: outcome)
        } catch {
            state = .failed(error.localizedDescription)
        }
        if let index = imports.firstIndex(where: { $0.id == jobID }) {
            imports[index].progress = 1
            imports[index].state = state
        }
        return record
    }

    private static func record(from outcome: IngestOutcome) -> DocumentRecord {
        switch outcome {
        case .added(let record), .duplicate(let record): return record
        }
    }

    private static func describe(_ outcome: IngestOutcome) -> String {
        switch outcome {
        case .added(let record): return "Indexed \(record.chunkCount) passages"
        case .duplicate: return "Already in your library"
        }
    }

    private func dismissCompleted(_ ids: [UUID]) async {
        try? await Task.sleep(for: .seconds(3))
        imports.removeAll { job in
            guard ids.contains(job.id) else { return false }
            if case .done = job.state { return true }
            return false
        }
    }

    private func setProgress(_ value: Double, for id: UUID) {
        if let index = imports.firstIndex(where: { $0.id == id }) { imports[index].progress = value }
    }

    private func update(_ job: ImportJob) {
        if let index = imports.firstIndex(where: { $0.id == job.id }) { imports[index] = job }
    }

    func dismissFinishedImports() {
        imports.removeAll { $0.state != .running }
    }

    func remove(document: DocumentRecord) async {
        try? await knowledgeBase.remove(documentID: document.id)
        await refreshDocuments()
    }

    /// Erase the document library, chats and cross-chat memories.
    func deleteAllData(modelContext: ModelContext) async {
        voice.stopAll()
        try? await knowledgeBase.removeAll()
        try? modelContext.delete(model: Conversation.self)
        memory.deleteAll()
        medications.deleteAll()
        health.clearInsights()
        watchlist.deleteAll()
        holdings.deleteAll()
        stockAlerts.deleteAll()
        stocks.clearInsights()
        profile.clear()
        behavior.clear()
        styleCard.clear()
        dailyBrief.clearHistory()
        checkIns.clearHistory()
        retrievalTuner.reset()
        automations.clear()
        try? modelContext.save()
        await refreshDocuments()
        await connectors.disconnectAll()
        // API keys are Settings, not chat data — leave them. The user can clear them under External model.
    }


    // MARK: Connectors

    /// The scripted engine for UI tests. `-UITestToolDemo` makes the first answer propose adding a
    /// calendar event, which exercises tool calling and the approval sheet without a real model.
    private static func makeMockEngine() -> MockEngine {
        let engine = MockEngine(chunkSize: 6, delayNanoseconds: 15_000_000)
        if ProcessInfo.processInfo.arguments.contains("-UITestToolDemo") {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            let day = formatter.string(from: Date().addingTimeInterval(86_400))
            engine.enqueue(.useTools(
                [.init("calendar_create_event", ["title": "Lunch with Sam", "start": "\(day) 12:30", "location": "Cafe Roma"])],
                reply: "Tool said: {results}"
            ))
        }
        return engine
    }

    /// Canned OpenAI-style SSE so UI tests can flip the external switch without calling a real API.
    private static func makeMockExternalTransport() -> MockStreamingTransport {
        MockStreamingTransport { _ in
            MockStreamingTransport.Reply(status: 200, lines: [
                #"data: {"choices":[{"delta":{"content":"External mock reply."}}]}"#,
                #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
                "data: [DONE]",
            ])
        }
    }

    private struct BuiltConnectors {
        var connectors: [any Connector]
        var healthProvider: any HealthKitProvider
        var locationProvider: any LocationProvider
        var locationController: CoreLocationController?
        var motionProvider: any MotionProvider
        var trailStore: any TrailStore
        var mapStore: OfflineMapFileStore?
    }

    private static func makeConnectors(mock: Bool) -> BuiltConnectors {
        let web = WebAuthSession()
        let trailRoot = AppPaths.dataDirectory.appendingPathComponent(mock ? "trail-mock" : "trail", isDirectory: true)
        let mapsRoot = AppPaths.dataDirectory.appendingPathComponent(mock ? "maps-mock" : "maps", isDirectory: true)
        let weatherCache = FileWeatherCacheStore(directory: trailRoot)
        let trailStore: any TrailStore = FileTrailStore(directory: trailRoot)
        let mapStore = OfflineMapFileStore(directory: mapsRoot)
        let locationController = CoreLocationController()
        let locationProvider = locationController.asProvider

        if mock {
            // UI tests and `make sim MOCK=1`: no permission prompts, no Keychain. The live-data
            // connectors only touch the network when switched on and called, which the mock
            // engine never does, and web search has no key here.
            let now = Date()
            let dayStart = Calendar.current.startOfDay(for: now)
            let sample = CalendarEventInfo(
                id: "demo-1", title: "Design review", start: now.addingTimeInterval(3600),
                end: now.addingTimeInterval(7200), location: "Room 4"
            )
            let sampleReminder = ReminderInfo(id: "rem-1", title: "Ship onboarding", due: now.addingTimeInterval(7200))
            var healthSamples: [HealthSampleInfo] = [
                HealthSampleInfo(
                    id: "hk-1", metric: .steps, value: 6420, unit: "steps",
                    start: now.addingTimeInterval(-3600), end: now
                ),
                HealthSampleInfo(
                    id: "hk-sleep", metric: .sleep, value: 7.2 * 3600, unit: "s",
                    start: dayStart.addingTimeInterval(-8 * 3600), end: dayStart.addingTimeInterval(-0.8 * 3600)
                ),
                HealthSampleInfo(
                    id: "hk-rhr", metric: .restingHeartRate, value: 62, unit: "count/min",
                    start: dayStart, end: dayStart.addingTimeInterval(60)
                ),
                HealthSampleInfo(
                    id: "hk-energy", metric: .activeEnergy, value: 320, unit: "kcal",
                    start: dayStart, end: now
                ),
            ]
            // Prior days so the Health tab 7-day trend has mock data.
            for offset in 1...6 {
                guard let day = Calendar.current.date(byAdding: .day, value: -offset, to: dayStart) else { continue }
                let steps = Double(5000 + offset * 350)
                healthSamples.append(HealthSampleInfo(
                    id: "hk-steps-\(offset)", metric: .steps, value: steps, unit: "steps",
                    start: day.addingTimeInterval(10 * 3600), end: day.addingTimeInterval(18 * 3600)
                ))
                healthSamples.append(HealthSampleInfo(
                    id: "hk-sleep-\(offset)", metric: .sleep, value: (6.5 + Double(offset % 3) * 0.4) * 3600, unit: "s",
                    start: day.addingTimeInterval(-7.5 * 3600), end: day.addingTimeInterval(-0.5 * 3600)
                ))
                healthSamples.append(HealthSampleInfo(
                    id: "hk-rhr-\(offset)", metric: .restingHeartRate, value: Double(58 + offset), unit: "count/min",
                    start: day, end: day.addingTimeInterval(60)
                ))
            }
            let sampleWorkout = HealthWorkoutInfo(
                id: "wo-1", activityType: "Walking",
                start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-5400),
                durationMinutes: 30, totalEnergyKcal: 120, totalDistanceMeters: 2400
            )
            let sampleRecord = HealthClinicalRecordInfo(
                id: "cr-1", recordType: "allergy", displayName: "Penicillin"
            )
            let healthProvider = InMemoryHealthKitProvider(
                permission: .notDetermined,
                samples: healthSamples,
                workouts: [sampleWorkout],
                records: [sampleRecord]
            )
            let mockLocation = InMemoryLocationProvider(permission: .notDetermined)
            let mockMotion = InMemoryMotionProvider(permission: .notDetermined)
            return BuiltConnectors(
                connectors: [
                    CalendarConnector(provider: InMemoryCalendarProvider(permission: .notDetermined, events: [sample])),
                    RemindersConnector(provider: InMemoryRemindersProvider(permission: .notDetermined, reminders: [sampleReminder])),
                    HealthKitConnector(provider: healthProvider),
                    GmailConnector(configuration: nil, store: InMemoryTokenStore(), web: web),
                    LocationConnector(provider: mockLocation, trail: trailStore, maps: mapStore),
                    MotionConnector(provider: mockMotion),
                    WeatherConnector(locationProvider: mockLocation, cache: weatherCache),
                    StocksConnector(),
                    WebSearchConnector(configuration: nil),
                ],
                healthProvider: healthProvider,
                locationProvider: mockLocation,
                locationController: nil,
                motionProvider: mockMotion,
                trailStore: trailStore,
                mapStore: mapStore
            )
        }
        // The client ID and search key are injected at build time from GOOGLE_CLIENT_ID and
        // BRAVE_API_KEY (see docs/connectors.md).
        let clientID = Bundle.main.object(forInfoDictionaryKey: "GoogleOAuthClientID") as? String ?? ""
        let searchKey = Bundle.main.object(forInfoDictionaryKey: "BraveSearchAPIKey") as? String ?? ""
        #if canImport(HealthKit)
        let healthProvider: any HealthKitProvider = HealthKitStoreProvider()
        #else
        let healthProvider: any HealthKitProvider = InMemoryHealthKitProvider(permission: .restricted, available: false)
        #endif
        #if canImport(CoreMotion)
        let motionProvider: any MotionProvider = CoreMotionStoreProvider()
        #else
        let motionProvider: any MotionProvider = InMemoryMotionProvider(
            permission: .restricted,
            capabilities: .none
        )
        #endif
        let health = HealthKitConnector(provider: healthProvider)
        let motion = MotionConnector(provider: motionProvider)
        return BuiltConnectors(
            connectors: [
                CalendarConnector(provider: EventKitCalendarProvider()),
                RemindersConnector(provider: EventKitRemindersProvider()),
                health,
                GmailConnector(
                    configuration: GmailConfiguration(clientID: clientID),
                    store: KeychainTokenStore(), web: web
                ),
                LocationConnector(provider: locationProvider, trail: trailStore, maps: mapStore),
                motion,
                WeatherConnector(locationProvider: locationProvider, cache: weatherCache),
                StocksConnector(),
                WebSearchConnector(configuration: WebSearchConfiguration(apiKey: searchKey)),
            ],
            healthProvider: healthProvider,
            locationProvider: locationProvider,
            locationController: locationController,
            motionProvider: motionProvider,
            trailStore: trailStore,
            mapStore: mapStore
        )
    }
}

enum AppTab: String, Hashable, CaseIterable {
    case chat
    case library
    case health
    case stocks
    case trail
    case surroundings
    case scan
    case you
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum AppPaths {
    /// `Application Support/Applebot`, created on demand with file protection that keeps data
    /// encrypted at rest whenever the device is locked and the file is not already open.
    static var dataDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Applebot", isDirectory: true)
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try? manager.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
            )
        }
        return directory
    }
}
