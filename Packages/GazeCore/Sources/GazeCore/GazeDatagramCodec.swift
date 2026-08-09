import Foundation

public enum GazeDatagramError: Error, Equatable, Sendable {
    case unsupportedVersion(received: Int, supported: Int)
}

/// JSON transport encoding for a single gaze sample.
public enum GazeDatagramCodec {
    public static func encode(_ sample: GazeSample) throws -> Data {
        guard sample.version == GazeSample.currentVersion else {
            throw GazeDatagramError.unsupportedVersion(
                received: sample.version,
                supported: GazeSample.currentVersion
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(sample)
    }

    public static func decode(_ datagram: Data) throws -> GazeSample {
        let sample = try JSONDecoder().decode(GazeSample.self, from: datagram)
        guard sample.version == GazeSample.currentVersion else {
            throw GazeDatagramError.unsupportedVersion(
                received: sample.version,
                supported: GazeSample.currentVersion
            )
        }
        return sample
    }
}
