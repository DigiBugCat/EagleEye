import Foundation

#if canImport(Security)
import Security

/// Device-only Keychain adapter for the off-device gaze consent.  Consent is
/// a capability gate, so losing it on device migration is safer than silently
/// restoring permission on a different phone.
final class KeychainPhonePrivacyConsentStore: PhonePrivacyConsentStore, @unchecked Sendable {
    static let defaultService = "com.aviary.eaglegaze.phone.privacy-consent"

    private let service: String
    private let account: String
    private let accessGroup: String?

    init(
        service: String = KeychainPhonePrivacyConsentStore.defaultService,
        account: String = "active",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    func load() throws -> PhoneOffDeviceGazeConsent? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainPhonePrivacyConsentStoreError.status(status)
        }
        do {
            let consent = try JSONDecoder().decode(PhoneOffDeviceGazeConsent.self, from: data)
            try consent.validate()
            return consent
        } catch let error as PhonePrivacyConsentError {
            throw PhonePrivacyConsentStoreError.invalidConsent(error)
        } catch {
            throw PhonePrivacyConsentStoreError.decodingFailed
        }
    }

    func save(_ consent: PhoneOffDeviceGazeConsent) throws {
        do {
            try consent.validate()
            let data = try JSONEncoder().encode(consent)
            let updateStatus = SecItemUpdate(
                baseQuery() as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            if updateStatus == errSecSuccess { return }
            guard updateStatus == errSecItemNotFound else {
                throw KeychainPhonePrivacyConsentStoreError.status(updateStatus)
            }
            var add = baseQuery()
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainPhonePrivacyConsentStoreError.status(addStatus)
            }
        } catch let error as PhonePrivacyConsentError {
            throw PhonePrivacyConsentStoreError.invalidConsent(error)
        } catch let error as PhonePrivacyConsentStoreError {
            throw error
        } catch let error as KeychainPhonePrivacyConsentStoreError {
            throw error
        } catch {
            throw PhonePrivacyConsentStoreError.encodingFailed
        }
    }

    func revoke() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainPhonePrivacyConsentStoreError.status(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}

enum KeychainPhonePrivacyConsentStoreError: Error, Equatable, Sendable {
    case status(OSStatus)
}
#else

/// Host builds do not expose Security.framework; composition can still use
/// the deterministic in-memory store supplied by PhonePrivacyConsentStore.
typealias KeychainPhonePrivacyConsentStore = InMemoryPhonePrivacyConsentStore

#endif
