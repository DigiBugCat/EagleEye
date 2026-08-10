import SwiftUI

enum EagleGazeSceneID {
    static let mainWindow = "main"
    static let statusWindow = "status"
}

@main
struct EagleGazeMacApp: App {
    @StateObject private var application: EagleGazeApplication
    @StateObject private var voiceOSBridge: VoiceOSBridge
    @StateObject private var overlayController = GazeOverlayController()

    init() {
        let application = EagleGazeApplication()
        _application = StateObject(wrappedValue: application)
        _voiceOSBridge = StateObject(wrappedValue: VoiceOSBridge(service: application))
    }

    var body: some Scene {
        WindowGroup("EagleEye", id: EagleGazeSceneID.mainWindow) {
            MacContentView(
                application: application,
                voiceOSBridge: voiceOSBridge,
                overlayController: overlayController
            )
            .frame(minWidth: 900, minHeight: 640)
            .onAppear { overlayController.show(application: application) }
        }
        .defaultSize(width: 1180, height: 780)

        Window("EagleEye Status", id: EagleGazeSceneID.statusWindow) {
            EagleGazeCompactStatusView(
                application: application,
                overlayController: overlayController
            )
        }
        .defaultSize(width: 320, height: 210)
        .windowResizability(.contentSize)

        MenuBarExtra {
            EagleGazeMenuBarView(
                application: application,
                overlayController: overlayController
            )
        } label: {
            let status = EagleGazeMenuBarStatus.resolve(
                hasSource: application.activeSource != nil,
                isFresh: application.isFresh,
                phase: application.snapshot.phase,
                hasProfile: application.snapshot.profile != nil
            )
            Image(systemName: status.symbolName)
                .accessibilityLabel("EagleEye: \(status.title)")
        }
        .menuBarExtraStyle(.window)
    }
}
