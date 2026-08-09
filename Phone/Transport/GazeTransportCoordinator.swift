import Foundation
import GazeCore

/// Owns receiver selection and one authenticated stream.  Discovery may find
/// many receivers; this type never chooses one implicitly.
@MainActor
public final class GazeTransportCoordinator {
    public private(set) var discoveredReceivers: [GazeReceiverID: DiscoveredGazeReceiver] = [:]
    public private(set) var selectedReceiver: PairedGazeReceiver?
    public private(set) var state: GazeConnectionState = .cancelled
    public private(set) var lastError: Error?
    public var onStateChanged: ((GazeConnectionState) -> Void)?
    public var onReceiversChanged: (([GazeReceiverID: DiscoveredGazeReceiver]) -> Void)?

    private let browser: GazeReceiverBrowser
    private let factory: GazeDatagramConnectionFactory
    private let codec: AuthenticatedGazeCodec
    private var connection: GazeDatagramConnection?
    private var latestSender: LatestOnlyGazeSender?
    private var pendingLatest: Data?
    private var reconnectTask: Task<Void, Never>?
    private var retryAttempt = 0
    private var running = false

    public init(
        browser: GazeReceiverBrowser,
        factory: GazeDatagramConnectionFactory,
        codec: AuthenticatedGazeCodec = AuthenticatedGazeCodec()
    ) {
        self.browser = browser
        self.factory = factory
        self.codec = codec

        browser.stateChanged = { [weak self] state in
            Task { @MainActor in self?.handleBrowserState(state) }
        }
        browser.receiversChanged = { [weak self] receivers in
            Task { @MainActor in self?.handleReceiversChanged(receivers) }
        }
    }

    public func start() {
        guard !running else { return }
        running = true
        updateState(.starting)
        browser.start()
        connectIfNeeded()
    }

    public func stop() {
        running = false
        reconnectTask?.cancel()
        reconnectTask = nil
        retryAttempt = 0
        latestSender?.stop()
        latestSender = nil
        pendingLatest = nil
        connection?.cancel()
        connection = nil
        browser.stop()
        updateState(.cancelled)
    }

    /// Selects one discovered receiver and fresh session material.  The
    /// receiver ID and endpoint are captured together, so a later Bonjour
    /// result cannot silently redirect an active stream.
    public func selectReceiver(
        id: GazeReceiverID,
        receiverFingerprint: String,
        session: GazeSessionMaterial
    ) throws {
        guard let discovered = discoveredReceivers[id] else {
            throw GazeTransportError.receiverNotDiscovered(id)
        }
        guard discovered.hasValidReceiverIdentity else {
            throw GazeTransportError.receiverIdentityRequired
        }
        guard discovered.receiverFingerprint == receiverFingerprint else {
            throw GazeTransportError.receiverIdentityMismatch
        }
        let selection = PairedGazeReceiver(
            receiverID: id,
            receiverFingerprint: receiverFingerprint,
            endpoint: discovered.endpoint,
            session: session
        )
        selectReceiver(selection)
    }

    /// Composition can use this overload when pairing already resolved an
    /// endpoint (for example, a retained endpoint during discovery outage).
    @discardableResult
    public func selectReceiver(_ selection: PairedGazeReceiver) -> Bool {
        guard DiscoveredGazeReceiver.isValidReceiverFingerprint(selection.receiverFingerprint) else {
            lastError = GazeTransportError.receiverIdentityRequired
            updateState(.failed("Receiver identity is missing or invalid"))
            return false
        }
        if let discovered = discoveredReceivers[selection.receiverID],
           discovered.receiverFingerprint != selection.receiverFingerprint {
            lastError = GazeTransportError.receiverIdentityMismatch
            updateState(.failed("Receiver identity does not match pairing"))
            return false
        }
        guard selectedReceiver != selection else { return true }
        disconnect()
        selectedReceiver = selection
        retryAttempt = 0
        lastError = nil
        updateState(.starting)
        connectIfNeeded()
        return true
    }

    public func clearSelection() {
        disconnect()
        selectedReceiver = nil
        updateState(running ? .starting : .cancelled)
    }

    public func sendLatest(_ frame: CanonicalGazeFrame) {
        guard let selectedReceiver else {
            lastError = GazeTransportError.noSelectedReceiver
            return
        }
        guard let encoded = try? codec.encode(frame, session: selectedReceiver.session) else {
            do {
                _ = try codec.encode(frame, session: selectedReceiver.session)
            } catch {
                lastError = error
            }
            return
        }
        pendingLatest = encoded
        latestSender?.sendLatest(encoded)
    }

    #if DEBUG
    /// Temporary migration hook for the existing ARKit prototype. Release
    /// builds never call this unauthenticated path.
    public func sendDebugLatest(_ data: Data) {
        latestSender?.sendLatest(data)
    }
    #endif

    private func handleBrowserState(_ newState: GazeBrowserState) {
        guard running else { return }
        if case .failed(let detail) = newState {
            lastError = GazeTransportError.connectionUnavailable
            updateState(.failed(detail))
        }
    }

    private func handleReceiversChanged(_ receivers: [DiscoveredGazeReceiver]) {
        discoveredReceivers = Dictionary(uniqueKeysWithValues: receivers.map { ($0.id, $0) })
        onReceiversChanged?(discoveredReceivers)
        guard let selectedReceiver,
              let current = discoveredReceivers[selectedReceiver.receiverID],
              (current.endpoint != selectedReceiver.endpoint ||
               current.receiverFingerprint != selectedReceiver.receiverFingerprint)
        else { return }
        if current.receiverFingerprint != selectedReceiver.receiverFingerprint {
            // A changed identity is not a reconnectable path. Requiring an
            // explicit reselection prevents a stale pairing from streaming to
            // a service that now claims another receiver identity.
            disconnect()
            self.selectedReceiver = nil
            lastError = GazeTransportError.receiverIdentityMismatch
            updateState(.failed("Receiver identity changed; select it again"))
        } else {
            // Retain the selected endpoint until composition explicitly
            // selects a replacement. This is intentionally not an automatic
            // switch.
            lastError = GazeTransportError.receiverChangedWhileSelected
        }
    }

    private func connectIfNeeded() {
        guard running, connection == nil, let selection = selectedReceiver else {
            if selectedReceiver == nil { updateState(running ? .starting : .cancelled) }
            return
        }
        updateState(.starting)
        let connection = factory.makeConnection(to: selection.endpoint)
        self.connection = connection
        let connectionID = ObjectIdentifier(connection)
        connection.stateChanged = { [weak self] state in
            Task { @MainActor in
                guard let self,
                      let current = self.connection,
                      ObjectIdentifier(current) == connectionID
                else { return }
                self.handleConnectionState(state)
            }
        }
        connection.start()
    }

    private func handleConnectionState(_ newState: GazeConnectionState) {
        updateState(newState)
        switch newState {
        case .ready:
            retryAttempt = 0
            reconnectTask?.cancel()
            reconnectTask = nil
            lastError = nil
            if let connection {
                latestSender?.stop()
                let sender = LatestOnlyGazeSender(connection: connection)
                sender.onSendError = { [weak self] error in
                    Task { @MainActor in self?.lastError = error }
                }
                latestSender = sender
                if let pendingLatest {
                    latestSender?.sendLatest(pendingLatest)
                    self.pendingLatest = nil
                }
            }
        case .failed(let detail):
            lastError = NSError(domain: "EagleGaze.Transport", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
            disconnectConnectionOnly()
            scheduleReconnect()
        case .cancelled:
            disconnectConnectionOnly()
            if running { scheduleReconnect() }
        case .starting, .waiting:
            break
        }
    }

    private func scheduleReconnect() {
        guard running, selectedReceiver != nil, reconnectTask == nil else { return }
        let delayMilliseconds = min(8_000, 250 * (1 << min(retryAttempt, 5)))
        retryAttempt += 1
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard !Task.isCancelled, let self else { return }
            self.reconnectTask = nil
            self.connectIfNeeded()
        }
    }

    private func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        latestSender?.stop()
        latestSender = nil
        pendingLatest = nil
        connection?.cancel()
        connection = nil
    }

    private func disconnectConnectionOnly() {
        latestSender?.stop()
        latestSender = nil
        connection?.cancel()
        connection = nil
    }

    private func updateState(_ newState: GazeConnectionState) {
        state = newState
        onStateChanged?(newState)
    }
}
