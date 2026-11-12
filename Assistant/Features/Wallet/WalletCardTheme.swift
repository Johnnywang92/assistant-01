import AssistantCore
import SwiftUI

// MARK: - Apple Wallet 风格视觉组件与质感系统

/// 仿 Apple Wallet 实体卡金属芯片触点（EMV Chip）
struct WalletChipView: View {
    var isGold: Bool = true

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppRadius.badge, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: isGold
                            ? [Color(red: 0.95, green: 0.85, blue: 0.55), Color(red: 0.80, green: 0.65, blue: 0.35)]
                            : [Color(white: 0.88), Color(white: 0.65)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 34, height: 26)
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.badge, style: .continuous)
                        .stroke(Color.black.opacity(0.2), lineWidth: 0.5)
                )

            // 芯片内部分割线
            HStack(spacing: 0) {
                Spacer()
                Rectangle()
                    .fill(Color.black.opacity(0.18))
                    .frame(width: 0.6)
                Spacer()
                Rectangle()
                    .fill(Color.black.opacity(0.18))
                    .frame(width: 0.6)
                Spacer()
            }
            .frame(width: 34, height: 26)

            VStack(spacing: 0) {
                Spacer()
                Rectangle()
                    .fill(Color.black.opacity(0.18))
                    .frame(height: 0.6)
                Spacer()
            }
            .frame(width: 34, height: 26)
        }
        .accessibilityHidden(true)
    }
}

/// 仿 Apple Wallet 射频无感波纹图标
struct WalletContactlessWaveView: View {
    var tintColor: Color = .white.opacity(0.8)

    var body: some View {
        Image(systemName: "wave.3.right")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(tintColor)
            .rotationEffect(.degrees(-90))
            .accessibilityHidden(true)
    }
}

/// 订阅卡片主题色推断
struct SubscriptionCardTheme {
    let backgroundGradient: LinearGradient
    let accentColor: Color
    let iconName: String

    static func theme(for name: String) -> SubscriptionCardTheme {
        let lower = name.lowercased()

        if lower.contains("icloud") || lower.contains("apple") || lower.contains("arcade") || lower.contains("apple one") {
            return SubscriptionCardTheme(
                backgroundGradient: LinearGradient(
                    colors: [Color(red: 0.15, green: 0.16, blue: 0.24), Color(red: 0.08, green: 0.09, blue: 0.14)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                accentColor: Color(red: 0.65, green: 0.75, blue: 1.0),
                iconName: "applelogo"
            )
        } else if lower.contains("spotify") || lower.contains("微信读书") || lower.contains("网易云") || lower.contains("音乐") {
            return SubscriptionCardTheme(
                backgroundGradient: LinearGradient(
                    colors: [Color(red: 0.08, green: 0.38, blue: 0.28), Color(red: 0.04, green: 0.18, blue: 0.14)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                accentColor: Color(red: 0.2, green: 0.9, blue: 0.55),
                iconName: "music.note"
            )
        } else if lower.contains("netflix") || lower.contains("爱奇艺") || lower.contains("优酷") || lower.contains("视频") || lower.contains("tv") {
            return SubscriptionCardTheme(
                backgroundGradient: LinearGradient(
                    colors: [Color(red: 0.55, green: 0.08, blue: 0.14), Color(red: 0.20, green: 0.04, blue: 0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                accentColor: Color(red: 1.0, green: 0.35, blue: 0.45),
                iconName: "play.tv.fill"
            )
        } else if lower.contains("bilibili") || lower.contains("b站") || lower.contains("会员") {
            return SubscriptionCardTheme(
                backgroundGradient: LinearGradient(
                    colors: [Color(red: 0.85, green: 0.25, blue: 0.45), Color(red: 0.40, green: 0.10, blue: 0.22)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                accentColor: Color(red: 1.0, green: 0.7, blue: 0.85),
                iconName: "play.rectangle.fill"
            )
        } else if lower.contains("chatgpt") || lower.contains("openai") || lower.contains("claude") || lower.contains("ai") || lower.contains("copilot") {
            return SubscriptionCardTheme(
                backgroundGradient: LinearGradient(
                    colors: [Color(red: 0.12, green: 0.32, blue: 0.30), Color(red: 0.05, green: 0.15, blue: 0.16)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                accentColor: Color(red: 0.4, green: 0.9, blue: 0.85),
                iconName: "sparkles"
            )
        } else if lower.contains("office") || lower.contains("microsoft") || lower.contains("onedrive") || lower.contains("google") || lower.contains("云盘") {
            return SubscriptionCardTheme(
                backgroundGradient: LinearGradient(
                    colors: [Color(red: 0.12, green: 0.25, blue: 0.55), Color(red: 0.05, green: 0.12, blue: 0.30)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                accentColor: Color(red: 0.45, green: 0.75, blue: 1.0),
                iconName: "cloud.fill"
            )
        } else if lower.contains("健身") || lower.contains("keep") || lower.contains("健康") {
            return SubscriptionCardTheme(
                backgroundGradient: LinearGradient(
                    colors: [Color(red: 0.65, green: 0.30, blue: 0.10), Color(red: 0.28, green: 0.12, blue: 0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                accentColor: Color(red: 1.0, green: 0.65, blue: 0.3),
                iconName: "figure.run"
            )
        } else {
            // 通用高质感钛金紫金卡
            return SubscriptionCardTheme(
                backgroundGradient: LinearGradient(
                    colors: [Color(red: 0.22, green: 0.18, blue: 0.35), Color(red: 0.10, green: 0.08, blue: 0.18)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                accentColor: Color(red: 0.85, green: 0.75, blue: 1.0),
                iconName: "creditcard.fill"
            )
        }
    }
}

/// 物品收纳卡片房间主题色推断
struct StorageRoomCardTheme {
    let backgroundGradient: LinearGradient
    let tagColor: Color
    let iconName: String

    static func theme(for roomArea: String) -> StorageRoomCardTheme {
        switch roomArea {
        case "玄关":
            return StorageRoomCardTheme(
                backgroundGradient: LinearGradient(
                    colors: [Color(red: 0.32, green: 0.24, blue: 0.16), Color(red: 0.15, green: 0.11, blue: 0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                tagColor: Color(red: 0.95, green: 0.75, blue: 0.45),
                iconName: "door.left.hand.open"
            )
        case "主卧", "次卧":
            return StorageRoomCardTheme(
                backgroundGradient: LinearGradient(
                    colors: [Color(red: 0.24, green: 0.18, blue: 0.35), Color(red: 0.11, green: 0.08, blue: 0.18)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                tagColor: Color(red: 0.82, green: 0.68, blue: 0.98),
                iconName: "bed.double.fill"
            )
        case "客厅":
            return StorageRoomCardTheme(
                backgroundGradient: LinearGradient(
                    colors: [Color(red: 0.14, green: 0.24, blue: 0.38), Color(red: 0.07, green: 0.12, blue: 0.20)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                tagColor: Color(red: 0.55, green: 0.80, blue: 1.0),
                iconName: "sofa.fill"
            )
        case "书房":
            return StorageRoomCardTheme(
                backgroundGradient: LinearGradient(
                    colors: [Color(red: 0.12, green: 0.28, blue: 0.24), Color(red: 0.06, green: 0.14, blue: 0.12)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                tagColor: Color(red: 0.50, green: 0.90, blue: 0.75),
                iconName: "books.vertical.fill"
            )
        case "阳台":
            return StorageRoomCardTheme(
                backgroundGradient: LinearGradient(
                    colors: [Color(red: 0.20, green: 0.30, blue: 0.18), Color(red: 0.09, green: 0.15, blue: 0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                tagColor: Color(red: 0.65, green: 0.92, blue: 0.55),
                iconName: "sun.max.fill"
            )
        case "储物间":
            return StorageRoomCardTheme(
                backgroundGradient: LinearGradient(
                    colors: [Color(red: 0.25, green: 0.25, blue: 0.28), Color(red: 0.12, green: 0.12, blue: 0.14)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                tagColor: Color(red: 0.78, green: 0.80, blue: 0.85),
                iconName: "archivebox.fill"
            )
        case "厨房":
            return StorageRoomCardTheme(
                backgroundGradient: LinearGradient(
                    colors: [Color(red: 0.38, green: 0.20, blue: 0.12), Color(red: 0.18, green: 0.09, blue: 0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                tagColor: Color(red: 1.0, green: 0.65, blue: 0.40),
                iconName: "fork.knife"
            )
        default:
            return StorageRoomCardTheme(
                backgroundGradient: LinearGradient(
                    colors: [Color(red: 0.20, green: 0.22, blue: 0.30), Color(red: 0.10, green: 0.11, blue: 0.16)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                tagColor: Color(red: 0.70, green: 0.80, blue: 0.95),
                iconName: "shippingbox.fill"
            )
        }
    }
}

