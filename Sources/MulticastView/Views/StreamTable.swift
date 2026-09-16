import SwiftUI
import MulticastCore

/// One table row, flattened so the columns can sort on plain comparable values.
struct StreamRow: Identifiable {
    let snapshot: StreamSnapshot
    let switchPorts: String
    let joinedOn: String
    /// Worked out once when the row is built. Deriving it inside the cell means
    /// running the diagnostic and building its strings for every row on every
    /// redraw, once a second.
    let ttlIsSuspect: Bool
    let ttlHelp: String

    var id: StreamKey { snapshot.key }
    var group: String { snapshot.key.group.description }
    var source: String { snapshot.key.source.description }
    var port: Int { Int(snapshot.key.destinationPort ?? 0) }
    var vlan: Int { Int(snapshot.key.vlan ?? 0) }
    var identityText: String { snapshot.identity.displayText }
    var bitsPerSecond: Double { snapshot.bitsPerSecond }
    var packetsPerSecond: Double { snapshot.packetsPerSecond }
    var ttl: Int { Int(snapshot.ttl) }

    init(snapshot: StreamSnapshot, switchPorts: String, joinedOn: String) {
        self.snapshot = snapshot
        self.switchPorts = switchPorts
        self.joinedOn = joinedOn

        let diagnostic = TTLDiagnostics.diagnose(snapshot)
        ttlIsSuspect = diagnostic?.severity == .warning

        var parts: [String] = []
        if let diagnostic { parts.append(diagnostic.detail) }
        if snapshot.ttlVaries {
            parts.append("This stream has been seen with more than one TTL, which usually means two "
                       + "senders are using the same group.")
        }
        ttlHelp = parts.isEmpty ? "Time to live: \(snapshot.ttl)" : parts.joined(separator: "\n\n")
    }
}

struct StreamTableView: View {
    @ObservedObject var model: AppModel
    @State private var sortOrder: [KeyPathComparator<StreamRow>] = [
        .init(\.bitsPerSecond, order: .reverse)
    ]

    var body: some View {
        // Built once per redraw and shared with the header, rather than
        // recomputed (and re-sorted) for each place that needs it.
        let rows = buildRows()
        return VStack(alignment: .leading, spacing: 0) {
            header(rows: rows)
            Table(rows, sortOrder: $sortOrder) {
                TableColumn("Group", value: \.group) { row in
                    Text(row.group).font(.callout.monospaced())
                        .foregroundColor(.primary)
                }
                .width(min: 104, ideal: 112)

                TableColumn("Source", value: \.source) { row in
                    Text(row.source).font(.callout.monospaced())
                        .foregroundColor(.secondary)
                }
                .width(min: 104, ideal: 112)

                TableColumn("Port", value: \.port) { row in
                    Text(row.snapshot.key.portText)
                        .font(.callout.monospaced())
                        .foregroundColor(.secondary)
                }
                .width(min: 42, ideal: 46)

                TableColumn("VLAN", value: \.vlan) { row in
                    Text(row.snapshot.key.vlanText)
                        .font(.callout.monospaced())
                        .foregroundColor(row.snapshot.key.vlan == nil ? Token.textMuted : .secondary)
                        .help(row.snapshot.key.vlan == nil
                              ? "Untagged. Either this is an access port, or the frames arrived without a tag."
                              : "Tagged VLAN \(row.snapshot.key.vlan!). This capture point is a trunk, or a mirror of one.")
                }
                .width(min: 40, ideal: 44)

                TableColumn("Identified as", value: \.identityText) { row in
                    IdentityCell(identity: row.snapshot.identity)
                }
                .width(min: 140, ideal: 172)

                // Trend and current value share a column: macOS 13's Table
                // allows ten, and these two are read together anyway.
                TableColumn("Bitrate \u{00B7} last 60s", value: \.bitsPerSecond) { row in
                    HStack(spacing: 8) {
                        Text(Format.bitRate(row.bitsPerSecond))
                            .font(.callout.monospacedDigit())
                            .foregroundColor(.primary)
                            .frame(width: 72, alignment: .trailing)
                        Sparkline(values: row.snapshot.sparkline,
                                  tint: Token.seriesColor(slot: 0))
                    }
                }
                .width(min: 146, ideal: 154)

                TableColumn("pps", value: \.packetsPerSecond) { row in
                    Text(Format.packetRate(row.packetsPerSecond))
                        .font(.callout.monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 42, ideal: 48)

                TableColumn("TTL", value: \.ttl) { row in
                    TTLCell(row: row)
                }
                .width(min: 44, ideal: 50)

                TableColumn("Switch ports", value: \.switchPorts) { row in
                    Text(row.switchPorts.isEmpty ? "\u{2014}" : row.switchPorts)
                        .font(.callout.monospaced())
                        .foregroundColor(row.switchPorts.isEmpty ? Token.textMuted : .secondary)
                        .help(row.switchPorts.isEmpty
                              ? "No switch reports forwarding this group out of any port."
                              : "Forwarded out of these ports.")
                }
                .width(min: 72, ideal: 88)

                TableColumn("This host joined on", value: \.joinedOn) { row in
                    Text(row.joinedOn.isEmpty ? "\u{2014}" : row.joinedOn)
                        .font(.callout)
                        .foregroundColor(row.joinedOn.isEmpty ? Token.textMuted : .secondary)
                }
                .width(min: 80, ideal: 96)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private func buildRows() -> [StreamRow] {
        let built = model.filteredStreams.map { snapshot in
            StreamRow(snapshot: snapshot,
                      switchPorts: model.switchPorts(for: snapshot.key.group),
                      joinedOn: model.memberships(for: snapshot.key.group).joined(separator: ", "))
        }
        return built.sorted(using: sortOrder)
    }

    private func header(rows: [StreamRow]) -> some View {
        HStack(spacing: 8) {
            Text("Streams").font(.headline)
            Text(countText(rowCount: rows.count))
                .font(.callout.monospacedDigit())
                .foregroundColor(.secondary)

            Spacer(minLength: 12)

            // These two scope this table and nothing else, so they belong here
            // rather than in the window toolbar.
            FamilyFilterMenu(model: model)

            TextField("Group, source, port or protocol", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180, idealWidth: 240, maxWidth: 300)

            if isFiltered {
                Button {
                    model.searchText = ""
                    model.familyFilter = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Clear the filter")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var isFiltered: Bool {
        !model.searchText.isEmpty || !model.familyFilter.isEmpty
    }

    private func countText(rowCount: Int) -> String {
        isFiltered ? "\(rowCount) of \(model.snapshot.streams.count)" : "\(rowCount)"
    }
}

/// The identified-as cell: a coloured mark for the family, the name, and the
/// detail an operator reads first. A low-confidence label is drawn faded, so a
/// wrong guess costs a glance at the port column and nothing more.
struct IdentityCell: View {
    let identity: StreamIdentity

    var body: some View {
        HStack(spacing: 6) {
            SeriesDot(color: familyColor, size: 7)
            Text(identity.name)
                .font(.callout.weight(.medium))
                .foregroundColor(.primary)
                .opacity(nameOpacity)
            if let detail = identity.detail {
                Text(detail)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .opacity(nameOpacity)
            }
            if identity.confidence != .certain {
                Text(identity.confidence == .likely ? "likely" : "guess")
                    .font(.caption2.weight(.medium))
                    .foregroundColor(Token.textMuted)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Token.gridline)
                    .cornerRadius(3)
            }
        }
        .help(identity.reason)
    }

    /// Faded in proportion to how much the label should be trusted.
    private var nameOpacity: Double {
        switch identity.confidence {
        case .certain: return 1.0
        case .likely:  return 0.75
        case .guess:   return 0.5
        }
    }

    private var familyColor: Color {
        switch identity.family {
        case .audio:     return Token.seriesColor(slot: 0)
        case .video:     return Token.seriesColor(slot: 4)
        case .lighting:  return Token.seriesColor(slot: 3)
        case .clock:     return Token.seriesColor(slot: 2)
        case .discovery: return Token.seriesColor(slot: 1)
        case .control:   return Token.seriesColor(slot: 4)
        case .routing:   return Token.seriesOther
        case .unknown:   return Token.seriesOther
        }
    }
}

struct TTLCell: View {
    let row: StreamRow
    private var snapshot: StreamSnapshot { row.snapshot }

    var body: some View {
        HStack(spacing: 3) {
            Text("\(snapshot.ttl)")
                .font(.callout.monospacedDigit())
                .foregroundColor(.primary)
            if row.ttlIsSuspect {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundColor(Token.statusWarning)
            }
            if snapshot.ttlVaries {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.caption2)
                    .foregroundColor(Token.textMuted)
            }
        }
        .help(row.ttlHelp)
    }
}
