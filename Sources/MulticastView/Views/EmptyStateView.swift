import SwiftUI
import MulticastCore
import MulticastSystem

/// What you see when the capture is running and almost nothing is arriving.
///
/// This is the single most important screen in the app to get right, because
/// the most likely reason for an empty table is not a bug: it is that this Mac
/// is plugged into an ordinary access port and is only being shown the traffic
/// addressed to it.
struct EmptyStateView: View {
    let interfaceName: String?
    let secondsRunning: Double

    var body: some View {
        GroupBox { content } label: {
            Label("Almost nothing on \(interfaceName ?? "this interface")",
                  systemImage: "dot.radiowaves.left.and.right")
                .font(.headline)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                EmptyView()
            }
            .frame(height: 0)

            Text("This is usually correct behaviour rather than a fault. A switch only sends a port "
               + "the multicast that port has asked for, so plugged into an ordinary wall port you see "
               + "your own traffic and the groups this Mac has joined \u{2014} and very little else.")
                .font(.body)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Advice(icon: "arrow.triangle.branch",
                       title: "To see a whole VLAN you need a mirror",
                       detail: "Configure a SPAN/mirror port on the switch, or put a network tap inline, "
                             + "and plug this Mac into that.")
                Advice(icon: "arrow.up.arrow.down.circle",
                       title: "Mirror an uplink, not an endpoint",
                       detail: "Mirroring the link between two switches shows you everything crossing "
                             + "between them. Mirroring a single endpoint port only ever shows you that "
                             + "one device, which is rarely the problem.")
                Advice(icon: "wifi.slash",
                       title: "Check you are on the right adapter",
                       detail: "On a Mac the AV network is usually a Thunderbolt or USB adapter, not "
                             + "en0. Wi-Fi and awdl0 will never show you the Dante VLAN.")
            }

            if secondsRunning > 5 {
                Text("Capturing for \(Int(secondsRunning))s.")
                    .font(.callout)
                    .foregroundColor(Token.textMuted)
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
        .padding(4)
    }
}

private struct Advice: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundColor(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundColor(.primary)
                Text(detail)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Shown when no BPF device can be opened. This is the ChmodBPF case and it
/// gets a completely different explanation from "capture failed".
struct PermissionView: View {
    let error: CaptureError
    let onRecheck: () -> Void

    var body: some View {
        GroupBox { content } label: {
            Label(error.errorDescription ?? "Cannot capture", systemImage: "lock.fill")
                .font(.headline)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let suggestion = error.recoverySuggestion {
                Text(suggestion)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("Check again", action: onRecheck)
                if isPermission {
                    Link("Wireshark download", destination: URL(string: "https://www.wireshark.org/download.html")!)
                        .font(.callout)
                }
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
        .padding(4)
    }

    private var isPermission: Bool {
        if case .permissionDenied = error { return true }
        return false
    }
}
