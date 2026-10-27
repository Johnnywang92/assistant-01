import AppIntents

/// 系统级快捷入口：注册后自动出现在
/// iPhone 快捷指令 App、iPhone 15 Pro Max 操作按钮（Action Button）、敲击背面，
/// 以及 Apple Watch「快捷指令」表盘组件（watchOS 10+ 经 iPhone 远程执行，抬腕即用）。
struct AssistantAppShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: QuickAddExpenseIntent(),
            phrases: [
                "用\(.applicationName)记一笔",
                "\(.applicationName)记账"
            ],
            shortTitle: "一句话记账",
            systemImageName: "yensign.circle.fill"
        )
        AppShortcut(
            intent: QuickAddTodoIntent(),
            phrases: [
                "用\(.applicationName)记个待办",
                "用\(.applicationName)加个待办"
            ],
            shortTitle: "新建待办",
            systemImageName: "checkmark.circle.badge.plus"
        )
        AppShortcut(
            intent: QueryParcelsIntent(),
            phrases: [
                "查\(.applicationName)待取快递",
                "\(.applicationName)取件码上岛"
            ],
            shortTitle: "快递上岛",
            systemImageName: "shippingbox.fill"
        )
        AppShortcut(
            intent: QueryBudgetIntent(),
            phrases: [
                "用\(.applicationName)查预算",
                "\(.applicationName)还剩多少钱",
                "查\(.applicationName)今日支出",
                "\(.applicationName)安心花余额"
            ],
            shortTitle: "查询预算",
            systemImageName: "yensign.circle.fill"
        )
        AppShortcut(
            intent: QueryTodayTodosIntent(),
            phrases: [
                "查\(.applicationName)待办",
                "用\(.applicationName)查今天要做什么",
                "\(.applicationName)今天还有什么事"
            ],
            shortTitle: "今日待办",
            systemImageName: "checklist"
        )
    }
}
