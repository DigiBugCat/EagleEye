import Foundation

public enum MacPrivacyDisclosureStoreError: Error, Equatable, Sendable {
    case encodingFailed
    case decodingFailed
    case invalidDisclosure(MacPrivacyDisclosureError)
}

public protocol MacPrivacyDisclosureStore: AnyObject, Sendable {
    func load() throws -> MacPrivacyDisclosure?
    func save(_ disclosure: MacPrivacyDisclosure) throws
    func clear() throws
}

public final class UserDefaultsMacPrivacyDisclosureStore: MacPrivacyDisclosureStore, @unchecked Sendable {
    public static let defaultKey = "com.aviary.eaglegaze.mac.privacyDisclosure.v1"

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = UserDefaultsMacPrivacyDisclosureStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() throws -> MacPrivacyDisclosure? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            let disclosure = try JSONDecoder().decode(MacPrivacyDisclosure.self, from: data)
            try disclosure.validate()
            return disclosure
        } catch let error as MacPrivacyDisclosureError {
            throw MacPrivacyDisclosureStoreError.invalidDisclosure(error)
        } catch {
            throw MacPrivacyDisclosureStoreError.decodingFailed
        }
    }

    public func save(_ disclosure: MacPrivacyDisclosure) throws {
        do {
            try disclosure.validate()
            defaults.set(try JSONEncoder().encode(disclosure), forKey: key)
        } catch let error as MacPrivacyDisclosureError {
            throw MacPrivacyDisclosureStoreError.invalidDisclosure(error)
        } catch {
            throw MacPrivacyDisclosureStoreError.encodingFailed
        }
    }

    public func clear() throws {
        defaults.removeObject(forKey: key)
    }
}

public final class InMemoryMacPrivacyDisclosureStore: MacPrivacyDisclosureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: MacPrivacyDisclosure?

    public init(value: MacPrivacyDisclosure? = nil) {
        self.value = value
    }

    public func load() throws -> MacPrivacyDisclosure? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func save(_ disclosure: MacPrivacyDisclosure) throws {
        try disclosure.validate()
        lock.lock()
        value = disclosure
        lock.unlock()
    }

    public func clear() throws {
        lock.lock()
        value = nil
        lock.unlock()
    }
}

/// Small state adapter for Mac composition.  Continuous gaze remains outside
/// this object; it only answers whether the coarse disclosure was acknowledged.
public final class MacPrivacyDisclosureCoordinator: @unchecked Sendable {
    private let store: MacPrivacyDisclosureStore

    public init(store: MacPrivacyDisclosureStore) {
        self.store = store
    }

    public func state() throws -> MacPrivacyDisclosureState {
        guard let disclosure = try store.load() else { return .undisclosed }
        return .acknowledged(disclosure)
    }

    @discardableResult
    public func acknowledge(at date: Date = Date()) throws -> MacPrivacyDisclosure {
        let disclosure = try MacPrivacyDisclosure(acknowledgedAt: date)
        try store.save(disclosure)
        return disclosure
    }

    public func clear() throws {
        try store.clear()
    }
}
