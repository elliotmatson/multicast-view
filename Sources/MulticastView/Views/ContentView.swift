import SwiftUI
import UniformTypeIdentifiers
import MulticastCore
import MulticastSystem

enum SidePane: Hashable {
    case timeline
    case igmp
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var isExporting = false
    @State private var sidePane: SidePane = .timeline
    /// Built when Export is pressed, not on every render. Passing
    /// `CSVDocument(text: Exporter.csv(...))` straight to .fileExporter
    /// rebuilds the whole table and every finding once a second, for nothing.
    @State private var exportDocument = CSVDocument(text: "")

    var body: some View {
        // A draggable split rather than one long scroll: the table is the thing
        // you stare at, so it gets real height and you decide how much.
        VSplitView {
            dashboard
                .frame(minHeight: 200, idealHeight: 380)
            detail
                .frame(minHeight: 220)
        }
        .frame(minWidth: 820, minHeight: 560)
        .toolbar { toolbarContent }
        .fileExporter(isPresented: $isExporting,
                      document: exportDocument,
                      contentType: .commaSeparatedText,
                      defaultFilename: Exporter.suggestedFilename()) { _ in }
    }

    // MARK: - Top half

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let problem = model.permissionProblem, !model.isCapturing {
                    PermissionView(error: problem) { model.checkPermissions() }
                }
                if case .failed(let message) = model.captureState {
                    FailureBanner(message: message)
                }

                StatTileRow(model: model)
                BandwidthChart(snapshot: model.snapshot, windowSeconds: 120)

                if showEmptyState {
                    EmptyStateView(interfaceName: model.settings.selectedInterface,
                                   secondsRunning: secondsRunning)
                }

                DiagnosticsView(diagnostics: model.diagnostics)
                MembershipPanel(model: model)
            }
            .padding(12)
        }
    }

    // MARK: - Bottom half

    private var detail: some View {
        HSplitView {
            StreamTableView(model: model)
                .frame(minWidth: 420)
            side
                .frame(minWidth: 260, idealWidth: 330, maxWidth: 460)
        }
    }

    /// Two panes rather than one long scroll, so the queriers verdict stays
    /// visible while the activity below it fills up.
    private var side: some View {
        VSplitView {
            QueriersView(queriers: model.queriers, diagnostics: model.diagnostics)
                .padding(10)
                .frame(minHeight: 130)

            VStack(spacing: 6) {
                Picker("", selection: $sidePane) {
                    Text("Timeline").tag(SidePane.timeline)
                    Text("IGMP").tag(SidePane.igmp)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch sidePane {
                case .timeline:
                    TimelineView(events: model.sessionEvents,
                                 fileName: model.sessionFileName,
                                 writeError: model.sessionWriteError,
                                 onReveal: { model.revealSessionLogs() })
                case .igmp:
                    IGMPLogView(events: model.igmpEvents)
                }
            }
            .padding(10)
            .frame(minHeight: 180)
        }
    }

    private var showEmptyState: Bool {
        model.captureState == .running && !model.hasAnyTraffic && secondsRunning > 3
    }

    private var secondsRunning: Double {
        guard let started = model.captureStartedAt else { return 0 }
        return Date().timeIntervalSince1970 - started
    }

    // MARK: - Toolbar
    //
    // Only the things that act on the whole session live here. The search field
    // and the family filter scope the stream table alone, so they sit with it.

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            InterfacePicker(model: model)
        }
        ToolbarItem {
            Button {
                model.isCapturing ? model.stop() : model.start()
            } label: {
                Label(model.isCapturing ? "Stop" : "Start",
                      systemImage: model.isCapturing ? "stop.fill" : "play.fill")
            }
            .help(model.isCapturing ? "Stop capturing" : "Start capturing")
        }
        ToolbarItem {
            Button {
                model.togglePause()
            } label: {
                Label(model.captureState == .paused ? "Resume" : "Pause",
                      systemImage: model.captureState == .paused ? "play.circle" : "pause.circle")
            }
            .disabled(!model.isCapturing)
            .help("Freeze the display. The capture keeps draining so the kernel buffer does not overflow.")
        }
        ToolbarItem {
            Button {
                exportDocument = CSVDocument(text: Exporter.csv(model: model))
                isExporting = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export the streams currently shown, and the findings, as CSV")
        }
    }
}

private struct FailureBanner: View {
    let message: String

    var body: some View {
        GroupBox {
            Label(message, systemImage: "exclamationmark.octagon.fill")
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Toolbar pieces

struct InterfacePicker: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Picker("Interface", selection: interfaceBinding) {
            ForEach(model.interfaces) { interface in
                Text(label(for: interface)).tag(interface.name as String?)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(minWidth: 180, maxWidth: 260)
        .help(helpText)
        .disabled(model.isCapturing)
    }

    private var interfaceBinding: Binding<String?> {
        Binding(get: { model.settings.selectedInterface },
                set: { model.settings.selectedInterface = $0 })
    }

    /// Noisy and unhelpful interfaces are marked rather than hidden: awdl0 is
    /// the most common reason a Mac capture is unreadable, and it is better to
    /// explain it than to silently leave it out.
    private func label(for interface: NetworkInterfaceInfo) -> String {
        var text = interface.title
        switch interface.kind {
        case .appleWirelessDirect: text += "  \u{26A0} AirDrop chatter"
        case .vpn:                 text += "  \u{26A0} VPN"
        case .loopback:            text += "  \u{26A0} loopback"
        case .virtual:             text += "  \u{26A0} virtual"
        case .wireless:            text += "  \u{26A0} Wi-Fi"
        case .vlan:                text += "  \u{00B7} VLAN sub-interface"
        case .wired, .other:       break
        }
        if !interface.isUp { text += "  \u{00B7} down" }
        return text
    }

    private var helpText: String {
        guard let interface = model.selectedInterfaceInfo else {
            return "Pick the interface to capture on."
        }
        return InterfaceAdvice.warning(for: interface) ?? "Capturing on \(interface.title)."
    }
}

struct FamilyFilterMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Menu {
            Button("All families") { model.familyFilter = [] }
            Divider()
            ForEach(ProtocolFamily.filterable, id: \.self) { family in
                Toggle(family.displayName, isOn: binding(for: family))
            }
        } label: {
            Label(title, systemImage: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Filter the stream table by what the traffic is")
    }

    private func binding(for family: ProtocolFamily) -> Binding<Bool> {
        Binding(
            get: { model.familyFilter.contains(family) },
            set: { isOn in
                if isOn { model.familyFilter.insert(family) } else { model.familyFilter.remove(family) }
            })
    }

    private var title: String {
        if model.familyFilter.isEmpty { return "All families" }
        if model.familyFilter.count == 1 { return model.familyFilter.first!.displayName }
        return "\(model.familyFilter.count) families"
    }
}

// MARK: - Local memberships

struct MembershipPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        PanelBox(title: "This Mac's memberships", subtitle: "\(model.memberships.count) joins") {
            if model.memberships.isEmpty {
                Text("This Mac has not joined any multicast groups.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), alignment: .leading)],
                          alignment: .leading, spacing: 4) {
                    ForEach(model.memberships) { membership in
                        MembershipRow(membership: membership,
                                      captureInterface: model.settings.selectedInterface)
                    }
                }
            }
        }
    }
}

private struct MembershipRow: View {
    let membership: LocalMembership
    let captureInterface: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(membership.interfaceName)
                .font(.caption.weight(.medium))
                .foregroundColor(isOnCaptureInterface ? .primary : .secondary)
                .frame(width: 56, alignment: .leading)
            Text(membership.group.description)
                .font(.caption.monospaced())
                .foregroundColor(.primary)
            if isSuspect {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundColor(Token.statusWarning)
                    .help("Joined on \(membership.interfaceName), not the capture interface. macOS joins "
                        + "on the interface with the lowest-metric default route, which is often not the "
                        + "AV network.")
            }
            Spacer(minLength: 0)
        }
    }

    private var isOnCaptureInterface: Bool { membership.interfaceName == captureInterface }

    private var isSuspect: Bool {
        !isOnCaptureInterface && !membership.group.isLinkLocalControl
            && !InterfaceAdvice.isNoiseInterface(membership.interfaceName)
    }
}
