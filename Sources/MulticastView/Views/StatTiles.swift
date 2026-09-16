import SwiftUI
import MulticastCore

struct StatTileRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        // Wraps rather than squashing: four across on a wide window, two or one
        // when it is narrow.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)],
                  alignment: .leading, spacing: 10) {
            HeroTile(bitsPerSecond: model.snapshot.totalBitsPerSecond,
                     isRunning: model.captureState == .running,
                     understated: understated)
            StatTile(title: "Active streams",
                     value: Format.count(model.snapshot.streams.count),
                     caption: streamCaption)
            StatTile(title: "Packets/sec",
                     value: Format.packetRate(model.snapshot.totalPacketsPerSecond),
                     caption: samplingCaption)
            StatTile(title: "IGMP events/min",
                     value: "\(model.igmpEventsPerMinute)",
                     caption: querierCaption)
        }
    }

    private var understated: Bool {
        (model.captureStatistics?.dropped ?? 0) > 0
    }

    private var streamCaption: String {
        let groups = Set(model.snapshot.streams.map(\.key.group)).count
        return "\(groups) group\(groups == 1 ? "" : "s")"
    }

    private var samplingCaption: String? {
        let rate = model.settings.sampleRate
        return rate > 1 ? "sampled 1-in-\(rate), scaled up" : nil
    }

    private var querierCaption: String {
        let count = model.queriers.count
        if count == 0 { return "no querier seen" }
        return "\(count) querier\(count == 1 ? "" : "s")"
    }
}

/// The headline figure: total multicast on the wire, set large.
struct HeroTile: View {
    let bitsPerSecond: Double
    let isRunning: Bool
    let understated: Bool

    var body: some View {
        let parts = Format.bitRateParts(bitsPerSecond)
        GroupBox {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(parts.value)
                        .font(.system(.largeTitle, design: .default).weight(.semibold))
                        .foregroundColor(.primary)
                    Text(parts.unit)
                        .font(.title3.weight(.medium))
                        .foregroundColor(.secondary)
                }
                captionRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Total multicast").font(.headline)
        }
    }

    @ViewBuilder
    private var captionRow: some View {
        if understated {
            Label("understated \u{2014} capture is dropping", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(.secondary)
        } else if !isRunning {
            Text("not capturing").font(.caption).foregroundColor(.secondary)
        } else {
            Text("across all groups").font(.caption).foregroundColor(.secondary)
        }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var caption: String?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title.weight(.semibold))
                    .foregroundColor(.primary)
                Text(caption ?? " ")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title).font(.headline)
        }
    }
}
