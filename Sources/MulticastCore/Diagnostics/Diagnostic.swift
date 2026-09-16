import Foundation

public enum DiagnosticSeverity: Int, Comparable, Sendable {
    case info = 0
    case warning = 1
    case critical = 2

    public static func < (lhs: DiagnosticSeverity, rhs: DiagnosticSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct Diagnostic: Identifiable, Equatable, Sendable {
    public let id: String
    public let severity: DiagnosticSeverity
    public let title: String
    public let detail: String

    public init(id: String, severity: DiagnosticSeverity, title: String, detail: String) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
    }
}
