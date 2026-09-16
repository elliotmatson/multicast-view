import Foundation

/// The kinds of thing worth being able to look up after the fact.
public enum SessionEventKind: String, Codable, Sendable {
    case sessionStart
    case sessionEnd
    case findingRaised
    case findingCleared
    case streamAppeared
    case streamStopped
    case querierChanged
    case captureDrops
    /// A periodic rate sample, so a dip is visible even where nothing else
    /// changed.
    case sample

    public var displayName: String {
        switch self {
        case .sessionStart:    return "Capture started"
        case .sessionEnd:      return "Capture stopped"
        case .findingRaised:   return "Finding"
        case .findingCleared:  return "Cleared"
        case .streamAppeared:  return "Stream started"
        case .streamStopped:   return "Stream stopped"
        case .querierChanged:  return "Querier change"
        case .captureDrops:    return "Capture drops"
        case .sample:          return "Sample"
        }
    }
}

public struct SessionEvent: Identifiable, Equatable, Sendable {
    public let id: UInt64
    public let timestamp: Double
    public let kind: SessionEventKind
    public let severity: DiagnosticSeverity
    /// One line, readable on its own six hours later.
    public let summary: String
    public let detail: String?
    /// Structured extras, written to the log for later grepping.
    public let fields: [String: String]

    public init(id: UInt64, timestamp: Double, kind: SessionEventKind,
                severity: DiagnosticSeverity = .info, summary: String,
                detail: String? = nil, fields: [String: String] = [:]) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.severity = severity
        self.summary = summary
        self.detail = detail
        self.fields = fields
    }

    /// One JSON object per line: appendable while the capture runs, readable
    /// with grep or jq afterwards, and no dependency to write it.
    public var jsonLine: String {
        var parts: [String] = []
        parts.append("\"t\":\(String(format: "%.3f", timestamp))")
        parts.append("\"time\":\(JSON.quote(SessionEvent.isoFormatter.string(from: Date(timeIntervalSince1970: timestamp))))")
        parts.append("\"kind\":\(JSON.quote(kind.rawValue))")
        parts.append("\"severity\":\(JSON.quote(severityName))")
        parts.append("\"summary\":\(JSON.quote(summary))")
        if let detail { parts.append("\"detail\":\(JSON.quote(detail))") }
        for key in fields.keys.sorted() {
            parts.append("\(JSON.quote(key)):\(JSON.quote(fields[key]!))")
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    public var severityName: String {
        switch severity {
        case .critical: return "critical"
        case .warning:  return "warning"
        case .info:     return "info"
        }
    }

    static let isoFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return formatter
    }()
}

public enum JSON {
    /// Minimal RFC 8259 string escaping. Control characters have to go, or a
    /// device name with a stray byte in it makes the whole log unparseable.
    public static func quote(_ text: String) -> String {
        var out = "\""
        for character in text.unicodeScalars {
            switch character {
            case "\"":  out += "\\\""
            case "\\":  out += "\\\\"
            case "\n":  out += "\\n"
            case "\r":  out += "\\r"
            case "\t":  out += "\\t"
            default:
                if character.value < 0x20 {
                    out += String(format: "\\u%04x", character.value)
                } else {
                    out.unicodeScalars.append(character)
                }
            }
        }
        return out + "\""
    }
}
