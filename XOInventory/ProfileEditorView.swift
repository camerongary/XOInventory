//
//  ProfileEditorView.swift
//  XOInventory
//
//  Sheet for adding or editing a saved host profile.
//

import SwiftUI

struct ProfileEditorView: View {
    enum Mode {
        case add
        case edit(HostProfile)

        var title: String {
            switch self {
            case .add: return "New Host"
            case .edit: return "Edit Host"
            }
        }
    }

    let mode: Mode
    @ObservedObject var store: ProfileStore
    var onSaved: (HostProfile) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var host: String = ""
    @State private var token: String = ""
    @State private var allowSelfSigned: Bool = true
    @State private var tokenPlaceholder: String = "Paste token"
    @State private var testState: TestState = .idle

    enum TestState: Equatable {
        case idle
        case running
        case success(String)
        case failure(String)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !host.trimmingCharacters(in: .whitespaces).isEmpty &&
        (isEdit || !token.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private var isEdit: Bool {
        if case .edit = mode { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(mode.title).font(.headline)
                Spacer()
            }
            .padding()
            Divider()

            // Form
            VStack(alignment: .leading, spacing: 14) {
                field(label: "Profile Name") {
                    TextField("Homelab, Production, etc.", text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                field(label: "XO Host") {
                    TextField("xo.lan or 10.0.0.5", text: $host)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                }

                field(label: "Authentication Token") {
                    SecureField(tokenPlaceholder, text: $token)
                        .textFieldStyle(.roundedBorder)
                    if isEdit {
                        Text("Leave blank to keep the current token.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Toggle("Allow self-signed certificate", isOn: $allowSelfSigned)
                    .toggleStyle(.checkbox)

                // Test result line
                HStack(spacing: 6) {
                    switch testState {
                    case .idle:
                        EmptyView()
                    case .running:
                        ProgressView().controlSize(.small)
                        Text("Testing connection…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .success(let msg):
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.green)
                    case .failure(let msg):
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }
                .frame(height: 36, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()

            Spacer(minLength: 0)
            Divider()

            // Footer
            HStack {
                Button {
                    Task { await runTest() }
                } label: {
                    Label("Test Connection", systemImage: "bolt.horizontal")
                }
                .disabled(!canTest || testState == .running)

                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 480, height: 440)
        .onAppear(perform: populate)
    }

    /// Test is allowed when host is set AND either a token was typed, or we're
    /// editing an existing profile with a saved token we can use.
    private var canTest: Bool {
        guard !host.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if !token.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        if case .edit(let p) = mode, Keychain.token(for: p.id) != nil { return true }
        return false
    }

    private func runTest() async {
        testState = .running

        // Resolve the token to test with: typed > stored (edit mode).
        var tokenToUse = token.trimmingCharacters(in: .whitespaces)
        if tokenToUse.isEmpty, case .edit(let p) = mode {
            tokenToUse = Keychain.token(for: p.id) ?? ""
        }

        let connection = XOConnection(
            host: host.trimmingCharacters(in: .whitespaces),
            token: tokenToUse,
            allowSelfSignedCert: allowSelfSigned
        )
        let client = XOClient(connection: connection)
        do {
            let result = try await client.testConnection()
            testState = .success("Connected — \(result.hosts) host\(result.hosts == 1 ? "" : "s"), \(result.vms) VM\(result.vms == 1 ? "" : "s")")
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            testState = .failure(msg)
        }
    }

    private func populate() {
        if case .edit(let profile) = mode {
            name = profile.name
            host = profile.host
            allowSelfSigned = profile.allowSelfSignedCert
            tokenPlaceholder = "••••••••  (unchanged)"
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedToken = token.trimmingCharacters(in: .whitespaces)

        switch mode {
        case .add:
            let profile = store.add(
                name: trimmedName,
                host: trimmedHost,
                token: trimmedToken,
                allowSelfSignedCert: allowSelfSigned
            )
            onSaved(profile)
        case .edit(var profile):
            profile.name = trimmedName
            profile.host = trimmedHost
            profile.allowSelfSignedCert = allowSelfSigned
            store.update(profile, newToken: trimmedToken.isEmpty ? nil : trimmedToken)
            onSaved(profile)
        }
        dismiss()
    }

    @ViewBuilder
    private func field<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }
}
