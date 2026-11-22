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
    /// When set, ChatsView opens a new chat and sends this prompt (check-in / automation).
    var pendingChatPrompt: String?

    /// Combined profile + ranked memory for the chat pipeline.
    var personalContextBlock: String? {
        memory.personalContext(profile: profile.profile)
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

        connectors = ConnectorsModel(registry: ConnectorRegistry(
            connectors: Self.makeConnectors(mock: useMockEngine),
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
        Task { await knowledgeBase.setIngestProfileID(family.activeID) }
    }

    /// Switch family profile (Face ID when required) and reload scoped personalization.
    @discardableResult
    func switchProfile(to id: UUID) async -> Bool {
        let ok = await family.select(id)
        guard ok else { return false }
        profile.bind(profileID: id)
        styleCard.bind(profileID: id)
        dailyBrief.bind(profileID: id)
        checkIns.bind(profileID: id)
        retrievalTuner.bind(profileID: id)
        automations.bind(profileID: id)
        automations.installTemplatesIfEmpty()
        memory.bind(profileID: id)
        await knowledgeBase.setIngestProfileID(id)
        await refreshDocuments()
        await refreshDailyBriefIfNeeded()
        checkIns.consider(facts: memory.facts)
        automations.considerDue()
        return true
    }

    func start() async {
        do {
            try await knowledgeBase.open()
        } catch {
            startupError = "Could not load the document library: \(error.localizedDescription)"
        }
        await refreshDocuments()
        refreshAvailability()
        await connectors.refresh()
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
            // Permissions can change in the Settings app while Applebot is in the background.
            Task {
                await connectors.refresh()
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
        dailyBrief.considerShowing(
            profile: profile.profile,
            facts: memory.facts,
            events: events,
            reminderTitles: reminders
        )
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
            automations: automations.recipes
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
        profile.clear()
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

    private static func makeConnectors(mock: Bool) -> [any Connector] {
        let web = WebAuthSession()
        if mock {
            // UI tests and `make sim MOCK=1`: no permission prompts, no Keychain. The live-data
            // connectors only touch the network when switched on and called, which the mock
            // engine never does, and web search has no key here.
            let now = Date()
            let sample = CalendarEventInfo(
                id: "demo-1", title: "Design review", start: now.addingTimeInterval(3600),
                end: now.addingTimeInterval(7200), location: "Room 4"
            )
            let sampleReminder = ReminderInfo(id: "rem-1", title: "Ship onboarding", due: now.addingTimeInterval(7200))
            return [
                CalendarConnector(provider: InMemoryCalendarProvider(permission: .notDetermined, events: [sample])),
                RemindersConnector(provider: InMemoryRemindersProvider(permission: .notDetermined, reminders: [sampleReminder])),
                GmailConnector(configuration: nil, store: InMemoryTokenStore(), web: web),
                WeatherConnector(),
                StocksConnector(),
                WebSearchConnector(configuration: nil),
            ]
        }
        // The client ID and search key are injected at build time from GOOGLE_CLIENT_ID and
        // BRAVE_API_KEY (see docs/connectors.md).
        let clientID = Bundle.main.object(forInfoDictionaryKey: "GoogleOAuthClientID") as? String ?? ""
        let searchKey = Bundle.main.object(forInfoDictionaryKey: "BraveSearchAPIKey") as? String ?? ""
        return [
            CalendarConnector(provider: EventKitCalendarProvider()),
            RemindersConnector(provider: EventKitRemindersProvider()),
            GmailConnector(
                configuration: GmailConfiguration(clientID: clientID),
                store: KeychainTokenStore(), web: web
            ),
            WeatherConnector(),
            StocksConnector(),
            WebSearchConnector(configuration: WebSearchConfiguration(apiKey: searchKey)),
        ]
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
