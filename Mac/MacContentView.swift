import GazeCore
import AppKit
import SwiftUI

@MainActor
final class MacGazeSession: ObservableObject {
    enum Phase: Equatable {
        case setup
        case calibrating
        case calibrated
        case evaluating
        case complete
        case calibrationFailed(String)

        var title: String {
            switch self {
            case .setup: return "Ready to calibrate"
            case .calibrating: return "Calibrating"
            case .calibrated: return "Calibration complete"
            case .evaluating: return "Evaluating"
            case .complete: return "Evaluation complete"
            case .calibrationFailed: return "Calibration failed"
            }
        }
    }

    static let gridPoints: [Point2D] = [0.16, 0.50, 0.84].flatMap { y in
        [0.16, 0.50, 0.84].map { x in Point2D(x: x, y: y) }
    }

    @Published private(set) var phase: Phase = .setup
    @Published private(set) var target: Point2D?
    @Published private(set) var mappedGaze: Point2D?
    @Published private(set) var calibrationStep = 0
    @Published private(set) var calibrationSampleCount = 0
    @Published private(set) var evaluationTrial = 0
    @Published private(set) var evaluationTrialCount = 18
    @Published private(set) var evaluationHits = 0
    @Published var showsGazeOverlay = true

    private let settleDuration: TimeInterval = 0.65
    private let collectDuration: TimeInterval = 0.75
    private let minimumSamplesPerTarget = 12
    private var targetStartedAt = Date()
    private var targetSamples: [Point2D] = []
    private var observations: [AffineObservation] = []
    private var calibration: AffineTransform2D?
    private var smoother = try! ExponentialMovingAverage2D(alpha: 0.24)
    private var evaluationOrder: [Point2D] = []
    private var lastConsumedKey: (UUID, UInt64)?

    var accuracy: Double {
        guard evaluationTrial > 0 else { return 0 }
        return Double(evaluationHits) / Double(evaluationTrial)
    }

    var progressText: String {
        switch phase {
        case .calibrating:
            return "Point \(min(calibrationStep + 1, Self.gridPoints.count)) of \(Self.gridPoints.count)"
        case .calibrated:
            return "9 points fitted"
        case .evaluating, .complete:
            return "\(evaluationHits) / \(evaluationTrial) hits (\(accuracy.formatted(.percent.precision(.fractionLength(0)))))"
        default:
            return "No calibration"
        }
    }

    func beginCalibration() {
        phase = .calibrating
        calibration = nil
        observations.removeAll(keepingCapacity: true)
        calibrationStep = 0
        calibrationSampleCount = 0
        evaluationTrial = 0
        evaluationHits = 0
        mappedGaze = nil
        smoother.reset()
        beginTarget(Self.gridPoints[0])
    }

    func beginEvaluation() {
        guard calibration != nil else { return }
        evaluationOrder = Self.gridPoints.shuffled() + Self.gridPoints.shuffled()
        // Each cell appears exactly twice. Avoid a repeated target where the
        // two independently shuffled passes meet.
        if evaluationOrder[8] == evaluationOrder[9],
           let swapIndex = (10..<evaluationOrder.count).first(where: { evaluationOrder[$0] != evaluationOrder[8] }) {
            evaluationOrder.swapAt(9, swapIndex)
        }
        evaluationTrial = 0
        evaluationHits = 0
        phase = .evaluating
        beginTarget(evaluationOrder[0])
    }

    func reset() {
        phase = .setup
        target = nil
        mappedGaze = nil
        calibration = nil
        observations.removeAll()
        targetSamples.removeAll()
        calibrationStep = 0
        calibrationSampleCount = 0
        evaluationTrial = 0
        evaluationHits = 0
        lastConsumedKey = nil
        smoother.reset()
    }

    func consume(_ sample: GazeSample) {
        let key = (sample.sessionID, sample.sequence)
        guard lastConsumedKey?.0 != key.0 || lastConsumedKey?.1 != key.1 else { return }
        lastConsumedKey = key

        guard sample.isTracked,
              sample.leftBlink < 0.75,
              sample.rightBlink < 0.75,
              sample.lookAt.x.isFinite,
              sample.lookAt.y.isFinite
        else { return }

        guard let raw = gazeDirectionFeature(from: sample) else { return }
        if let calibration {
            mappedGaze = smoother.update(with: calibration.apply(to: raw))
        }

        switch phase {
        case .calibrating:
            collect(raw, then: finishCalibrationTarget)
        case .evaluating:
            guard let calibration else { return }
            collect(calibration.apply(to: raw), then: finishEvaluationTrial)
        default:
            break
        }
    }

    private func beginTarget(_ point: Point2D) {
        target = point
        targetSamples.removeAll(keepingCapacity: true)
        calibrationSampleCount = 0
        targetStartedAt = Date()
    }

    private func collect(_ point: Point2D, then finish: () -> Void) {
        let elapsed = Date().timeIntervalSince(targetStartedAt)
        guard elapsed >= settleDuration else { return }

        if elapsed < settleDuration + collectDuration || targetSamples.count < minimumSamplesPerTarget {
            targetSamples.append(point)
            calibrationSampleCount = targetSamples.count
            return
        }
        finish()
    }

    private func finishCalibrationTarget() {
        guard let target, let representative = median(of: targetSamples) else { return }
        observations.append(AffineObservation(input: representative, output: target))
        calibrationStep += 1

        if calibrationStep < Self.gridPoints.count {
            beginTarget(Self.gridPoints[calibrationStep])
            return
        }

        do {
            calibration = try AffineCalibration.fit(observations: observations)
            smoother.reset()
            self.target = nil
            phase = .calibrated
        } catch {
            self.target = nil
            phase = .calibrationFailed(error.localizedDescription)
        }
    }

    private func finishEvaluationTrial() {
        guard let target, let representative = median(of: targetSamples) else { return }
        if gridCell(for: representative) == gridCell(for: target) {
            evaluationHits += 1
        }
        evaluationTrial += 1

        if evaluationTrial < evaluationTrialCount {
            beginTarget(evaluationOrder[evaluationTrial])
        } else {
            self.target = nil
            phase = .complete
        }
    }

    private func median(of points: [Point2D]) -> Point2D? {
        guard !points.isEmpty else { return nil }
        let xs = points.map(\.x).sorted()
        let ys = points.map(\.y).sorted()
        let middle = points.count / 2
        if points.count.isMultiple(of: 2) {
            return Point2D(
                x: (xs[middle - 1] + xs[middle]) / 2,
                y: (ys[middle - 1] + ys[middle]) / 2
            )
        }
        return Point2D(x: xs[middle], y: ys[middle])
    }

    private func gridCell(for point: Point2D) -> Int {
        let column = point.x < 1.0 / 3.0 ? 0 : (point.x < 2.0 / 3.0 ? 1 : 2)
        let row = point.y < 1.0 / 3.0 ? 0 : (point.y < 2.0 / 3.0 ? 1 : 2)
        return row * 3 + column
    }

    /// Convert ARKit's face-local fixation point into a gaze direction in the
    /// phone's stable session coordinates. This retains head rotation instead
    /// of treating eye motion relative to the face as the whole signal.
    private func gazeDirectionFeature(from sample: GazeSample) -> Point2D? {
        let left = sample.leftEyeTransform.elements
        let right = sample.rightEyeTransform.elements
        let eyeInFace = Vector3(
            x: (left[12] + right[12]) / 2,
            y: (left[13] + right[13]) / 2,
            z: (left[14] + right[14]) / 2
        )

        let eyeInSession = transform(point: eyeInFace, by: sample.faceTransform)
        let targetInSession = transform(point: sample.lookAt, by: sample.faceTransform)
        let dx = targetInSession.x - eyeInSession.x
        let dy = targetInSession.y - eyeInSession.y
        let dz = targetInSession.z - eyeInSession.z

        guard dx.isFinite, dy.isFinite, dz.isFinite, abs(dz) > 1e-6 else { return nil }
        return Point2D(x: dx / dz, y: dy / dz)
    }

    private func transform(point: Vector3, by matrix: Matrix4x4) -> Vector3 {
        let m = matrix.elements
        return Vector3(
            x: m[0] * point.x + m[4] * point.y + m[8] * point.z + m[12],
            y: m[1] * point.x + m[5] * point.y + m[9] * point.z + m[13],
            z: m[2] * point.x + m[6] * point.y + m[10] * point.z + m[14]
        )
    }
}

struct MacContentView: View {
    @ObservedObject var receiver: GazeReceiver
    @ObservedObject var session: MacGazeSession

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            gazeCanvas
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: receiver.latestSample) { _, sample in
            if let sample { session.consume(sample) }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("EagleGaze")
                    .font(.largeTitle.bold())
                Text("iPhone ARKit feasibility test")
                    .foregroundStyle(.secondary)
            }

            GroupBox("Connection") {
                VStack(alignment: .leading, spacing: 8) {
                    Label(receiver.state.label, systemImage: receiver.state.isReady ? "antenna.radiowaves.left.and.right" : "hourglass")
                    Label(
                        receiver.isFresh ? "Live gaze packets" : "No recent gaze packet",
                        systemImage: receiver.isFresh ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(receiver.isFresh ? .green : .orange)
                    Text("Accepted \(receiver.acceptedPacketCount)  •  Rejected \(receiver.rejectedPacketCount + receiver.decodeErrorCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Session") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(session.phase.title).font(.headline)
                    Text(session.progressText)
                        .font(.body.monospacedDigit())
                    if case .calibrationFailed(let detail) = session.phase {
                        Text(detail).font(.caption).foregroundStyle(.red)
                    }
                    if session.phase == .complete {
                        Text(session.accuracy >= 0.9 ? "Passed the 90% MVP gate" : "Below the 90% MVP gate")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(session.accuracy >= 0.9 ? .green : .orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Toggle("Show gaze dot over Mac apps", isOn: $session.showsGazeOverlay)
                .disabled(session.mappedGaze == nil)

            rawSample

            Spacer()

            VStack(spacing: 10) {
                switch session.phase {
                case .setup, .calibrationFailed:
                    Button("Start 3×3 calibration") { session.beginCalibration() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!receiver.isFresh)
                case .calibrated:
                    Button("Start randomized evaluation") { session.beginEvaluation() }
                        .buttonStyle(.borderedProminent)
                case .complete:
                    Button("Run evaluation again") { session.beginEvaluation() }
                        .buttonStyle(.borderedProminent)
                case .calibrating, .evaluating:
                    Text("Hold your gaze on the teal target shown across the Mac display.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if session.phase != .setup {
                    Button(session.phase == .calibrating ? "Restart calibration" : "Recalibrate") {
                        session.beginCalibration()
                    }
                    .disabled(!receiver.isFresh)
                }
            }
            .frame(maxWidth: .infinity)

            Text("Mount the iPhone rigidly below the display center, with its front camera close to the lower bezel and aimed at your face from about 60 cm (roughly arm’s length). Keep both devices still during calibration.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 310)
    }

    private var rawSample: some View {
        GroupBox("Raw ARKit look-at") {
            if let sample = receiver.latestSample {
                VStack(alignment: .leading, spacing: 5) {
                    Text("x  \(sample.lookAt.x, format: .number.precision(.fractionLength(4)))")
                    Text("y  \(sample.lookAt.y, format: .number.precision(.fractionLength(4)))")
                    Text("z  \(sample.lookAt.z, format: .number.precision(.fractionLength(4)))")
                    Text(sample.isTracked ? "Face tracked" : "Tracking lost")
                        .foregroundStyle(sample.isTracked ? .green : .orange)
                }
                .font(.caption.monospacedDigit())
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Waiting for iPhone…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var gazeCanvas: some View {
        GeometryReader { geometry in
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                grid

                if let gaze = session.mappedGaze, receiver.isFresh {
                    Circle()
                        .fill(.pink.opacity(0.88))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .position(position(clamped(gaze), in: geometry.size))
                        .animation(.linear(duration: 0.04), value: gaze)
                }

                if session.phase == .setup {
                    ContentUnavailableView(
                        "Connect the iPhone",
                        systemImage: "iphone.gen3.radiowaves.left.and.right",
                        description: Text("When gaze packets are live, start calibration from the left panel.")
                    )
                } else if session.phase == .calibrated {
                    ContentUnavailableView(
                        "Calibration fitted",
                        systemImage: "scope",
                        description: Text("The pink dot is the live smoothed estimate. Start evaluation when ready.")
                    )
                } else if session.phase == .complete {
                    VStack(spacing: 10) {
                        Text(session.accuracy.formatted(.percent.precision(.fractionLength(0))))
                            .font(.system(size: 72, weight: .bold, design: .rounded))
                        Text("\(session.evaluationHits) of \(session.evaluationTrial) intended cells identified")
                            .font(.title2)
                        Text("Pink is the live smoothed gaze estimate.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .clipShape(Rectangle())
        }
    }

    private var grid: some View {
        GeometryReader { geometry in
            Path { path in
                for fraction in [1.0 / 3.0, 2.0 / 3.0] {
                    path.move(to: CGPoint(x: geometry.size.width * fraction, y: 0))
                    path.addLine(to: CGPoint(x: geometry.size.width * fraction, y: geometry.size.height))
                    path.move(to: CGPoint(x: 0, y: geometry.size.height * fraction))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height * fraction))
                }
            }
            .stroke(.secondary.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [6, 8]))
        }
    }

    private func position(_ point: Point2D, in size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }

    private func clamped(_ point: Point2D) -> Point2D {
        Point2D(x: min(max(point.x, 0.015), 0.985), y: min(max(point.y, 0.015), 0.985))
    }
}

/// Owns a transparent, click-through window whose coordinates match the Mac
/// display. Calibration targets and the live gaze dot therefore share one
/// coordinate system, even when EagleGaze's control window is moved.
@MainActor
final class GazeOverlayController: ObservableObject {
    private var panel: NSPanel?

    func show(session: MacGazeSession, receiver: GazeReceiver) {
        guard panel == nil, let screen = NSScreen.main else { return }

        let panel = NSPanel(
            contentRect: screen.frame,
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
        panel.contentView = NSHostingView(
            rootView: GazeDisplayOverlay(session: session, receiver: receiver)
        )
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

private struct GazeDisplayOverlay: View {
    @ObservedObject var session: MacGazeSession
    @ObservedObject var receiver: GazeReceiver

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.clear

                if let target = session.target,
                   session.phase == .calibrating || session.phase == .evaluating {
                    calibrationTarget
                        .position(position(target, in: geometry.size))
                }

                if session.showsGazeOverlay,
                   receiver.isFresh,
                   let gaze = session.mappedGaze,
                   session.phase != .calibrating {
                    gazeDot
                        .position(position(clamped(gaze), in: geometry.size))
                        .animation(.linear(duration: 0.04), value: gaze)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var calibrationTarget: some View {
        ZStack {
            Circle()
                .fill(.teal)
                .frame(width: 42, height: 42)
                .shadow(color: .black.opacity(0.5), radius: 5)
            Circle()
                .stroke(.white, lineWidth: 3)
                .frame(width: 42, height: 42)
            Circle()
                .fill(.white)
                .frame(width: 7, height: 7)
        }
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
