import Foundation
import SwiftData

/// 落库失败的统一出口。
///
/// 背景：全仓曾有 184 处 `try? context.save()`（视图层 135 / 服务层 46 / 模型 3）。
/// `try?` 把落库失败压成 `nil`，调用方却在下一行播成功震动、回「已记下」、
/// 把通知排出去——磁盘满 / 库损坏 / 迁移残留约束时，用户看到的是成功，
/// 数据其实没落库。这是本项目最伤数据可信度的一类缺陷（见审计报告 UI-01/SVC-04）。
///
/// 用法约定：
/// - **有用户反馈的写路径**：`guard context.saveReportingFailure({ error in
///   showToast("保存失败：\(error.localizedDescription)") }) else { Haptic.warning(); return }`，
///   成功反馈（Haptic.success / 成功文案 / 排通知）放到 `guard` 之后。
/// - **纯派生数据的尽力而为路径**：允许失败，但必须显式说明并至少记录，
///   不要用 `try?` 让它看起来和成功一样。
///
/// 闸门：`scripts/check_save_swallow.py` 禁止新增 `try? ... save()`，存量按文件基线只降不升。
extension ModelContext {

    /// 保存，失败时回滚并回调错误。
    /// - Parameter onFailure: 失败回调（在主线程上下文执行，可安全更新 UI 状态）。
    /// - Returns: 是否保存成功；调用方必须检查返回值再决定是否给成功反馈。
    @discardableResult
    func saveReportingFailure(rollbackOnFailure: Bool = true, _ onFailure: (Error) -> Void) -> Bool {
        do {
            try save()
            return true
        } catch {
            // 不 rollback 的话，失败后 context 里仍留着未落库的改动，
            // 下一次无关的 save 会把它们一起提交——失败会延迟到更晚的地方爆发。
            if rollbackOnFailure { rollback() }
            onFailure(error)
            return false
        }
    }
}
