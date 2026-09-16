import Foundation

/// A fixed-size ring of per-wall-clock-second counters.
///
/// Rates are computed over a trailing window that *excludes* the current,
/// still-filling second. Including it makes the displayed number dip every
/// time the UI refreshes early in a second, which reads as the stream
/// stuttering when nothing is wrong.
public struct RateBuckets: Equatable {
    public let capacity: Int
    private var seconds: [Int64]
    private var byteCounts: [Int]
    private var packetCounts: [Int]
    private var latestSecond: Int64
    private var earliestSecond: Int64
    private var hasData: Bool

    public init(capacity: Int = 300) {
        self.capacity = max(1, capacity)
        seconds = [Int64](repeating: Int64.min, count: self.capacity)
        byteCounts = [Int](repeating: 0, count: self.capacity)
        packetCounts = [Int](repeating: 0, count: self.capacity)
        latestSecond = Int64.min
        earliestSecond = Int64.max
        hasData = false
    }

    public var isEmpty: Bool { !hasData }
    public var mostRecentSecond: Int64? { hasData ? latestSecond : nil }
    public var firstSecond: Int64? { hasData ? earliestSecond : nil }

    private func index(for second: Int64) -> Int {
        let modulus = Int64(capacity)
        // Swift's % keeps the sign of the dividend; wall-clock seconds are
        // positive in practice, but normalise anyway.
        return Int(((second % modulus) + modulus) % modulus)
    }

    public mutating func add(second: Int64, bytes: Int, packets: Int) {
        // A timestamp older than the whole ring would land on a live slot and
        // corrupt it. Out-of-order by a second or two is normal; by minutes is not.
        if hasData && second <= latestSecond - Int64(capacity) { return }

        let slot = index(for: second)
        if seconds[slot] != second {
            seconds[slot] = second
            byteCounts[slot] = 0
            packetCounts[slot] = 0
        }
        byteCounts[slot] += bytes
        packetCounts[slot] += packets

        if !hasData || second > latestSecond { latestSecond = second }
        if !hasData || second < earliestSecond { earliestSecond = second }
        hasData = true
    }

    public func counts(at second: Int64) -> (bytes: Int, packets: Int) {
        let slot = index(for: second)
        guard seconds[slot] == second else { return (0, 0) }
        return (byteCounts[slot], packetCounts[slot])
    }

    /// Bits and packets per second over the `window` seconds ending at
    /// `currentSecond - 1`. The partial current second is left out.
    ///
    /// The divisor is the number of seconds the stream has actually been
    /// observable within the window, so a stream two seconds old is not
    /// reported at a fifth of its real rate.
    public func rates(currentSecond: Int64, window: Int = 5) -> (bitsPerSecond: Double, packetsPerSecond: Double) {
        guard hasData, window > 0 else { return (0, 0) }
        let last = currentSecond - 1
        let first = currentSecond - Int64(window)
        guard last >= first else { return (0, 0) }

        var bytes = 0
        var packets = 0
        var second = first
        while second <= last {
            let counted = counts(at: second)
            bytes += counted.bytes
            packets += counted.packets
            second += 1
        }

        let observableFrom = max(first, earliestSecond)
        let elapsed = max(1, Int(last - observableFrom) + 1)
        let divisor = Double(min(window, elapsed))
        return (Double(bytes) * 8 / divisor, Double(packets) / divisor)
    }

    /// Per-second byte counts for a sparkline or chart, oldest first, ending at
    /// `currentSecond - 1`. Always exactly `count` entries; missing seconds are
    /// zero, which is the truth -- nothing arrived.
    public func series(currentSecond: Int64, count: Int) -> [Double] {
        guard count > 0 else { return [] }
        var values: [Double] = []
        values.reserveCapacity(count)
        let last = currentSecond - 1
        for offset in stride(from: count - 1, through: 0, by: -1) {
            values.append(Double(counts(at: last - Int64(offset)).bytes))
        }
        return values
    }

    /// Bits per second for each second in the window, for the bandwidth chart.
    public func bitRateSeries(currentSecond: Int64, count: Int) -> [Double] {
        series(currentSecond: currentSecond, count: count).map { $0 * 8 }
    }

    public var totalBytes: Int {
        var sum = 0
        for slot in 0..<capacity where seconds[slot] != Int64.min { sum += byteCounts[slot] }
        return sum
    }

    public var totalPackets: Int {
        var sum = 0
        for slot in 0..<capacity where seconds[slot] != Int64.min { sum += packetCounts[slot] }
        return sum
    }
}
