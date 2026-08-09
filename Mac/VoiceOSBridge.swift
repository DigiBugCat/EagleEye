import Foundation
import Network
import Combine

/// The application-facing surface used by the local VoiceOS bridge.
///
/// This protocol is intentionally coarser than the gaze pipeline. An app
/// composition root adapts its receiver/session to this service and keeps
/// source IDs, user names, coordinates, rays, matrices, and blink values on
/// the Mac side of the boundary.
@MainActor
protocol GazeApplicationService: AnyObject {
    var voiceOSSnapshot: GazeApplicationSnapshot { get }

    func startCalibration() throws
    func resetCalibration() throws
    func startEvaluation() throws
}

enum GazeApplicationServiceError: LocalizedError, Equatable {
    case unavailable
    case notConnected
    case notCalibrated

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "EagleGaze application services are not configured."
        case .notConnected:
            return "Connect the iPhone and wait for a live stream first."
        case .notCalibrated:
            return "Complete calibration before starting an evaluation."
        }
    }
}

enum GazeApplicationSourceKind: String, Codable, Sendable {
    case phone
    case vendor
    case unknown
}

enum GazeApplicationConnectionState: String, Codable, Sendable {
    case connected
    case stale
    case offline
    case unavailable
}

enum GazeApplicationCalibrationState: String, Codable, Sendable {
    case setup
    case calibrating
    case calibrated
    case failed
}

enum GazeApplicationEvaluationState: String, Codable, Sendable {
    case idle
    case evaluating
    case complete
}

/// Coarse, VoiceOS-safe application state. This type must not grow fields
/// containing source identity, user identity, gaze points, face transforms,
/// rays, matrices, or blink values.
struct GazeApplicationSnapshot: Codable, Equatable, Sendable {
    let sourceKind: GazeApplicationSourceKind
    let connectionState: GazeApplicationConnectionState
    let calibrationState: GazeApplicationCalibrationState
    let calibrationStep: Int
    let calibrationPointCount: Int
    let calibrationSampleCount: Int
    let evaluationState: GazeApplicationEvaluationState
    let evaluationTrial: Int
    let evaluationTrialCount: Int
    let evaluationHits: Int
    let overlayVisible: Bool

    init(
        sourceKind: GazeApplicationSourceKind = .phone,
        connectionState: GazeApplicationConnectionState,
        calibrationState: GazeApplicationCalibrationState,
        calibrationStep: Int = 0,
        calibrationPointCount: Int = 0,
        calibrationSampleCount: Int = 0,
        evaluationState: GazeApplicationEvaluationState = .idle,
        evaluationTrial: Int = 0,
        evaluationTrialCount: Int = 0,
        evaluationHits: Int = 0,
        overlayVisible: Bool = false
    ) {
        self.sourceKind = sourceKind
        self.connectionState = connectionState
        self.calibrationState = calibrationState
        self.calibrationStep = max(calibrationStep, 0)
        self.calibrationPointCount = max(calibrationPointCount, 0)
        self.calibrationSampleCount = max(calibrationSampleCount, 0)
        self.evaluationState = evaluationState
        self.evaluationTrial = max(evaluationTrial, 0)
        self.evaluationTrialCount = max(evaluationTrialCount, 0)
        self.evaluationHits = max(evaluationHits, 0)
        self.overlayVisible = overlayVisible
    }
}

/// A deliberately small, loopback-only control surface for local integrations.
///
/// The bridge never returns ARKit transforms or gaze coordinates. VoiceOS can
/// ask for coarse session state and trigger the same reversible actions that
/// are available in the EagleGaze window.
@MainActor
final class VoiceOSBridge: ObservableObject {
    nonisolated static let protocolVersion = 1
    static let port: NWEndpoint.Port = 47_474

    @Published private(set) var status = "Starting local bridge…"
    @Published private(set) var isListening = false

    private let service: any GazeApplicationService
    private let queue = DispatchQueue(label: "com.digibugcat.eaglegaze.voiceos-bridge")
    private var listener: NWListener?

    init(service: any GazeApplicationService) {
        self.service = service
        start()
    }

    /// Compatibility initializer for older app compositions. New callers
    /// should pass an explicit `GazeApplicationService`; the untyped arguments
    /// keep source compatibility without coupling this bridge to Mac UI types.
    @available(*, deprecated, message: "Compose VoiceOSBridge with GazeApplicationService.")
    init(receiver: AnyObject, session: AnyObject) {
        self.service = UnconfiguredGazeApplicationService()
        start()
    }

    deinit {
        listener?.cancel()
    }

    private func start() {
        do {
            let parameters = NWParameters.tcp
            parameters.acceptLocalOnly = true
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)

            let listener = try NWListener(using: parameters, on: Self.port)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.updateListenerState(state)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.accept(connection)
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            status = "Bridge failed: \(error.localizedDescription)"
        }
    }

    private func updateListenerState(_ state: NWListener.State) {
        switch state {
        case .setup:
            status = "Starting local bridge…"
        case .ready:
            isListening = true
            status = "Listening on 127.0.0.1:\(Self.port.rawValue)"
        case .waiting(let error):
            isListening = false
            status = "Bridge waiting: \(error.localizedDescription)"
        case .failed(let error):
            isListening = false
            status = "Bridge failed: \(error.localizedDescription)"
        case .cancelled:
            isListening = false
            status = "Bridge stopped"
        @unknown default:
            isListening = false
            status = "Bridge state is unavailable"
        }
    }

    private func accept(_ connection: NWConnection) {
        let reader = VoiceOSLineReader(connection: connection) { [weak self] line, connection in
            Task { @MainActor in
                self?.handle(line, on: connection)
            }
        }
        reader.start(on: queue)
    }

    private func handle(_ line: Data, on connection: NWConnection) {
        let response: BridgeResponse
        do {
            let request = try JSONDecoder().decode(BridgeRequest.self, from: line)
            response = process(request)
        } catch {
            response = BridgeResponse(
                requestID: nil,
                ok: false,
                snapshot: nil,
                error: BridgeErrorPayload(code: "invalid_request", message: "Request was not valid protocol v1 JSON.")
            )
        }

        do {
            var data = try JSONEncoder().encode(response)
            data.append(0x0A)
            connection.send(content: data, completion: .contentProcessed { _ in
                connection.cancel()
            })
        } catch {
            connection.cancel()
        }
    }

    private func process(_ request: BridgeRequest) -> BridgeResponse {
        guard request.version == Self.protocolVersion else {
            return failure(request, code: "unsupported_version", message: "EagleGaze bridge protocol v1 is required.")
        }
        switch request.command {
        case "status":
            return success(request)
        case "start_calibration":
            do {
                try service.startCalibration()
            } catch let error as GazeApplicationServiceError {
                return failure(request, code: error.code, message: error.localizedDescription)
            } catch {
                return failure(request, code: "command_failed", message: error.localizedDescription)
            }
            return success(request)
        case "reset_calibration":
            do {
                try service.resetCalibration()
            } catch {
                return failure(request, code: "command_failed", message: error.localizedDescription)
            }
            return success(request)
        case "start_evaluation":
            do {
                try service.startEvaluation()
            } catch let error as GazeApplicationServiceError {
                return failure(request, code: error.code, message: error.localizedDescription)
            } catch {
                return failure(request, code: "command_failed", message: error.localizedDescription)
            }
            return success(request)
        default:
            return failure(request, code: "unknown_command", message: "That bridge command is not supported.")
        }
    }

    private func success(_ request: BridgeRequest) -> BridgeResponse {
        BridgeResponse(requestID: request.requestID, ok: true, snapshot: snapshot(), error: nil)
    }

    private func failure(_ request: BridgeRequest, code: String, message: String) -> BridgeResponse {
        BridgeResponse(
            requestID: request.requestID,
            ok: false,
            snapshot: snapshot(),
            error: BridgeErrorPayload(code: code, message: message)
        )
    }

    private func snapshot() -> BridgeSnapshot {
        BridgeSnapshot(snapshot: service.voiceOSSnapshot)
    }
}

private extension GazeApplicationServiceError {
    var code: String {
        switch self {
        case .unavailable: return "service_unavailable"
        case .notConnected: return "phone_not_connected"
        case .notCalibrated: return "not_calibrated"
        }
    }
}

/// Used only by the deprecated compatibility initializer. It makes an old
/// composition fail closed rather than exposing the bridge to UI internals.
@MainActor
private final class UnconfiguredGazeApplicationService: GazeApplicationService {
    let voiceOSSnapshot = GazeApplicationSnapshot(
        connectionState: .unavailable,
        calibrationState: .setup
    )

    func startCalibration() throws { throw GazeApplicationServiceError.unavailable }
    func resetCalibration() throws { throw GazeApplicationServiceError.unavailable }
    func startEvaluation() throws { throw GazeApplicationServiceError.unavailable }
}

private struct BridgeRequest: Decodable {
    let version: Int
    let requestID: String
    let command: String
}

private struct BridgeResponse: Encodable {
    let version = VoiceOSBridge.protocolVersion
    let requestID: String?
    let ok: Bool
    let snapshot: BridgeSnapshot?
    let error: BridgeErrorPayload?
}

private struct BridgeErrorPayload: Encodable {
    let code: String
    let message: String
}

private struct BridgeSnapshot: Encodable {
    let sourceKind: String
    let connectionState: String
    let calibrationState: String
    let evaluationState: String
    let phase: String
    let phaseTitle: String
    let progress: String
    let phoneConnected: Bool
    let calibrationStep: Int
    let calibrationPointCount: Int
    let calibrationSampleCount: Int
    let evaluationTrial: Int
    let evaluationTrialCount: Int
    let evaluationHits: Int
    let overlayVisible: Bool

    init(snapshot: GazeApplicationSnapshot) {
        sourceKind = snapshot.sourceKind.rawValue
        connectionState = snapshot.connectionState.rawValue
        calibrationState = snapshot.calibrationState.rawValue
        evaluationState = snapshot.evaluationState.rawValue
        phase = switch snapshot.evaluationState {
        case .evaluating: "evaluating"
        case .complete: "complete"
        case .idle: snapshot.calibrationState.rawValue
        }
        phaseTitle = switch snapshot.evaluationState {
        case .evaluating: "Evaluating"
        case .complete: "Evaluation complete"
        case .idle:
            switch snapshot.calibrationState {
            case .setup: "Ready to calibrate"
            case .calibrating: "Calibrating"
            case .calibrated: "Calibration complete"
            case .failed: "Calibration failed"
            }
        }
        progress = switch snapshot.evaluationState {
        case .evaluating, .complete:
            "\(snapshot.evaluationHits) / \(snapshot.evaluationTrial) hits"
        case .idle:
            switch snapshot.calibrationState {
            case .calibrating:
                "Point \(min(snapshot.calibrationStep + 1, snapshot.calibrationPointCount)) of \(snapshot.calibrationPointCount)"
            case .calibrated: "\(snapshot.calibrationPointCount) points fitted"
            default: "No calibration"
            }
        }
        phoneConnected = snapshot.connectionState == .connected
        calibrationStep = snapshot.calibrationStep
        calibrationPointCount = snapshot.calibrationPointCount
        calibrationSampleCount = snapshot.calibrationSampleCount
        evaluationTrial = snapshot.evaluationTrial
        evaluationTrialCount = snapshot.evaluationTrialCount
        evaluationHits = snapshot.evaluationHits
        overlayVisible = snapshot.overlayVisible
    }
}

/// Reads one newline-delimited request and then hands the connection back to
/// the main-actor bridge. All mutation stays on the bridge's serial queue.
private final class VoiceOSLineReader: @unchecked Sendable {
    private static let maximumRequestBytes = 16_384

    private let connection: NWConnection
    private let handler: @Sendable (Data, NWConnection) -> Void
    private var buffer = Data()
    private var finished = false

    init(connection: NWConnection, handler: @escaping @Sendable (Data, NWConnection) -> Void) {
        self.connection = connection
        self.handler = handler
    }

    func start(on queue: DispatchQueue) {
        connection.start(queue: queue)
        receiveNext()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [self] data, _, isComplete, error in
            guard !finished else { return }
            if let data {
                buffer.append(data)
            }

            if buffer.count > Self.maximumRequestBytes {
                finished = true
                connection.cancel()
                return
            }

            if let newline = buffer.firstIndex(of: 0x0A) {
                finished = true
                handler(Data(buffer[..<newline]), connection)
                return
            }

            if isComplete || error != nil {
                finished = true
                connection.cancel()
                return
            }
            receiveNext()
        }
    }
}
