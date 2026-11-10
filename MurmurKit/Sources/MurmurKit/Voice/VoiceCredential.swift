import Foundation
import Security

/// User-owned native credentials; never embedded in releases or stored in preferences.
public enum VoiceCredential {
    #if os(macOS)
    private static let interactionLock = NSLock()
    #endif
    static func nonInteractive<T>(fallback: T, _ action: () -> T) -> T {
        #if os(macOS)
        guard interactionLock.try() else { return fallback }
        defer { interactionLock.unlock() }
        var previous = DarwinBoolean(true)
        let available = SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess
        if available { SecKeychainSetUserInteractionAllowed(false) }
        defer { if available { SecKeychainSetUserInteractionAllowed(previous.boolValue) } }
        #endif
        return action()
    }
    static func userInitiated<T>(_ action: () throws -> T) rethrows -> T {
        #if os(macOS)
        interactionLock.lock()
        defer { interactionLock.unlock() }
        var previous = DarwinBoolean(true)
        let available = SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess
        if available { SecKeychainSetUserInteractionAllowed(true) }
        defer { if available { SecKeychainSetUserInteractionAllowed(previous.boolValue) } }
        #endif
        return try action()
    }
    public static func readAsync() async -> String? {
        await Task.detached(priority: .userInitiated) { read() }.value
    }
    public static func saveAsync(_ value: String) async throws {
        try await Task.detached(priority: .userInitiated) { try save(value) }.value
    }
    public static func deleteAsync() async throws {
        try await Task.detached(priority: .userInitiated) { try delete() }.value
    }
    private static let service = "com.murmur.speech"
    private static let account = "native-voice-key"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    /// Settings/status refresh must not unlock or read the saved secret.
    public static var isStored: Bool {
        var lookup = query
        lookup[kSecReturnAttributes as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        lookup[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        let status = nonInteractive(fallback: errSecInteractionNotAllowed) { SecItemCopyMatching(lookup as CFDictionary, nil) }
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }
    public static func read(interactive: Bool = true) -> String? {
        var query = query
        if !interactive { query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = interactive ? userInitiated { SecItemCopyMatching(query as CFDictionary, &result) } : nonInteractive(fallback: errSecInteractionNotAllowed) { SecItemCopyMatching(query as CFDictionary, &result) }
        guard status == errSecSuccess,
              let data = result as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }
    public static func save(_ value: String) throws { try userInitiated { try saveValue(value) } }
    private static func saveValue(_ value: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { try deleteValue(); return }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw CredentialError(status: added) }
        } else if status != errSecSuccess { throw CredentialError(status: status) }
    }
    public static func delete() throws { try userInitiated { try deleteValue() } }
    private static func deleteValue() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError(status: status) }
    }
    private struct CredentialError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "The speech credential could not be saved to Keychain (\(status))." }
    }
}
