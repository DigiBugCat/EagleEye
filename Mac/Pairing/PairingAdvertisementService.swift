import Foundation
import GazeCore
import Network

/// Platform seam for advertising the nearby pairing service. Bonjour makes
/// the Mac discoverable; a selected connection requests a short-lived offer.
public protocol PairingAdvertisementService: AnyObject, Sendable {
    var isAdvertising: Bool { get }
    func start(offer: PairingOffer) throws
    func stop()
    /// Ends the active one-time offer while allowing a long-lived listener
    /// to remain discoverable for reconnects.  Simple advertisements may use
    /// the default implementation, which stops the listener entirely.
    func stopOffer()
}

public extension PairingAdvertisementService {
    func stopOffer() { stop() }
}

public enum PairingAdvertisementError: Error, Equatable, Sendable {
    case alreadyAdvertising
    case listenerUnavailable
}

/// Network.framework implementation used by the Mac app.  It intentionally
/// does not accept gaze packets or persist the offer; a transport/listener can
/// be layered on top by the receiver owner later.
public final class BonjourPairingAdvertisementService: PairingAdvertisementService, @unchecked Sendable {
    public static let serviceType = "_eagle-gaze-pair._tcp"

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var listener: NWListener?
    private var advertising = false

    public init(queue: DispatchQueue = DispatchQueue(label: "app.eaglegaze.mac.pairing-advertisement")) {
        self.queue = queue
    }

    public var isAdvertising: Bool {
        lock.lock()
        defer { lock.unlock() }
        return advertising
    }

    public func start(offer: PairingOffer) throws {
        lock.lock()
        if advertising {
            lock.unlock()
            throw PairingAdvertisementError.alreadyAdvertising
        }
        lock.unlock()

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters, on: .any)
        } catch {
            throw PairingAdvertisementError.listenerUnavailable
        }

        // Do not put the one-time secret or pairing key in TXT metadata.
        // Offer material is returned only after a phone connects to the
        // selected Bonjour endpoint; TXT remains a routing label.
        let advertisedName = String(offer.serviceIdentity.prefix(63))
        newListener.service = NWListener.Service(
            name: advertisedName,
            type: Self.serviceType,
            domain: nil,
            txtRecord: nil
        )
        newListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed = state {
                self.lock.lock()
                self.advertising = false
                self.listener = nil
                self.lock.unlock()
            }
        }
        newListener.newConnectionHandler = { connection in
            // Pairing transport is a separate concern.  Keep the listener
            // available as a seam without accepting unauthenticated payloads.
            connection.cancel()
        }

        lock.lock()
        listener = newListener
        advertising = true
        lock.unlock()
        newListener.start(queue: queue)
    }

    public func stop() {
        lock.lock()
        let current = listener
        listener = nil
        advertising = false
        lock.unlock()
        current?.cancel()
    }

    public func stopOffer() {
        stop()
    }
}
