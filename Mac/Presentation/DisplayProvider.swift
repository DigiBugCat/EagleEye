import AppKit
import Combine
import Foundation
import GazeCore

struct DisplayDescriptor: Identifiable, Equatable {
    let id: String
    let name: String
    let frame: CGRect
    let isMain: Bool
    let physicalSize: PhysicalSize2D?

    init(
        id: String,
        name: String,
        frame: CGRect,
        isMain: Bool,
        physicalSize: PhysicalSize2D? = nil
    ) {
        self.id = id
        self.name = name
        self.frame = frame
        self.isMain = isMain
        self.physicalSize = physicalSize
    }
}

/// Supplies the display topology used by calibration and overlay rendering.
/// Display identity is part of the calibration profile key; a display change
/// therefore invalidates the visible dot until the matching profile is used.
@MainActor
final class DisplayProvider: ObservableObject {
    @Published private(set) var displays: [DisplayDescriptor] = []
    @Published private(set) var selectedDisplayID: String

    // NotificationCenter's opaque token is Objective-C and non-Sendable;
    // this narrowly scoped storage is only touched during MainActor setup and
    // teardown, where it is removed before the provider becomes unreachable.
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    init() {
        let descriptors = Self.readDisplays()
        displays = descriptors
        selectedDisplayID = descriptors.first(where: \.isMain)?.id ?? descriptors.first?.id ?? "main"
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func display(id: String) -> DisplayDescriptor? { displays.first { $0.id == id } }

    func select(id: String) {
        guard displays.contains(where: { $0.id == id }) else { return }
        selectedDisplayID = id
    }

    func refresh() {
        let next = Self.readDisplays()
        displays = next
        if !next.contains(where: { $0.id == selectedDisplayID }) {
            selectedDisplayID = next.first(where: \.isMain)?.id ?? next.first?.id ?? "main"
        }
    }

    private static func readDisplays() -> [DisplayDescriptor] {
        NSScreen.screens.enumerated().map { index, screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            let id = number.map { "display-\($0.uint32Value)" } ?? "display-\(index)"
            let millimeters = number.map { CGDisplayScreenSize($0.uint32Value) }
            let physicalSize = millimeters.flatMap { size -> PhysicalSize2D? in
                let value = PhysicalSize2D(
                    widthMeters: size.width / 1_000,
                    heightMeters: size.height / 1_000
                )
                return value.isValid ? value : nil
            }
            return DisplayDescriptor(
                id: id,
                name: screen.localizedName.isEmpty ? "Display \(index + 1)" : screen.localizedName,
                frame: screen.frame,
                isMain: screen == NSScreen.main,
                physicalSize: physicalSize
            )
        }
    }
}
