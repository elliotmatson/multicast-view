import Foundation

/// The groupings an AV operator actually thinks in, and the toolbar filter.
public enum ProtocolFamily: String, CaseIterable, Codable, Sendable {
    case audio
    case video
    case lighting
    case clock
    case discovery
    case control
    case routing
    case unknown

    public var displayName: String {
        switch self {
        case .audio:     return "Audio"
        case .video:     return "Video"
        case .lighting:  return "Lighting"
        case .clock:     return "Clock"
        case .discovery: return "Discovery"
        case .control:   return "Control"
        case .routing:   return "Routing"
        case .unknown:   return "Unknown"
        }
    }

    /// The families offered in the toolbar filter, in the order the brief lists them.
    public static var filterable: [ProtocolFamily] {
        [.audio, .video, .lighting, .clock, .discovery, .control, .routing, .unknown]
    }
}

/// How much to trust the label. Drives how faded it is drawn: a wrong guess
/// should cost a glance at the port column and nothing more.
public enum IdentificationConfidence: Int, Comparable, Codable, Sendable {
    /// Range membership only. Says something about scope, not about protocol.
    case guess = 0
    /// A protocol's default port or default address range.
    case likely = 1
    /// Pinned by an IANA assignment or a protocol-specific port.
    case certain = 2

    public static func < (lhs: IdentificationConfidence, rhs: IdentificationConfidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var displayName: String {
        switch self {
        case .guess:   return "Guess"
        case .likely:  return "Likely"
        case .certain: return "Certain"
        }
    }
}

/// What a stream was identified as.
public struct StreamIdentity: Equatable, Codable, Sendable {
    /// Short protocol name, e.g. "sACN (E1.31)".
    public let name: String
    /// The bit an operator reads first, e.g. "Universe 12" or "Domain 0".
    public let detail: String?
    public let family: ProtocolFamily
    public let confidence: IdentificationConfidence
    /// Why the classifier says so. Shown on hover, so a guess can be checked.
    public let reason: String

    public init(name: String, detail: String? = nil, family: ProtocolFamily,
                confidence: IdentificationConfidence, reason: String) {
        self.name = name
        self.detail = detail
        self.family = family
        self.confidence = confidence
        self.reason = reason
    }

    public var displayText: String {
        guard let detail else { return name }
        return "\(name) \u{00B7} \(detail)"
    }

    public static let unidentified = StreamIdentity(
        name: "Unidentified", detail: nil, family: .unknown, confidence: .guess,
        reason: "No matching port assignment or address range.")
}
