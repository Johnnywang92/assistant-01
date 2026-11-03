import AssistantCore
import Foundation
import SwiftData

/// 心理疏解动作 → 待办的转换服务。
///
/// ## 为什么建议必须落成真待办
///
/// 「出门走 10 分钟」如果只是一句文案，用户点一下就过去了；
/// 落成一条**能提醒、能打卡**的待办，它才会真的发生。
/// 这也是行为激活（behavioral activation）能起作用的关键：
/// 门槛低到不需要「先有动力」，先做了，感受才会跟上。
///
/// 因此这里直接落库，而不是弹一个需要用户再填一遍标题的表单——
/// 多一次输入就少一半人真的去做。
public enum PsychReliefTodoBuilder {

    /// 把一个疏解动作转成待办并落库。
    ///
    /// - Parameters:
    ///   - action: 疏解动作。
    ///   - dueAt: 建议的执行时间。nil 表示不设时间（只做一条普通待办）。
    ///   - context: SwiftData 上下文。
    /// - Returns: 创建的待办；失败返回 nil（**不谎报成功**）。
    @discardableResult
    static func createTodo(
        for action: PsychReliefAction,
        dueAt: Date? = nil,
        in context: ModelContext
    ) -> TodoItem? {
        // 只有「可转待办」的动作才落库。
        guard action.isConvertibleToTodo else { return nil }

        let todo = TodoItem(
            type: todoType(for: action),
            title: action.title,
            detail: action.detail,
            dueAt: dueAt
        )
        context.insert(todo)
        do {
            try context.save()
            return todo
        } catch {
            return nil
        }
    }

    /// 动作对应的待办类型。
    ///
    /// 复用既有类型而不是新增枚举——`TodoType` 的 rawValue 已进用户数据库，
    /// 新增 case 虽可行但会让所有 TodoType 的穷尽 switch 都要改，收益不抵成本。
    private static func todoType(for action: PsychReliefAction) -> TodoType {
        switch action {
        case .walk, .breathing:
            return .exercise
        case .sleepEarlier:
            return .exercise
        case .reachOut:
            return .general
        case .journal, .speak, .professionalCare:
            return .general
        }
    }
}
