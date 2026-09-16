import SwiftUI

/// A 60-second trace of one stream's byte rate.
///
/// Deliberately unlabelled and unscaled against other rows: it answers "is this
/// steady, bursty, or stopping?", and the bitrate column answers "how much?".
struct Sparkline: View {
    let values: [Double]
    let tint: Color

    private static let size = CGSize(width: 64, height: 20)

    var body: some View {
        // Canvas draws straight into one layer. A GeometryReader plus two
        // Paths per row costs far more when sixty-odd rows redraw every second.
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let peak = values.max() ?? 0
            guard peak > 0, values.count > 1 else {
                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: size.height - 1))
                baseline.addLine(to: CGPoint(x: size.width, y: size.height - 1))
                context.stroke(baseline, with: .color(Token.baseline), lineWidth: 1)
                return
            }

            let stepX = size.width / CGFloat(values.count - 1)
            let usableHeight = size.height - 2
            var line = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: CGFloat(index) * stepX,
                                    y: size.height - 1 - CGFloat(value / peak) * usableHeight)
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }

            var filled = line
            filled.addLine(to: CGPoint(x: size.width, y: size.height))
            filled.addLine(to: CGPoint(x: 0, y: size.height))
            filled.closeSubpath()

            context.fill(filled, with: .color(tint.opacity(0.16)))
            context.stroke(line, with: .color(tint),
                           style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
        .frame(width: Sparkline.size.width, height: Sparkline.size.height)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard let peak = values.max(), peak > 0 else { return "No traffic in the last 60 seconds" }
        let active = values.filter { $0 > 0 }.count
        return "Traffic in \(active) of the last \(values.count) seconds"
    }
}

/// A coloured mark that carries identity beside text, so the text itself can
/// stay in an ink colour and remain readable.
struct SeriesDot: View {
    let color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(Token.surface, lineWidth: 1))
            .accessibilityHidden(true)
    }
}
