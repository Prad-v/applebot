import SwiftUI
import PhotosUI
import ConnectorKit
import LLMKit
import RAGKit

/// Health tab: Apple Health readouts, Applebot-only medications, wellness score + narrative.
struct HealthView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var showAddMedication = false
    @State private var editing: MedicationInfo?
    @State private var showPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var reviewDraft: MedicationDraft?
    @State private var ocrBusy = false
    @State private var ocrError: String?

    private var health: HealthDashboardController { environment.health }
    private var meds: MedicationStore { environment.medications }

    var body: some View {
        NavigationStack {
            Group {
                if !health.isAvailable {
                    unavailable
                } else if !health.isConnected {
                    connectPrompt
                } else {
                    dashboard
                }
            }
            .applebotCanvas()
            .navigationTitle("Health")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if health.isConnected {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button {
                                showAddMedication = true
                            } label: {
                                Label("Add medication", systemImage: "plus")
                            }
                            Button {
                                showPhotoPicker = true
                            } label: {
                                Label("Add from photo", systemImage: "camera")
                            }
                            Button {
                                Task {
                                    await health.refresh(medications: meds.confirmed, includeInsight: true)
                                }
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityIdentifier("health-options")
                    }
                }
            }
            .task {
                await health.refreshStatus()
                if health.isConnected {
                    await health.refresh(medications: meds.confirmed, includeInsight: health.insightNarrative == nil)
                }
            }
            .refreshable {
                await health.refresh(medications: meds.confirmed, includeInsight: true)
            }
            .sheet(isPresented: $showAddMedication) {
                MedicationEditSheet(initial: nil) { info in
                    _ = meds.upsert(info)
                    Task { await health.regenerateInsight(medications: meds.confirmed) }
                }
            }
            .sheet(item: $editing) { med in
                MedicationEditSheet(initial: med) { info in
                    _ = meds.upsert(info)
                    Task { await health.regenerateInsight(medications: meds.confirmed) }
                }
            }
            .sheet(item: $reviewDraft) { draft in
                MedicationReviewSheet(draft: draft) { info in
                    _ = meds.upsert(info)
                    Task { await health.regenerateInsight(medications: meds.confirmed) }
                }
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems, maxSelectionCount: 1, matching: .images)
            .onChange(of: photoItems) { _, items in
                guard let item = items.first else { return }
                Task { await ingestPhoto(item) }
            }
            .alert("Couldn’t read label", isPresented: Binding(
                get: { ocrError != nil },
                set: { if !$0 { ocrError = nil } }
            )) {
                Button("OK", role: .cancel) { ocrError = nil }
            } message: {
                Text(ocrError ?? "")
            }
            .overlay {
                if ocrBusy {
                    ProgressView("Reading label…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private var unavailable: some View {
        ScrollView {
            ApplebotHeroEmpty(
                symbol: "heart.slash",
                title: "Apple Health unavailable",
                message: "This device can’t share Health data with Applebot.",
                primaryTitle: nil,
                primarySystemImage: nil,
                primaryAction: nil
            )
            disclaimerFooter
        }
    }

    private var connectPrompt: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ApplebotTheme.spaceL) {
                ApplebotHeroEmpty(
                    symbol: "heart.text.square",
                    title: "Your health, on this iPhone",
                    message: "Connect Apple Health to see today’s activity and vitals. Medications you add stay in Applebot only — nothing is written back to Health.",
                    primaryTitle: "Connect Apple Health",
                    primarySystemImage: "heart",
                    primaryAction: {
                        Task {
                            await health.connect()
                            await environment.connectors.refresh()
                        }
                    }
                )
                .accessibilityIdentifier("health-connect")

                if let error = health.errorMessage {
                    Text(error)
                        .font(ApplebotTheme.footnote())
                        .foregroundStyle(ApplebotTheme.warning)
                        .padding(.horizontal, ApplebotTheme.spaceM)
                }

                disclaimerFooter
            }
            .padding(.bottom, ApplebotTheme.spaceXL)
        }
    }

    private var dashboard: some View {
        List {
            Section {
                Text(HealthInsightBuilder.userFacingDisclaimer)
                    .font(ApplebotTheme.caption())
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 4, trailing: 20))
            }

            if let score = health.score {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(score.total)")
                                .font(ApplebotTheme.display(44))
                                .foregroundStyle(ApplebotTheme.ink)
                                .accessibilityIdentifier("wellness-score")
                            Text("/ 100")
                                .font(ApplebotTheme.footnote())
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Text("Wellness")
                                .font(ApplebotTheme.caption())
                                .foregroundStyle(.secondary)
                        }
                        ForEach(score.components) { component in
                            HStack {
                                Text(component.name)
                                    .font(ApplebotTheme.footnote())
                                Spacer()
                                Text("\(component.points)/\(component.maxPoints)")
                                    .font(ApplebotTheme.caption())
                                    .foregroundStyle(.secondary)
                            }
                            Text(component.detail)
                                .font(ApplebotTheme.caption())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
                    .listRowBackground(Color.clear)
                } header: {
                    Text("Wellness score")
                } footer: {
                    Text("Transparent formula from steps, sleep, resting heart rate, and activity on this iPhone — not a diagnosis.")
                }
            }

            if let narrative = health.insightNarrative {
                Section("Awareness") {
                    Text(narrative)
                        .font(ApplebotTheme.footnote())
                        .foregroundStyle(ApplebotTheme.ink)
                        .listRowBackground(Color.clear)
                    if health.isRefreshingInsight {
                        ProgressView()
                    }
                }
            } else if health.isRefreshingInsight {
                Section("Awareness") {
                    ProgressView("Writing a short note…")
                }
            }

            if !health.weekPoints.isEmpty {
                Section {
                    ForEach(health.weekPoints) { point in
                        HStack {
                            Text(point.day, format: .dateTime.weekday(.abbreviated))
                                .frame(width: 36, alignment: .leading)
                            Text("\(point.score)")
                                .font(.body.weight(.medium))
                                .monospacedDigit()
                            GeometryReader { geo in
                                Capsule()
                                    .fill(ApplebotTheme.accent.opacity(0.25))
                                    .frame(width: max(4, geo.size.width * CGFloat(point.score) / 100), height: 8)
                                    .frame(maxHeight: .infinity, alignment: .center)
                            }
                            .frame(height: 16)
                            if let steps = point.steps {
                                Text("\(Int(steps.rounded()))")
                                    .font(ApplebotTheme.caption())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 44, alignment: .trailing)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("Last 7 days")
                } footer: {
                    Text("Daily wellness scores from Apple Health on this iPhone.")
                }
                .accessibilityIdentifier("health-week-trend")
            }

            Section {
                Button {
                    environment.askInChat(health.askPrompt(kind: .score, medications: meds.confirmed))
                } label: {
                    Label("Ask about my score", systemImage: "bubble.left")
                }
                .accessibilityIdentifier("ask-health-score")
                Button {
                    environment.askInChat(health.askPrompt(kind: .week, medications: meds.confirmed))
                } label: {
                    Label("Ask about my week", systemImage: "calendar")
                }
                Button {
                    environment.askInChat(health.askPrompt(kind: .medications, medications: meds.confirmed))
                } label: {
                    Label("Ask about my medications", systemImage: "pills")
                }
                .accessibilityIdentifier("ask-health-meds")
            } header: {
                Text("Ask Applebot")
            } footer: {
                Text("Opens Chat with a private on-device prompt. Not medical advice.")
            }

            Section("Today") {
                if health.isLoading && health.today == nil {
                    ProgressView()
                } else if let today = health.today {
                    metricRow("Steps", value: today.steps.map { "\(Int($0.rounded()))" } ?? "—")
                    metricRow("Active energy", value: today.activeEnergyKcal.map { String(format: "%.0f kcal", $0) } ?? "—")
                    metricRow("Sleep", value: today.sleepHours.map { String(format: "%.1f h", $0) } ?? "—")
                    metricRow("Resting HR", value: today.restingHeartRate.map { String(format: "%.0f bpm", $0) } ?? "—")
                    metricRow("Heart rate avg", value: today.heartRateAvg.map { String(format: "%.0f bpm", $0) } ?? "—")
                    metricRow("Blood oxygen", value: today.bloodOxygenAvg.map { String(format: "%.0f%%", $0) } ?? "—")
                    metricRow("Weight", value: today.weightKg.map { String(format: "%.1f kg", $0) } ?? "—")
                    metricRow("Workouts", value: "\(today.workoutCount)")
                } else {
                    Text("No samples for today yet.")
                        .foregroundStyle(.secondary)
                }
            }

            if !health.workouts.isEmpty {
                Section("Workouts") {
                    ForEach(health.workouts) { workout in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(workout.activityType)
                                .font(.body.weight(.medium))
                            Text(String(format: "%.0f min", workout.durationMinutes)
                                 + (workout.totalEnergyKcal.map { String(format: " · %.0f kcal", $0) } ?? ""))
                                .font(ApplebotTheme.caption())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                if meds.medications.isEmpty {
                    Text("No medications yet. Add one manually or from a label photo.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(meds.medications) { med in
                        HStack(alignment: .top, spacing: 12) {
                            Button {
                                editing = med
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(med.name)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(ApplebotTheme.ink)
                                    Text(med.displayLine)
                                        .font(ApplebotTheme.caption())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                    HStack(spacing: 6) {
                                        Text(med.source.displayName)
                                        if med.remindersEnabled, !med.reminderTimes.isEmpty {
                                            Text("· \(med.reminderTimes.joined(separator: ", "))")
                                        }
                                        if med.takenToday() {
                                            Text("· Taken today")
                                                .foregroundStyle(ApplebotTheme.accent)
                                        }
                                    }
                                    .font(ApplebotTheme.caption())
                                    .foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                            Spacer(minLength: 0)
                            if !med.takenToday() {
                                Button("Taken") {
                                    meds.markTaken(med.id)
                                }
                                .font(ApplebotTheme.caption().weight(.semibold))
                                .accessibilityIdentifier("mark-taken-\(med.id.uuidString)")
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                meds.delete(med.id)
                                Task { await health.regenerateInsight(medications: meds.confirmed) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                Button {
                    showAddMedication = true
                } label: {
                    Label("Add medication", systemImage: "plus")
                }
                .accessibilityIdentifier("add-medication")
                Button {
                    showPhotoPicker = true
                } label: {
                    Label("Add from photo", systemImage: "camera")
                }
                .accessibilityIdentifier("add-medication-photo")
            } header: {
                Text("Medications")
            } footer: {
                Text("Stored only in Applebot. Never written to Apple Health.")
            }

            if !health.clinicalRecords.isEmpty {
                Section {
                    ForEach(health.clinicalRecords) { record in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.displayName)
                                .font(.body.weight(.medium))
                            Text(record.recordType)
                                .font(ApplebotTheme.caption())
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Health Records")
                } footer: {
                    Text("Read-only from Apple Health when you’ve linked a provider.")
                }
            }

            if let error = health.errorMessage {
                Section {
                    Text(error).foregroundStyle(ApplebotTheme.warning)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func metricRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var disclaimerFooter: some View {
        Text(HealthInsightBuilder.userFacingDisclaimer)
            .font(ApplebotTheme.caption())
            .foregroundStyle(.tertiary)
            .padding(.horizontal, ApplebotTheme.spaceM)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ingestPhoto(_ item: PhotosPickerItem) async {
        ocrBusy = true
        ocrError = nil
        defer {
            ocrBusy = false
            photoItems = []
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                ocrError = "Could not load that photo."
                return
            }
            let ext = "jpg"
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("med-label-\(UUID().uuidString).\(ext)")
            try data.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }

            #if canImport(Vision) && canImport(ImageIO)
            let blocks = try await ImageTextExtractor().extract(from: url)
            let text = blocks.map(\.text).joined(separator: "\n")
            #else
            let text = ""
            #endif
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                ocrError = "No text found on that image. Try a clearer photo of the label."
                return
            }

            var draft = MedicationParser.draft(fromOCR: text)
            let polish = MedicationParser().polishRequest(ocrText: text)
            if let raw = try? await environment.activeEngine().respond(polish) {
                draft = MedicationParser.parsePolished(raw, fallback: text)
            }
            reviewDraft = draft

            // Optional: keep a copy in the Health document pack for auditability.
            _ = await environment.importText(
                title: "Label \(draft.name.isEmpty ? "scan" : draft.name)",
                text: text,
                pack: DocumentPack.health,
                autoDismiss: true
            )
        } catch {
            ocrError = error.localizedDescription
        }
    }
}

// MARK: - Sheets

private struct MedicationEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let initial: MedicationInfo?
    var onSave: (MedicationInfo) -> Void

    @State private var name: String
    @State private var dose: String
    @State private var frequency: String
    @State private var notes: String
    @State private var remindersEnabled: Bool
    @State private var reminderTimesText: String

    init(initial: MedicationInfo?, onSave: @escaping (MedicationInfo) -> Void) {
        self.initial = initial
        self.onSave = onSave
        _name = State(initialValue: initial?.name ?? "")
        _dose = State(initialValue: initial?.dose ?? "")
        _frequency = State(initialValue: initial?.frequency ?? "")
        _notes = State(initialValue: initial?.notes ?? "")
        _remindersEnabled = State(initialValue: initial?.remindersEnabled ?? false)
        _reminderTimesText = State(initialValue: (initial?.reminderTimes ?? []).joined(separator: ", "))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("medication-name")
                    TextField("Dose (e.g. 500 mg)", text: $dose)
                    TextField("Frequency (e.g. twice daily)", text: $frequency)
                }
                Section {
                    Toggle("Daily reminders", isOn: $remindersEnabled)
                        .accessibilityIdentifier("medication-reminders-toggle")
                    if remindersEnabled {
                        TextField("Times (e.g. 08:00, 20:00)", text: $reminderTimesText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("medication-reminder-times")
                    }
                } header: {
                    Text("Reminders")
                } footer: {
                    Text("Local notifications on this iPhone only. Applebot does not write doses to Apple Health.")
                }
                Section("Notes") {
                    TextField("Optional notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }
                Section {
                    Text(HealthInsightBuilder.userFacingDisclaimer)
                        .font(ApplebotTheme.caption())
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(initial == nil ? "Add medication" : "Edit medication")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let times = reminderTimesText
                            .split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
                            .map(String.init)
                        let info = MedicationInfo(
                            id: initial?.id ?? UUID(),
                            name: name,
                            dose: dose,
                            frequency: frequency,
                            notes: notes,
                            source: initial?.source ?? .manual,
                            ocrRawText: initial?.ocrRawText,
                            userConfirmed: true,
                            remindersEnabled: remindersEnabled,
                            reminderTimes: times,
                            lastTakenAt: initial?.lastTakenAt
                        )
                        onSave(info)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("save-medication")
                }
            }
        }
    }
}

private struct MedicationReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let draft: MedicationDraft
    var onSave: (MedicationInfo) -> Void

    @State private var name: String
    @State private var dose: String
    @State private var frequency: String
    @State private var notes: String

    init(draft: MedicationDraft, onSave: @escaping (MedicationInfo) -> Void) {
        self.draft = draft
        self.onSave = onSave
        _name = State(initialValue: draft.name)
        _dose = State(initialValue: draft.dose)
        _frequency = State(initialValue: draft.frequency)
        _notes = State(initialValue: draft.notes)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Confirm what was read from the label before saving.")
                        .font(ApplebotTheme.footnote())
                        .foregroundStyle(.secondary)
                }
                Section("Medication") {
                    TextField("Name", text: $name)
                    TextField("Dose", text: $dose)
                    TextField("Frequency", text: $frequency)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }
                if !draft.ocrRawText.isEmpty {
                    Section("OCR text") {
                        Text(draft.ocrRawText)
                            .font(ApplebotTheme.caption())
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text(HealthInsightBuilder.userFacingDisclaimer)
                        .font(ApplebotTheme.caption())
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Review label")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var info = draft.asInfo
                        info.name = name
                        info.dose = dose
                        info.frequency = frequency
                        info.notes = notes
                        info.userConfirmed = true
                        onSave(info)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

