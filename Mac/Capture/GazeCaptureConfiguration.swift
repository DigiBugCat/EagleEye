import Foundation
import Security

struct GazeCaptureOptions: Sendable {
    let smartCropEnabled: Bool
    let cerebrasAPIKey: String?

    var cerebrasEnrichmentEnabled: Bool { cerebrasAPIKey?.isEmpty == false }
}

enum CerebrasCredentialStoreError: LocalizedError {
    case encodingFailed
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            "The Cerebras API key could not be encoded."
        case let .keychain(status):
            "The Cerebras API key could not be stored in Keychain (status \(status))."
        }
    }
}

/// Stores only the optional provider credential. Feature switches remain
/// ordinary local preferences; screenshot and gaze data are never persisted.
final class CerebrasCredentialStore: @unchecked Sendable {
    static let defaultService = "com.aviary.EagleGaze.cerebras"
    private let service: String
    private let account = "api-key"
    private let lock = NSLock()

    init(service: String = CerebrasCredentialStore.defaultService) {
        self.service = service
    }

    func load() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8)
        else { throw CerebrasCredentialStoreError.keychain(status) }
        return key
    }

    func save(_ rawKey: String) throws {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = key.data(using: .utf8) else {
            throw CerebrasCredentialStoreError.encodingFailed
        }
        if key.isEmpty {
            try delete()
            return
        }
        lock.lock()
        defer { lock.unlock() }
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        var status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(
                baseQuery as CFDictionary,
                [
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                ] as CFDictionary
            )
        }
        guard status == errSecSuccess else { throw CerebrasCredentialStoreError.keychain(status) }
    }

    func delete() throws {
        lock.lock()
        defer { lock.unlock() }
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CerebrasCredentialStoreError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
