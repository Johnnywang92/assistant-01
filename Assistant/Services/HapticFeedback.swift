import UIKit

/// 全局触觉与震动反馈引擎
public enum Haptic {
    @MainActor
    public static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @MainActor
    public static func medium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    @MainActor
    public static func heavy() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }

    @MainActor
    public static func impact(style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    @MainActor
    public static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    @MainActor
    public static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    @MainActor
    public static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    @MainActor
    public static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}
