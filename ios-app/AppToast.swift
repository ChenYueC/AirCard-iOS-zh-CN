import SwiftUI

struct AppToast: Identifiable {
    let id = UUID()
    let message: String
}

extension View {
    func toast(_ message: Binding<AppToast?>) -> some View {
        modifier(AppToastModifier(message: message))
    }
}

private struct AppToastModifier: ViewModifier {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @Binding var message: AppToast?
    @State private var horizontalOffset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .center) {
            if let toast = message {
                Text(AppL(toast.message))
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                    .offset(x: horizontalOffset)
                    .padding(.horizontal, 24)
                    .allowsHitTesting(false)
                    .task(id: toast.id) {
                        horizontalOffset = 0
                        do {
                            if !reduceMotion {
                                for offset in [CGFloat(-8), 8, -6, 6, -3, 3, 0] {
                                    withAnimation(.easeInOut(duration: 0.07)) { horizontalOffset = offset }
                                    try await Task.sleep(for: .milliseconds(70))
                                }
                            }
                            try await Task.sleep(for: .seconds(2))
                            guard message?.id == toast.id else { return }
                            message = nil
                        } catch {
                            // A new toast or a dismissed page cancels this presentation.
                        }
                    }
            }
        }
    }
}
