import SwiftUI

public struct MurmurWaveformView: View {
    public let levels: [CGFloat]

    public init(levels: [CGFloat]) {
        self.levels = levels
    }

    private var barCount: Int { MurmurTokens.Sizing.waveformBarCount }
    private var maxHeight: CGFloat { MurmurTokens.Sizing.waveformMaxHeight }

    private var displayLevels: [CGFloat] {
        guard !levels.isEmpty else {
            return Array(repeating: 0, count: barCount)
        }
        if levels.count == barCount {
            return Array(levels)
        }
        return (0..<barCount).map { i in
            let sourceIndex = Int(Float(i) / Float(barCount) * Float(levels.count))
            return levels[min(sourceIndex, levels.count - 1)]
        }
    }

    public var body: some View {
        HStack(spacing: MurmurTokens.Sizing.waveformBarSpacing) {
            ForEach(Array(displayLevels.enumerated()), id: \.offset) { _, level in
                WaveformBar(level: level)
            }
        }
        .frame(height: maxHeight)
    }
}

private struct WaveformBar: View {
    let level: CGFloat

    private var barWidth: CGFloat { MurmurTokens.Sizing.waveformBarWidth }
    private var maxHeight: CGFloat { MurmurTokens.Sizing.waveformMaxHeight }
    private var minHeight: CGFloat { MurmurTokens.Sizing.waveformMinBarHeight }

    private var barHeight: CGFloat {
        max(minHeight, level * maxHeight)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: barWidth / 2)
            .fill(MurmurTokens.waveformTint)
            .frame(width: barWidth, height: barHeight)
            .animation(MurmurTokens.Anim.waveformLevel, value: level)
    }
}
