import Foundation
import XCTest
@testable import EagleGazePhone
@testable import EagleGazePhone

final class PhonePrivacyConsentTests: XCTestCase {
    func testGrantCreatesAuthorizationAndRevokeClearsItAndNotifies() throws {
        let store = InMemoryPhonePrivacyConsentStore()
        let coordinator = PhonePrivacyConsentCoordinator(store: store)
        let revoked = expectation(description: "revocation callback")
        coordinator.setRevocationHandler { revoked.fulfill() }

        let consent = try PhoneOffDeviceGazeConsent(
            consentID: UUID(),
            destinationID: "paired-mac-1",
            grantedAt: Date(timeIntervalSinceReferenceDate: 10)
        )
        let authorization = try coordinator.grant(consent)
        XCTAssertEqual(authorization.consentID, consent.consentID)
        XCTAssertEqual(coordinator.currentAuthorization, authorization)
        XCTAssertEqual(try store.load(), consent)

        try coordinator.revoke()
        XCTAssertNil(coordinator.currentAuthorization)
        XCTAssertNil(try store.load())
        wait(for: [revoked], timeout: 1)
    }

    func testAuthorizationIsScopedToDestination() throws {
        let store = InMemoryPhonePrivacyConsentStore()
        let coordinator = PhonePrivacyConsentCoordinator(store: store)
        let consent = try PhoneOffDeviceGazeConsent(destinationID: "paired-mac-1")
        _ = try coordinator.grant(consent)

        XCTAssertNotNil(try coordinator.authorizeStreaming(to: "paired-mac-1"))
        XCTAssertNil(try coordinator.authorizeStreaming(to: "paired-mac-2"))
        XCTAssertNil(coordinator.currentAuthorization)
    }

    func testUserDefaultsAdapterRoundTripsAndRevokes() throws {
        let suite = "PhonePrivacyConsentTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsPhonePrivacyConsentStore(defaults: defaults)
        let consent = try PhoneOffDeviceGazeConsent(destinationID: "paired-mac-1")

        try store.save(consent)
        XCTAssertEqual(try store.load(), consent)
        try store.revoke()
        XCTAssertNil(try store.load())
    }

    func testUnsupportedVersionCannotBeConstructed() {
        XCTAssertThrowsError(try PhoneOffDeviceGazeConsent(version: 99, destinationID: "paired-mac-1")) { error in
            XCTAssertEqual(
                error as? PhonePrivacyConsentError,
                .unsupportedVersion(received: 99, supported: PhoneOffDeviceGazeConsent.currentVersion)
            )
        }
    }
}
