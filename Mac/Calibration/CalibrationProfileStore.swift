import Foundation
import GazeCore

/// Storage boundary for calibration profiles.
///
/// The Mac application deliberately depends on this small synchronous
/// protocol rather than a persistence framework.  A durable implementation
/// (for example, Keychain or a database) is a separate reviewed decision;
/// `InMemoryCalibrationProfileStore` is intended for composition and tests.
public protocol CalibrationProfileStore {
    func profile(for key: CalibrationProfileKey) -> CalibrationProfile?
    func save(_ profile: CalibrationProfile)
    func removeProfile(for key: CalibrationProfileKey)
}

/// Process-local profile storage.  Profiles are not written to disk.
public final class InMemoryCalibrationProfileStore: CalibrationProfileStore {
    private var profiles: [CalibrationProfileKey: CalibrationProfile]

    public init(profiles: [CalibrationProfileKey: CalibrationProfile] = [:]) {
        self.profiles = profiles
    }

    public func profile(for key: CalibrationProfileKey) -> CalibrationProfile? {
        profiles[key]
    }

    public func save(_ profile: CalibrationProfile) {
        profiles[profile.key] = profile
    }

    public func removeProfile(for key: CalibrationProfileKey) {
        profiles.removeValue(forKey: key)
    }

    public var count: Int { profiles.count }
}
