import SwiftUI
import UIKit

// MARK: - 剪贴板投喂检测服务

/// 检测剪贴板新内容并引导投喂，分三层设计以尊重 iOS 剪贴板隐私机制：
///
/// 1. **变化检测（零授权）**：App 回到前台时比对 `UIPasteboard.general.changeCount`
///    与上次已处理的值。changeCount 属于元数据，读取它**不会**触发系统"允许粘贴"弹窗。
/// 2. **类型区分（零授权）**：用 `hasImages` / `hasStrings` / `hasURLs` 判断内容形态，
///    同样不触发授权弹窗——图片（含截图"拷贝并删除"、微信"复制图片"）或文本。
/// 3. **内容读取（按需授权）**：只有用户点了「投喂」或开启了自动投喂后，才真正读
///    `pasteboard.image / string`，此时才可能出现一次系统粘贴授权弹窗。
///
/// 每个 changeCount 只提示一次；用户「忽略」后写入 UserDefaults 不再打扰。
@MainActor
final class ClipboardIngestionService: ObservableObject {
    static let shared = ClipboardIngestionService()

    enum SuggestionKind {
        /// 截图/图片（截图预览"拷贝并删除"、长按图片"拷贝"等）
        case image
        /// 复制的文字（订单信息、账单短信、口令等）
        case text
        /// 仅链接/颜色等暂不支持自动识别的内容 → 占位提示引导手动处理
        case unsupported

        var title: String {
            switch self {
            case .image: return L10n.tr("检测到剪贴板中的新截图/图片")
            case .text: return L10n.tr("检测到剪贴板中复制的新文字")
            case .unsupported: return L10n.tr("剪贴板有新内容，暂不支持自动识别")
            }
        }

        var systemImage: String {
            switch self {
            case .image: return "photo.on.rectangle.angled"
            case .text: return "doc.on.clipboard"
            case .unsupported: return "clipboard.questionmark"
            }
        }
    }

    struct Suggestion: Identifiable, Equatable {
        let id = UUID()
        let kind: SuggestionKind
        let changeCount: Int
    }

    /// 顶部提示条展示的可投喂建议
    @Published var suggestion: Suggestion?

    /// 自动投喂开关（默认开）：检测到新内容时直接进入投喂口并自动拆解
    static let autoIngestKey = "clipboard_auto_ingest_enabled"
    private static let handledKey = "clipboard_last_handled_change_count"

    var autoIngestEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.autoIngestKey) as? Bool ?? true
    }

    private init() {}

    /// App 回到前台时调用：检测剪贴板变化并生成建议（不读取内容、不触发授权）
    func checkOnBecomeActive() {
        let pasteboard = UIPasteboard.general
        let changeCount = pasteboard.changeCount
        let handled = UserDefaults.standard.integer(forKey: Self.handledKey)
        guard changeCount != handled else { return }

        let kind: SuggestionKind
        if pasteboard.hasImages {
            kind = .image
        } else if pasteboard.hasStrings {
            kind = .text
        } else {
            // 仅链接、颜色等，暂无对应填写流程
            kind = .unsupported
        }
        suggestion = Suggestion(kind: kind, changeCount: changeCount)
    }

    /// 标记该 changeCount 已处理，不再重复提示
    func markHandled(_ changeCount: Int) {
        UserDefaults.standard.set(changeCount, forKey: Self.handledKey)
        if suggestion?.changeCount == changeCount {
            suggestion = nil
        }
    }

    /// 读取真实内容并转为投喂载荷。首次调用可能触发系统"允许粘贴"授权弹窗。
    /// 读取失败（用户拒绝）返回 nil，由调用方给出占位提示。
    func resolvePayload() -> OmniboxPayload? {
        let pasteboard = UIPasteboard.general
        if pasteboard.hasImages,
           let image = pasteboard.image ?? pasteboard.images?.first,
           let data = image.jpegData(compressionQuality: 0.85) {
            return .image(data)
        }
        if let text = pasteboard.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return .text(text)
        }
        return nil
    }

    /// 元数据探测：剪贴板当前是否有可粘贴内容（不触发授权，用于投喂口内"一键粘贴"按钮显隐）
    var hasIngestibleContent: Bool {
        let pasteboard = UIPasteboard.general
        return pasteboard.hasImages || pasteboard.hasStrings
    }
}

// MARK: - 顶部提示条

/// 非侵入式引导条：检测到剪贴板新内容时从顶部滑入，用户可投喂/忽略
struct ClipboardSuggestionBanner: View {
    let suggestion: ClipboardIngestionService.Suggestion
    var onIngest: () -> Void
    var onOpenManual: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: suggestion.kind.systemImage)
                    .foregroundStyle(.purple)
                Text(suggestion.kind.title)
                    .font(.footnote.weight(.medium))
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
            }

            if suggestion.kind != .unsupported {
                Button(action: onIngest) {
                    Label(L10n.tr("投喂到万能投喂口"), systemImage: "tray.and.arrow.down.fill")
                        .font(.footnote.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
            } else {
                Button(action: onOpenManual) {
                    Label(L10n.tr("打开投喂口手动处理"), systemImage: "tray.full")
                        .font(.footnote.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.purple.opacity(0.25), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }
}
