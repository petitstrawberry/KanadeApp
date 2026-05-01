import SwiftUI

enum ShellChromeSuppressionReason: Hashable {
    case editing
}

@MainActor
@Observable
final class ShellUIState {
    private var chromeSuppressionReasons: [UUID: ShellChromeSuppressionReason] = [:]

    #if os(macOS)
    var isQueuePanelPresented = false
    #endif

    var isChromeSuppressed: Bool {
        !chromeSuppressionReasons.isEmpty
    }

    @discardableResult
    func beginChromeSuppression(reason: ShellChromeSuppressionReason) -> UUID {
        let id = UUID()
        chromeSuppressionReasons[id] = reason
        return id
    }

    func endChromeSuppression(_ id: UUID?) {
        guard let id else { return }
        chromeSuppressionReasons.removeValue(forKey: id)
    }
}

private struct ShellChromeSuppressionModifier: ViewModifier {
    @Environment(ShellUIState.self) private var shellUI
    let isActive: Bool
    let reason: ShellChromeSuppressionReason

    @State private var token: UUID?

    func body(content: Content) -> some View {
        content
            .onAppear {
                updateSuppression(isActive: isActive)
            }
            .onChange(of: isActive) {
                updateSuppression(isActive: isActive)
            }
            .onDisappear {
                shellUI.endChromeSuppression(token)
                token = nil
            }
    }

    private func updateSuppression(isActive: Bool) {
        if isActive {
            if token == nil {
                token = shellUI.beginChromeSuppression(reason: reason)
            }
        } else {
            shellUI.endChromeSuppression(token)
            token = nil
        }
    }
}

extension View {
    func shellChromeSuppressed(_ isActive: Bool, reason: ShellChromeSuppressionReason) -> some View {
        modifier(ShellChromeSuppressionModifier(isActive: isActive, reason: reason))
    }
}
