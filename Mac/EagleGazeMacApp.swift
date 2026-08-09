import SwiftUI

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
        WindowGroup("EagleGaze") {
            MacContentView(
                application: application,
                voiceOSBridge: voiceOSBridge,
                overlayController: overlayController
            )
            .frame(minWidth: 900, minHeight: 640)
            .onAppear { overlayController.show(application: application) }
        }
        .defaultSize(width: 1180, height: 780)
    }
}
