//
//  ConnectionView.swift
//  XOInventory
//
//  The landing screen: shows saved host profiles and lets the user pick one
//  to connect, or add / edit / delete profiles.
//

import SwiftUI

struct ConnectionView: View {
    @ObservedObject var store: ProfileStore
    @ObservedObject var viewModel: InventoryViewModel
    var onConnected: (HostProfile) -> Void

    @State private var selection: HostProfile.ID?
    @State private var sheet: Sheet?
    @State private var profileToDelete: HostProfile?

    private enum Sheet: Identifiable {
        case add
        case edit(HostProfile)
        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let p): return "edit-\(p.id)"
            }
        }
    }

    private var selectedProfile: HostProfile? {
        guard let id = selection else { return nil }
        return store.profiles.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if store.profiles.isEmpty {
                emptyState
            } else {
                profileList
            }

            if let error = viewModel.errorMessage {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08))
            }

            Divider()
            footer
        }
        .frame(width: 560, height: 480)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .add:
                ProfileEditorView(mode: .add, store: store) { profile in
                    selection = profile.id
                }
            case .edit(let profile):
                ProfileEditorView(mode: .edit(profile), store: store) { updated in
                    selection = updated.id
                }
            }
        }
        .alert("Delete profile?",
               isPresented: Binding(
                get: { profileToDelete != nil },
                set: { if !$0 { profileToDelete = nil } }
               ),
               presenting: profileToDelete) { profile in
            Button("Delete", role: .destructive) {
                store.delete(profile)
                if selection == profile.id { selection = nil }
                profileToDelete = nil
            }
            Button("Cancel", role: .cancel) { profileToDelete = nil }
        } message: { profile in
            Text("\"\(profile.name)\" will be removed and its token deleted from the Keychain. This can't be undone.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 4) {
            Image(systemName: "server.rack")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tint)
            Text("XCP-NG Inventory")
                .font(.title2).bold()
            Text("Choose a host to connect to")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Profile list

    private var profileList: some View {
        List(selection: $selection) {
            ForEach(store.profiles) { profile in
                ProfileRow(profile: profile)
                    .tag(profile.id)
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            connect(profile)
                        }
                    )
                    .contextMenu {
                        Button("Connect") { connect(profile) }
                        Button("Edit…") { sheet = .edit(profile) }
                        Divider()
                        Button("Delete", role: .destructive) { profileToDelete = profile }
                    }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .onChange(of: selection) { newValue in
            // Clear any previous error when the user picks a different profile.
            if newValue != nil { viewModel.errorMessage = nil }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text("No saved hosts yet")
                .font(.headline)
            Text("Add your first XO host to get started.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                sheet = .add
            } label: {
                Label("Add Host", systemImage: "plus")
            }
            .controlSize(.large)
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                sheet = .add
            } label: {
                Label("Add", systemImage: "plus")
            }
            .help("Add a new host profile")

            Button {
                if let p = selectedProfile { sheet = .edit(p) }
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .disabled(selectedProfile == nil)

            Button(role: .destructive) {
                profileToDelete = selectedProfile
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(selectedProfile == nil)

            Spacer()

            if viewModel.isLoading {
                ProgressView().controlSize(.small)
            }

            Button {
                if let p = selectedProfile { connect(p) }
            } label: {
                Text("Connect")
                    .frame(minWidth: 70)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedProfile == nil || viewModel.isLoading)
        }
        .padding(12)
    }

    // MARK: - Actions

    private func connect(_ profile: HostProfile) {
        guard let conn = profile.connection() else {
            viewModel.errorMessage = "No token stored for this profile. Edit it to add one."
            return
        }
        Task {
            await viewModel.connect(using: conn)
            if viewModel.errorMessage == nil {
                store.touch(profile)
                onConnected(profile)
            }
        }
    }
}

// MARK: - Row

private struct ProfileRow: View {
    let profile: HostProfile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .foregroundStyle(.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.headline)
                Text(profile.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospaced()
            }
            Spacer()
            if let last = profile.lastUsed {
                Text(last.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}
