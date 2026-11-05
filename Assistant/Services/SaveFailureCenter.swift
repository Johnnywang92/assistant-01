import Combine
import SwiftUI

/// 全局「保存失败」提示中心。
///
/// 为什么需要它：全仓曾有 184 处 `try? context.save()`，写失败时既没有提示、
/// 也照常播成功震动。逐页加 toast 会造出十几种不一致的提示样式，所以统一到这里：
/// 写路径调用 `context.saveReportingFailure { SaveFailureCenter.shared.report($0, action: "...") }`，
/// 由 `Assistant/Features/SaveFailureBanner.swift` 里的横幅在根视图顶部显示。
///
/// **放在 Services 而不是 Features**：服务层也要上报失败，反向依赖（Services→Features）
/// 会让分层倒挂；这里只依赖 Combine，不依赖 SwiftUI 视图。
@MainActor
final class SaveFailureCenter: ObservableObject {
    static let shared = SaveFailureCenter()

    /// 当前要展示的失败文案；nil 表示不显示。
    @Published private(set) var message: String?

    private var dismissTask: Task<Void, Never>?

    private init() {}

    /// 上报一次落库失败。
    /// - Parameters:
    ///   - error: 底层错误（会拼进文案，便于用户描述现象）。
    ///   - action: 用户视角的动作名，例如「服药打卡」「记账」「完成待办」。
    func report(_ error: Error, action: String = "保存") {
        message = "\(action)失败：\(error.localizedDescription)"
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        message = nil
    }
}
