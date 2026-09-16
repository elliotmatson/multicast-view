import SwiftUI
import MulticastCore

/// A titled section. GroupBox is the stock macOS container, so it picks up the
/// system's own materials, corner radius and appearance handling rather than
/// re-implementing them.
struct PanelBox<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 6) {
                Text(title)
                if let subtitle {
                    Text(subtitle).foregroundColor(.secondary)
                }
            }
            .font(.headline)
        }
    }
}

// MARK: - IGMP activity

struct IGMPLogView: View {
    let events: [IGMPEvent]

    var body: some View {
        PanelBox(title: "IGMP activity", subtitle: events.isEmpty ? nil : "\(events.count) recent") {
            if events.isEmpty {
                Text("No joins, leaves or queries seen yet.")
                    .font(.callout)
                    .foregroundColor(Token.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(events) { event in
                            IGMPEventRow(event: event)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }
}

private struct IGMPEventRow: View {
    let event: IGMPEvent

    var body: some View {
        HStack(spacing: 8) {
            Text(Format.time(event.timestamp))
                .font(.caption.monospaced())
                .foregroundColor(Token.textMuted)
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundColor(tint)
                Text(event.kind.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundColor(.primary)
            }
            .frame(width: 104, alignment: .leading)
            Text(event.groupText)
                .font(.caption.monospaced())
                .foregroundColor(.primary)
            Text("from " + event.source.description)
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
            if !event.sources.isEmpty {
                Text("\(event.sources.count) source\(event.sources.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(Token.textMuted)
            }
            Spacer(minLength: 0)
            Text(event.version)
                .font(.caption2)
                .foregroundColor(Token.textMuted)
        }
        .padding(.vertical, 2)
        .help(helpText)
    }

    private var icon: String {
        switch event.kind {
        case .join:              return "arrow.down.circle.fill"
        case .leave:             return "arrow.up.circle.fill"
        case .partialWithdrawal: return "minus.circle.fill"
        case .generalQuery:      return "questionmark.circle.fill"
        case .groupQuery:        return "questionmark.circle"
        case .report:            return "info.circle"
        }
    }

    // Status colours stay out of the series rotation, and never carry the
    // meaning alone -- each one sits beside its own word.
    private var tint: Color {
        switch event.kind {
        case .join:              return Token.statusGood
        case .leave:             return Color.secondary
        case .partialWithdrawal: return Token.statusSerious
        case .generalQuery, .groupQuery, .report: return Color.secondary
        }
    }

    private var helpText: String {
        if event.sources.isEmpty { return "\(event.kind.displayName) \(event.groupText) from \(event.source)" }
        return "\(event.kind.displayName) \(event.groupText) from \(event.source)\nSources: "
             + event.sources.map(\.description).joined(separator: ", ")
    }
}

// MARK: - Queriers

struct QueriersView: View {
    let queriers: [QuerierRecord]
    let diagnostics: [Diagnostic]

    fileprivate struct VLANGroup: Identifiable {
        let vlan: UInt16?
        let records: [QuerierRecord]
        var id: String { vlan.map(String.init) ?? "untagged" }
        var label: String { vlan.map { "VLAN \($0)" } ?? "Untagged" }
        /// More than one querier on one VLAN is the fault; many VLANs each
        /// with one querier is a healthy trunk.
        var isContested: Bool { records.count > 1 }
    }

    var body: some View {
        PanelBox(title: "IGMP queriers",
                 subtitle: groups.count > 1 ? "\(groups.count) VLANs" : nil) {
            VStack(alignment: .leading, spacing: 8) {
                if let verdict {
                    DiagnosticBanner(diagnostic: verdict)
                }
                if queriers.isEmpty {
                    Text("Nothing on this segment has sent an IGMP query yet.")
                        .font(.callout)
                        .foregroundColor(Token.textMuted)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(groups) { group in
                                VLANQuerierRow(group: group)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        }
    }

    /// Contested VLANs first: those are the ones to act on.
    private var groups: [VLANGroup] {
        var byVLAN: [UInt16?: [QuerierRecord]] = [:]
        for record in queriers { byVLAN[record.vlan, default: []].append(record) }
        let built = byVLAN.map { vlan, records in
            VLANGroup(vlan: vlan, records: records.sorted { $0.queryCount > $1.queryCount })
        }
        return built.sorted { lhs, rhs in
            if lhs.isContested != rhs.isContested { return lhs.isContested }
            return (lhs.vlan ?? 0) < (rhs.vlan ?? 0)
        }
    }

    private var verdict: Diagnostic? {
        diagnostics.first { $0.id.hasPrefix("querier.") }
    }
}

private struct VLANQuerierRow: View {
    let group: QueriersView.VLANGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: group.isContested ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundColor(group.isContested ? Token.statusCritical : Token.statusGood)
                Text(group.label)
                    .font(.callout.weight(.semibold))
                    .foregroundColor(.primary)
                if group.isContested {
                    Text("\(group.records.count) queriers")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
            ForEach(group.records) { record in
                HStack(spacing: 6) {
                    Text(record.displayName)
                        .font(.caption.monospaced())
                        .foregroundColor(.primary)
                    Text("\(record.queryCount) quer\(record.queryCount == 1 ? "y" : "ies")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer(minLength: 0)
                    Text(Format.time(record.lastSeen))
                        .font(.caption.monospaced())
                        .foregroundColor(Token.textMuted)
                }
                .padding(.leading, 14)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Diagnostics

struct DiagnosticsView: View {
    let diagnostics: [Diagnostic]

    var body: some View {
        PanelBox(title: "Findings",
                 subtitle: actionable.isEmpty ? "nothing to flag" : "\(actionable.count)") {
            if diagnostics.isEmpty {
                Text("No disagreements between the capture, the switches and this Mac.")
                    .font(.callout)
                    .foregroundColor(Token.textMuted)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(diagnostics) { diagnostic in
                        DiagnosticBanner(diagnostic: diagnostic)
                    }
                }
            }
        }
    }

    private var actionable: [Diagnostic] {
        diagnostics.filter { $0.severity > .info }
    }
}

/// The headline of a finding, for places where the full wording is already
/// shown elsewhere. The detail is still reachable on hover.
struct CompactDiagnosticBanner: View {
    let diagnostic: Diagnostic

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: DiagnosticStyle.icon(diagnostic.severity))
                .font(.callout)
                .foregroundColor(DiagnosticStyle.tint(diagnostic.severity))
            Text(diagnostic.title)
                .font(.callout.weight(.semibold))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DiagnosticStyle.tint(diagnostic.severity).opacity(0.10))
        .cornerRadius(5)
        .help(diagnostic.detail)
    }
}

enum DiagnosticStyle {
    // Icon plus wording, never colour alone.
    static func icon(_ severity: DiagnosticSeverity) -> String {
        switch severity {
        case .critical: return "exclamationmark.octagon.fill"
        case .warning:  return "exclamationmark.triangle.fill"
        case .info:     return "checkmark.circle.fill"
        }
    }

    static func tint(_ severity: DiagnosticSeverity) -> Color {
        switch severity {
        case .critical: return Token.statusCritical
        case .warning:  return Token.statusWarning
        case .info:     return Token.statusGood
        }
    }
}

struct DiagnosticBanner: View {
    let diagnostic: Diagnostic

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.body)
                .foregroundColor(tint)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(diagnostic.title)
                    .font(.callout.weight(.semibold))
                    .foregroundColor(.primary)
                Text(diagnostic.detail)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(tint.opacity(0.08))
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(tint.opacity(0.35), lineWidth: 1))
    }

    private var icon: String { DiagnosticStyle.icon(diagnostic.severity) }
    private var tint: Color { DiagnosticStyle.tint(diagnostic.severity) }
}
