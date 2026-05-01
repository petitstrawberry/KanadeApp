import SwiftUI

enum HeaderActionButtonStyle {
    case primary
    case secondary
}

struct HeaderActionButtonLabel: View {
    @Environment(\.isEnabled) private var isEnabled

    let title: String
    let systemImage: String
    let style: HeaderActionButtonStyle

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(title)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(foregroundStyle)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            Capsule()
                .fill(backgroundStyle)
        }
        .overlay {
            if style == .secondary {
                Capsule()
                    .strokeBorder(Color.accentColor.opacity(0.24), lineWidth: 1)
            }
        }
        .contentShape(Capsule())
        .opacity(isEnabled ? 1 : 0.5)
    }

    private var foregroundStyle: some ShapeStyle {
        switch style {
        case .primary:
            return AnyShapeStyle(Color.white)
        case .secondary:
            return AnyShapeStyle(Color.accentColor)
        }
    }

    private var backgroundStyle: some ShapeStyle {
        switch style {
        case .primary:
            return AnyShapeStyle(Color.accentColor)
        case .secondary:
            return AnyShapeStyle(Color.accentColor.opacity(0.10))
        }
    }
}
