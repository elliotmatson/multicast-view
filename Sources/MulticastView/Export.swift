import SwiftUI
import UniformTypeIdentifiers
import MulticastCore

struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        text = String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

enum Exporter {
    /// The stream table exactly as filtered and shown, so an export matches
    /// what was on screen when something went wrong.
    static func csv(model: AppModel) -> String {
        var lines: [String] = []
        lines.append(["group", "source", "port", "protocol", "detail", "confidence", "family",
                      "bits_per_second", "packets_per_second", "ttl", "ttl_varies",
                      "switch_ports", "joined_on", "total_bytes", "total_packets", "fragmented"]
            .joined(separator: ","))

        for row in model.filteredStreams.sorted(by: { $0.bitsPerSecond > $1.bitsPerSecond }) {
            let fields: [String] = [
                row.key.group.description,
                row.key.source.description,
                row.key.portText,
                row.identity.name,
                row.identity.detail ?? "",
                row.identity.confidence.displayName,
                row.identity.family.displayName,
                String(format: "%.0f", row.bitsPerSecond),
                String(format: "%.1f", row.packetsPerSecond),
                "\(row.ttl)",
                row.ttlVaries ? "yes" : "no",
                model.switchPorts(for: row.key.group),
                model.memberships(for: row.key.group).joined(separator: " "),
                "\(row.totalBytes)",
                "\(row.totalPackets)",
                row.sawFragments ? "yes" : "no",
            ]
            lines.append(fields.map(escape).joined(separator: ","))
        }

        // Findings travel with the data: a table without them loses the point.
        if !model.diagnostics.isEmpty {
            lines.append("")
            lines.append("findings")
            lines.append(["severity", "title", "detail"].joined(separator: ","))
            for diagnostic in model.diagnostics {
                let severity: String
                switch diagnostic.severity {
                case .critical: severity = "critical"
                case .warning:  severity = "warning"
                case .info:     severity = "info"
                }
                lines.append([severity, diagnostic.title, diagnostic.detail].map(escape).joined(separator: ","))
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func suggestedFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "multicast-\(formatter.string(from: Date()))"
    }
}
