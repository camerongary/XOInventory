//
//  Keychain.swift
//  XOInventory
//
//  Thin wrapper around Security framework for storing per-profile tokens.
//  Tokens are stored as generic passwords keyed by a profile UUID so they
//  survive restart and aren't readable from the app bundle.
//

import Foundation
import Security

enum Keychain {
    /// All items are namespaced under this service so they don't collide
    /// with anything else running on the user's Mac.
    private static let service = "com.camerongary.XOInventory.token"

    @discardableResult
    static func setToken(_ token: String, for profileID: UUID) -> Bool {
        let account = profileID.uuidString
        guard let data = token.data(using: .utf8) else { return false }

        // Delete any existing item for this account first; simplest atomic write.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func token(for profileID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    @discardableResult
    static func deleteToken(for profileID: UUID) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
