//
//  HostProfile.swift
//  XOInventory
//
//  Saved XO host profile + store. Profile metadata is persisted in
//  UserDefaults; the token for each profile lives in the Keychain.
//

import Foundation
import SwiftUI

struct HostProfile: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String              // friendly label, e.g. "Homelab"
    var host: String              // hostname or IP, possibly with port/scheme
    var allowSelfSignedCert: Bool = true
    var lastUsed: Date?

    /// Build an XOConnection for this profile, pulling the token from Keychain.
    func connection() -> XOConnection? {
        guard let token = Keychain.token(for: id), !token.isEmpty else { return nil }
        return XOConnection(host: host, token: token, allowSelfSignedCert: allowSelfSignedCert)
    }
}

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [HostProfile] = []

    private let defaultsKey = "XOInventory.profiles.v1"

    init() {
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return }
        if let decoded = try? JSONDecoder().decode([HostProfile].self, from: data) {
            self.profiles = decoded.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    // MARK: - Mutations

    /// Add a new profile and write its token to the Keychain.
    func add(name: String, host: String, token: String, allowSelfSignedCert: Bool) -> HostProfile {
        var profile = HostProfile(
            name: name,
            host: host,
            allowSelfSignedCert: allowSelfSignedCert,
            lastUsed: nil
        )
        profile.id = UUID()
        Keychain.setToken(token, for: profile.id)
        profiles.insert(profile, at: 0)
        save()
        return profile
    }

    /// Update metadata for an existing profile. If `newToken` is non-nil, replaces the stored token.
    func update(_ profile: HostProfile, newToken: String? = nil) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[idx] = profile
        if let newToken, !newToken.isEmpty {
            Keychain.setToken(newToken, for: profile.id)
        }
        save()
    }

    func delete(_ profile: HostProfile) {
        Keychain.deleteToken(for: profile.id)
        profiles.removeAll { $0.id == profile.id }
        save()
    }

    /// Mark a profile as most-recently-used and bubble it to the top.
    func touch(_ profile: HostProfile) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[idx].lastUsed = Date()
        profiles.sort { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
        save()
    }
}
