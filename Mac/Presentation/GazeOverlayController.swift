import AppKit
import SwiftUI
import GazeCore

/// Owns a click-through overlay panel for the selected display.  The panel is
/// deliberately presentation-only: app state supplies an already mapped,
/// freshness-gated point and no raw source data enters this layer.
@MainActor
final class GazeOverlayController: ObservableObject {
    private var panel: NSPanel?

    func show(application: EagleGazeApplication) {
        update(application: application)
    }

    func update(application: EagleGazeApplication) {
        guard let display = application.selectedDisplay else {
            hide()
            return
        }
        if panel == nil {
            let panel = NSPanel(
                contentRect: display.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.hidesOnDeactivate = false
            self.panel = panel
        }
        panel?.setFrame(display.frame, display: true)
        panel?.contentView = NSHostingView(rootView: GazeDisplayOverlay(application: application))
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct GazeDisplayOverlay: View {
    @ObservedObject var application: EagleGazeApplication

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.clear
                if let target = application.snapshot.target,
                   application.snapshot.phase == .calibrating || application.snapshot.phase == .evaluating {
                    targetView
                        .position(position(target, in: geometry.size))
                }
                if application.showsGazeOverlay,
                   application.isFresh,
                   let point = application.mappedPoint,
                   application.snapshot.phase != .calibrating {
                    gazeDot
                        .position(position(clamped(point), in: geometry.size))
                        .animation(.linear(duration: 0.04), value: point)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var targetView: some View {
        ZStack {
            Circle().fill(.teal).frame(width: 42, height: 42)
            Circle().stroke(.white, lineWidth: 3).frame(width: 42, height: 42)
            Circle().fill(.white).frame(width: 7, height: 7)
        }
        .shadow(color: .black.opacity(0.5), radius: 5)
    }

    private var gazeDot: some View {
        Circle()
            .fill(.pink.opacity(0.82))
            .frame(width: 18, height: 18)
            .overlay(Circle().stroke(.white.opacity(0.95), lineWidth: 2))
            .shadow(color: .black.opacity(0.45), radius: 4)
    }

    private func position(_ point: Point2D, in size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }

    private func clamped(_ point: Point2D) -> Point2D {
        Point2D(x: min(max(point.x, 0.01), 0.99), y: min(max(point.y, 0.01), 0.99))
    }
}
