/// 社交网络分享海报卡片主题
///
/// 从 TodoShareSheet.swift 拆出：主题是纯视觉配置，与分享流程无关。
import AssistantCore
import Photos
import SwiftData
import SwiftUI
import UIKit

/// 社交网络分享海报卡片主题
enum ShareCardTheme: String, CaseIterable, Identifiable {
    case cleanWhite = "极简白"
    case midnight = "暗夜星空"
    case obsidian = "黑曜石成就"
    case paper = "羊皮书卷"

    var id: String { rawValue }

    var backgroundColor: Color {
        switch self {
        case .cleanWhite:
            return Color.white
        case .midnight:
            return Color(red: 0.08, green: 0.09, blue: 0.12)
        case .obsidian:
            return Color(red: 0.05, green: 0.06, blue: 0.08)
        case .paper:
            return Color(red: 0.96, green: 0.94, blue: 0.90)
        }
    }

    var textColor: Color {
        switch self {
        case .cleanWhite, .paper:
            return Color(red: 0.12, green: 0.13, blue: 0.15)
        case .midnight, .obsidian:
            return Color.white
        }
    }

    var secondaryTextColor: Color {
        switch self {
        case .cleanWhite, .paper:
            return Color.secondary
        case .midnight:
            return Color(white: 0.65)
        case .obsidian:
            return Color(red: 0.55, green: 0.60, blue: 0.66)
        }
    }

    var dividerColor: Color {
        switch self {
        case .cleanWhite:
            return Color(.systemGray5)
        case .midnight:
            return Color.white.opacity(0.12)
        case .obsidian:
            return Color(red: 0.18, green: 0.85, blue: 0.48).opacity(0.25)
        case .paper:
            return Color(red: 0.85, green: 0.82, blue: 0.77)
        }
    }

    var accentColor: Color {
        switch self {
        case .obsidian:
            return Color(red: 0.18, green: 0.85, blue: 0.48)
        default:
            return Color.accentColor
        }
    }
}

