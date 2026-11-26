import Foundation
import Observation
import UIKit
import ConnectorKit
import LLMKit

#if canImport(RoomPlan)
import RoomPlan
#endif

/// Scan tab: RoomPlan 3D room capture, USDZ save/share, spoken summary.
@MainActor
@Observable
final class RoomScanController {
    private(set) var capabilities: RoomScanCapabilities = .airTypical
    private(set) var records: [RoomScanRecord] = []
    private(set) var statusMessage: String?
    private(set) var errorMessage: String?
    private(set) var lastSummary: String?
    private(set) var usedModel = false
    private(set) var isSaving = false
    private(set) var isSummarizing = false
    private(set) var acceptedDisclaimer: Bool

    @ObservationIgnored private var store: RoomScanFileStore?
    @ObservationIgnored private var engine: (() -> any LLMEngine)?
    @ObservationIgnored private var speak: ((String) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    private enum Keys {
        static let accepted = "roomScanAcceptedDisclaimer"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        acceptedDisclaimer = defaults.bool(forKey: Keys.accepted)
        capabilities = RoomScanCapabilityProbe.current()
    }

    var canScan: Bool {
        acceptedDisclaimer && capabilities.scanSupported
    }

    var sensorWarnings: [String] {
        capabilities.warnings
    }

    func configure(
        store: RoomScanFileStore,
        engine: @escaping () -> any LLMEngine,
        speak: @escaping (String) -> Void
    ) {
        self.store = store
        self.engine = engine
        self.speak = speak
        reload()
    }

    func refreshCapabilities() {
        capabilities = RoomScanCapabilityProbe.current()
    }

    func acceptDisclaimer() {
        acceptedDisclaimer = true
        defaults.set(true, forKey: Keys.accepted)
        UIAccessibility.post(notification: .announcement, argument: RoomScanNarrator.safetyDisclaimer)
    }

    func reload() {
        records = store?.list() ?? []
    }

    #if canImport(RoomPlan)
    func save(captured: CapturedRoom, name: String) async {
        guard let store else {
            errorMessage = "Scan storage is not available."
            return
        }
        isSaving = true
        errorMessage = nil
        statusMessage = "Saving USDZ…"
        defer { isSaving = false }

        do {
            let facts = Self.facts(from: captured)
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("applebot-room-\(UUID().uuidString).usdz")
            try captured.export(to: temp, exportOptions: .mesh)
            let record = try store.importUSDZ(
                from: temp,
                name: name.isEmpty ? Self.defaultName() : name,
                facts: facts
            )
            try? FileManager.default.removeItem(at: temp)
            reload()
            statusMessage = "Saved “\(record.name)”."
            UIAccessibility.post(notification: .announcement, argument: statusMessage ?? "")
            await summarize(facts: facts, autoSpeak: true)
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
            UIAccessibility.post(notification: .announcement, argument: errorMessage ?? "Save failed.")
        }
    }

    static func facts(from room: CapturedRoom) -> RoomScanFacts {
        let labels = room.objects.map { categoryLabel($0.category) }
        return RoomScanFacts(
            wallCount: room.walls.count,
            doorCount: room.doors.count,
            windowCount: room.windows.count,
            openingCount: room.openings.count,
            objectLabels: labels,
            capturedAt: Date()
        )
    }

    private static func categoryLabel(_ category: CapturedRoom.Object.Category) -> String {
        let raw = String(describing: category)
        let leaf = raw.split(separator: ".").last.map(String.init) ?? raw
        switch leaf.lowercased() {
        case "washerdryer": return "washer or dryer"
        case "unknown", "": return "object"
        default: return leaf.lowercased()
        }
    }
    #endif

    func summarize(facts: RoomScanFacts, autoSpeak: Bool) async {
        isSummarizing = true
        defer { isSummarizing = false }
        let text: String
        if let engine, let raw = try? await engine().respond(RoomScanNarrator.narrationRequest(facts: facts)) {
            text = RoomScanNarrator.normalizeModelOutput(raw, facts: facts)
            usedModel = true
        } else {
            text = RoomScanNarrator.mechanicalSummary(facts)
            usedModel = false
        }
        lastSummary = text
        if autoSpeak {
            speak?(text)
        }
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    func speakSummaryAgain() {
        guard let lastSummary else { return }
        speak?(lastSummary)
    }

    func delete(_ id: UUID) {
        do {
            try store?.delete(id)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rename(_ id: UUID, to name: String) {
        do {
            try store?.rename(id, to: name)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func usdzURL(for record: RoomScanRecord) -> URL? {
        guard let store else { return nil }
        let url = store.usdzURL(for: record)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func defaultName() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Room \(formatter.string(from: Date()))"
    }
}
