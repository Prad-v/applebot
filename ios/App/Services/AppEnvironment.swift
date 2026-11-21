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
    let engine: any LLMEngine
    let knowledgeBase: KnowledgeBase
    let embedderIdentifier: String
    /// Gmail, Calendar and any other connectors the user has switched on.
    let connectors: ConnectorsModel
    /// Holds a chat while the user decides on an action the assistant proposed.
    let approvals = ApprovalCoordinator()

    private(set) var availability: EngineAvailability
    private(set) var documents: [DocumentRecord] = []
    private(set) var chunkCount = 0
    private(set) var imports: [ImportJob] = []
    private(set) var startupError: String?

    var isLocked: Bool

    @ObservationIgnored private let defaults = UserDefaults.standard

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

    /// How Applebot talks (Settings → Conversation style).
    var chatTone: ChatTone {
        ChatTone(rawValue: defaults.string(forKey: Keys.chatTone) ?? "") ?? .neutral
    }

    enum Keys {
        static let lockEnabled = "lockEnabled"
        static let retrievalLimit = "retrievalLimit"
        static let chatTone = "chatTone"
    }

    init(useMockEngine: Bool = ProcessInfo.processInfo.arguments.contains("-UITestMockEngine")) {
        let defaults = UserDefaults.standard
        lockEnabled = defaults.bool(forKey: Keys.lockEnabled)
        isLocked = defaults.bool(forKey: Keys.lockEnabled)

        engine = useMockEngine ? Self.makeMockEngine() : AppleFMEngine()
        availability = engine.availability()

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
    }

    // MARK: Lifecycle

    func start() async {
        do {
            try await knowledgeBase.open()
        } catch {
            startupError = "Could not load the document library: \(error.localizedDescription)"
        }
        await refreshDocuments()
        refreshAvailability()
        await connectors.refresh()
        if let engine = engine as? AppleFMEngine {
            engine.prewarm(instructions: PromptBuilder().instructions(summary: nil, grounded: false))
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            if lockEnabled { isLocked = true }
        case .active:
            refreshAvailability()
            // Permissions can change in the Settings app while Applebot is in the background.
            Task { await connectors.refresh() }
        default:
            break
        }
    }

    func refreshAvailability() {
        availability = engine.availability()
    }

    // MARK: Lock

    func unlock() async {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode or biometrics configured: nothing to protect with, so do not trap the user.
            isLocked = false
            return
        }
        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthentication, localizedReason: "Unlock your private chats and documents"
            )
            if ok { isLocked = false }
        } catch {
            // Cancelled or failed; stay locked.
        }
    }

    // MARK: Documents

    func refreshDocuments() async {
        documents = await knowledgeBase.documents()
        chunkCount = await knowledgeBase.chunkCount
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
    func importText(title: String, text: String, autoDismiss: Bool = false) async -> DocumentRecord? {
        var job = ImportJob(name: title)
        imports.append(job)
        var record: DocumentRecord?
        do {
            let outcome = try await knowledgeBase.ingest(title: title, text: text)
            job.state = .done(Self.describe(outcome))
            record = Self.record(from: outcome)
        } catch {
            job.state = .failed(error.localizedDescription)
        }
        job.progress = 1
        update(job)
        await refreshDocuments()
        if autoDismiss { await dismissCompleted([job.id]) }
        return record
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

    /// Erase the document library and all chats.
    func deleteAllData(modelContext: ModelContext) async {
        try? await knowledgeBase.removeAll()
        try? modelContext.delete(model: Conversation.self)
        try? modelContext.save()
        await refreshDocuments()
        await connectors.disconnectAll()
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

    private static func makeConnectors(mock: Bool) -> [any Connector] {
        let web = WebAuthSession()
        if mock {
            // UI tests and `make sim MOCK=1`: no permission prompts, no network, no Keychain.
            let now = Date()
            let sample = CalendarEventInfo(
                id: "demo-1", title: "Design review", start: now.addingTimeInterval(3600),
                end: now.addingTimeInterval(7200), location: "Room 4"
            )
            return [
                CalendarConnector(provider: InMemoryCalendarProvider(permission: .notDetermined, events: [sample])),
                GmailConnector(configuration: nil, store: InMemoryTokenStore(), web: web),
            ]
        }
        // The client ID is injected at build time from GOOGLE_CLIENT_ID (see docs/connectors.md).
        let clientID = Bundle.main.object(forInfoDictionaryKey: "GoogleOAuthClientID") as? String ?? ""
        return [
            CalendarConnector(provider: EventKitCalendarProvider()),
            GmailConnector(
                configuration: GmailConfiguration(clientID: clientID),
                store: KeychainTokenStore(), web: web
            ),
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
