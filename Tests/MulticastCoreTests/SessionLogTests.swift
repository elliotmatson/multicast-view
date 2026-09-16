import Foundation
import XCTest
import MulticastCore

final class SessionLogTests: XCTestCase {
    private func stream(_ group: String, port: UInt16 = 5568, rate: Double = 1000,
                        name: String = "sACN (E1.31)", detail: String? = "Universe 12") -> StreamSnapshot {
        StreamSnapshot(key: StreamKey(source: IPv4Address("10.0.0.1")!, group: IPv4Address(group)!,
                                      destinationPort: port, protocolNumber: IPProtocol.udp, vlan: 152),
                       identity: StreamIdentity(name: name, detail: detail, family: .lighting,
                                                confidence: .certain, reason: ""),
                       bitsPerSecond: rate, packetsPerSecond: 44, ttl: 16, ttlVaries: false,
                       sparkline: [], firstSeen: 0, lastSeen: 0, totalPackets: 1, totalBytes: 1,
                       sawFragments: false)
    }

    private func diagnostic(_ id: String, _ severity: DiagnosticSeverity = .critical,
                            title: String = "Two queriers") -> Diagnostic {
        Diagnostic(id: id, severity: severity, title: title, detail: "detail")
    }

    private func update(_ log: SessionLog, streams: [StreamSnapshot] = [],
                        diagnostics: [Diagnostic] = [], queriers: [QuerierRecord] = [],
                        dropped: UInt32 = 0, at now: Double) -> [SessionEvent] {
        log.update(streams: streams, diagnostics: diagnostics, queriers: queriers,
                   totalBitsPerSecond: 1000, totalPacketsPerSecond: 44,
                   droppedPackets: dropped, at: now)
    }

    // MARK: - The case this exists for

    /// A stream that stops mid-service is the thing you come looking for at 2pm.
    func testStreamStoppingIsRecordedWithATimestamp() throws {
        let log = SessionLog(sampleInterval: 1_000_000)
        _ = update(log, streams: [stream("239.255.0.12")], at: 100)
        let events = update(log, streams: [], at: 160)

        let stopped = try XCTUnwrap(events.first { $0.kind == .streamStopped })
        XCTAssertEqual(stopped.timestamp, 160)
        XCTAssertEqual(stopped.severity, .warning)
        XCTAssertTrue(stopped.summary.contains("sACN (E1.31)"))
        XCTAssertTrue(stopped.summary.contains("239.255.0.12"))
        XCTAssertEqual(stopped.fields["group"], "239.255.0.12")
        XCTAssertEqual(stopped.fields["vlan"], "152")
    }

    func testStreamStartingIsRecordedOnce() {
        let log = SessionLog(sampleInterval: 1_000_000)
        let first = update(log, streams: [stream("239.255.0.12")], at: 100)
        XCTAssertEqual(first.filter { $0.kind == .streamAppeared }.count, 1)
        // Still present a second later: not a new event.
        let second = update(log, streams: [stream("239.255.0.12")], at: 101)
        XCTAssertTrue(second.isEmpty)
    }

    /// mDNS and SSDP go quiet between announcements and come back. Recording
    /// every one of those as a stream stopping and starting would bury the one
    /// line that matters.
    func testDiscoveryChatterDoesNotProduceLifecycleEvents() {
        let log = SessionLog(sampleInterval: 1_000_000)
        let mdns = stream("224.0.0.251", port: 5353, name: "mDNS", detail: nil)
        let discovery = StreamSnapshot(
            key: mdns.key,
            identity: StreamIdentity(name: "mDNS", detail: nil, family: .discovery,
                                     confidence: .certain, reason: ""),
            bitsPerSecond: 500, packetsPerSecond: 1, ttl: 255, ttlVaries: false,
            sparkline: [], firstSeen: 0, lastSeen: 0, totalPackets: 1, totalBytes: 1,
            sawFragments: false)

        XCTAssertTrue(update(log, streams: [discovery], at: 100)
            .filter { $0.kind == .streamAppeared }.isEmpty)
        XCTAssertTrue(update(log, streams: [], at: 140)
            .filter { $0.kind == .streamStopped }.isEmpty)
    }

    /// Audio, video, lighting and clock streams are exactly what you want
    /// recorded when they stop.
    func testMediaStreamsStillProduceLifecycleEvents() {
        let log = SessionLog(sampleInterval: 1_000_000)
        XCTAssertEqual(update(log, streams: [stream("239.255.0.12")], at: 100)
            .filter { $0.kind == .streamAppeared }.count, 1)
        XCTAssertEqual(update(log, streams: [], at: 140)
            .filter { $0.kind == .streamStopped }.count, 1)
    }

    // MARK: - Findings

    func testFindingIsRecordedOnceWhenRaisedAndOnceWhenCleared() throws {
        let log = SessionLog(sampleInterval: 1_000_000)
        let raised = update(log, diagnostics: [diagnostic("querier.multiple")], at: 100)
        let findings = raised.filter { $0.kind == .findingRaised }
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].severity, .critical)
        // The first update also lays down a baseline rate sample, so the record
        // has a starting point to compare a later dip against.
        XCTAssertEqual(raised.filter { $0.kind == .sample }.count, 1)

        // Still true: no repeat, or a two-hour service is 7200 identical lines.
        XCTAssertTrue(update(log, diagnostics: [diagnostic("querier.multiple")], at: 101).isEmpty)

        let cleared = update(log, diagnostics: [], at: 200).filter { $0.kind == .findingCleared }
        XCTAssertEqual(cleared.count, 1)
        XCTAssertEqual(cleared[0].timestamp, 200)
        XCTAssertTrue(cleared[0].summary.hasPrefix("Cleared:"))
    }

    func testFindingWhoseWordingChangesIsRecordedAgain() {
        let log = SessionLog(sampleInterval: 1_000_000)
        _ = update(log, diagnostics: [diagnostic("querier.multiple", title: "2 queriers")], at: 100)
        let changed = update(log, diagnostics: [diagnostic("querier.multiple", title: "3 queriers")], at: 101)
        XCTAssertEqual(changed.count, 1)
        XCTAssertEqual(changed[0].fields["changed"], "yes")
        XCTAssertTrue(changed[0].summary.contains("3 queriers"))
    }

    /// Informational notes are the app saying things are fine. Recording them
    /// would bury the transitions that matter.
    func testInformationalDiagnosticsAreNotRecorded() {
        let log = SessionLog(sampleInterval: 1_000_000)
        let events = update(log, diagnostics: [diagnostic("ttl1.expected", .info)], at: 100)
        XCTAssertTrue(events.filter { $0.kind == .findingRaised }.isEmpty)
    }

    // MARK: - Drops

    func testOnlyNewDropsAreRecorded() throws {
        let log = SessionLog(sampleInterval: 1_000_000)
        let first = update(log, dropped: 40, at: 100).filter { $0.kind == .captureDrops }
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].fields["dropped_delta"], "40")

        XCTAssertTrue(update(log, dropped: 40, at: 101).isEmpty, "unchanged total is not a new event")

        let more = update(log, dropped: 105, at: 102).filter { $0.kind == .captureDrops }
        XCTAssertEqual(more[0].fields["dropped_delta"], "65")
        XCTAssertEqual(more[0].fields["dropped_total"], "105")
    }

    // MARK: - Sampling

    func testRateSamplesAreWrittenOnTheInterval() {
        let log = SessionLog(sampleInterval: 10)
        XCTAssertEqual(update(log, at: 100).filter { $0.kind == .sample }.count, 1)
        XCTAssertEqual(update(log, at: 105).filter { $0.kind == .sample }.count, 0)
        XCTAssertEqual(update(log, at: 110).filter { $0.kind == .sample }.count, 1)
    }

    func testSampleCarriesPerGroupRatesNotPerStream() throws {
        let log = SessionLog(sampleInterval: 1)
        let streams = [
            stream("239.255.0.12", port: 5568, rate: 1000),
            stream("239.255.0.12", port: 5569, rate: 500),   // same group, other port
            stream("239.255.0.13", port: 5568, rate: 250),
        ]
        let events = update(log, streams: streams, at: 100)
        let sample = try XCTUnwrap(events.first { $0.kind == .sample })
        // The two streams in one group are summed.
        XCTAssertEqual(sample.fields["g_239.255.0.12"], "1500")
        XCTAssertEqual(sample.fields["g_239.255.0.13"], "250")
        XCTAssertEqual(sample.fields["streams"], "3")
    }

    // MARK: - The written record

    func testJSONLineIsValidAndParsesBack() throws {
        let log = SessionLog(sampleInterval: 1_000_000)
        let events = log.begin(interface: "en7", sampleRate: 4, bufferMegabytes: 8, at: 1_700_000_000)
        let line = try XCTUnwrap(events.first).jsonLine

        let parsed = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        let object = try XCTUnwrap(parsed)
        XCTAssertEqual(object["kind"] as? String, "sessionStart")
        XCTAssertEqual(object["interface"] as? String, "en7")
        XCTAssertEqual(object["sample_rate"] as? String, "1-in-4")
        XCTAssertEqual(object["buffer_mb"] as? String, "8")
        XCTAssertNotNil(object["time"] as? String)
    }

    func testAwkwardTextSurvivesTheEncoding() throws {
        let log = SessionLog(sampleInterval: 1_000_000)
        // A quote, a backslash, a newline and a control character all have to
        // survive, or one odd device name makes the whole log unparseable.
        _ = update(log, diagnostics: [
            Diagnostic(id: "x", severity: .warning,
                       title: "He said \"no\" \\ then\nstopped\u{0007}",
                       detail: "tab\there")], at: 100)
        let line = try XCTUnwrap(log.recent.first { $0.kind == .findingRaised }).jsonLine
        let parsed = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        let object = try XCTUnwrap(parsed)
        XCTAssertEqual(object["summary"] as? String, "He said \"no\" \\ then\nstopped\u{0007}")
        XCTAssertEqual(object["detail"] as? String, "tab\there")
    }

    func testInMemoryRingIsBoundedAndNewestFirst() {
        let log = SessionLog(capacity: 10, sampleInterval: 0)
        for second in 0..<100 { _ = update(log, at: Double(second)) }
        XCTAssertEqual(log.count, 10)
        XCTAssertEqual(log.recent.first?.timestamp, 99)
        XCTAssertEqual(log.recent.last?.timestamp, 90)
    }

    func testBeginResetsPriorState() {
        let log = SessionLog(sampleInterval: 1_000_000)
        _ = update(log, streams: [stream("239.255.0.12")], at: 100)
        _ = log.begin(interface: "en7", sampleRate: 1, bufferMegabytes: 4, at: 200)
        // The stream from the previous session must not be reported as stopped.
        let events = update(log, streams: [], at: 201)
        XCTAssertTrue(events.filter { $0.kind == .streamStopped }.isEmpty)
    }
}
