import Foundation
import GazeCore

/// Transport boundary used by the app composition. A mock can implement this
/// protocol in lifecycle tests without importing Network or ARKit.
@MainActor
protocol PhoneGazeTransport: AnyObject {
    func start()
    func stop()
    func sendLatest(_ frame: CanonicalGazeFrame)
}

extension GazeSender: PhoneGazeTransport {}

/// Owns foreground/background resource transitions for the phone stream.
/// UIKit's transient `.inactive` phase is deliberately not represented here;
/// callers simply do not invoke `stop()` for it.
@MainActor
final class PhoneLifecycleCoordinator {
    let tracker: any FaceTrackingSource
    let sender: any PhoneGazeTransport
    let pipeline: PhoneGazePipeline

    private let idleTimer: PhoneIdleTimerControlling
    private(set) var isRunning = false
    private(set) var streamSessionID: UUID?
    /// Set when the presentation temporarily owns the camera (for example a
    /// another temporary interruption). The coordinator intentionally does not resume by
    /// itself: the app must obtain fresh authenticated session material first.
    private(set) var wantsResumeAfterPresentation = false

    init(
        tracker: any FaceTrackingSource,
        sender: any PhoneGazeTransport,
        pipeline: PhoneGazePipeline,
        idleTimer: PhoneIdleTimerControlling
    ) {
        self.tracker = tracker
        self.sender = sender
        self.pipeline = pipeline
        self.idleTimer = idleTimer
    }

    func start(sessionID: UUID = UUID()) {
        if isRunning {
            guard streamSessionID != sessionID else { return }
            // A fresh authenticated session owns a fresh camera/pipeline
            // generation. Never leave ARKit producing frames for an obsolete
            // encryption session.
            pipeline.stop()
            tracker.stop()
            isRunning = false
            streamSessionID = nil
        }
        sender.start()
        let trackingGeneration = tracker.start()
        _ = pipeline.start(sessionID: sessionID, generation: trackingGeneration)
        streamSessionID = sessionID
        isRunning = true
        idleTimer.setIdleTimerDisabled(true)
        wantsResumeAfterPresentation = false
    }

    /// Stops frame production while a replacement authenticated session is
    /// negotiated, without tearing down receiver discovery. This collapses
    /// camera and transport rollover into one atomic transition.
    func prepareForSessionReplacement() {
        guard isRunning else { return }
        pipeline.stop()
        tracker.stop()
        isRunning = false
        streamSessionID = nil
        idleTimer.setIdleTimerDisabled(false)
    }

    func stop() {
        guard isRunning else {
            idleTimer.setIdleTimerDisabled(false)
            return
        }
        isRunning = false
        pipeline.stop()
        tracker.stop()
        sender.stop()
        idleTimer.setIdleTimerDisabled(false)
        streamSessionID = nil
        wantsResumeAfterPresentation = false
    }

    /// Pauses all camera and stream resources while a presentation flow owns
    /// the camera.  This is deliberately equivalent to a background stop for
    /// the ARSession generation, but remembers that a foreground stream was
    /// requested so the app can re-authenticate before resuming.
    func pauseForPresentation() {
        guard isRunning else {
            wantsResumeAfterPresentation = false
            return
        }
        wantsResumeAfterPresentation = true
        isRunning = false
        pipeline.stop()
        tracker.stop()
        sender.stop()
        idleTimer.setIdleTimerDisabled(false)
        streamSessionID = nil
    }

    /// Cancels any pending presentation resume request without starting the
    /// stream.  The app calls this when a pairing flow is dismissed.
    func cancelPresentationResume() {
        wantsResumeAfterPresentation = false
    }
}
