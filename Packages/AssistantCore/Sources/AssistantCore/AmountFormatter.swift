import Foundation

/// 金额与剂量的统一格式化（纯函数，无平台依赖）。
///
/// 规则：整数省略小数位，一位小数保留一位，其余保留两位（0/1/2 三档）。
/// 同一笔 1500.5 在任何上下文都渲染为 "1500.5"，不再出现 "1500.50" 的分歧。
///
/// 原先 5 处各自实现（ExpenseCurrency / QueryAnswerBuilder / VoiceIntentProcessor /
/// ShareInboxService / HabitAndMedicationView），舍入规则各不相同。
/// 收敛后各调用点改为一行转发，行为差异仅由「是否带货币符号」和「是否取绝对值」两个参数表达。
public enum AmountFormatter {

    /// 裸数字（不带货币符号）。用于语音回执、查询回答、分享导入、药品剂量。
    ///
    /// 边界行为：
    /// - 0 → "0"
    /// - 整数（含极大值）→ 无小数位
    /// - 一位小数 suffices → 保留一位
    /// - 其余 → 保留两位（四舍五入）
    /// - 负数 → 带 "-" 前缀
    public static func format(_ value: Double) -> String {
        let rounded2 = (value * 100).rounded() / 100
        if rounded2 == rounded2.rounded() {
            return String(format: "%.0f", rounded2)
        }
        let rounded1 = (value * 10).rounded() / 10
        if rounded2 == rounded1 {
            return String(format: "%.1f", rounded2)
        }
        return String(format: "%.2f", rounded2)
    }

    /// 带货币符号。用于记账展示。
    ///
    /// `absolute` = true（默认）时取绝对值：支出/收入由 UI 红绿色与标签表达，
    /// 数字本身不带符号（沿用 `ExpenseCurrency.formatAmount` 的既有语义）。
    /// `absolute` = false 时保留正负号。
    public static func format(_ value: Double, currency: ExpenseCurrency, absolute: Bool = true) -> String {
        let v = absolute ? Swift.abs(value) : value
        let sign = v < 0 ? "-" : ""
        return "\(sign)\(currency.symbol)\(format(Swift.abs(v)))"
    }
}
