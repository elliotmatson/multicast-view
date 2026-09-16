import Foundation

/// One row of the stream table: a particular sender, to a particular group, on
/// a particular port.
public struct StreamKey: Hashable, Codable, Sendable {
    public let source: IPv4Address
    public let group: IPv4Address
    public let destinationPort: UInt16?
    public let protocolNumber: UInt8
    /// The VLAN the frames were tagged with, when the capture point is a trunk
    /// or a mirror of one. Nil means untagged.
    public let vlan: UInt16?

    public init(source: IPv4Address, group: IPv4Address,
                destinationPort: UInt16?, protocolNumber: UInt8, vlan: UInt16? = nil) {
        self.source = source
        self.group = group
        self.destinationPort = destinationPort
        self.protocolNumber = protocolNumber
        self.vlan = vlan
    }

    public var vlanText: String { vlan.map(String.init) ?? "\u{2014}" }

    public var portText: String { destinationPort.map(String.init) ?? "-" }
}

public struct StreamSnapshot: Identifiable, Equatable {
    public let key: StreamKey
    public let identity: StreamIdentity
    public let bitsPerSecond: Double
    public let packetsPerSecond: Double
    /// Most recently observed TTL.
    public let ttl: UInt8
    /// True when this stream has been seen with more than one TTL, which
    /// usually means two senders are using the same group.
    public let ttlVaries: Bool
    /// Per-second byte counts, oldest first, for the 60s sparkline.
    public let sparkline: [Double]
    public let firstSeen: Double
    public let lastSeen: Double
    public let totalPackets: Int
    public let totalBytes: Int
    /// True if any packet in this stream arrived fragmented.
    public let sawFragments: Bool

    public var id: StreamKey { key }

    public init(key: StreamKey, identity: StreamIdentity, bitsPerSecond: Double,
                packetsPerSecond: Double, ttl: UInt8, ttlVaries: Bool, sparkline: [Double],
                firstSeen: Double, lastSeen: Double, totalPackets: Int, totalBytes: Int,
                sawFragments: Bool) {
        self.key = key
        self.identity = identity
        self.bitsPerSecond = bitsPerSecond
        self.packetsPerSecond = packetsPerSecond
        self.ttl = ttl
        self.ttlVaries = ttlVaries
        self.sparkline = sparkline
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.totalPackets = totalPackets
        self.totalBytes = totalBytes
        self.sawFragments = sawFragments
    }
}

/// A charted series: a group, or the "Other" bucket everything outside the top
/// few folds into.
public struct GroupSeries: Identifiable, Equatable {
    public let group: IPv4Address?      // nil for "Other"
    public let label: String
    public let detail: String?
    /// Bits per second for each second in the chart window, oldest first.
    public let values: [Double]
    public let currentBitsPerSecond: Double
    /// Fixed palette slot. Stable for as long as the group stays charted, so
    /// a series does not change colour as ranks shuffle.
    public let colorSlot: Int

    public var id: String { group?.description ?? "__other__" }
    public var isOther: Bool { group == nil }

    public init(group: IPv4Address?, label: String, detail: String?, values: [Double],
                currentBitsPerSecond: Double, colorSlot: Int) {
        self.group = group
        self.label = label
        self.detail = detail
        self.values = values
        self.currentBitsPerSecond = currentBitsPerSecond
        self.colorSlot = colorSlot
    }
}

public struct AggregateSnapshot: Equatable {
    public let streams: [StreamSnapshot]
    public let totalBitsPerSecond: Double
    public let totalPacketsPerSecond: Double
    public let series: [GroupSeries]
    /// Seconds covered by the chart window, oldest first, as offsets from now.
    public let seriesSecondOffsets: [Int]

    public init(streams: [StreamSnapshot], totalBitsPerSecond: Double,
                totalPacketsPerSecond: Double, series: [GroupSeries], seriesSecondOffsets: [Int]) {
        self.streams = streams
        self.totalBitsPerSecond = totalBitsPerSecond
        self.totalPacketsPerSecond = totalPacketsPerSecond
        self.series = series
        self.seriesSecondOffsets = seriesSecondOffsets
    }

    public static let empty = AggregateSnapshot(streams: [], totalBitsPerSecond: 0,
                                                totalPacketsPerSecond: 0, series: [],
                                                seriesSecondOffsets: [])
}

/// Hands out a stable palette slot per group, so a series keeps its colour for
/// as long as it stays on the chart. Slots are never cycled: when they run out,
/// the extra groups fold into "Other" rather than reusing a colour.
public final class SeriesSlotAllocator {
    public let slotCount: Int
    private var assigned: [IPv4Address: Int] = [:]
    private var free: [Int]

    public init(slotCount: Int) {
        self.slotCount = max(1, slotCount)
        free = Array((0..<self.slotCount).reversed())
    }

    public func slot(for group: IPv4Address) -> Int? {
        if let existing = assigned[group] { return existing }
        guard let next = free.popLast() else { return nil }
        assigned[group] = next
        return next
    }

    /// Frees the slots of any group no longer being charted.
    public func retain(only groups: Set<IPv4Address>) {
        for (group, slot) in assigned where !groups.contains(group) {
            assigned.removeValue(forKey: group)
            free.append(slot)
        }
        free.sort(by: >)    // hand out low slots first
    }

    public func reset() {
        assigned.removeAll()
        free = Array((0..<slotCount).reversed())
    }
}

public final class StreamAggregator {
    private final class StreamState {
        var buckets: RateBuckets
        var identity: StreamIdentity
        var ttl: UInt8
        var ttlVaries = false
        var firstSeen: Double
        var lastSeen: Double
        var totalPackets = 0
        var totalBytes = 0
        var sawFragments = false

        init(identity: StreamIdentity, ttl: UInt8, now: Double, historySeconds: Int) {
            buckets = RateBuckets(capacity: historySeconds)
            self.identity = identity
            self.ttl = ttl
            firstSeen = now
            lastSeen = now
        }
    }

    /// A few hundred seconds per stream is plenty; the chart window is 120s and
    /// the sparkline 60s.
    public let historySeconds: Int
    /// Streams silent longer than this leave the table, so it reflects now.
    public var streamTimeout: Double
    /// Rates are averaged over this many whole seconds.
    public var rateWindow: Int
    public let chartWindowSeconds: Int
    public let sparklineSeconds: Int

    private var streams: [StreamKey: StreamState] = [:]
    private var groupBuckets: [IPv4Address: RateBuckets] = [:]
    private var totals = RateBuckets(capacity: 300)
    private let slots: SeriesSlotAllocator
    public let chartSeriesCount: Int

    public private(set) var packetsProcessed = 0
    public private(set) var bytesProcessed = 0

    public init(historySeconds: Int = 300,
                streamTimeout: Double = 30,
                rateWindow: Int = 5,
                chartWindowSeconds: Int = 120,
                sparklineSeconds: Int = 60,
                chartSeriesCount: Int = 5) {
        self.historySeconds = max(chartWindowSeconds + 10, historySeconds)
        self.streamTimeout = streamTimeout
        self.rateWindow = rateWindow
        self.chartWindowSeconds = chartWindowSeconds
        self.sparklineSeconds = sparklineSeconds
        self.chartSeriesCount = chartSeriesCount
        totals = RateBuckets(capacity: self.historySeconds)
        slots = SeriesSlotAllocator(slotCount: chartSeriesCount)
    }

    /// `scale` multiplies the counted bytes and packets. With 1-in-N sampling
    /// the capture only sees every Nth packet, so the counts are scaled back up
    /// -- and the UI says the figures are sampled.
    public func ingest(_ packet: ObservedPacket, scale: Int = 1) {
        let second = Int64(packet.timestamp.rounded(.down))
        let bytes = packet.ipTotalLength * scale
        let packets = 1 * scale

        packetsProcessed += packets
        bytesProcessed += bytes

        totals.add(second: second, bytes: bytes, packets: packets)
        groupBuckets[packet.destination, default: RateBuckets(capacity: historySeconds)]
            .add(second: second, bytes: bytes, packets: packets)

        // IGMP is control traffic, not a stream. It is counted in the totals
        // and charted, but it does not earn a row in the stream table.
        guard packet.protocolNumber != IPProtocol.igmp else { return }

        // The innermost tag is the one the IP traffic is actually on.
        let key = StreamKey(source: packet.source, group: packet.destination,
                            destinationPort: packet.destinationPort,
                            protocolNumber: packet.protocolNumber,
                            vlan: packet.vlanIdentifiers.last)

        let state: StreamState
        if let existing = streams[key] {
            state = existing
            if existing.ttl != packet.ttl {
                existing.ttlVaries = true
                existing.ttl = packet.ttl
            }
        } else {
            state = StreamState(identity: StreamClassifier.classify(packet), ttl: packet.ttl,
                                now: packet.timestamp, historySeconds: historySeconds)
            streams[key] = state
        }

        state.lastSeen = packet.timestamp
        state.totalPackets += packets
        state.totalBytes += bytes
        if packet.isFragment { state.sawFragments = true }
        state.buckets.add(second: second, bytes: bytes, packets: packets)
    }

    public func prune(now: Double) {
        let cutoff = now - streamTimeout
        streams = streams.filter { $0.value.lastSeen >= cutoff }

        // A group with no stream still sending is not worth charting.
        let liveGroups = Set(streams.keys.map(\.group))
        groupBuckets = groupBuckets.filter { group, buckets in
            if liveGroups.contains(group) { return true }
            guard let latest = buckets.mostRecentSecond else { return false }
            return Double(latest) >= cutoff
        }
    }

    public func reset() {
        streams.removeAll()
        groupBuckets.removeAll()
        totals = RateBuckets(capacity: historySeconds)
        slots.reset()
        packetsProcessed = 0
        bytesProcessed = 0
    }

    public func snapshot(now: Double) -> AggregateSnapshot {
        let currentSecond = Int64(now.rounded(.down))

        var rows: [StreamSnapshot] = []
        rows.reserveCapacity(streams.count)
        for (key, state) in streams {
            let rates = state.buckets.rates(currentSecond: currentSecond, window: rateWindow)
            rows.append(StreamSnapshot(key: key,
                                       identity: state.identity,
                                       bitsPerSecond: rates.bitsPerSecond,
                                       packetsPerSecond: rates.packetsPerSecond,
                                       ttl: state.ttl,
                                       ttlVaries: state.ttlVaries,
                                       sparkline: state.buckets.series(currentSecond: currentSecond,
                                                                       count: sparklineSeconds),
                                       firstSeen: state.firstSeen,
                                       lastSeen: state.lastSeen,
                                       totalPackets: state.totalPackets,
                                       totalBytes: state.totalBytes,
                                       sawFragments: state.sawFragments))
        }

        let totalRates = totals.rates(currentSecond: currentSecond, window: rateWindow)
        let series = buildSeries(currentSecond: currentSecond)

        return AggregateSnapshot(streams: rows,
                                 totalBitsPerSecond: totalRates.bitsPerSecond,
                                 totalPacketsPerSecond: totalRates.packetsPerSecond,
                                 series: series,
                                 seriesSecondOffsets: Self.secondOffsets(count: chartWindowSeconds))
    }

    private static func secondOffsets(count: Int) -> [Int] {
        var offsets: [Int] = []
        offsets.reserveCapacity(count)
        for index in stride(from: count, through: 1, by: -1) { offsets.append(-index) }
        return offsets
    }

    private struct RankedGroup {
        let group: IPv4Address
        let rate: Double
    }

    private func buildSeries(currentSecond: Int64) -> [GroupSeries] {
        // Rank by current rate, take the top few, everything else is "Other".
        var ranked: [RankedGroup] = []
        ranked.reserveCapacity(groupBuckets.count)
        for (group, buckets) in groupBuckets {
            let rate: Double = buckets.rates(currentSecond: currentSecond, window: rateWindow).bitsPerSecond
            if rate > 0 { ranked.append(RankedGroup(group: group, rate: rate)) }
        }
        ranked.sort { (lhs: RankedGroup, rhs: RankedGroup) -> Bool in
            if lhs.rate != rhs.rate { return lhs.rate > rhs.rate }
            return lhs.group.raw < rhs.group.raw
        }

        let charted: [RankedGroup] = Array(ranked.prefix(chartSeriesCount))
        var chartedGroups = Set<IPv4Address>()
        for entry in charted { chartedGroups.insert(entry.group) }
        slots.retain(only: chartedGroups)

        var result: [GroupSeries] = []
        for entry in charted {
            guard let buckets = groupBuckets[entry.group], let slot = slots.slot(for: entry.group) else { continue }
            let identity = identityForGroup(entry.group)
            result.append(GroupSeries(group: entry.group,
                                      label: entry.group.description,
                                      detail: identity?.displayText,
                                      values: buckets.bitRateSeries(currentSecond: currentSecond,
                                                                    count: chartWindowSeconds),
                                      currentBitsPerSecond: entry.rate,
                                      colorSlot: slot))
        }

        // Everything below the cut, summed second by second.
        let remainder: [RankedGroup] = Array(ranked.dropFirst(chartSeriesCount))
        if !remainder.isEmpty {
            var summed = [Double](repeating: 0, count: chartWindowSeconds)
            var currentRate = 0.0
            for entry in remainder {
                guard let buckets = groupBuckets[entry.group] else { continue }
                let values = buckets.bitRateSeries(currentSecond: currentSecond, count: chartWindowSeconds)
                for index in 0..<min(summed.count, values.count) { summed[index] += values[index] }
                currentRate += entry.rate
            }
            result.append(GroupSeries(group: nil, label: "Other",
                                      detail: "\(remainder.count) more group\(remainder.count == 1 ? "" : "s")",
                                      values: summed, currentBitsPerSecond: currentRate,
                                      colorSlot: -1))
        }
        return result
    }

    /// The identity of the loudest stream in a group, for the chart legend.
    private func identityForGroup(_ group: IPv4Address) -> StreamIdentity? {
        var best: (StreamIdentity, Int)?
        for (key, state) in streams where key.group == group {
            if best == nil || state.totalBytes > best!.1 {
                best = (state.identity, state.totalBytes)
            }
        }
        return best?.0
    }
}
