import Foundation
import XCTest
@testable import EagleGazeMac
@testable import EagleGazeMac

final class MacPrivacyDisclosureTests: XCTestCase {
    func testCoordinatorReportsUndisclosedThenAcknowledged() throws {
        let store = InMemoryMacPrivacyDisclosureStore()
        let coordinator = MacPrivacyDisclosureCoordinator(store: store)
        XCTAssertEqual(try coordinator.state(), .undisclosed)

        let date = Date(timeIntervalSinceReferenceDate: 20)
        let disclosure = try coordinator.acknowledge(at: date)
        XCTAssertEqual(disclosure.acknowledgedAt, date)
        XCTAssertEqual(try coordinator.state(), .acknowledged(disclosure))
        XCTAssertTrue((try coordinator.state()).isAcknowledged)

        try coordinator.clear()
        XCTAssertEqual(try coordinator.state(), .undisclosed)
    }

    func testUserDefaultsAdapterRoundTrips() throws {
        let suite = "MacPrivacyDisclosureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsMacPrivacyDisclosureStore(defaults: defaults)
        let disclosure = try MacPrivacyDisclosure(acknowledgedAt: Date(timeIntervalSinceReferenceDate: 30))

        try store.save(disclosure)
        XCTAssertEqual(try store.load(), disclosure)
        try store.clear()
        XCTAssertNil(try store.load())
    }
}
