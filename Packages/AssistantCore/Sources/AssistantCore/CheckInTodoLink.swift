import Foundation

/// 打卡类待办 ↔ 打卡计划（服药 / 运动习惯）的关联规则。
///
/// ## 这类待办是「自动关联」出来的
///
/// - 服药待办由 `MedicationTodoMaterializer` 每日物化，标题 `服药：药名（HH:mm）`；
/// - 运动待办由 App 侧调度器生成，标题 `运动：习惯名`。
///
/// 两条链路都要求**正向与反向都通**：
///
/// | 方向 | 含义 | 状态 |
/// |---|---|---|
/// | 正向 | 打卡动作（吃药 / 运动打卡）→ 计划状态更新 + 待办完成 | 已通 |
/// | 反向 | 待办完成 → 计划状态更新 | **改动前缺失** |
///
/// 反向缺失的后果：用户在待办上直接勾完成，待办确实消失了，**但计划状态没变**——
/// 小组件仍显示「待服 2 次」「待打卡 1 项」，首页汇总数字也不动。用户看到的就是
/// 「点了没反应，但记录确实完成了」。
///
/// ## 本类型只放纯规则
///
/// 标题 ↔ 计划名的映射是纯字符串逻辑，放 Core 才能被单测钉住。
/// 不认识 App 的枚举、不碰数据库：App 层负责把「待办类型」翻译成这里的目标。
public enum CheckInTodoLink {

    // MARK: - 运动打卡待办

    /// 运动打卡待办标题前缀。
    ///
    /// 此前生成端（App 调度器）与匹配端（小组件指令处理）各写了一份
    /// `"运动：\\(name)"` 字面量，两边漂移就会「打卡了但待办没完成」。
    /// 现在只有这一处定义。
    public static let habitTitlePrefix = "运动："

    /// 生成运动打卡待办标题（与解析端同源）。
    public static func habitTodoTitle(habitName: String) -> String {
        habitTitlePrefix + habitName
    }

    /// 解析运动打卡待办标题 → 习惯名。
    ///
    /// 解析不出来一律返回 nil：宁可漏联动，也不能错联动
    /// （「跑步」⊂「夜跑」，错解析会让一个习惯认领另一个习惯的待办）。
    public static func habitName(fromTodoTitle title: String) -> String? {
        guard title.hasPrefix(habitTitlePrefix) else { return nil }
        let name = String(title.dropFirst(habitTitlePrefix.count))
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    // MARK: - 关联目标

    /// 待办关联到的打卡目标。
    public enum Target: Equatable, Sendable {
        /// 关联到某个用药计划（按药名精确匹配）。
        case medication(medName: String)
        /// 关联到某个周期习惯（按习惯名精确匹配）。
        case habit(habitName: String)
    }

    /// 服药待办标题 → 目标（药名）。
    public static func medicationTarget(fromTodoTitle title: String) -> Target? {
        guard let medName = MedicationTodoMaterializer.medName(fromMaterializedTitle: title) else { return nil }
        return .medication(medName: medName)
    }

    /// 运动待办标题 → 目标（习惯名）。
    public static func habitTarget(fromTodoTitle title: String) -> Target? {
        guard let habitName = habitName(fromTodoTitle: title) else { return nil }
        return .habit(habitName: habitName)
    }
}
