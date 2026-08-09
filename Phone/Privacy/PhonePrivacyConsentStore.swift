import Foundation

public enum PhonePrivacyConsentStoreError: Error, Equatable, Sendable {
    case encodingFailed
    case decodingFailed
    case invalidConsent(PhonePrivacyConsentError)
}

/// Persistence contract for the phone's one active off-device consent.
public protocol PhonePrivacyConsentStore: AnyObject, Sendable {
    func load() throws -> PhoneOffDeviceGazeConsent?
    func save(_ consent: PhoneOffDeviceGazeConsent) throws
    func revoke() throws
}

/// UserDefaults is an adapter for the MVP only.  A production build should
/// migrate this record to a device-only Keychain or another protected store.
public final class UserDefaultsPhonePrivacyConsentStore: PhonePrivacyConsentStore, @unchecked Sendable {
    public static let defaultKey = "com.aviary.eaglegaze.phone.privacyConsent.v1"

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = UserDefaultsPhonePrivacyConsentStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() throws -> PhoneOffDeviceGazeConsent? {
        guard let data = defaults.data(forKey: key) else { return nil }
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

    public func save(_ consent: PhoneOffDeviceGazeConsent) throws {
        do {
            try consent.validate()
            defaults.set(try JSONEncoder().encode(consent), forKey: key)
        } catch let error as PhonePrivacyConsentError {
            throw PhonePrivacyConsentStoreError.invalidConsent(error)
        } catch {
            throw PhonePrivacyConsentStoreError.encodingFailed
        }
    }

    public func revoke() throws {
        defaults.removeObject(forKey: key)
    }
}

/// Deterministic fake used by unit tests and dependency composition.
public final class InMemoryPhonePrivacyConsentStore: PhonePrivacyConsentStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: PhoneOffDeviceGazeConsent?

    public init(value: PhoneOffDeviceGazeConsent? = nil) {
        self.value = value
    }

    public func load() throws -> PhoneOffDeviceGazeConsent? {
        lock.withLock { value }
    }

    public func save(_ consent: PhoneOffDeviceGazeConsent) throws {
        try consent.validate()
        lock.withLock { value = consent }
    }

    public func revoke() throws {
        lock.withLock { value = nil }
    }
}

/// Coordinates persisted consent with the short-lived capability required by
/// the phone transport.  The app should pass the returned authorization to its
/// streaming composition and refuse to start without one.
public final class PhonePrivacyConsentCoordinator: @unchecked Sendable {
    private let store: PhonePrivacyConsentStore
    private let lock = NSLock()
    private var activeAuthorization: PhoneStreamingAuthorization?
    private var revocationHandler: (@Sendable () -> Void)?

    public init(store: PhonePrivacyConsentStore) {
        self.store = store
    }

    public func setRevocationHandler(_ handler: (@Sendable () -> Void)?) {
        lock.withLock { revocationHandler = handler }
    }

    /// Saves a newly displayed and accepted disclosure, then creates the
    /// capability that may be used to start local-network streaming.
    @discardableResult
    public func grant(_ consent: PhoneOffDeviceGazeConsent) throws -> PhoneStreamingAuthorization {
        do {
            try store.save(consent)
        } catch {
            // A failed persistence write cannot establish a durable consent;
            // invalidate any prior capability rather than keeping streaming
            // authorized against an unknown record.
            let handler = lock.withLock { () -> (@Sendable () -> Void)? in
                let hadAuthorization = activeAuthorization != nil
                activeAuthorization = nil
                return hadAuthorization ? revocationHandler : nil
            }
            handler?()
            throw error
        }
        let authorization = PhoneStreamingAuthorization(consent: consent)
        lock.withLock { activeAuthorization = authorization }
        return authorization
    }

    /// Rehydrates a persisted consent after app launch.  This does not bypass
    /// destination scoping: callers still have to request the matching Mac.
    @discardableResult
    public func authorizeStreaming(to destinationID: String) throws -> PhoneStreamingAuthorization? {
        let consent: PhoneOffDeviceGazeConsent?
        do {
            consent = try store.load()
        } catch {
            // Corrupt or unsupported persisted consent must fail closed rather
            // than leave a token from an earlier session active.
            lock.withLock { activeAuthorization = nil }
            throw error
        }
        guard let consent, consent.destinationID == destinationID else {
            lock.withLock { activeAuthorization = nil }
            return nil
        }
        let authorization = PhoneStreamingAuthorization(consent: consent)
        lock.withLock { activeAuthorization = authorization }
        return authorization
    }

    public var currentAuthorization: PhoneStreamingAuthorization? {
        lock.withLock { activeAuthorization }
    }

    /// Revocation removes durable consent, clears the active capability, and
    /// notifies composition so it can stop camera and network streaming.
    public func revoke() throws {
        // Fail closed if persistence is unavailable: even when the durable
        // delete reports an error, the in-memory capability must not survive a
        // user's revoke action.
        var persistenceError: Error?
        do {
            try store.revoke()
        } catch {
            persistenceError = error
        }
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            activeAuthorization = nil
            return revocationHandler
        }
        handler?()
        if let persistenceError { throw persistenceError }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
