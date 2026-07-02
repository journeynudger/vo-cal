public struct DeterministicRNG: Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed == 0 ? 0x9e3779b97f4a7c15 : seed
    }

    public mutating func next() -> UInt64 {
        // xorshift64*
        var x = state
        x ^= x >> 12
        x ^= x << 25
        x ^= x >> 27
        state = x
        return x &* 0x2545F4914F6CDD1D
    }

    public mutating func nextInt(upperBound: Int) -> Int {
        precondition(upperBound > 0)
        return Int(next() % UInt64(upperBound))
    }

    public mutating func nextBool(probabilityPercent: Int) -> Bool {
        precondition((0...100).contains(probabilityPercent))
        let threshold = UInt64(probabilityPercent)
        return (next() % 100) < threshold
    }
}
