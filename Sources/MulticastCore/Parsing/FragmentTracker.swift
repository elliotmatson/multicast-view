import Foundation

/// Remembers the UDP ports carried by the first fragment of a datagram so that
/// the trailing fragments can be attributed to the same stream.
///
/// Without this, trailing fragments are read at the transport offset regardless
/// and the first four bytes of payload get interpreted as ports -- which shows
/// up in the table as a phantom stream on a garbage port. A fragmented AES67
/// stream does exactly this.
public final class FragmentTracker {
    public struct Key: Hashable {
        public let source: IPv4Address
        public let destination: IPv4Address
        public let identification: UInt16
        public let protocolNumber: UInt8

        public init(source: IPv4Address, destination: IPv4Address,
                    identification: UInt16, protocolNumber: UInt8) {
            self.source = source
            self.destination = destination
            self.identification = identification
            self.protocolNumber = protocolNumber
        }
    }

    public struct Ports: Equatable {
        public let source: UInt16
        public let destination: UInt16

        public init(source: UInt16, destination: UInt16) {
            self.source = source
            self.destination = destination
        }
    }

    private struct Entry {
        let ports: Ports
        let recordedAt: Double
    }

    private var entries: [Key: Entry] = [:]
    private var insertionOrder: [Key] = []

    public let capacity: Int
    /// Matches the usual IP reassembly timeout; a first fragment older than
    /// this will never be joined by anything.
    public let lifetime: Double

    public init(capacity: Int = 4096, lifetime: Double = 30) {
        self.capacity = max(1, capacity)
        self.lifetime = lifetime
    }

    public var count: Int { entries.count }

    public func record(key: Key, ports: Ports, at now: Double) {
        if entries[key] == nil {
            insertionOrder.append(key)
        }
        entries[key] = Entry(ports: ports, recordedAt: now)
        evictIfNeeded(now: now)
    }

    /// Returns the ports seen on the first fragment, or nil if it was missed
    /// (dropped, or the capture started mid-datagram).
    public func ports(for key: Key, at now: Double) -> Ports? {
        guard let entry = entries[key] else { return nil }
        guard now - entry.recordedAt <= lifetime else {
            entries.removeValue(forKey: key)
            return nil
        }
        return entry.ports
    }

    /// Called once the last fragment arrives; the datagram is complete and the
    /// identification value is free to be reused by the sender.
    public func forget(key: Key) {
        entries.removeValue(forKey: key)
    }

    public func removeAll() {
        entries.removeAll()
        insertionOrder.removeAll()
    }

    private func evictIfNeeded(now: Double) {
        guard entries.count > capacity else { return }
        // Drop from the front of the insertion order until back under the cap.
        var index = 0
        while entries.count > capacity, index < insertionOrder.count {
            let key = insertionOrder[index]
            index += 1
            entries.removeValue(forKey: key)
        }
        insertionOrder.removeFirst(index)
        // Keep the order list from growing without bound when keys are
        // overwritten rather than added.
        if insertionOrder.count > capacity * 2 {
            insertionOrder = insertionOrder.filter { entries[$0] != nil }
        }
    }
}
