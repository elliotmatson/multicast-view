import SwiftUI
import MulticastCore

/// What changed, and when.
///
/// The live table can only answer "what is true now". This answers "what
/// happened at 10:40", which is the question you actually have at 2pm on a
/// Sunday afternoon.
struct TimelineView: View {
    let events: [SessionEvent]
    let fileName: String?
    let writeError: String?
    let onReveal: () -> Void

    @State private var showSamples = false

    var body: some View {
        PanelBox(title: "Timeline", subtitle: subtitle) {
            VStack(alignment: .leading, spacing: 6) {
                controls
                if let writeError {
                    Label("Not being saved: \(writeError)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if visible.isEmpty {
                    Text(events.isEmpty
                         ? "Nothing has changed since the capture started."
                         : "Only rate samples so far. Turn on \u{201C}Show rate samples\u{201D} to see them.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(visible) { event in
                                TimelineRow(event: event)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Toggle("Show rate samples", isOn: $showSamples)
                .toggleStyle(.checkbox)
                .font(.caption)
            Spacer(minLength: 0)
            Button(action: onReveal) {
                Label("Reveal", systemImage: "folder")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .help(fileName.map { "Saved to \($0). Click to open the folder." }
                  ?? "Open the session log folder.")
        }
    }

    private var subtitle: String? {
        guard !events.isEmpty else { return nil }
        return "\(visible.count)"
    }

    private var visible: [SessionEvent] {
        showSamples ? events : events.filter { $0.kind != .sample }
    }
}

private struct TimelineRow: View {
    let event: SessionEvent

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(Format.time(event.timestamp))
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
            Image(systemName: icon)
                .font(.caption2)
                .foregroundColor(tint)
                .frame(width: 12)
            Text(event.summary)
                .font(.caption)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .help(event.detail ?? event.summary)
    }

    // Icon and wording carry the meaning; colour only reinforces it.
    private var icon: String {
        switch event.kind {
        case .sessionStart:   return "play.circle.fill"
        case .sessionEnd:     return "stop.circle.fill"
        case .findingRaised:  return DiagnosticStyle.icon(event.severity)
        case .findingCleared: return "checkmark.circle.fill"
        case .streamAppeared: return "arrow.down.circle.fill"
        case .streamStopped:  return "arrow.up.circle.fill"
        case .querierChanged: return "questionmark.circle.fill"
        case .captureDrops:   return "exclamationmark.triangle.fill"
        case .sample:         return "chart.bar.fill"
        }
    }

    private var tint: Color {
        switch event.kind {
        case .findingCleared: return Token.statusGood
        case .streamAppeared: return Token.statusGood
        case .sample:         return .secondary
        default:              return DiagnosticStyle.tint(event.severity)
        }
    }
}
