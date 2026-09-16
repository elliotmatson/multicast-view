import Foundation
import Combine
import MulticastCore
import MulticastSystem

enum CaptureState: Equatable {
    case stopped
    case running
    case paused
    case failed(String)
}

/// Everything the window renders, and the machinery that keeps it current.
final class AppModel: ObservableObject {

    // MARK: Published state

    @Published private(set) var interfaces: [NetworkInterfaceInfo] = []
    @Published private(set) var captureState: CaptureState = .stopped
    @Published private(set) var snapshot: AggregateSnapshot = .empty
    @Published private(set) var igmpEvents: [IGMPEvent] = []
    @Published private(set) var queriers: [QuerierRecord] = []
    @Published private(set) var diagnostics: [Diagnostic] = []
    @Published private(set) var forwarding: [ResolvedForwarding] = []
    @Published private(set) var memberships: [LocalMembership] = []
    @Published private(set) var captureStatistics: CaptureStatistics?
    @Published private(set) var igmpEventsPerMinute: Int = 0
    @Published private(set) var sessionEvents: [SessionEvent] = []
    @Published private(set) var sessionFileName: String?
    @Published private(set) var snmpStatus: String?
    @Published private(set) var snmpFailures: [String] = []
    @Published private(set) var permissionProblem: CaptureError?

    /// True once the capture has run long enough that "nothing here" is a
    /// finding rather than just an early moment.
    @Published private(set) var captureStartedAt: Double?

    // MARK: Filters, owned here so the toolbar and table agree

    @Published var searchText: String = ""
    @Published var familyFilter: Set<ProtocolFamily> = []

    // MARK: Collaborators

    let settings: AppSettings
    private var aggregator: StreamAggregator
    private let querierTracker = QuerierTracker()
    private let igmpLog = IGMPActivityLog()
    /// The record that outlives the window: what changed, and when.
    private let sessionLog = SessionLog()
    private let sessionWriter = SessionWriter()
    private var capture: BPFCapture?
    private var refreshTimer: Timer?
    private var pollTimer: Timer?
    private let snmpQueue = DispatchQueue(label: "MulticastView.snmp", qos: .utility)
    private var observedGroups = Set<IPv4Address>()
    private var observedVLANs = Set<UInt16>()
    /// Guards everything the capture thread touches: the aggregator, the IGMP
    /// log, the querier tracker and the observed-value sets. Held only for the
    /// duration of an ingest batch or a snapshot, never across UI work.
    private let captureLock = NSLock()
    private var rawForwarding: [GroupForwarding] = []
    private var isPolling = false

    /// Mirrors of state the capture thread needs, so it never reads a
    /// @Published property from off the main thread. Both are written on the
    /// main thread and read on the capture thread, so both live under
    /// `captureLock` like everything else that crosses.
    private var captureIsLive = false
    private var sampleRateForCapture = 1

    private func setCaptureLive(_ live: Bool) {
        captureLock.lock()
        captureIsLive = live
        captureLock.unlock()
    }

    private func setSampleRateForCapture(_ rate: Int) {
        captureLock.lock()
        sampleRateForCapture = max(1, rate)
        captureLock.unlock()
    }

    init(settings: AppSettings = AppSettings()) {
        self.settings = settings
        aggregator = StreamAggregator(streamTimeout: settings.streamTimeout)
        refreshInterfaces()
        refreshMemberships()
        checkPermissions()

        if settings.selectedInterface == nil {
            settings.selectedInterface = InterfaceAdvice.preferredInterface(from: interfaces)?.name
        }
        startRefreshTimer()
        startPollTimer()
    }

    deinit {
        refreshTimer?.invalidate()
        pollTimer?.invalidate()
        capture?.stop()
    }

    // MARK: - Interfaces and permissions

    var sessionLogPath: String? { sessionWriter.url?.path }
    var sessionWriteError: String? { sessionWriter.lastError }

    func revealSessionLogs() { SessionWriter.revealInFinder() }

    func refreshInterfaces() {
        interfaces = NetworkInterfaces.all()
    }

    func checkPermissions() {
        switch BPFCapture.probePermissions() {
        case .success:
            permissionProblem = nil
        case .failure(let error):
            permissionProblem = error
        }
    }

    var selectedInterfaceInfo: NetworkInterfaceInfo? {
        guard let name = settings.selectedInterface else { return nil }
        return interfaces.first { $0.name == name }
    }

    // MARK: - Capture control

    func start() {
        guard capture == nil else { return }
        guard let interfaceName = settings.selectedInterface else {
            captureState = .failed("Pick an interface first.")
            return
        }

        captureLock.lock()
        sampleRateForCapture = max(1, settings.sampleRate)
        aggregator = StreamAggregator(streamTimeout: settings.streamTimeout)
        querierTracker.reset()
        igmpLog.reset()
        observedGroups.removeAll()
        observedVLANs.removeAll()
        captureLock.unlock()
        snapshot = .empty
        igmpEvents = []

        var configuration = BPFCapture.Configuration(interfaceName: interfaceName)
        configuration.bufferBytes = max(1, settings.bufferMegabytes) * 1024 * 1024
        configuration.sampleRate = max(1, settings.sampleRate)

        let session = BPFCapture(configuration: configuration)
        do {
            try session.start(
                onPackets: { [weak self] packets in self?.ingest(packets) },
                onError: { [weak self] error in
                    self?.setCaptureLive(false)
                    self?.captureState = .failed(error.errorDescription ?? "Capture failed")
                    self?.capture = nil
                })
            capture = session
            let startedAt = Date().timeIntervalSince1970
            captureStartedAt = startedAt
            captureState = .running
            setCaptureLive(true)

            sessionWriter.begin(interface: interfaceName)
            sessionFileName = sessionWriter.url?.lastPathComponent
            sessionWriter.append(sessionLog.begin(interface: interfaceName,
                                                  sampleRate: settings.sampleRate,
                                                  bufferMegabytes: settings.bufferMegabytes,
                                                  at: startedAt))
            sessionEvents = sessionLog.recent
            permissionProblem = nil
        } catch let error as CaptureError {
            permissionProblem = error
            captureState = .failed(error.errorDescription ?? "Capture failed")
        } catch {
            captureState = .failed(error.localizedDescription)
        }
    }

    func stop() {
        setCaptureLive(false)
        capture?.stop()
        capture = nil
        if captureStartedAt != nil {
            sessionWriter.append(sessionLog.end(at: Date().timeIntervalSince1970))
            sessionEvents = sessionLog.recent
        }
        sessionWriter.close()
        captureState = .stopped
        captureStartedAt = nil
    }

    func togglePause() {
        switch captureState {
        case .running: captureState = .paused;  setCaptureLive(false)
        case .paused:  captureState = .running; setCaptureLive(true)
        default: break
        }
    }

    var isCapturing: Bool {
        captureState == .running || captureState == .paused
    }

    // MARK: - Ingest

    /// Called on the capture thread, roughly a thousand times a second on a
    /// busy mirror. Everything here happens under the lock and nothing here
    /// touches a @Published property -- the UI picks the results up on its own
    /// timer instead.
    private func ingest(_ packets: [ObservedPacket]) {
        // Paused freezes the display but keeps the capture draining, so the
        // kernel buffer does not overflow while you read the screen.
        captureLock.lock()
        defer { captureLock.unlock() }

        guard captureIsLive else { return }
        let scale = sampleRateForCapture

        for packet in packets {
            aggregator.ingest(packet, scale: scale)
            observedGroups.insert(packet.destination)
            if let vlan = packet.vlanIdentifiers.last { observedVLANs.insert(vlan) }

            guard let message = packet.igmp else { continue }
            igmpLog.record(message, from: packet.source, at: packet.timestamp)
            if message.messageType == .query {
                querierTracker.record(source: packet.source,
                                      sourceMAC: packet.sourceMAC,
                                      vlan: packet.vlanIdentifiers.last,
                                      isGeneralQuery: message.isGeneralQuery,
                                      at: packet.timestamp)
            }
        }
    }

    // MARK: - Periodic refresh

    private func startRefreshTimer() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func refresh() {
        let now = Date().timeIntervalSince1970
        guard captureState == .running else { return }

        captureLock.lock()
        sampleRateForCapture = max(1, settings.sampleRate)
        aggregator.streamTimeout = settings.streamTimeout
        aggregator.prune(now: now)
        let currentSnapshot = aggregator.snapshot(now: now)
        let events = igmpLog.recent(limit: 200)
        let perMinute = igmpLog.eventsPerMinute(now: now)
        let activeQueriers = querierTracker.active(now: now)
        let groups = observedGroups
        let vlans = observedVLANs
        let querierDiagnostics = querierTracker.diagnostics(now: now, captureStarted: captureStartedAt)
        captureLock.unlock()

        snapshot = currentSnapshot
        igmpEvents = events
        igmpEventsPerMinute = perMinute
        queriers = activeQueriers
        visibleVLANs = vlans
        captureStatistics = capture?.statistics()
        forwarding = ForwardingResolver.resolve(rawForwarding, observedGroups: groups)
        rebuildIndexes()
        rebuildDiagnostics(now: now, querierDiagnostics: querierDiagnostics)

        // Record what changed since the last second, then hand it to disk.
        let produced = sessionLog.update(streams: currentSnapshot.streams,
                                         diagnostics: diagnostics,
                                         queriers: activeQueriers,
                                         totalBitsPerSecond: currentSnapshot.totalBitsPerSecond,
                                         totalPacketsPerSecond: currentSnapshot.totalPacketsPerSecond,
                                         droppedPackets: captureStatistics?.dropped ?? 0,
                                         at: now)
        if !produced.isEmpty {
            sessionWriter.append(produced)
            sessionEvents = sessionLog.recent
        }
    }

    private var visibleVLANs = Set<UInt16>()

    private func rebuildDiagnostics(now: Double, querierDiagnostics: [Diagnostic]) {
        var collected: [Diagnostic] = []
        collected += querierDiagnostics

        // Seeing several VLANs at once changes how everything else reads, so
        // say it plainly rather than leaving it to be inferred from the table.
        if visibleVLANs.count > 1 {
            let listed = visibleVLANs.sorted().prefix(12).map(String.init).joined(separator: ", ")
            let more = visibleVLANs.count > 12 ? " and \(visibleVLANs.count - 12) more" : ""
            collected.append(Diagnostic(
                id: "capture.trunk",
                severity: .info,
                title: "Traffic from \(visibleVLANs.count) VLANs is visible here",
                detail: "\(listed)\(more). This interface is a trunk, or a mirror of one, so you are "
                      + "looking at several networks at once rather than one. Querier counts are judged "
                      + "per VLAN. The VLAN column shows which network each stream is on, and the search "
                      + "field filters by it."))
        }
        collected += TTLDiagnostics.diagnose(snapshot.streams)
        collected += CorrelationDiagnostics.diagnose(streams: snapshot.streams,
                                                     forwarding: forwarding,
                                                     snmpAvailable: !rawForwarding.isEmpty,
                                                     memberships: memberships,
                                                     captureInterface: settings.selectedInterface)
        if let statistics = captureStatistics, statistics.dropped > 0 {
            let percent = statistics.dropFraction * 100
            collected.append(Diagnostic(
                id: "capture.drops",
                severity: percent > 1 ? .critical : .warning,
                title: String(format: "Capture dropped %u packets (%.1f%%)", statistics.dropped, percent),
                detail: "The kernel discarded packets the capture could not collect in time, so every rate "
                      + "shown here is understated. Raise the capture buffer in Settings, or turn on 1-in-N "
                      + "sampling so each packet costs less to process."))
        }
        diagnostics = collected.sorted { lhs, rhs in
            lhs.severity == rhs.severity ? lhs.id < rhs.id : lhs.severity > rhs.severity
        }
    }

    // MARK: - Local memberships

    func refreshMemberships() {
        memberships = LocalMemberships.current()
        rebuildIndexes()
    }

    func memberships(for group: IPv4Address) -> [String] {
        membershipIndex[group] ?? []
    }

    /// Built once whenever the inputs change, rather than scanned per table
    /// row on every redraw.
    private var membershipIndex: [IPv4Address: [String]] = [:]
    private var switchPortIndex: [IPv4Address: String] = [:]

    private func rebuildIndexes() {
        var byGroup: [IPv4Address: [String]] = [:]
        for membership in memberships {
            byGroup[membership.group, default: []].append(membership.interfaceName)
        }
        membershipIndex = byGroup

        var ports: [IPv4Address: [ResolvedForwarding]] = [:]
        for row in forwarding where !row.ports.isEmpty {
            guard let group = row.group else { continue }
            ports[group, default: []].append(row)
        }
        var text: [IPv4Address: String] = [:]
        for (group, rows) in ports {
            text[group] = rows.map { row in
                let list = row.ports.map(String.init).joined(separator: ",")
                return rows.count > 1 ? "\(row.switchName):\(list)" : list
            }.joined(separator: " ")
        }
        switchPortIndex = text
    }

    // MARK: - SNMP

    private func startPollTimer() {
        pollTimer?.invalidate()
        let interval = max(5, settings.pollInterval)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshMemberships()
            self?.pollSwitches()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func pollIntervalChanged() {
        startPollTimer()
    }

    func pollSwitches() {
        let devices = settings.switches.filter(\.isUsable)
        guard !devices.isEmpty, !isPolling else {
            if devices.isEmpty {
                rawForwarding = []
                snmpStatus = nil
                snmpFailures = []
            }
            return
        }
        isPolling = true

        snmpQueue.async { [weak self] in
            guard let self else { return }
            let client = SNMPClient()
            var rows: [GroupForwarding] = []
            var failures: [String] = []

            for device in devices {
                do {
                    rows += try client.fetchForwarding(from: device)
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    failures.append("\(device.displayName): \(message)")
                }
            }

            let collected = rows
            let failed = failures
            DispatchQueue.main.async {
                self.rawForwarding = collected
                self.snmpFailures = failed
                let reachable = devices.count - failed.count
                if collected.isEmpty && failed.isEmpty {
                    self.snmpStatus = "\(reachable) switch\(reachable == 1 ? "" : "es") answered, but reported no "
                                    + "multicast forwarding entries. Some switches expose very little of the "
                                    + "Q-BRIDGE MIB and some expose none of it; that is a limit of the switch, "
                                    + "not a failed poll."
                } else if collected.isEmpty {
                    self.snmpStatus = nil
                } else {
                    self.snmpStatus = "\(collected.count) forwarding entries from \(reachable) switch"
                                    + "\(reachable == 1 ? "" : "es")."
                }
                    self.captureLock.lock()
                let groups = self.observedGroups
                self.captureLock.unlock()
                self.forwarding = ForwardingResolver.resolve(collected, observedGroups: groups)
                self.rebuildIndexes()
                self.isPolling = false
            }
        }
    }

    // MARK: - Derived views

    /// The table rows after the search field and family filter.
    var filteredStreams: [StreamSnapshot] {
        var rows = snapshot.streams
        if !familyFilter.isEmpty {
            rows = rows.filter { familyFilter.contains($0.identity.family) }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            rows = rows.filter { row in
                row.key.group.description.contains(query)
                    || row.key.source.description.contains(query)
                    || row.key.portText.contains(query)
                    || row.identity.name.lowercased().contains(query)
                    || (row.identity.detail?.lowercased().contains(query) ?? false)
            }
        }
        return rows
    }

    func switchPorts(for group: IPv4Address) -> String {
        switchPortIndex[group] ?? ""
    }

    var hasAnyTraffic: Bool { !snapshot.streams.isEmpty }
}
