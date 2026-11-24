import SwiftUI

/// A tiny equaliser while something plays, driven by time (no state to stick).
struct AudioBars: View {

    var isPlaying: Bool
    var color: Color = .white
    /// Set while the display is asleep. Redrawing behind a dark screen is the
    /// purest waste there is.
    var isSuspended = false

    private static let speeds: [Double] = [3.7, 4.6, 3.1, 4.1]
    private static let offsets: [Double] = [0.0, 0.9, 1.8, 2.6]
    private static let minHeight: CGFloat = 2.5
    private static let maxHeight: CGFloat = 12

    /// 12 fps: it's on screen most of the day.
    private static let frameRate = 12.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / Self.frameRate,
                                paused: !isPlaying || isSuspended)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(color)
                        .frame(width: 2, height: height(index, at: time))
                }
            }
        }
        .frame(width: 14, height: Self.maxHeight)
        .opacity(isPlaying ? 1 : 0.45)
        .animation(.easeOut(duration: 0.2), value: isPlaying)
        // Long and gentle: the colour is ambient, and a fast swap between two
        // saturated album colours reads as a glitch rather than a transition.
        .animation(.easeInOut(duration: 0.7), value: color)
    }

    private func height(_ index: Int, at time: TimeInterval) -> CGFloat {
        guard isPlaying else { return Self.minHeight }
        let wave = (sin(time * Self.speeds[index] + Self.offsets[index]) + 1) / 2
        return Self.minHeight + CGFloat(wave) * (Self.maxHeight - Self.minHeight)
    }
}
