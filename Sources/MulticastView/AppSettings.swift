import Foundation
import Combine
import MulticastCore
import MulticastSystem

/// Persisted preferences. Small enough to keep as JSON in UserDefaults; there
/// is no document model and nothing here is worth a file on disk.
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    @Published var selectedInterface: String? {
        didSet { defaults.set(selectedInterface, forKey: Keys.interface) }
    }

    @Published var switches: [SNMPSwitch] {
        didSet { save(switches, forKey: Keys.switches) }
    }

    /// Seconds between SNMP polls. Long enough not to hammer a switch CPU
    /// during a service, short enough that the forwarding view is current.
    @Published var pollInterval: Double {
        didSet { defaults.set(pollInterval, forKey: Keys.pollInterval) }
    }

    /// Process one packet in every N. Offered when the capture is dropping.
    @Published var sampleRate: Int {
        didSet { defaults.set(sampleRate, forKey: Keys.sampleRate) }
    }

    /// Kernel capture buffer, in megabytes.
    @Published var bufferMegabytes: Int {
        didSet { defaults.set(bufferMegabytes, forKey: Keys.bufferMegabytes) }
    }

    /// Drop a stream from the table after this many seconds of silence, so
    /// the table reflects now rather than everything ever seen.
    @Published var streamTimeout: Double {
        didSet { defaults.set(streamTimeout, forKey: Keys.streamTimeout) }
    }

    @Published var customRules: [CustomClassificationRule] {
        didSet {
            save(customRules, forKey: Keys.customRules)
            StreamClassifier.customRules = customRules
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedInterface = defaults.string(forKey: Keys.interface)
        switches = AppSettings.load([SNMPSwitch].self, forKey: Keys.switches, from: defaults) ?? []
        pollInterval = defaults.object(forKey: Keys.pollInterval) as? Double ?? 30
        sampleRate = defaults.object(forKey: Keys.sampleRate) as? Int ?? 1
        bufferMegabytes = defaults.object(forKey: Keys.bufferMegabytes) as? Int ?? 4
        streamTimeout = defaults.object(forKey: Keys.streamTimeout) as? Double ?? 30
        customRules = AppSettings.load([CustomClassificationRule].self, forKey: Keys.customRules, from: defaults) ?? []
        StreamClassifier.customRules = customRules
    }

    private func save<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, forKey key: String, from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private enum Keys {
        static let interface = "selectedInterface"
        static let switches = "snmpSwitches"
        static let pollInterval = "snmpPollInterval"
        static let sampleRate = "sampleRate"
        static let bufferMegabytes = "bufferMegabytes"
        static let streamTimeout = "streamTimeout"
        static let customRules = "customClassificationRules"
    }
}
