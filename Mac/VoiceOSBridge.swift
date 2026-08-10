import Foundation
import Network
import Combine
import CryptoKit

/// The application-facing surface used by the local VoiceOS bridge.
///
/// This protocol is intentionally narrower than the gaze pipeline. An app
/// composition root keeps source IDs, user names, rays, matrices, blink
/// values, and global coordinates on the Mac side. The sole exception is an
/// approved capture, which carries coordinates relative to that image only.
@MainActor
protocol GazeApplicationService: AnyObject {
    var voiceOSSnapshot: GazeApplicationSnapshot { get }

    func startCalibration() throws
    func resetCalibration() throws
    func startEvaluation() throws
    func recalibrateEagleEye() throws
    func captureGaze(
        marker: GazeCaptureMarker,
        cancellation: any GazeCaptureCancellationChecking
    ) async throws -> GazeCaptureArtifact
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
/// The bridge never returns ARKit transforms or global gaze coordinates.
/// Protocol v2 can return one annotated image plus image-relative coordinates,
/// but only after EagleGaze itself displays and approves that exact capture.
@MainActor
final class VoiceOSBridge: ObservableObject {
    nonisolated static let protocolVersion = 1
    nonisolated static let toolProtocolVersion = 2
    static let port: NWEndpoint.Port = 47_474
    private static let maximumConcurrentConnections = 8

    @Published private(set) var status = "Starting local bridge…"
    @Published private(set) var isListening = false

    private let service: any GazeApplicationService
    private let queue = DispatchQueue(label: "com.digibugcat.eaglegaze.voiceos-bridge")
    private var listener: NWListener?
    private var activeConnectionCount = 0

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
        guard activeConnectionCount < Self.maximumConcurrentConnections else {
            connection.cancel()
            return
        }
        activeConnectionCount += 1
        let reader = VoiceOSLineReader(
            connection: connection,
            handler: { [weak self] line, connection, cancellation in
                Task { @MainActor in
                    self?.handle(line, on: connection, cancellation: cancellation)
                }
            },
            onFinished: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.activeConnectionCount = max(0, self.activeConnectionCount - 1)
                }
            }
        )
        reader.start(on: queue)
    }

    private func handle(
        _ line: Data,
        on connection: NWConnection,
        cancellation: BridgeConnectionCancellation
    ) {
        if (try? JSONDecoder().decode(BridgeVersion.self, from: line).version) == Self.toolProtocolVersion {
            Task { @MainActor [weak self] in
                await self?.handleV2(line, on: connection, cancellation: cancellation)
            }
            return
        }
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

    private func handleV2(
        _ line: Data,
        on connection: NWConnection,
        cancellation: BridgeConnectionCancellation
    ) async {
        let response: ToolBridgeResponse
        var body: Data?
        do {
            let request = try JSONDecoder().decode(ToolBridgeRequest.self, from: line)
            guard request.version == Self.toolProtocolVersion else {
                throw ToolBridgeFailure(code: "unsupported_version", message: "EagleGaze tool protocol v2 is required.", retryable: false)
            }
            guard UUID(uuidString: request.requestID) != nil else {
                throw ToolBridgeFailure(code: "invalid_request", message: "requestID must be a UUID.", retryable: false)
            }
            guard request.method == "tools/call" else {
                throw ToolBridgeFailure(code: "unknown_method", message: "Only tools/call is supported.", retryable: false)
            }
            switch request.params.name {
            case "recalibrate_eagleeye":
                try service.recalibrateEagleEye()
                response = ToolBridgeResponse.success(
                    requestID: request.requestID,
                    result: ToolResult(snapshot: snapshot())
                )
            case "start_gaze_evaluation":
                try service.startEvaluation()
                response = ToolBridgeResponse.success(
                    requestID: request.requestID,
                    result: ToolResult(snapshot: snapshot())
                )
            case "capture_gaze":
                let marker = try request.params.arguments?.decodedMarker() ?? .circle
                let artifact = try await service.captureGaze(marker: marker, cancellation: cancellation)
                guard artifact.jpeg.count <= GazeCaptureService.maximumBodyBytes else {
                    throw GazeCaptureError.responseTooLarge
                }
                let digest = SHA256.hash(data: artifact.jpeg).map { String(format: "%02x", $0) }.joined()
                body = artifact.jpeg
                response = ToolBridgeResponse.success(
                    requestID: request.requestID,
                    bodyLength: artifact.jpeg.count,
                    result: ToolResult(
                        kind: "image",
                        mimeType: "image/jpeg",
                        width: artifact.width,
                        height: artifact.height,
                        sha256: digest,
                        marker: artifact.marker.rawValue,
                        capturedAt: Self.timestampFormatter.string(from: artifact.capturedAt),
                        target: "calibrated_display",
                        scope: "context_region",
                        gaze: ToolGazeResult(
                            x: artifact.gazeX,
                            y: artifact.gazeY,
                            normalizedX: artifact.normalizedX,
                            normalizedY: artifact.normalizedY,
                            uncertaintyRadius: artifact.uncertaintyRadius
                        ),
                        region: ToolRegionResult(
                            kind: artifact.region.kind.rawValue,
                            resolvedBy: artifact.region.resolvedBy.rawValue,
                            confidence: artifact.region.confidence,
                            fallbackUsed: artifact.region.fallbackUsed,
                            topmostAtGaze: artifact.region.topmostAtGaze,
                            includedRelationships: artifact.region.includedRelationships
                        ),
                        enrichment: artifact.enrichment.map {
                            ToolEnrichmentResult(
                                provenance: "external_provider",
                                trust: "untrusted_advisory",
                                provider: "cerebras",
                                model: "gemma-4-31b",
                                contentType: $0.contentType,
                                regionSummary: $0.regionSummary,
                                focusedSubject: $0.focusedSubject,
                                focusedText: $0.focusedText,
                                contextSufficient: $0.contextSufficient,
                                labels: $0.labels,
                                confidence: $0.providerConfidence,
                                warnings: $0.warnings
                            )
                        },
                        enrichmentWarning: artifact.enrichmentWarning
                    )
                )
            default:
                throw ToolBridgeFailure(code: "unknown_tool", message: "That EagleGaze tool is not supported.", retryable: false)
            }
        } catch let error as ToolBridgeFailure {
            response = .failure(requestID: Self.requestID(from: line), error: error)
        } catch let error as GazeApplicationServiceError {
            response = .failure(
                requestID: Self.requestID(from: line),
                error: ToolBridgeFailure(code: error.code, message: error.localizedDescription, retryable: error != .unavailable)
            )
        } catch let error as GazeCaptureError {
            response = .failure(requestID: Self.requestID(from: line), error: error.bridgeFailure)
        } catch DecodingError.dataCorrupted {
            response = .failure(
                requestID: Self.requestID(from: line),
                error: ToolBridgeFailure(code: "invalid_arguments", message: "Tool arguments are invalid.", retryable: false)
            )
        } catch {
            response = .failure(
                requestID: Self.requestID(from: line),
                error: ToolBridgeFailure(code: "invalid_request", message: "Request was not valid protocol v2 JSON.", retryable: false)
            )
        }
        send(response, body: body, on: connection)
    }

    private func send(_ response: ToolBridgeResponse, body: Data?, on connection: NWConnection) {
        do {
            var framed = try JSONEncoder().encode(response)
            guard framed.count <= 65_536 else { throw GazeCaptureError.responseTooLarge }
            framed.append(0x0A)
            if let body { framed.append(body) }
            connection.send(content: framed, completion: .contentProcessed { _ in connection.cancel() })
        } catch {
            connection.cancel()
        }
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated static func requestID(from data: Data) -> String? {
        try? JSONDecoder().decode(BridgeRequestID.self, from: data).requestID
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
    func recalibrateEagleEye() throws { throw GazeApplicationServiceError.unavailable }
    func captureGaze(marker: GazeCaptureMarker, cancellation: any GazeCaptureCancellationChecking) async throws -> GazeCaptureArtifact {
        throw GazeApplicationServiceError.unavailable
    }
}

private struct BridgeVersion: Decodable { let version: Int }
private struct BridgeRequestID: Decodable { let requestID: String }

private struct ToolBridgeRequest: Decodable {
    let version: Int
    let requestID: String
    let method: String
    let params: ToolCallParams
}

private struct ToolCallParams: Decodable {
    let name: String
    let arguments: ToolArguments?
}

private struct ToolArguments: Decodable {
    let marker: String?

    func decodedMarker() throws -> GazeCaptureMarker {
        guard let marker else { return .circle }
        guard let value = GazeCaptureMarker(rawValue: marker) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unsupported marker"))
        }
        return value
    }
}

private struct ToolBridgeResponse: Encodable {
    let version: Int
    let requestID: String?
    let ok: Bool
    let bodyLength: Int
    let result: ToolResult?
    let error: ToolBridgeErrorPayload?

    static func success(requestID: String, bodyLength: Int = 0, result: ToolResult) -> Self {
        Self(version: VoiceOSBridge.toolProtocolVersion, requestID: requestID, ok: true, bodyLength: bodyLength, result: result, error: nil)
    }

    static func failure(requestID: String?, error: ToolBridgeFailure) -> Self {
        Self(
            version: VoiceOSBridge.toolProtocolVersion,
            requestID: requestID,
            ok: false,
            bodyLength: 0,
            result: nil,
            error: ToolBridgeErrorPayload(code: error.code, message: error.message, retryable: error.retryable)
        )
    }
}

private struct ToolResult: Encodable {
    let snapshot: BridgeSnapshot?
    let kind: String?
    let mimeType: String?
    let width: Int?
    let height: Int?
    let sha256: String?
    let marker: String?
    let capturedAt: String?
    let target: String?
    let scope: String?
    let gaze: ToolGazeResult?
    let region: ToolRegionResult?
    let enrichment: ToolEnrichmentResult?
    let enrichmentWarning: String?

    init(snapshot: BridgeSnapshot? = nil, kind: String? = nil, mimeType: String? = nil, width: Int? = nil, height: Int? = nil, sha256: String? = nil, marker: String? = nil, capturedAt: String? = nil, target: String? = nil, scope: String? = nil, gaze: ToolGazeResult? = nil, region: ToolRegionResult? = nil, enrichment: ToolEnrichmentResult? = nil, enrichmentWarning: String? = nil) {
        self.snapshot = snapshot
        self.kind = kind
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.sha256 = sha256
        self.marker = marker
        self.capturedAt = capturedAt
        self.target = target
        self.scope = scope
        self.gaze = gaze
        self.region = region
        self.enrichment = enrichment
        self.enrichmentWarning = enrichmentWarning
    }
}

private struct ToolRegionResult: Encodable {
    let kind: String
    let resolvedBy: String
    let confidence: Double
    let fallbackUsed: Bool
    let topmostAtGaze: Bool?
    let includedRelationships: [String]
}

private struct ToolEnrichmentResult: Encodable {
    let provenance: String
    let trust: String
    let provider: String
    let model: String
    let contentType: String
    let regionSummary: String
    let focusedSubject: String
    let focusedText: String
    let contextSufficient: Bool
    let labels: [String]
    let confidence: Double
    let warnings: [String]
}

private struct ToolGazeResult: Encodable {
    let x: Int
    let y: Int
    let normalizedX: Double
    let normalizedY: Double
    let uncertaintyRadius: Int
}

private struct ToolBridgeErrorPayload: Encodable {
    let code: String
    let message: String
    let retryable: Bool
}

private struct ToolBridgeFailure: Error {
    let code: String
    let message: String
    let retryable: Bool
}

private extension GazeCaptureError {
    var bridgeFailure: ToolBridgeFailure {
        switch self {
        case .captureBusy: .init(code: "capture_busy", message: localizedDescription, retryable: true)
        case .gazeStale: .init(code: "gaze_stale", message: localizedDescription, retryable: true)
        case .notCalibrated: .init(code: "not_calibrated", message: localizedDescription, retryable: true)
        case .displayUnavailable: .init(code: "display_unavailable", message: localizedDescription, retryable: true)
        case .permissionRequired: .init(code: "screen_recording_permission_required", message: localizedDescription, retryable: true)
        case .approvalRejected: .init(code: "approval_rejected", message: localizedDescription, retryable: false)
        case .captureFailed: .init(code: "capture_failed", message: localizedDescription, retryable: true)
        case .encodingFailed: .init(code: "encoding_failed", message: localizedDescription, retryable: true)
        case .responseTooLarge: .init(code: "response_too_large", message: localizedDescription, retryable: true)
        case .requestCancelled: .init(code: "request_cancelled", message: localizedDescription, retryable: false)
        }
    }
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
    private static let requestDeadline: TimeInterval = 5

    private let connection: NWConnection
    private let handler: @Sendable (Data, NWConnection, BridgeConnectionCancellation) -> Void
    private let cancellation = BridgeConnectionCancellation()
    private let onFinished: @Sendable () -> Void
    private var buffer = Data()
    private var finished = false
    private var closed = false
    private var deadlineWorkItem: DispatchWorkItem?

    init(
        connection: NWConnection,
        handler: @escaping @Sendable (Data, NWConnection, BridgeConnectionCancellation) -> Void,
        onFinished: @escaping @Sendable () -> Void
    ) {
        self.connection = connection
        self.handler = handler
        self.onFinished = onFinished
    }

    func start(on queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                cancellation.cancel()
                completeConnection()
            default: break
            }
        }
        connection.start(queue: queue)
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, !finished else { return }
            cancellation.cancel()
            connection.cancel()
            completeConnection()
        }
        deadlineWorkItem = deadline
        queue.asyncAfter(deadline: .now() + Self.requestDeadline, execute: deadline)
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
                deadlineWorkItem?.cancel()
                connection.cancel()
                completeConnection()
                return
            }

            if let newline = buffer.firstIndex(of: 0x0A) {
                finished = true
                deadlineWorkItem?.cancel()
                let trailingStart = buffer.index(after: newline)
                guard trailingStart == buffer.endIndex else {
                    cancellation.cancel()
                    connection.cancel()
                    completeConnection()
                    return
                }
                if isComplete || error != nil {
                    cancellation.cancel()
                }
                handler(Data(buffer[..<newline]), connection, cancellation)
                if !cancellation.isCancelled { monitorDisconnect() }
                return
            }

            if isComplete || error != nil {
                finished = true
                deadlineWorkItem?.cancel()
                connection.cancel()
                completeConnection()
                return
            }
            receiveNext()
        }
    }

    private func monitorDisconnect() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [self] data, _, isComplete, error in
            if isComplete || error != nil {
                cancellation.cancel()
                completeConnection()
                return
            }
            // Requests are one-shot. Any bytes after the newline are invalid;
            // treat them as cancellation rather than retaining capture state.
            if data?.isEmpty == false {
                cancellation.cancel()
                connection.cancel()
                completeConnection()
                return
            }
            monitorDisconnect()
        }
    }

    private func completeConnection() {
        guard !closed else { return }
        closed = true
        deadlineWorkItem?.cancel()
        onFinished()
    }
}

final class BridgeConnectionCancellation: GazeCaptureCancellationChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
