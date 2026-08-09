import Foundation
import Security

/// Stable, opaque identity for this Mac installation.  It is intentionally a
/// random UUID rather than a hardware serial or network address.
public struct MacReceiverIdentity: Codable, Equatable, Sendable {
    public let fingerprint: String

    public init(fingerprint: String) throws {
        let value = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, value.utf8.count <= 128 else {
            throw MacReceiverIdentityError.invalidFingerprint
        }
        self.fingerprint = value
    }

    public static func random() -> Self {
        // UUID randomness is sufficient for an opaque endpoint identifier;
        // no hardware-derived value leaves the Mac.
        try! Self(fingerprint: UUID().uuidString.lowercased())
    }
}

public enum MacReceiverIdentityError: Error, Equatable, Sendable {
    case invalidFingerprint
    case persistenceFailed
}

public protocol MacReceiverIdentityStore: Sendable {
    func loadOrCreate() throws -> MacReceiverIdentity
}

/// Keychain-backed identity with device-only accessibility.  The identity is
/// not a secret, but device-only storage prevents a backup/restore from
/// silently claiming the same Bonjour endpoint on another Mac.
public final class KeychainMacReceiverIdentityStore: MacReceiverIdentityStore, @unchecked Sendable {
    public static let defaultService = "com.aviary.EagleGaze.receiver-identity"
    private let service: String
    private let account: String
    private let lock = NSLock()

    public init(
        service: String = KeychainMacReceiverIdentityStore.defaultService,
        account: String = "receiver"
    ) {
        self.service = service
        self.account = account
    }

    public func loadOrCreate() throws -> MacReceiverIdentity {
        lock.lock()
        defer { lock.unlock() }

        var query = baseQuery
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            do { return try JSONDecoder().decode(MacReceiverIdentity.self, from: data) }
            catch { throw MacReceiverIdentityError.persistenceFailed }
        }
        guard status == errSecItemNotFound else { throw MacReceiverIdentityError.persistenceFailed }

        let identity = MacReceiverIdentity.random()
        let data: Data
        do { data = try JSONEncoder().encode(identity) }
        catch { throw MacReceiverIdentityError.persistenceFailed }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            // Another process won the first-write race; read its identity so
            // all callers converge on one stable value.
            var reread = baseQuery
            reread[kSecReturnData as String] = true
            var rereadResult: CFTypeRef?
            guard SecItemCopyMatching(reread as CFDictionary, &rereadResult) == errSecSuccess,
                  let rereadData = rereadResult as? Data else {
                throw MacReceiverIdentityError.persistenceFailed
            }
            do { return try JSONDecoder().decode(MacReceiverIdentity.self, from: rereadData) }
            catch { throw MacReceiverIdentityError.persistenceFailed }
        }
        guard addStatus == errSecSuccess else { throw MacReceiverIdentityError.persistenceFailed }
        return identity
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public final class InMemoryMacReceiverIdentityStore: MacReceiverIdentityStore, @unchecked Sendable {
    private let lock = NSLock()
    private var identity: MacReceiverIdentity?

    public init(identity: MacReceiverIdentity? = nil) {
        self.identity = identity
    }

    public func loadOrCreate() throws -> MacReceiverIdentity {
        lock.lock()
        defer { lock.unlock() }
        if let identity { return identity }
        let created = MacReceiverIdentity.random()
        identity = created
        return created
    }

    public func reset() {
        lock.lock()
        identity = nil
        lock.unlock()
    }
}

public typealias FakeMacReceiverIdentityStore = InMemoryMacReceiverIdentityStore
