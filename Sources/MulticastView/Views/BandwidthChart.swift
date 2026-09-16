import SwiftUI
import Charts
import MulticastCore

/// Bandwidth over the last two minutes: the top five groups, plus everything
/// else summed into "Other".
///
/// The legend is always present and carries each series' current rate, so
/// identity never rests on colour alone -- which matters because three of the
/// light-mode series steps sit below 3:1 against the chart surface.
struct BandwidthChart: View {
    let snapshot: AggregateSnapshot
    let windowSeconds: Int

    private struct Point: Identifiable {
        let id: String
        let seriesID: String
        let label: String
        let secondsAgo: Int
        let bitsPerSecond: Double
        let color: Color
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if snapshot.series.isEmpty {
                    emptyPlot
                } else {
                    chart
                    legend
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Text("Bandwidth by group")
                Spacer()
                Text("last \(windowSeconds)s").foregroundColor(.secondary)
            }
            .font(.headline)
        }
    }

    private var emptyPlot: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.clear)
            .frame(minHeight: 150, idealHeight: 190)
            .overlay(
                Text("No multicast seen yet")
                    .font(.body)
                    .foregroundColor(Token.textMuted))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Token.gridline, lineWidth: 1))
    }

    private var points: [Point] {
        var result: [Point] = []
        for series in snapshot.series {
            let color = series.isOther ? Token.seriesOther : Token.seriesColor(slot: series.colorSlot)
            let offsets = snapshot.seriesSecondOffsets
            for (index, value) in series.values.enumerated() {
                guard index < offsets.count else { break }
                result.append(Point(id: "\(series.id)#\(index)",
                                    seriesID: series.id,
                                    label: series.label,
                                    secondsAgo: offsets[index],
                                    bitsPerSecond: value,
                                    color: color))
            }
        }
        return result
    }

    private var chart: some View {
        Chart(points) { point in
            // `series:` is what separates the groups. Without it every point
            // joins one line and the whole chart draws in a single colour.
            LineMark(x: .value("Seconds ago", point.secondsAgo),
                     y: .value("Bit/s", point.bitsPerSecond),
                     series: .value("Group", point.seriesID))
                .foregroundStyle(point.color)
                .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
                .interpolationMethod(.monotone)
        }
        .chartLegend(.hidden)      // replaced by the richer legend below
        .chartXAxis {
            AxisMarks(values: .stride(by: 30)) { value in
                AxisGridLine().foregroundStyle(Token.gridline)
                AxisValueLabel {
                    if let seconds = value.as(Int.self) {
                        Text(seconds == 0 ? "now" : "\(seconds)s")
                            .font(.caption)
                            .foregroundColor(Token.textMuted)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Token.gridline)
                AxisValueLabel {
                    if let bits = value.as(Double.self) {
                        Text(Format.bitRate(bits))
                            .font(.caption)
                            .foregroundColor(Token.textMuted)
                    }
                }
            }
        }
        .frame(minHeight: 150, idealHeight: 190, maxHeight: 260)
    }

    private var legend: some View {
        // A grid rather than a row, so entries wrap instead of truncating when
        // the window is narrow. The legend is never hidden: it is what keeps
        // identity off colour alone.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), alignment: .leading)],
                  alignment: .leading, spacing: 6) {
            ForEach(snapshot.series) { series in
                LegendEntry(series: series)
            }
        }
    }
}

private struct LegendEntry: View {
    let series: GroupSeries

    var body: some View {
        HStack(spacing: 5) {
            SeriesDot(color: series.isOther ? Token.seriesOther : Token.seriesColor(slot: series.colorSlot))
            VStack(alignment: .leading, spacing: 0) {
                Text(series.label)
                    .font(.callout.weight(.medium))
                    .foregroundColor(.primary)
                Text(Format.bitRate(series.currentBitsPerSecond))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .help(series.detail ?? series.label)
    }
}
