import SwiftUI

/// Playback position bar; while dragging it follows the pointer and
/// publishes `preview` for the time label.
struct ScrubBar: View {

    var fraction: Double
    @Binding var preview: Double?
    var enabled: Bool
    var tint: Color = .white
    var onCommit: (Double) -> Void

    @State private var hovering = false

    private var active: Bool { hovering || preview != nil }
    private var barHeight: CGFloat { active ? 5 : 3.5 }
    private var handle: CGFloat { active ? 9 : 0 }

    var body: some View {
        GeometryReader { geo in
            let shown = min(max(preview ?? fraction, 0), 1)
            let filled = shown * geo.size.width

            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.14))
                Capsule().fill(tint.opacity(0.92)).frame(width: filled)

                Circle()
                    .fill(tint)
                    .frame(width: handle, height: handle)
                    .offset(x: filled - handle / 2)
                    .opacity(active ? 1 : 0)
            }
            .frame(height: barHeight)
            // Taller invisible target — a 4pt bar is miserable to hit.
            .frame(height: 14)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard enabled else { return }
                        preview = min(max(value.location.x / geo.size.width, 0), 1)
                    }
                    .onEnded { value in
                        guard enabled else { return }
                        let target = min(max(value.location.x / geo.size.width, 0), 1)
                        preview = nil
                        onCommit(target)
                    }
            )
            .onHover { hovering = enabled && $0 }
            .animation(.easeOut(duration: 0.14), value: active)
            .animation(.easeInOut(duration: 0.7), value: tint)
        }
        .frame(height: 14)
    }
}
