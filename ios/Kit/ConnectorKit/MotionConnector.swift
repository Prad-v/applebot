import Foundation
import LLMKit

/// On-device Core Motion sedentary / activity summaries for chat.
///
/// Raw streams never leave the device. Missing sensors disable only the matching slice
/// (see `MotionCapabilities` warnings).
public struct MotionConnector: Connector {
    public let id = "motion"
    public let displayName = "Motion"
    public let summary = "On-device steps and activity for a soft sedentary check — no cloud."
    public let symbolName = "figure.walk.motion"
    public let dataNote =
        "Reads the accelerometer, gyro, pedometer and (when available) barometer on this iPhone only. "
        + "Summaries stay on-device and are never uploaded. Applebot does not nag; it answers when you ask."
    public let hasAccount = false
    public var usesNetwork: Bool { false }

    public let provider: any MotionProvider

    /// Steps in the last two hours below this (while stationary) count as sedentary.
    public static let sedentaryStepThreshold = 200

    public init(provider: any MotionProvider) {
        self.provider = provider
    }

    public func status() async -> ConnectorStatus {
        let caps = await provider.capabilities()
        guard caps.sedentarySupported else {
            return .unavailable(
                "Sedentary check needs step counting or motion activity, which are not available on this device."
            )
        }
        switch await provider.permission() {
        case .authorized:
            return .connected(account: nil)
        case .denied, .restricted:
            return .notConnected
        case .notDetermined:
            return .notConnected
        }
    }

    public func connect() async throws {
        let caps = await provider.capabilities()
        guard caps.sedentarySupported else {
            throw ConnectorError.notConfigured(
                "Sedentary check needs step counting or motion activity. That is not available on this device."
            )
        }
        let granted = try await provider.requestAccess()
        guard granted else {
            throw ConnectorError.permissionDenied(
                "Motion access was denied. Allow Motion & Fitness for Applebot in the Settings app."
            )
        }
    }

    public func disconnect() async {}

    public func tools() -> [ToolSpec] {
        [sedentaryTool, capabilitiesTool]
    }

    // MARK: Tools

    private var sedentaryTool: ToolSpec {
        let provider = self.provider
        return ToolSpec(
            name: "motion_sedentary",
            description:
                "Summarise recent on-device motion: current activity (stationary/walking/…), steps in the last two hours and today, "
                + "and whether a soft sedentary check looks likely. Use when the user asks if they have been sitting too long, "
                + "about recent movement, or a gentle activity nudge. Not medical advice. Do not invent numbers.",
            parameters: [],
            label: "Checking motion",
            handler: { _ in
                let snap = try await provider.sedentarySnapshot()
                return Self.render(snap)
            }
        )
    }

    private var capabilitiesTool: ToolSpec {
        let provider = self.provider
        return ToolSpec(
            name: "motion_capabilities",
            description:
                "List which motion sensors are available on this iPhone (pedometer, activity, barometer altitude) "
                + "and which sedentary features are disabled with reasons. Use when the user asks what sensors work, "
                + "or why a motion feature is unavailable (for example on a simulator).",
            parameters: [],
            label: "Checking sensors",
            handler: { _ in
                let caps = await provider.capabilities()
                return Self.renderCapabilities(caps)
            }
        )
    }

    // MARK: Rendering

    public static func render(_ snap: MotionSedentarySnapshot) -> String {
        var lines: [String] = ["Motion summary (on this iPhone):"]
        lines.append("- Activity: \(snap.activity.displayName)")
        if let steps = snap.stepsLastTwoHours {
            lines.append("- Steps in last ~2 hours: \(steps)")
        } else if !snap.capabilities.pedometer {
            lines.append("- Steps (2h): unavailable (pedometer disabled on this device)")
        }
        if let today = snap.stepsToday {
            lines.append("- Steps today: \(today)")
        }
        if let floors = snap.floorsAscended {
            lines.append("- Floors ascended today: \(floors)")
        } else if !snap.capabilities.relativeAltitude {
            lines.append("- Floors / relative altitude: unavailable (no barometer altitude API)")
        }
        if let alt = snap.relativeAltitudeMeters {
            lines.append(String(format: "- Relative altitude since session start: %.1f m", alt))
        }
        lines.append("- Sedentary likely: \(snap.sedentaryLikely ? "yes" : "no")")
        if !snap.note.isEmpty {
            lines.append("- Note: \(snap.note)")
        }
        let warnings = snap.capabilities.warnings.filter {
            $0.contains("Sedentary") == false || !snap.capabilities.sedentarySupported
        }
        if !warnings.isEmpty {
            lines.append("Sensor notes:")
            for warning in warnings.prefix(4) {
                lines.append("- \(warning)")
            }
        }
        lines.append("Not medical advice. Encourage a short stretch or walk only if the user wants a nudge.")
        return lines.joined(separator: "\n")
    }

    public static func renderCapabilities(_ caps: MotionCapabilities) -> String {
        var lines: [String] = ["Motion sensors on this iPhone:"]
        for feature in caps.features {
            let mark = feature.isAvailable ? "available" : "disabled"
            lines.append("- \(feature.displayName): \(mark)")
            if let reason = feature.unavailableReason, !feature.isAvailable {
                lines.append("  \(reason)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Shared sedentary heuristic for live and test providers.
    public static func evaluateSedentary(
        activity: MotionActivityKind,
        stepsLastTwoHours: Int?,
        capabilities: MotionCapabilities
    ) -> (likely: Bool, note: String) {
        guard capabilities.sedentarySupported else {
            return (false, "Sedentary check disabled — pedometer and activity classification are unavailable.")
        }
        let lowSteps: Bool
        if let steps = stepsLastTwoHours {
            lowSteps = steps < sedentaryStepThreshold
        } else {
            lowSteps = false
        }
        switch activity {
        case .stationary:
            if lowSteps || stepsLastTwoHours == nil {
                return (
                    true,
                    stepsLastTwoHours == nil
                        ? "Currently stationary."
                        : "Few steps in the last two hours while stationary."
                )
            }
            return (false, "Stationary now, but recent step count looks active.")
        case .walking, .running, .cycling:
            return (false, "Currently \(activity.displayName.lowercased()).")
        case .automotive:
            return (false, "In a vehicle — sedentary check skipped.")
        case .unknown:
            if lowSteps {
                return (true, "Low steps in the last two hours; activity classification unknown.")
            }
            return (false, "Activity classification unknown.")
        }
    }
}
