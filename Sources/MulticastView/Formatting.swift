import Foundation

enum Format {
    /// Bit rates, in the units a network person reads.
    static func bitRate(_ bitsPerSecond: Double) -> String {
        let value = max(0, bitsPerSecond)
        if value < 1_000 { return String(format: "%.0f bit/s", value) }
        if value < 1_000_000 { return String(format: "%.1f kbit/s", value / 1_000) }
        if value < 1_000_000_000 { return String(format: "%.2f Mbit/s", value / 1_000_000) }
        return String(format: "%.2f Gbit/s", value / 1_000_000_000)
    }

    /// Split for the hero tile, which sets the number and the unit differently.
    static func bitRateParts(_ bitsPerSecond: Double) -> (value: String, unit: String) {
        let value = max(0, bitsPerSecond)
        if value < 1_000 { return (String(format: "%.0f", value), "bit/s") }
        if value < 1_000_000 { return (String(format: "%.1f", value / 1_000), "kbit/s") }
        if value < 1_000_000_000 { return (String(format: "%.1f", value / 1_000_000), "Mbit/s") }
        return (String(format: "%.2f", value / 1_000_000_000), "Gbit/s")
    }

    static func packetRate(_ packetsPerSecond: Double) -> String {
        let value = max(0, packetsPerSecond)
        if value < 10 { return String(format: "%.1f", value) }
        if value < 100_000 { return String(format: "%.0f", value) }
        return String(format: "%.0fk", value / 1000)
    }

    static func count(_ value: Int) -> String {
        if value < 10_000 { return "\(value)" }
        if value < 1_000_000 { return String(format: "%.1fk", Double(value) / 1000) }
        return String(format: "%.1fM", Double(value) / 1_000_000)
    }

    static func bytes(_ value: Int) -> String {
        let amount = Double(value)
        if amount < 1024 { return "\(value) B" }
        if amount < 1024 * 1024 { return String(format: "%.1f KB", amount / 1024) }
        if amount < 1024 * 1024 * 1024 { return String(format: "%.1f MB", amount / (1024 * 1024)) }
        return String(format: "%.2f GB", amount / (1024 * 1024 * 1024))
    }

    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func time(_ timestamp: Double) -> String {
        clock.string(from: Date(timeIntervalSince1970: timestamp))
    }

    static func relative(_ seconds: Double) -> String {
        if seconds < 1 { return "now" }
        if seconds < 60 { return String(format: "%.0fs ago", seconds) }
        if seconds < 3600 { return String(format: "%.0fm ago", seconds / 60) }
        return String(format: "%.1fh ago", seconds / 3600)
    }
}
