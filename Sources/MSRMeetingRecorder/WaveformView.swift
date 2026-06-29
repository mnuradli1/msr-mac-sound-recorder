import SwiftUI

struct WaveformView: View {
    let samples: [Float]
    let level: Float
    let isActive: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(indicatorColor)
                            .frame(width: 7, height: 7)
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(Int(level * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                GeometryReader { geometry in
                    let bars = animatedSamples(at: timeline.date)
                    let spacing: CGFloat = 3
                    let barWidth = max(3, (geometry.size.width - spacing * CGFloat(max(0, bars.count - 1))) / CGFloat(max(1, bars.count)))
                    HStack(alignment: .center, spacing: spacing) {
                        ForEach(Array(bars.enumerated()), id: \.offset) { index, sample in
                            Capsule()
                                .fill(barColor(index: index, count: bars.count))
                                .frame(width: barWidth, height: max(4, geometry.size.height * CGFloat(sample)))
                                .animation(.easeOut(duration: 0.08), value: sample)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(statusText)
            .accessibilityValue("\(Int(level * 100)) percent")
        }
    }

    private func animatedSamples(at date: Date) -> [Float] {
        let target = 36
        let time = date.timeIntervalSinceReferenceDate
        let padded: [Float]
        if samples.isEmpty {
            padded = Array(repeating: 0.04, count: target)
        } else if samples.count >= target {
            padded = Array(samples.suffix(target))
        } else {
            padded = Array(repeating: 0.04, count: target - samples.count) + samples
        }
        return padded.enumerated().map { index, sample in
            let ripple = isActive && level > 0.02 ? realSignalRipple(index: index, time: time) : 0
            if isActive {
                return max(0.04, min(1.0, sample + ripple))
            }
            return max(0.04, sample * 0.35)
        }
    }

    private func realSignalRipple(index: Int, time: TimeInterval) -> Float {
        let phase = time * 7.0 + Double(index) * 0.62
        let wave = (sin(phase) + 1) / 2
        return Float(wave * Double(level) * 0.18)
    }

    private func barColor(index: Int, count: Int) -> Color {
        guard isActive else {
            return Color.secondary.opacity(0.35)
        }
        let center = Double(count - 1) / 2
        let distance = abs(Double(index) - center) / max(1, center)
        return Color.accentColor.opacity(1.0 - distance * 0.35)
    }

    private var statusText: String {
        guard isActive else { return "Input idle" }
        return level < 0.02 ? "No input signal" : "Input signal"
    }

    private var indicatorColor: Color {
        guard isActive else { return Color.secondary.opacity(0.4) }
        return level < 0.02 ? .orange : .red
    }
}
