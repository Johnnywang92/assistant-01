#!/usr/bin/env python3
"""在宿主 `sandbox-exec` 失效的环境里，对 SwiftUI 视图做**类型检查**。

## 为什么需要它

`@State` / `@Query` / `@Environment` / `@Model` 都是**外部宏**，展开需要
`swift-plugin-server`，而它内部走 `sandbox-exec`——宿主拦截后整个宏体系不可用：

    error: external macro implementation type 'SwiftUIMacros.StateMacro'
      could not be found for macro 'State()'

于是 `xcodebuild` 与 `swiftc -typecheck` 都做不了视图层的检查。

但**宏只影响属性声明那一行**，视图体（真正容易写错的地方）不受影响。
所以这里把宏属性改写成**语义等价的普通属性**，让类型检查能跑起来。

## 改写规则

| 原始 | 改写后 |
|---|---|
| `@State private var x: Bool = false` | `private var x = State(initialValue: false)` |
| `@State private var x: String?` | `private var x = State<String?>(initialValue: nil)` |
| `@State private var x = false` | `private var x = State(initialValue: false)` |
| `@Query(...) private var x: [T]` | `private var x: [T] = []` |
| `@Environment(\\.modelContext) private var c` | `private var c = PsychTypeCheckStub.modelContext` |
| `$x`（Binding 投影） | `x`（`State` 本身就是 `Binding`，类型等价） |

`State` 是公开的 `@propertyWrapper`，`State(initialValue:)` 可直接构造，
所以改写后**类型与真实编译完全一致**——比手工桩更可信。

## 用法

    python3 scripts/typecheck-views.py <文件...>

脚本会自动为 iOS 目标编译 AssistantCore 模块（Core 是纯 Foundation，无宏）。
"""
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
CORE_SRC = ROOT / "Packages/AssistantCore/Sources/AssistantCore"
CORE_OUT = pathlib.Path("/tmp/psych-typecheck/ioscore")

# 视图依赖但不属于心理模块的 Core 文件。
CORE_EXTRA = [
    "PleasureIndexEvaluator.swift",
    "SettingsSnapshot.swift",
    "ExpenseCurrency.swift",
    "AmountFormatter.swift",
]


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def sdk_path():
    return run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"]).stdout.strip()


def build_ios_core_module():
    """为 iOS 目标编译 AssistantCore 模块（Core 是纯 Foundation，无宏）。"""
    CORE_OUT.mkdir(parents=True, exist_ok=True)
    files = [str(p) for p in sorted(CORE_SRC.glob("*.swift"))
             if "Psych" in p.name or "MentalHealth" in p.name]
    for p in sorted(CORE_SRC.glob("*.swift")):
        text = p.read_text(encoding="utf-8", errors="ignore")
        if "struct HealthDaySnapshot" in text and p.name not in CORE_EXTRA:
            CORE_EXTRA.append(p.name)
            break
    files += [str(CORE_SRC / n) for n in CORE_EXTRA if (CORE_SRC / n).exists()]

    proc = run(["xcrun", "swiftc", "-emit-module", "-module-name", "AssistantCore",
                "-sdk", sdk_path(), "-target", "arm64-apple-ios18.0", "-swift-version", "5",
                "-emit-module-path", str(CORE_OUT / "AssistantCore.swiftmodule")] + files)
    errs = [l for l in (proc.stdout + proc.stderr).splitlines() if "error:" in l]
    if errs:
        print("❌ iOS Core 模块编译失败：")
        for e in errs[:10]:
            print("  " + e)
        return None
    return CORE_OUT


STUB_SOURCE = r'''
import AssistantCore
import SwiftUI
import SwiftData

// MARK: - 视图依赖的 App 侧桩（仅用于类型检查，不进工程）

enum PsychTypeCheckStub {
    static var modelContext: ModelContext {
        ModelContext(PsychStubContainer.shared.container)
    }
    static var dismiss: DismissAction { fatalError("类型检查桩") }
    static var environment: Any { fatalError("类型检查桩") }
}

/// `@State` 存**字典**时的替身。
///
/// **必须是 class（引用语义）**：真实 `@State` 靠引用语义让闭包里的
/// `answers[i] = x` 能编译通过；换成普通 struct 属性就会报
/// "cannot assign through subscript: 'self' is immutable"。
final class PsychStateDict<Key: Hashable, Value> {
    private var storage: [Key: Value] = [:]
    init(_ initial: [Key: Value] = [:]) { storage = initial }

    subscript(key: Key) -> Value? {
        get { storage[key] }
        set { storage[key] = newValue }
    }

    /// 只读遍历（ForEach 等场景）。
    var keys: Dictionary<Key, Value>.Keys { storage.keys }
    var values: Dictionary<Key, Value>.Values { storage.values }
    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }

    /// 传给期望普通字典的参数时用（真实 `@State` 读出来就是字典）。
    var asDictionary: [Key: Value] { storage }
}

@MainActor
final class PsychStubContainer {
    static let shared = PsychStubContainer()
    let container: ModelContainer = {
        let schema = Schema([])
        return try! ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }()
}

final class PsychStubScaleRecord {
    var id: UUID = UUID()
    var completedAt: Date = .now
    var scaleIDRaw: String = PsychScaleID.phq9.rawValue
    var itemScores: [Int?] = []
    var answeredCount: Int = 0
    var hasAcknowledgedCrisis: Bool = false
    var createdAt: Date = .now
    var scaleID: PsychScaleID {
        get { PsychScaleID(rawValue: scaleIDRaw) ?? .phq9 }
        set { scaleIDRaw = newValue.rawValue }
    }
    func toAnswers() -> [Int: PsychItemAnswer] { PsychItemScoreArray.answers(from: itemScores) }
    func score() -> PsychScaleScore {
        PsychScaleScorer.score(
            answers: toAnswers(),
            definition: PsychScaleCatalog.definition(for: scaleID),
            completedAt: completedAt
        )
    }
}

final class PsychStubMoodRecord {
    var id: UUID = UUID()
    var day: Date = .now
    var moodScore: Int = 3
    var energyScore: Int = 3
    var stressScore: Int = 2
    var note: String?
    var createdAt: Date = .now
    var updatedAt: Date = .now
}

final class PsychStubSnapshotRecord {
    var id: UUID = UUID()
    var day: Date = .now
    var sleepHours: Double?
    var updatedAt: Date = .now
}

@MainActor
final class PsychStubHealthKitService: ObservableObject {
    static let shared = PsychStubHealthKitService()
    var pleasureEvaluation: PleasureIndexEvaluation?
}

@MainActor
final class PsychStubReminderScheduler: ObservableObject {
    static let shared = PsychStubReminderScheduler()
    var isEnabled: Bool = false
    var isAssessmentReminderEnabled: Bool = true
    var isTrendReminderEnabled: Bool = true
    func rescheduleNotifications(context: ModelContext) {}
    func resetNotificationState() {}
}

enum PsychStubHaptic {
    static func success() {}
    static func light() {}
    static func selection() {}
}

/// 视图依赖的其它 App 侧组件桩：**签名必须与真实实现对齐**
/// （`CompanionEchoCard` 见 Features/Share/，`PsychShareSheet` 见 Features/PsychShareCardView.swift）。
/// 桩一旦落后于真实签名，闸门就会「通不过」——这是有意为之：宁可红，也不要假绿。
struct PsychStubCompanionCard: View {
    var moodRecord: PsychStubMoodRecord?
    var completedTodosCount: Int
    var pendingTodosCount: Int
    var todayExpenseAmount: Double
    var body: some View { EmptyView() }
}

struct PsychStubShareSheet: View {
    var date: Date
    var todayMood: MoodCheckInEntry?
    var moodEntries: [MoodCheckInEntry]
    var scaleScores: [PsychScaleScore]
    var insight: MentalHealthInsight?
    var physiology: PleasureIndexEvaluation?
    var body: some View { EmptyView() }
}

extension View {
    /// 真实实现见 Services/AppBackgroundManager.swift
    func themedAppBackground() -> some View { self }
    /// 真实实现见 Theme/AppTheme.swift
    func responsiveAnimation(_ animation: Animation?, value: some Equatable) -> some View { self }
}

@MainActor
enum PsychStubReliefTodoBuilder {
    @discardableResult
    static func createTodo(for action: PsychReliefAction, dueAt: Date? = nil, in context: ModelContext) -> UUID? { UUID() }
}

@MainActor
enum PsychStubDataAdapter {
    static func moodEntries(from records: [PsychStubMoodRecord]) -> [MoodCheckInEntry] {
        records.map {
            MoodCheckInEntry(day: $0.day, moodScore: $0.moodScore, energyScore: $0.energyScore, stressScore: $0.stressScore)
        }
    }
    static func scaleScores(from records: [PsychStubScaleRecord]) -> [PsychScaleScore] {
        records.map { $0.score() }
    }
    static func recentAverageSleepHours(context: ModelContext, days: Int = 7) -> Double? { nil }
    static func exportPayload(
        scaleRecords: [PsychStubScaleRecord],
        moodRecords: [PsychStubMoodRecord],
        recentAverageSleepHours: Double?,
        physiologicalStressScore: Int?
    ) -> PsychExportPayload {
        PsychExportPayload(scaleRecords: [], moodEntries: [])
    }
}

/// 落库服务的桩（真实实现用 `@Model`，宏不可用时用这个替身）。
enum PsychRecordStore {
    @discardableResult
    static func save(
        scaleID: PsychScaleID,
        answers: [Int: PsychItemAnswer],
        completedAt: Date = .now,
        in context: ModelContext
    ) -> Bool { true }

    @discardableResult
    static func saveMoodCheckIn(
        day: Date,
        mood: Int,
        energy: Int,
        stress: Int,
        note: String?,
        in context: ModelContext
    ) -> Bool { true }
}

// MARK: - 设计令牌与本地化（照抄 Assistant/Theme/AppTheme.swift）

enum AppColor {
    static var primary: Color { Color.accentColor }
    static var danger: Color { Color(.systemRed) }
    static var warning: Color { Color(.systemOrange) }
    static var success: Color { Color(.systemGreen) }
    static var info: Color { Color(.systemBlue) }
    static var feature: Color { Color(.systemPurple) }
    static var surface: Color { Color(.secondarySystemGroupedBackground) }
    static var fillTertiary: Color { Color(.tertiarySystemFill) }
    static var text: Color { Color(.label) }
    static var secondaryText: Color { Color(.secondaryLabel) }
    static var separator: Color { Color(.separator) }
    static func softFill(_ color: Color, opacity: Double = 0.12) -> Color { color.opacity(opacity) }
}

enum AppSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
}

enum AppRadius {
    static let hairline: CGFloat = 2
    static let badge: CGFloat = 4
    static let small: CGFloat = 6
    static let chip: CGFloat = 8
    static let medium: CGFloat = 10
    static let card: CGFloat = 12
    static let banner: CGFloat = 14
    static let large: CGFloat = 16
    static let panel: CGFloat = 20
    static let hero: CGFloat = 24
}

extension View {
    func appCard(cornerRadius: CGFloat = AppRadius.card) -> some View { self }
}

enum AppMotion {
    static let standardSpring: Animation = .spring(response: 0.35, dampingFraction: 0.8)
    static let reduceMotion: Bool = false
}

/// `@Query` 元素类型的桩：视图里按 `$0.status == .done`、`$0.isIncome` 这类
/// 成员读，桩必须把用到的成员备齐（见 MentalHealthView 的计数函数）。
final class PsychStubTodo {
    enum Status { case done, active }
    var status: Status = .active
    var completedAt: Date?
}

final class PsychStubExpense {
    var isIncome: Bool = false
    var date: Date = .now
    var amount: Double = 0
}

enum L10n {
    static func tr(_ key: String) -> String { key }
}
'''


def replace_attribute_calls(source: str, attr: str, build) -> str:
    """把 `@Attr(...) private var name: Type` 改写成普通属性。

    按**括号配平**扫描参数区间——排序键等参数里含嵌套括号
    （`@Query(sort: \Model.field, order: .reverse)`），
    用 `[^)]*` 会在第一个 `)` 处截断，剩下半截变成语法错误。
    """
    out = source
    # `attr` 已含 `@`（调用方传 "@Query"），这里不要重复加。
    pattern = re.compile(re.escape(attr) + r'\(')
    while True:
        m = pattern.search(out)
        if not m:
            break
        # 从左括号开始做配平扫描
        i = m.end() - 1
        depth = 0
        end = -1
        while i < len(out):
            if out[i] == '(':
                depth += 1
            elif out[i] == ')':
                depth -= 1
                if depth == 0:
                    end = i
                    break
            i += 1
        if end < 0:
            break
        args = out[m.end():end]
        rest = out[end + 1:]
        # 类型可能跨行（`[T]` 与后续修饰），用宽松匹配
        decl = re.match(r'\s*private var (\w+):\s*([^=]+?)\s*$', rest, flags=re.M)
        if not decl:
            break
        name = decl.group(1)
        type_text = decl.group(2).strip()
        replacement = build(args, name, type_text)
        # 偏移量修正：`decl` 是对 `rest`（切片）匹配的，
        # `decl.end()` 是相对切片的偏移，要加回 `rest` 在 out 中的起点。
        rest_start = end + 1
        out = out[:m.start()] + replacement + out[rest_start + decl.end():]
    return out

MODEL_ALIASES = {
    "PsychScaleRecord": "PsychStubScaleRecord",
    "MoodCheckInRecord": "PsychStubMoodRecord",
    "HealthDaySnapshotRecord": "PsychStubSnapshotRecord",
    "TodoItem": "PsychStubTodo",
    "ExpenseRecord": "PsychStubExpense",
}

APP_ALIASES = {
    "HealthKitService": "PsychStubHealthKitService",
    "PsychReminderScheduler": "PsychStubReminderScheduler",
    "Haptic": "PsychStubHaptic",
    "PsychReliefTodoBuilder": "PsychStubReliefTodoBuilder",
    "PsychDataAdapter": "PsychStubDataAdapter",
    # 视图依赖但不在本次类型检查文件集里的 App 组件（含跨文件使用的视图）
    "CompanionEchoCard": "PsychStubCompanionCard",
    "PsychShareSheet": "PsychStubShareSheet",
}


def alias_models(source: str) -> str:
    out = source
    for real, stub in MODEL_ALIASES.items():
        out = re.sub(rf':\s*(\[\s*){re.escape(real)}(\s*\])', rf': \1{stub}\2', out)
        out = re.sub(rf':\s*{re.escape(real)}\b', f': {stub}', out)
        out = re.sub(rf'FetchDescriptor<{re.escape(real)}>', f'FetchDescriptor<{stub}>', out)
        # 排序键等 key path 里的类型名：`\Model.field`
        out = re.sub(rf'\\{re.escape(real)}\.', rf'\\{stub}.', out)
    for real, stub in APP_ALIASES.items():
        out = re.sub(rf'\b{re.escape(real)}\b', stub, out)
    # 兜底：模型类型还可能出现在返回类型、泛型实参等位置
    # （`-> MoodCheckInRecord?`、`[MoodCheckInRecord]` 之外的各种写法）。
    # 上面的定点替换已经覆盖了绝大多数，这里只清理残留的独立标识符。
    for real, stub in MODEL_ALIASES.items():
        out = re.sub(rf'\b{re.escape(real)}\b', stub, out)
    return out


def rewrite(source: str) -> str:
    """把宏属性改写成语义等价的普通属性。"""
    out = alias_models(source)

    # @Environment(\.modelContext) private var c
    out = re.sub(r'@Environment\(\\\.modelContext\)[ \t]+private var (\w+)',
                 r'private var \1 = PsychTypeCheckStub.modelContext', out)
    # @Environment(\.dismiss) private var d
    out = re.sub(r'@Environment\(\\\.dismiss\)[ \t]+private var (\w+)',
                 r'private var \1 = PsychTypeCheckStub.dismiss', out)
    # @Environment(其它) private var x
    out = re.sub(r'@Environment\([^)]*\)[ \t]+private var (\w+)',
                 r'private var \1 = PsychTypeCheckStub.environment', out)
    # @Query(...) private var x: [T]
    #
    # **不能用 `\([^)]*\)` 匹配参数**——排序键里含嵌套括号
    # （`@Query(sort: \MoodCheckInRecord.day, order: .reverse)`），
    # 非贪婪匹配会在第一个 `)` 处截断，剩下 `, order: .reverse)` 变成语法错误。
    # 所以按括号配平手动扫描。
    out = replace_attribute_calls(out, "@Query", lambda args, name, type_text:
                                   f"private var {name}: {type_text} = []")
    # 裸 `@Query`（不带参数，声明在下一行）：`replace_attribute_calls` 只认 `@Query(`，
    # 这类无参写法会漏过去，宏展开失败会直接报
    # "external macro implementation type 'SwiftDataMacros.QueryMacro' could not be found"。
    out = re.sub(
        r'^[ \t]*@Query[ \t]*\r?\n([ \t]*)(private var \w+:[^\n{=]+?)[ \t]*$',
        r'\1\2 = []',
        out, flags=re.M)

    # @State 存**集合类型**（数组 / 字典）时不能用 Binding 表达——
    # `Binding` 的 subscript 只读，写不进 `answers[i] = x`。
    #
    # 改写成一个**类**包装（引用语义），这样闭包里的下标赋值也能过——
    # 普通 struct 属性在闭包内是「self is immutable」，
    # 而真实 `@State` 靠引用语义绕过了这个限制。
    # 类型标注保留在泛型参数里（`PsychStateBox<[Int: X]>`），
    # 空字典字面量 `[:]` 因此仍有类型上下文。
    # **必须放在其它 @State 规则之前**，否则会先被 Binding 规则吃掉。
    # 类型标注形如 `[Int: PsychItemAnswer]`，拆成 Key / Value 两个泛型参数。
    out = re.sub(
        r'@State[ \t]+private var (\w+):\s*\[\s*([^:\]]+)\s*:\s*([^\]]+)\]\s*=\s*([^\n]+)$',
        r'private var \1 = PsychStateDict<\2, \3>(\4)', out, flags=re.M)

    # @State → 直接用 `Binding` 表达。
    #
    # 为什么不用 `State(initialValue:)`：手写的普通属性**没有投影语义**，
    # `State<T>` 既不是 `Binding<T>` 也不能赋值给 `Binding<T>` 参数。
    # 而 `Binding` 本身就是 SwiftUI 视图要的东西（`.sheet(isPresented:)` 要 `Binding<Bool>`）。
    #
    # `private var x = Binding.constant(false)` 的类型与
    # `@State private var x = false` 投影出来的 `$x` **完全一致**。
    #
    # @State private var x: T = v   →   private var x = Binding<T>.constant(v)
    # 用**显式泛型参数**：`Binding.constant(.markdown)` 缺上下文会报
    # "cannot infer contextual base in reference to member 'markdown'"。
    out = re.sub(r'@State[ \t]+private var (\w+):\s*([A-Za-z_][\w<>\[\], .?]*)\s*=\s*([^\n]+)$',
                 r'private var \1 = Binding<\2>.constant(\3)', out, flags=re.M)
    # @State private var x: T?      →   private var x = Binding<T?>.constant(nil)
    out = re.sub(r'@State[ \t]+private var (\w+):\s*([A-Za-z_][\w<>\[\], .?]*\?)\s*$',
                 r'private var \1 = Binding<\2>.constant(nil)', out, flags=re.M)
    # @State private var x: T（非可选、无初值，值在 init 里通过 `_x = State(initialValue:)` 给）
    #   →   private var x: Binding<T>! = nil
    # 用隐式解包可选而非 `Binding<T>.constant(...)`：这里拿不到 T 的默认值，
    # 而 IUO 既能满足「按值读取」（`x.wrappedValue`）、也能满足「按 Binding 传递」
    # （`$x` 投影后直接当 `Binding<T>` 用）。真正的初值在下面 `_x = State(...)` 规则里丢弃。
    out = re.sub(r'@State[ \t]+private var (\w+):\s*([A-Za-z_][\w<>\[\], .?]*)\s*$',
                 r'private var \1: Binding<\2>! = nil', out, flags=re.M)

    # init 里的 `_x = State(initialValue: expr)`：属性宏已移除，`_x` 是这个宏生成的
    # 存储属性，改写后不再存在。保留表达式本身（仍参与类型检查），赋值语义对
    # 类型检查无意义——声明处已有初值或用 IUO 兜底。
    out = re.sub(r'^([ \t]*)_(\w+) = State\(initialValue: (.+)\)[ \t]*$',
                 r'\1_ = (\3)', out, flags=re.M)
    # @State private var x = v（无显式类型）
    # 用 `Binding.constant(v)`：类型由初值推断。
    # 枚举成员（`PsychExportFormat.markdown`）会缺上下文，
    # 那类声明在真实代码里都带显式类型，走上面那条规则。
    out = re.sub(r'@State[ \t]+private var (\w+)\s*=\s*([^\n]+)$',
                 r'private var \1 = Binding.constant(\2)', out, flags=re.M)

    # 残留保险
    out = re.sub(r'@State[ \t]+', '', out)
    out = re.sub(r'@Environment\([^)]*\)[ \t]+', '', out)

    # 赋值：`x = v` → `x.wrappedValue = v`
    # `Binding` 是不可变的（`@State` 才是可变的），所以直接赋值编译不过。
    #
    # **必须避开属性声明行**——`private var x = Binding.constant(...)` 里的
    # `x =` 不是赋值，改了会产出 `private var x.wrappedValue = ...` 这种非法声明。
    # 所以逐行处理，跳过以 `private var` / `let` / `var` 开头的声明行。
    state_names = re.findall(r'private var (\w+) = Binding', out)
    # 「init 里给初值」的 @State 被改写成了 `private var x: Binding<T>! = nil`（IUO）。
    # 这些名字同样需要按 `Binding` 打补丁，否则 `moodScore: mood` 会把
    # `Binding<Int>?` 直接当 `Int` 传进去（漏了 `.wrappedValue`）。
    state_names += re.findall(r'private var (\w+): Binding<[^\n]*?>!', out)
    state_names = list(dict.fromkeys(state_names))
    # 字典型 `@State`（改写成了 PsychStateDict）——传给期望普通字典的参数时
    # 要用 `.asDictionary`（真实 @State 读出来就是字典）。
    dict_names = re.findall(r'private var (\w+) = PsychStateDict', out)

    # 按顶层类型分段：@State 的补丁只能作用在**声明它的那个类型**里。
    # 否则别的类型里同名的局部绑定（`if let note = record.note`）会被误改写成
    # `if let note.wrappedValue = ...`，报一堆看不懂的错。
    type_decl = re.compile(
        r'^(?:@\w+[^\n]*\n\s*)*(?:public\s+|private\s+|internal\s+|final\s+)*'
        r'(?:struct|class|enum|extension)\s+\w+')
    seg_of_line = []
    seg = 0
    for ln in out.split("\n"):
        if type_decl.match(ln):
            seg += 1
        seg_of_line.append(seg)
    # 每个 state 名字归属的分段（取声明行所在段）
    state_seg = {}
    for i, ln in enumerate(out.split("\n")):
        m = re.match(r'^[ \t]*private var (\w+)(?:\s*:\s*Binding<[^\n]*?>!|\s*=\s*Binding\b)', ln)
        if m and m.group(1) in state_names:
            state_seg[m.group(1)] = seg_of_line[i]
    dict_seg = {}
    for i, ln in enumerate(out.split("\n")):
        m = re.match(r'^[ \t]*private var (\w+) = PsychStateDict\b', ln)
        if m:
            dict_seg[m.group(1)] = seg_of_line[i]

    # 只跳过**改写产物自身的声明行**。
    #
    # 早期版本跳过了所有以 `let` / `var` / `private var` 开头的行，想保护
    # `private var x = Binding.constant(...)` 这种声明不被改坏；副作用是 body 里的
    # `let periodRecords = Array(...prefix(selectedTrendPeriod)...)` 也被跳过了，
    # 于是 `prefix(Binding<Int>)` 漏改写、闸门报「Binding<Int> 不可转 Int」。
    # 现在只按「声明里赋的是 Binding / PsychStateDict / PsychTypeCheckStub」判定。
    decl_line = re.compile(
        r'^(?:@\w+|(?:private\s+|public\s+|fileprivate\s+|internal\s+)?'
        r'(?:var|let)\s+\w+\s*=\s*(?:Binding|PsychStateDict|PsychTypeCheckStub)\b)')

    if dict_names:
        lines = out.split("\n")
        for i, line in enumerate(lines):
            if decl_line.match(line.lstrip()):
                continue
            for name in dict_names:
                if dict_seg.get(name) != seg_of_line[i]:
                    continue  # 别的类型里的同名局部变量，不动
                # 实参位置：`PsychScaleResultView(answers: answers)` → `.asDictionary`
                line = re.sub(rf'(\b\w+:\s*)({re.escape(name)})(?![.\w])',
                              rf'\1\2.asDictionary', line)
            lines[i] = line
        out = "\n".join(lines)

    if state_names:
        lines = out.split("\n")
        for i, line in enumerate(lines):
            if decl_line.match(line.lstrip()):
                continue
            for name in state_names:
                if state_seg.get(name) != seg_of_line[i]:
                    continue  # 不是声明它的那个类型里的同名变量，不动
                # 本行若用同名局部绑定遮蔽了它（`if let note = record.note`），
                # 后续出现的 `note` 是绑定值（String）而不是 @State，
                # 再打 `.wrappedValue` 就会报 "String has no member 'wrappedValue'"。
                if re.search(rf'\b(?:if|guard)\s+let\s+{re.escape(name)}\b', line):
                    continue
                # 条件绑定：`guard let day = selectedTrendDay else`
                # 真实 `@State` 是 `Date?`，桩里是 `Binding<Date?>`，必须解包。
                line = re.sub(rf'(\b(?:if|guard)\s+let\s+\w+\s*=\s*)({re.escape(name)})(?![.\w])',
                              rf'\1\2.wrappedValue', line)
                # 无标签实参：`prefix(selectedTrendPeriod)` / `suffix(...)`
                line = re.sub(
                    rf'(\b(?:prefix|suffix|dropFirst|dropLast|indices|contains)\(\s*)({re.escape(name)})(?=[,)])',
                    rf'\1\2.wrappedValue', line)
                # 裸实参：`onSaved?(mood, energy, stress)` / `foo(1, note)`
                line = re.sub(rf'(\(|,\s*)({re.escape(name)})(?=[,)])',
                              rf'\1\2.wrappedValue', line)
                # 赋值（排除 `if let x =` / `guard let x =` / `for x in` 的左侧绑定名）
                line = re.sub(
                    rf'(?<![\w.])(?<!\blet )(?<!\bvar )(?<!\bcase ){re.escape(name)} = (?![=])',
                    f'{name}.wrappedValue = ', line)
                # 比较：Binding 不可直接与值比较（真实 @State 可以）
                line = re.sub(rf'(?<![\w.])({re.escape(name)}) == (?![=])',
                              rf'\1.wrappedValue == ', line)
                # Binding 的 isEmpty 是 get-only（真实 @State 可变）
                line = re.sub(rf'(?<![\w.])({re.escape(name)})\.isEmpty',
                              rf'\1.wrappedValue.isEmpty', line)
                # 作为实参值传递（`foo: mood`）→ 真实 @State 读出来就是 Int/String，
                # 桩里是 Binding<Int>，要显式解包。
                # 允许可选类型后缀（`foo: note?`），否则 `Binding<String?>` 漏掉。
                line = re.sub(rf'(\b\w+:\s*)({re.escape(name)})(?![.\w])',
                              rf'\1\2.wrappedValue', line)
                line = re.sub(rf'(\b\w+:\s*)({re.escape(name)})\?(?![.\w])',
                              rf'\1\2.wrappedValue', line)
                # 三元表达式的两个分支：`x ? a : b` —— 两侧都要解包。
                line = re.sub(rf'(\?[^:\n]*:\s*)({re.escape(name)})(?![.\w])',
                              rf'\1\2.wrappedValue', line)
                # 条件位置：`if copied {` / `&& showPreview` → 真实 @State 读出来是 Bool。
                line = re.sub(rf'(\bif\s+)({re.escape(name)})(?![.\w])',
                              rf'\1\2.wrappedValue', line)
                # 取反：`if !showResult {`
                line = re.sub(rf'(\bif\s+!)({re.escape(name)})(?![.\w])',
                              rf'\1\2.wrappedValue', line)
                # 三元表达式的**条件**位置：`copied ? a : b`。
                line = re.sub(rf'(?<![\w.])({re.escape(name)})\s*\?',
                              rf'\1.wrappedValue ?', line)
                # 算术运算：`currentIndex + 1` / `Double(currentIndex)`。
                # 真实 @State 读出来就是 Int，桩里是 Binding<Int>。
                line = re.sub(rf'(?<![\w.])({re.escape(name)})\s*([+\-*/])',
                              rf'\1.wrappedValue \2', line)
                line = re.sub(rf'\(\s*({re.escape(name)})\s*\)',
                              rf'(\1.wrappedValue)', line)
                # 运算的右操作数：`a - currentIndex`
                line = re.sub(rf'([+\-*/]\s*)({re.escape(name)})(?![.\w])',
                              rf'\1\2.wrappedValue', line)
                # 复合赋值：`currentIndex += 1`
                line = re.sub(rf'(?<![\w.])({re.escape(name)})\s*([+\-*/]=)',
                              rf'\1.wrappedValue \2', line)
            lines[i] = line
        out = "\n".join(lines)

    # `$x` 投影：改写后属性本身就是 `Binding`，所以 `$x` → `x` 类型一致。
    #
    # **必须排除 `$0` / `$1`**——它们是闭包简写参数（`points.sorted { $0.x < $1.x }`），
    # 不是 Binding 投影。误替换会变成 `0.x` / `1.x`，报出一堆看不懂的错。
    out = re.sub(r'\$(?!\d)(\w+)\b', r'\1', out)

    return out


def main() -> int:
    args = sys.argv[1:]
    # `--keep` 保留改写产物目录：桩腐化时靠它把编译器行号映射回原文件。
    keep = "--keep" in args
    files = [a for a in args if not a.startswith("--")]
    if not files:
        print("用法: typecheck-views.py [--keep] <文件...>")
        return 2

    core_dir = build_ios_core_module()
    if core_dir is None:
        return 1

    tmp = pathlib.Path(tempfile.mkdtemp(prefix="psych-tc-"))
    try:
        stub_path = tmp / "PsychTypeCheckStubs.swift"
        stub_path.write_text(STUB_SOURCE, encoding="utf-8")

        transformed = []
        for f in files:
            src = pathlib.Path(f)
            if not src.is_absolute():
                src = ROOT / f
            dst = tmp / (src.stem + ".rewritten.swift")
            dst.write_text(rewrite(src.read_text(encoding="utf-8")), encoding="utf-8")
            transformed.append(str(dst))

        proc = run(["xcrun", "swiftc", "-typecheck",
                    "-sdk", sdk_path(), "-target", "arm64-apple-ios18.0", "-swift-version", "5",
                    "-I", str(core_dir),
                    str(stub_path)] + transformed)
        errs = [l for l in (proc.stdout + proc.stderr).splitlines() if "error:" in l]
        if errs:
            print(f"❌ 类型检查失败（{len(errs)} 处）：")
            for e in errs[:40]:
                print("  " + e)
            return 1
        names = ", ".join(pathlib.Path(f).name for f in files)
        print(f"✅ 类型检查通过（iOS 目标）：{names}")
        return 0
    finally:
        if keep:
            print(f"（--keep：改写产物保留在 {tmp}）")
        else:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
