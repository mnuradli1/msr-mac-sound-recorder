import Foundation

public struct WaveformBuffer: Equatable, Sendable {
    public private(set) var samples: [Float]
    public let capacity: Int

    public init(capacity: Int, samples: [Float] = []) {
        self.capacity = max(1, capacity)
        self.samples = Array(samples.suffix(max(1, capacity))).map(Self.clamped)
    }

    public mutating func append(_ sample: Float) {
        samples.append(Self.clamped(sample))
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    public mutating func reset() {
        samples.removeAll()
    }

    private static func clamped(_ sample: Float) -> Float {
        min(1, max(0, sample))
    }
}
