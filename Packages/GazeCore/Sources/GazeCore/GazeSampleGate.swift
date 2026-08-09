import Foundation

public enum GazeSampleRejection: Error, Equatable, Sendable {
    case stale(age: TimeInterval)
    case duplicateOrOutOfOrder(lastAccepted: UInt64, received: UInt64)
    case captureTimeMovedBackward(lastAccepted: TimeInterval, received: TimeInterval)
}

/// Rejects delayed and non-monotonic samples before they reach UI state.
///
/// `receivedAtUptime` and `sample.sentUptime` must share a clock domain. For
/// separate devices, pass a sent uptime translated using the connection's
/// measured clock offset, or set `maximumTransitAge` to `nil` and rely on the
/// sequence/capture-time checks.
public struct GazeSampleGate: Sendable {
    public let maximumTransitAge: TimeInterval?

    private var sessionID: UUID?
    private var lastSequence: UInt64?
    private var lastCaptureUptime: TimeInterval?

    public init(maximumTransitAge: TimeInterval? = nil) {
        self.maximumTransitAge = maximumTransitAge
    }

    @discardableResult
    public mutating func accept(
        _ sample: GazeSample,
        receivedAtUptime: TimeInterval
    ) -> Result<Void, GazeSampleRejection> {
        if let maximumTransitAge {
            let age = receivedAtUptime - sample.sentUptime
            if !age.isFinite || age > maximumTransitAge {
                return .failure(.stale(age: age))
            }
        }

        if sessionID != sample.sessionID {
            sessionID = sample.sessionID
            lastSequence = nil
            lastCaptureUptime = nil
        }

        if let lastSequence, sample.sequence <= lastSequence {
            return .failure(.duplicateOrOutOfOrder(
                lastAccepted: lastSequence,
                received: sample.sequence
            ))
        }

        if let lastCaptureUptime, sample.captureUptime < lastCaptureUptime {
            return .failure(.captureTimeMovedBackward(
                lastAccepted: lastCaptureUptime,
                received: sample.captureUptime
            ))
        }

        lastSequence = sample.sequence
        lastCaptureUptime = sample.captureUptime
        return .success(())
    }

    public mutating func reset() {
        sessionID = nil
        lastSequence = nil
        lastCaptureUptime = nil
    }
}
