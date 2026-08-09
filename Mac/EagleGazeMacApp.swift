import SwiftUI

@main
struct EagleGazeMacApp: App {
    @StateObject private var receiver = GazeReceiver()
    @StateObject private var session = MacGazeSession()
    @StateObject private var overlay = GazeOverlayController()

    var body: some Scene {
        WindowGroup("EagleGaze") {
            MacContentView(receiver: receiver, session: session)
                .frame(minWidth: 820, minHeight: 620)
                .onAppear {
                    overlay.show(session: session, receiver: receiver)
                }
        }
        .defaultSize(width: 1100, height: 760)
    }
}
