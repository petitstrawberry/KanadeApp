import SwiftUI
import KanadeKit

struct TrackRow: View {
    let track: Track
    let isPlaying: Bool
    let onTap: () -> Void
    var client: KanadeClient?

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isPlaying ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08))
                            .frame(width: 34, height: 34)

                        if isPlaying {
                            PlayingIndicator()
                        } else {
                            Text(trackNumberText)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title ?? "Untitled")
                            .font(.body.weight(isPlaying ? .semibold : .regular))
                            .foregroundStyle(isPlaying ? Color.accentColor : Color.primary)
                            .lineLimit(1)

                        Text(track.artist ?? "Unknown Artist")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 12)

                    Text(formattedDuration)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(isPlaying ? Color.accentColor.opacity(0.08) : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)

            if isHovered && client != nil {
                Button {
                    client?.addToQueue(track)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 32, height: 32)
                        .background(.primary.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(.easeInOut(duration: 0.2), value: isHovered)
    }

    private var formattedDuration: String {
        let total = Int(max(track.durationSecs ?? 0, 0))
        let minutes = total / 60
        let seconds = total % 60
        return "\(minutes):\(String(format: "%02d", seconds))"
    }

    private var trackNumberText: String {
        let num = track.trackNumber ?? 0
        return num > 0 ? "\(num)" : "—"
    }
}

private struct PlayingIndicator: View {
    @State private var phase = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            indicatorBar(height: phase ? 14 : 8, delay: 0)
            indicatorBar(height: phase ? 9 : 15, delay: 0.12)
            indicatorBar(height: phase ? 16 : 10, delay: 0.24)
        }
        .frame(width: 16, height: 16)
        .onAppear {
            phase = true
        }
    }

    private func indicatorBar(height: CGFloat, delay: Double) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.accentColor)
            .frame(width: 3, height: height)
            .animation(
                .easeInOut(duration: 0.6)
                    .repeatForever(autoreverses: true)
                    .delay(delay),
                value: phase
            )
    }
}
