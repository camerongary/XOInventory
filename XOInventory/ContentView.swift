//
//  ContentView.swift
//  XOInventory
//

import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = InventoryViewModel()
    @StateObject private var store = ProfileStore()
    @State private var activeProfile: HostProfile?
    @State private var showTokenHelp = false

    var body: some View {
        Group {
            if let profile = activeProfile {
                InventoryView(
                    viewModel: viewModel,
                    hostDisplay: "\(profile.name) — \(profile.host)",
                    onDisconnect: {
                        viewModel.disconnect()
                        activeProfile = nil
                    }
                )
            } else {
                ConnectionView(
                    store: store,
                    viewModel: viewModel,
                    onConnected: { profile in
                        activeProfile = profile
                    }
                )
            }
        }
        .sheet(isPresented: $showTokenHelp) {
            TokenHelpView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showTokenHelp)) { _ in
            showTokenHelp = true
        }
        .onChange(of: activeProfile) { profile in
            MenuState.shared.isConnected = profile != nil
        }
        .onReceive(viewModel.$vms) { vms in
            MenuState.shared.hasVMs = !vms.isEmpty
        }
    }
}

// MARK: - Token help sheet

struct TokenHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Getting an Authentication Token")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("XO requires an authentication token to use the REST API. Tokens are tied to a user account and must belong to a user with **admin** rights.")
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 10) {
                        Label("From the XO Web UI", systemImage: "globe")
                            .font(.subheadline).fontWeight(.semibold)
                        VStack(alignment: .leading, spacing: 6) {
                            stepRow(number: "1", text: "Sign in to your Xen Orchestra instance.")
                            stepRow(number: "2", text: "Open the user menu (top-right corner) and choose **Authentication tokens**.")
                            stepRow(number: "3", text: "Click **New token**, give it a name, and copy the value shown — it won't be displayed again.")
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Label("From the CLI (xo-cli)", systemImage: "terminal")
                            .font(.subheadline).fontWeight(.semibold)

                        Text("If you have `xo-cli` installed:")
                            .foregroundStyle(.secondary)

                        Text("xo-cli create-token xo.your.lan admin@your.tld")
                            .font(.system(.body, design: .monospaced))
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .windowBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .textSelection(.enabled)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Label("Token storage", systemImage: "lock")
                            .font(.subheadline).fontWeight(.semibold)
                        Text("Tokens are stored in the **macOS Keychain** — never written to disk in plain text. Each saved host profile keeps its token under a separate Keychain entry. Deleting a profile also removes its token.")
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
        }
        .frame(width: 480, height: 420)
    }

    @ViewBuilder
    private func stepRow(number: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.caption).fontWeight(.semibold)
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Color.accentColor)
                .clipShape(Circle())
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    ContentView()
}
