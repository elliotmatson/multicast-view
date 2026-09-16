import XCTest
import MulticastCore

final class RateBucketTests: XCTestCase {
    func testCurrentPartialSecondIsExcluded() {
        var buckets = RateBuckets(capacity: 60)
        // A steady 1000 bytes in each of seconds 100-104.
        for second in Int64(100)...104 { buckets.add(second: second, bytes: 1000, packets: 10) }
        // We are now 0.1s into second 105, which has only 100 bytes so far.
        buckets.add(second: 105, bytes: 100, packets: 1)

        let rates = buckets.rates(currentSecond: 105, window: 5)
        // Seconds 100-104 only: 5000 bytes over 5s = 8000 bit/s.
        XCTAssertEqual(rates.bitsPerSecond, 8000, accuracy: 0.001)
        XCTAssertEqual(rates.packetsPerSecond, 10, accuracy: 0.001)
    }

    func testRateDoesNotDipAsThePartialSecondFills() {
        var buckets = RateBuckets(capacity: 60)
        for second in Int64(100)...104 { buckets.add(second: second, bytes: 1000, packets: 10) }

        let earlyInSecond = buckets.rates(currentSecond: 105, window: 5).bitsPerSecond
        buckets.add(second: 105, bytes: 250, packets: 2)
        let laterInSecond = buckets.rates(currentSecond: 105, window: 5).bitsPerSecond
        XCTAssertEqual(earlyInSecond, laterInSecond,
                       "the displayed rate must not change as the current second fills")
    }

    func testYoungStreamIsNotUnderstated() {
        var buckets = RateBuckets(capacity: 60)
        // Two whole seconds of history, asked for over a 5s window.
        buckets.add(second: 100, bytes: 1000, packets: 10)
        buckets.add(second: 101, bytes: 1000, packets: 10)
        let rates = buckets.rates(currentSecond: 102, window: 5)
        // 2000 bytes over the 2 seconds it has existed, not over 5.
        XCTAssertEqual(rates.bitsPerSecond, 8000, accuracy: 0.001)
    }

    func testSilentStreamFallsToZero() {
        var buckets = RateBuckets(capacity: 60)
        for second in Int64(100)...104 { buckets.add(second: second, bytes: 1000, packets: 10) }
        XCTAssertEqual(buckets.rates(currentSecond: 120, window: 5).bitsPerSecond, 0, accuracy: 0.001)
    }

    func testSeriesIsOldestFirstAndPadsWithZeros() {
        var buckets = RateBuckets(capacity: 60)
        buckets.add(second: 103, bytes: 100, packets: 1)
        buckets.add(second: 104, bytes: 200, packets: 1)
        let series = buckets.series(currentSecond: 105, count: 5)
        // Seconds 100, 101, 102, 103, 104.
        XCTAssertEqual(series, [0, 0, 0, 100, 200])
    }

    func testHistoryIsBounded() {
        var buckets = RateBuckets(capacity: 10)
        for second in Int64(0)..<1000 { buckets.add(second: second, bytes: 100, packets: 1) }
        // Only the last 10 seconds survive; second 989 is already gone.
        XCTAssertEqual(buckets.counts(at: 999).bytes, 100)
        XCTAssertEqual(buckets.counts(at: 990).bytes, 100)
        XCTAssertEqual(buckets.counts(at: 989).bytes, 0)
        XCTAssertEqual(buckets.totalBytes, 1000)
    }

    func testVeryLateTimestampDoesNotCorruptALiveSlot() {
        var buckets = RateBuckets(capacity: 10)
        buckets.add(second: 1000, bytes: 500, packets: 5)
        // 900 would land on the same ring slot as 1000. It must be dropped.
        buckets.add(second: 900, bytes: 999999, packets: 1)
        XCTAssertEqual(buckets.counts(at: 1000).bytes, 500)
    }

    func testOutOfOrderWithinTheRingIsAccepted() {
        var buckets = RateBuckets(capacity: 60)
        buckets.add(second: 105, bytes: 100, packets: 1)
        buckets.add(second: 104, bytes: 200, packets: 2)   // a touch out of order
        XCTAssertEqual(buckets.counts(at: 104).bytes, 200)
        XCTAssertEqual(buckets.counts(at: 105).bytes, 100)
    }
}

final class SeriesSlotTests: XCTestCase {
    func testSlotsAreStableWhileChartedAndReusedWhenFreed() {
        let allocator = SeriesSlotAllocator(slotCount: 3)
        let a = IPv4Address("239.255.0.1")!
        let b = IPv4Address("239.255.0.2")!
        let c = IPv4Address("239.255.0.3")!

        XCTAssertEqual(allocator.slot(for: a), 0)
        XCTAssertEqual(allocator.slot(for: b), 1)
        XCTAssertEqual(allocator.slot(for: c), 2)
        // Asking again must give the same answer -- a series must not change
        // colour just because the ranking shuffled.
        XCTAssertEqual(allocator.slot(for: a), 0)
        XCTAssertEqual(allocator.slot(for: b), 1)

        // b leaves the chart; its slot becomes available again.
        allocator.retain(only: [a, c])
        let d = IPv4Address("239.255.0.4")!
        XCTAssertEqual(allocator.slot(for: d), 1)
        XCTAssertEqual(allocator.slot(for: a), 0, "a kept its slot throughout")
    }

    func testSlotsAreNeverCycled() {
        let allocator = SeriesSlotAllocator(slotCount: 2)
        _ = allocator.slot(for: IPv4Address("239.255.0.1")!)
        _ = allocator.slot(for: IPv4Address("239.255.0.2")!)
        // A third group gets no slot rather than reusing a colour.
        XCTAssertNil(allocator.slot(for: IPv4Address("239.255.0.3")!))
    }
}

final class AggregatorTests: XCTestCase {
    private func packet(group: String, source: String = "10.10.1.50", port: UInt16 = 5568,
                        ttl: UInt8 = 16, bytes: Int = 658, at timestamp: Double) -> ObservedPacket {
        ObservedPacket(timestamp: timestamp, sourceMAC: nil, destinationMAC: nil,
                       vlanIdentifiers: [], source: IPv4Address(source)!,
                       destination: IPv4Address(group)!, ttl: ttl,
                       protocolNumber: IPProtocol.udp, ipTotalLength: bytes,
                       sourcePort: port, destinationPort: port,
                       portsInferredFromFirstFragment: false, isFragment: false, igmp: nil)
    }

    func testStreamsAreKeyedBySourceGroupAndPort() {
        let aggregator = StreamAggregator()
        aggregator.ingest(packet(group: "239.255.0.12", source: "10.0.0.1", port: 5568, at: 100))
        aggregator.ingest(packet(group: "239.255.0.12", source: "10.0.0.2", port: 5568, at: 100))
        aggregator.ingest(packet(group: "239.255.0.12", source: "10.0.0.1", port: 4321, at: 100))
        XCTAssertEqual(aggregator.snapshot(now: 101).streams.count, 3)
    }

    func testIdentityIsAttachedToTheRow() throws {
        let aggregator = StreamAggregator()
        aggregator.ingest(packet(group: "239.255.0.12", port: 5568, at: 100))
        let row = try XCTUnwrap(aggregator.snapshot(now: 101).streams.first)
        XCTAssertEqual(row.identity.name, "sACN (E1.31)")
        XCTAssertEqual(row.identity.detail, "Universe 12")
    }

    func testVaryingTTLIsFlagged() throws {
        let aggregator = StreamAggregator()
        aggregator.ingest(packet(group: "239.255.0.12", ttl: 16, at: 100))
        aggregator.ingest(packet(group: "239.255.0.12", ttl: 1, at: 100.5))
        let row = try XCTUnwrap(aggregator.snapshot(now: 101).streams.first)
        XCTAssertTrue(row.ttlVaries)
        XCTAssertEqual(row.ttl, 1)
    }

    func testSilentStreamsArePrunedSoTheTableShowsNow() {
        let aggregator = StreamAggregator(streamTimeout: 10)
        aggregator.ingest(packet(group: "239.255.0.12", at: 100))
        aggregator.ingest(packet(group: "239.255.0.13", at: 100))
        aggregator.ingest(packet(group: "239.255.0.13", at: 115))

        aggregator.prune(now: 116)
        let groups = aggregator.snapshot(now: 116).streams.map(\.key.group.description)
        XCTAssertEqual(groups, ["239.255.0.13"])
    }

    func testSamplingScalesCountsBackUp() throws {
        let aggregator = StreamAggregator()
        // 1-in-4 sampling: one captured packet stands for four on the wire.
        for second in stride(from: 100.0, through: 104.0, by: 1.0) {
            aggregator.ingest(packet(group: "239.255.0.12", bytes: 1000, at: second), scale: 4)
        }
        let row = try XCTUnwrap(aggregator.snapshot(now: 105).streams.first)
        XCTAssertEqual(row.bitsPerSecond, 32000, accuracy: 0.001)
        XCTAssertEqual(row.packetsPerSecond, 4, accuracy: 0.001)
    }

    func testIGMPCountsTowardTotalsButEarnsNoRow() {
        let aggregator = StreamAggregator()
        let igmp = ObservedPacket(timestamp: 100, sourceMAC: nil, destinationMAC: nil,
                                  vlanIdentifiers: [], source: IPv4Address("10.0.0.1")!,
                                  destination: IPv4Address("224.0.0.22")!, ttl: 1,
                                  protocolNumber: IPProtocol.igmp, ipTotalLength: 40,
                                  sourcePort: nil, destinationPort: nil,
                                  portsInferredFromFirstFragment: false, isFragment: false,
                                  igmp: IGMPMessage(messageType: .v3Report, group: .unspecified,
                                                    maxResponseCode: 0, records: []))
        aggregator.ingest(igmp)
        let snapshot = aggregator.snapshot(now: 101)
        XCTAssertTrue(snapshot.streams.isEmpty)
        XCTAssertGreaterThan(snapshot.totalBitsPerSecond, 0)
    }

    func testChartKeepsTopFiveAndFoldsTheRestIntoOther() {
        let aggregator = StreamAggregator(chartSeriesCount: 5)
        // Eight groups, descending rates.
        for index in 1...8 {
            for second in stride(from: 100.0, through: 104.0, by: 1.0) {
                aggregator.ingest(packet(group: "239.255.0.\(index)", bytes: 1000 * (10 - index), at: second))
            }
        }
        let series = aggregator.snapshot(now: 105).series
        XCTAssertEqual(series.count, 6, "five groups plus Other")
        XCTAssertEqual(series.last?.label, "Other")
        XCTAssertTrue(series.last?.isOther ?? false)
        XCTAssertEqual(series.last?.detail, "3 more groups")

        // The top five are the loudest five, in order.
        XCTAssertEqual(series[0].label, "239.255.0.1")
        XCTAssertEqual(series[4].label, "239.255.0.5")

        // Every charted series has its own palette slot; Other is outside the rotation.
        let slots = series.filter { !$0.isOther }.map(\.colorSlot)
        XCTAssertEqual(Set(slots).count, 5)
        XCTAssertEqual(series.last?.colorSlot, -1)
    }

    func testOtherSumsTheRemainderSecondBySecond() throws {
        let aggregator = StreamAggregator(chartSeriesCount: 1)
        for second in stride(from: 100.0, through: 104.0, by: 1.0) {
            aggregator.ingest(packet(group: "239.255.0.1", bytes: 5000, at: second))
            aggregator.ingest(packet(group: "239.255.0.2", bytes: 1000, at: second))
            aggregator.ingest(packet(group: "239.255.0.3", bytes: 1000, at: second))
        }
        let series = aggregator.snapshot(now: 105).series
        let other = try XCTUnwrap(series.last)
        XCTAssertTrue(other.isOther)
        XCTAssertEqual(other.currentBitsPerSecond, 16000, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(other.values.last), 16000, accuracy: 0.001)
    }

    func testChartWindowLength() {
        let aggregator = StreamAggregator(chartWindowSeconds: 120)
        aggregator.ingest(packet(group: "239.255.0.1", at: 1000))
        let snapshot = aggregator.snapshot(now: 1001)
        XCTAssertEqual(snapshot.seriesSecondOffsets.count, 120)
        XCTAssertEqual(snapshot.seriesSecondOffsets.first, -120)
        XCTAssertEqual(snapshot.seriesSecondOffsets.last, -1)
        XCTAssertEqual(snapshot.series.first?.values.count, 120)
    }

    func testSparklineLength() throws {
        let aggregator = StreamAggregator(sparklineSeconds: 60)
        aggregator.ingest(packet(group: "239.255.0.1", at: 1000))
        let row = try XCTUnwrap(aggregator.snapshot(now: 1001).streams.first)
        XCTAssertEqual(row.sparkline.count, 60)
    }
}
