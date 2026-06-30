import SwiftUI

struct AudioTransportView: View {
    let isPlaying: Bool
    let currentTime: TimeInterval
    let duration: TimeInterval
    let onTogglePlayPause: () -> Void
    let onSeek: (TimeInterval) -> Void
    let onSeekRelative: (TimeInterval) -> Void

    @State private var isScrubbing = false
    @State private var scrubPosition: TimeInterval = 0

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite else { return "0:00" }
        let total = Int(max(0, time))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var displayTime: TimeInterval {
        isScrubbing ? scrubPosition : currentTime
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onTogglePlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])

            Button(action: { onSeekRelative(-15) }) { EmptyView() }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .frame(width: 0, height: 0)
                .opacity(0)

            Button(action: { onSeekRelative(15) }) { EmptyView() }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .frame(width: 0, height: 0)
                .opacity(0)

            Text(formatTime(displayTime))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { displayTime },
                    set: { scrubPosition = $0 }
                ),
                in: 0...max(duration, 0.01),
                onEditingChanged: { editing in
                    if editing {
                        scrubPosition = currentTime
                        isScrubbing = true
                    } else {
                        onSeek(scrubPosition)
                        isScrubbing = false
                    }
                }
            )

            Text(formatTime(duration))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial)
    }
}
