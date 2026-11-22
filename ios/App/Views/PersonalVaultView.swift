import SwiftUI
import UniformTypeIdentifiers

struct PersonalVaultView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var password = ""
    @State private var confirm = ""
    @State private var includeDocuments = true
    @State private var exportURL: URL?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var importPassword = ""
    @State private var replaceMemories = true
    @State private var status: String?
    @State private var busy = false
    @State private var pendingImport: Data?

    var body: some View {
        Form {
            Section {
                SecureField("Password", text: $password)
                SecureField("Confirm password", text: $confirm)
                Toggle("Include document text", isOn: $includeDocuments)
                Button("Export encrypted pack") {
                    Task { await exportPack() }
                }
                .disabled(busy || password.count < 6 || password != confirm)
            } header: {
                Text("Export")
            } footer: {
                Text("Creates an encrypted .applebotpack on this iPhone. You need the password to restore. Nothing is uploaded.")
            }

            Section {
                SecureField("Password", text: $importPassword)
                Toggle("Replace memories", isOn: $replaceMemories)
                Button("Import pack…") { showImporter = true }
                    .disabled(busy || importPassword.count < 6)
            } header: {
                Text("Restore")
            } footer: {
                Text("Restores profile, style card, automations, retrieval weights, and optionally documents into the active family profile.")
            }

            if let status {
                Section { Text(status).font(.footnote) }
            }
        }
        .navigationTitle("Backup & restore")
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [UTType(filenameExtension: "applebotpack") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                pendingImport = try? Data(contentsOf: url)
                Task { await importPack() }
            }
        }
        .sheet(isPresented: $showExporter) {
            if let exportURL {
                ShareLink(item: exportURL) {
                    Label("Share Applebot pack", systemImage: "square.and.arrow.up")
                }
                .padding()
            }
        }
    }

    private func exportPack() async {
        busy = true
        defer { busy = false }
        do {
            let data = try await environment.exportVault(password: password, includeDocuments: includeDocuments)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Applebot-\(environment.family.active.name).applebotpack")
            try data.write(to: url, options: .atomic)
            exportURL = url
            showExporter = true
            status = "Export ready."
        } catch {
            status = error.localizedDescription
        }
    }

    private func importPack() async {
        guard let pendingImport else { return }
        busy = true
        defer { busy = false }
        do {
            try await environment.importVault(
                data: pendingImport,
                password: importPassword,
                replaceMemories: replaceMemories
            )
            status = "Restored into \(environment.family.active.name)."
            self.pendingImport = nil
        } catch {
            status = error.localizedDescription
        }
    }
}
