import Foundation

/// 端侧模型动作 JSON 输出的 GBNF 语法约束，与 `ActionCapability` 16 类 schema 一一对应。
///
/// 设计约束：
/// - 只允许输出「至少含一个动作对象」的 JSON 数组：空数组被语法禁止，杜绝模型用小尾巴躲开拆解；
/// - capability 用枚举字面量限定；target/title/memo 等自由文本走通用 text 规则，
///   允许任意非引号字符（含中文），引号与反斜杠必须按 JSON 规则转义；
/// - 文法放 AssistantCore 而非 app target：纯字符串可单测结构完整性，且推理层与测试共用同一份定义。
public enum ActionJSONGrammar {

    /// llama_sampler_init_grammar 的 grammar_root 起始符号名
    public static let rootName = "root"

    /// 完整 GBNF 文法文本
    public static let gbnf = #"""
    root ::= "[" ws action ("," ws action)* ws "]"

    ws ::= [ \t\n\r]*

    action ::= expense-create | expense-update | todo-create | todo-update | todo-complete | todo-cancel | reminder-snooze | query-lookup | memo-inbox | food-record | water-record | storage-record | habit-log | anniversary-create | departure-add | life-record

    expense-create ::= "{" ws "\"capability\":\"expense.create\"" "," ws "\"amount\":\"" number "\"" "," ws "\"isIncome\":\"" is-income "\"" "," ws "\"category\":\"" category "\"" "," ws "\"title\":\"" text "\"" ("," ws "\"dateISO\":\"" datetime "\"")? "}"

    expense-update ::= "{" ws "\"capability\":\"expense.update\"" "," ws "\"target\":\"" text "\"" "," ws "\"newAmount\":\"" number "\"" "}"

    todo-create ::= "{" ws "\"capability\":\"todo.create\"" "," ws "\"title\":\"" text "\"" ("," ws "\"detail\":\"" text "\"" ("," ws "\"dueAtDays\":\"" days "\"" ("," ws "\"dueAtTime\":\"" time "\"")?)?)? "}"

    todo-update ::= "{" ws "\"capability\":\"todo.update\"" "," ws "\"target\":\"" text "\"" ("," ws "\"newTitle\":\"" text "\"" ("," ws "\"dueAtDays\":\"" days "\"")?)? "}"

    todo-complete ::= "{" ws "\"capability\":\"todo.complete\"" "," ws "\"target\":\"" text "\"" "}"

    todo-cancel ::= "{" ws "\"capability\":\"todo.cancel\"" "," ws "\"target\":\"" text "\"" "}"

    reminder-snooze ::= "{" ws "\"capability\":\"reminder.snooze\"" "," ws "\"target\":\"" text "\"" ("," ws "\"duration\":\"" duration "\"")? "}"

    query-lookup ::= "{" ws "\"capability\":\"query.lookup\"" "," ws "\"target\":\"" text "\"" "}"

    memo-inbox ::= "{" ws "\"capability\":\"memo.inbox\"" "," ws "\"memo\":\"" text "\"" "}"

    food-record ::= "{" ws "\"capability\":\"food.record\"" "," ws "\"foodName\":\"" text "\"" ("," ws "\"mealSlot\":\"" meal-slot "\"")? ("," ws "\"calories\":\"" number "\"")? "}"

    water-record ::= "{" ws "\"capability\":\"water.record\"" "," ws "\"beverageType\":\"" beverage-type "\"" "," ws "\"volumeML\":\"" number "\"" ("," ws "\"customName\":\"" text "\"")? "}"

    storage-record ::= "{" ws "\"capability\":\"storage.record\"" "," ws "\"name\":\"" text "\"" "," ws "\"location\":\"" text "\"" ("," ws "\"roomArea\":\"" text "\"")? ("," ws "\"isMedicine\":\"" is-income "\"")? "}"

    habit-log ::= "{" ws "\"capability\":\"habit.log\"" "," ws "\"target\":\"" text "\"" "," ws "\"kind\":\"" habit-kind "\"" ("," ws "\"dosage\":\"" text "\"")? "}"

    anniversary-create ::= "{" ws "\"capability\":\"anniversary.create\"" "," ws "\"title\":\"" text "\"" "," ws "\"category\":\"" anniversary-cat "\"" ("," ws "\"targetDate\":\"" date "\"")? ("," ws "\"price\":\"" text "\"")? "}"

    departure-add ::= "{" ws "\"capability\":\"departure.add\"" "," ws "\"title\":\"" text "\"" ("," ws "\"scene\":\"" text "\"")? ("," ws "\"location\":\"" text "\"")? "}"

    life-record ::= "{" ws "\"capability\":\"life.record\"" "," ws "\"domain\":\"" life-domain "\"" "," ws "\"title\":\"" text "\"" ("," ws "\"detail\":\"" text "\"")? ("," ws "\"value\":\"" number "\"")? "}"

    number ::= "-"? [0-9]+ ("." [0-9]+)?

    days ::= "-"? [0-9]+

    time ::= ("0" [0-9] | "1" [0-9] | "2" [0-3]) ":" [0-5] [0-9]

    date ::= [0-9] [0-9] [0-9] [0-9] "-" [0-9] [0-9] "-" [0-9] [0-9]

    datetime ::= date " " time

    is-income ::= "true" | "false"

    duration ::= "10分钟" | "1小时" | "明早"

    meal-slot ::= "早餐" | "午餐" | "晚餐" | "加餐"

    beverage-type ::= "白开水" | "纯茶" | "黑咖啡" | "拿铁" | "牛奶" | "奶茶" | "含糖饮料" | "苏打水"

    habit-kind ::= "habit" | "medication"

    anniversary-cat ::= "纪念日" | "生日" | "倒数日" | "订阅续费" | "保质期"

    life-domain ::= "pet" | "vehicle" | "child" | "skill" | "document" | "event"

    category ::= "餐饮美食" | "交通出行" | "居家日用" | "购物消费" | "休闲娱乐" | "医疗健康" | "宠物萌宠" | "数码家电" | "人情社交" | "职业收入" | "其它收入" | "其它支出"

    text ::= char*

    char ::= [^"\\\x7F\x00-\x1F] | "\\" (["\\/bfnrt] | "u" hex hex hex hex)

    hex ::= [0-9a-fA-F]
    """#
}
