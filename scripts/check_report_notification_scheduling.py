#!/usr/bin/env python3
"""通知排期闸门：钉住「静默丢通知」的三类写法。

背景（2026-11-06 两轮修复）：
1. `getPendingNotificationRequests` 的**异步回调**里 remove 全部旧通知，紧接着
   同步 `center.add` 注册新通知，两者没有顺序保证。固定 identifier 的旧请求
   必然在待删清单里，remove 一旦晚于 add，刚排好的通知会被一起删掉 ——
   表现为「改过推送时间 / 打开开关后就再也不响」。报告模块与心理提醒模块
   先后踩了同一个坑。
2. 绕过 `NotificationBudget` 直接 `center.add(req)` 且不接错误回调：全开时
   远期一次性触发器叠加待办 / 服药 / 睡眠会顶满系统 64 条 pending 上限，
   超出的 add 静默失败、无日志、无重试。
3. 已重排的模块每轮「全前缀删除 + 全量重加」，固定 identifier 的重复触发器
   被反复撤销；某轮 add 失败或被预算拒绝就成了「旧的删了、新的没排上」。

规则分三层：

**全局层（扫 Assistant/ + WidgetShared/ 下所有通知相关 Swift 文件）**，存量
按文件登记 BASELINE，**只允许减少**；2026-11-06 第三轮已把 6 处存量清零：
- `callback_clear`：禁止回调式 `getPendingNotificationRequests {`；
- `unchecked_add`：`add` 必须接错误（completion 里的 `error in` 或 `try await`）；
- `swallowed_add`：禁止 `try? await ...add(` 把注册失败吞掉。

**专项层（已重构的四个批量模块，零容忍）**：
- 顺序读 `await ...pendingNotificationRequests()`；
- `try await center.add` 且逐条记录失败；
- `NotificationBudget.fingerprint(of:)` 差量对账，不再全删全加；
- 报告 / 待办 / 服药 / 心理都必须过 `NotificationBudget.admit`；
- 报告的分类注册表必须注册 `PERIODIC_REPORT` 分类。

**预算链路层（第三轮新增）**：
- 优先级表覆盖全部 identifier 前缀，且旧版 `.external` 最高豁免不得复活；
- 前台巡检必须先 `await` 完报告 / 待办 / 服药 / 心理的 AndWait，
  再 `await NotificationBudget.reconcile()` 作为唯一全局裁决点；
- fire-and-forget 同步壳留在交互入口可以，但不能出现在巡检链路里
  （裁决会读到残缺 pending，下轮差量对账又会加回来）。

用法：
    python3 scripts/check_report_notification_scheduling.py
    python3 scripts/check_report_notification_scheduling.py --print-baseline
    python3 scripts/check_report_notification_scheduling.py --self-test
"""
import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCAN_DIRS = ("Assistant", "WidgetShared")
REPORT = ROOT / "Assistant" / "Services" / "PeriodicReportManager.swift"
PSYCH = ROOT / "Assistant" / "Services" / "PsychReminderScheduler.swift"
TODO = ROOT / "Assistant" / "Services" / "TodoNotificationManager.swift"
MEDICATION = ROOT / "Assistant" / "Services" / "HabitAndMedicationScheduler.swift"
REGISTRY = ROOT / "Assistant" / "Services" / "NotificationCategoryRegistry.swift"
BUDGET = ROOT / "Assistant" / "Services" / "NotificationBudget.swift"
APP = ROOT / "Assistant" / "App" / "AssistantApp.swift"

# 存量违规基线：只降不升。2026-11-06 第三轮把 6 处全部修完，基线归零；
# 新增任何一处无错误处理 / 吞错 / 回调式清空都会直接判红。
BASELINE = {}

# 预算优先级表必须覆盖的前缀（漏一个就会落到最低档 .ambient，超限时最先被裁）。
REQUIRED_PREFIXES = (
    "med-", "sleep-bedtime-", "trip-arrival-", "psych-reminder-",
    "periodic-report-", "todo-", "weather-alert-", "anni_prep_",
    "expiry-reminder", "battery-", "geofence-arrival-", "parcel-station-",
    "travel-escort-session", "departure-check-session", "pickup-checkout-session",
)

# 巡检链路：四个批量模块必须先 await 完，reconcile 必须是最后一步。
REQUIRED_AWAITS = (
    "await PeriodicReportManager.shared.scheduleNotificationsAndWait()",
    "await TodoNotificationManager.shared.syncAllTodoNotificationsAndWait(context: context)",
    "await PsychReminderScheduler.shared.rescheduleNotificationsAndWait(context: context)",
    "await scheduler.scheduleMedicationRemindersAndWait()",
)
RECONCILE_CALL = "await NotificationBudget.reconcile()"

RULE_NAMES = {
    "callback_clear": "回调式清空",
    "unchecked_add": "无错误处理的 add",
    "swallowed_add": "try? await add 吞错",
}
RULE_HINTS = {
    "callback_clear": "改成 await pendingNotificationRequests() 的顺序化链路",
    "unchecked_add": "改成 try await center.add（逐条 catch）或接 completion 的 error in",
    "swallowed_add": "去掉 try?，用 do/catch 记录每条失败",
}

# 只把「参数长得像通知请求」的 add 算进来，避免误伤 SearchIndexService 的 engine.add(...)。
ADD_CALL = re.compile(r"\.add\(")
NOTIFICATION_ARG = re.compile(r"\b(?:request|req|item\.request|UNNotificationRequest)\b")
CALLBACK_CLEAR = re.compile(r"getPendingNotificationRequests\s*\{")
ASYNC_THROW_ADD = re.compile(r"try\s+await\s")
SWALLOWED_ADD = re.compile(r"try\?\s*await")
ERROR_COMPLETION = re.compile(r"\{\s*(?:\[[^\]]+\]\s*)?error\s+in")


def strip_comments(text: str) -> str:
    """去掉 // 与 /* */ 注释，但保留换行，让逐行分析与真实行号对齐。"""
    out = []
    i = 0
    n = len(text)
    in_str = in_line = in_block = False
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if in_line:
            if c == "\n":
                in_line = False
                out.append(c)
            i += 1
            continue
        if in_block:
            if c == "*" and nxt == "/":
                in_block = False
                i += 2
                continue
            if c == "\n":
                out.append(c)
            i += 1
            continue
        if in_str:
            out.append(c)
            if c == "\\":
                out.append(nxt)
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
            continue
        if c == "/" and nxt == "/":
            in_line = True
            i += 2
            continue
        if c == "/" and nxt == "*":
            in_block = True
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def analyze(text: str) -> dict:
    """对单个文件统计三类违规，返回 {规则: 次数}（只含非零项）。"""
    counts = {"callback_clear": 0, "unchecked_add": 0, "swallowed_add": 0}
    for line in strip_comments(text).splitlines():
        if CALLBACK_CLEAR.search(line):
            counts["callback_clear"] += 1
        if not ADD_CALL.search(line) or not NOTIFICATION_ARG.search(line):
            continue
        if SWALLOWED_ADD.search(line):
            counts["swallowed_add"] += 1
            continue
        if ASYNC_THROW_ADD.search(line) or ERROR_COMPLETION.search(line):
            continue
        counts["unchecked_add"] += 1
    return {k: v for k, v in counts.items() if v}


def scan_tree() -> dict:
    """扫全仓通知相关文件，返回 {相对路径: {规则: 次数}}。"""
    measured = {}
    for dirname in SCAN_DIRS:
        base = ROOT / dirname
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*.swift")):
            text = path.read_text(encoding="utf-8", errors="ignore")
            if "UNUserNotificationCenter" not in text and "UNNotificationRequest" not in text:
                continue
            found = analyze(text)
            if found:
                measured[path.relative_to(ROOT).as_posix()] = found
    return measured


def check_rebuilt_modules() -> list:
    """四个批量模块零容忍：顺序读 / 差量对账 / 错误可观测 / 预算与分类注册。"""
    issues = []
    specs = [
        ("PeriodicReportManager", REPORT),
        ("PsychReminderScheduler", PSYCH),
        ("TodoNotificationManager", TODO),
        ("HabitAndMedicationScheduler", MEDICATION),
    ]
    for name, path in specs:
        if not path.is_file():
            issues.append(f"找不到 {name} 源文件：{path}")
            continue
        text = strip_comments(path.read_text(encoding="utf-8", errors="ignore"))
        if "await center.pendingNotificationRequests()" not in text:
            issues.append(f"{name} 未用 await pendingNotificationRequests() 顺序读存量")
        if "try await center.add(" not in text:
            issues.append(f"{name} 未用 try await center.add 逐条注册（失败不可观测）")
        if "NotificationBudget.fingerprint(of:" not in text:
            issues.append(f"{name} 未做 fingerprint 差量对账，会退回全删全加")
        if "NotificationBudget.admit(" not in text:
            issues.append(f"{name} 未接 NotificationBudget.admit，会绕开统一预算直接占满 64 条上限")

    if not REGISTRY.is_file():
        issues.append("找不到 NotificationCategoryRegistry.swift")
    elif "PeriodicReportManager.makeNotificationCategory()" not in strip_comments(
        REGISTRY.read_text(encoding="utf-8", errors="ignore")
    ):
        issues.append("分类注册表缺少 PERIODIC_REPORT 分类，content 上的 categoryIdentifier 会是死配置")
    return issues


def audit_budget_pipeline(budget_text: str, app_text: str) -> list:
    """预算链路结构规则（纯文本，便于 self-test 传反例）。"""
    issues = []
    if "static func reconcile(" not in budget_text:
        issues.append("NotificationBudget 缺少全局 reconcile()，各模块 admit 会互相推翻")
    if "prefixPriorities" not in budget_text:
        issues.append("NotificationBudget 缺少前缀优先级表，未知模块无法参与统一裁剪")
    if "case external" in budget_text or ".external" in budget_text:
        issues.append("旧版 .external（最高优先级、永不裁剪）复活：守规矩的模块会反过来被裁掉")
    if "activeSuppressions(" not in budget_text:
        issues.append("缺少抑制名单，被裁通知会在下一轮差量对账里立刻加回")
    for prefix in REQUIRED_PREFIXES:
        if f'("{prefix}"' not in budget_text:
            issues.append(f"优先级表漏登记 identifier 前缀 {prefix!r}，会静默落到最低档")

    positions = [app_text.find(call) for call in REQUIRED_AWAITS]
    for call, pos in zip(REQUIRED_AWAITS, positions):
        if pos < 0:
            issues.append(f"巡检未 await 完成排期就裁决：缺少 {call}")
    rec = app_text.find(RECONCILE_CALL)
    if rec < 0:
        issues.append("巡检缺少 await NotificationBudget.reconcile()，一轮巡检没有最终裁决点")
    elif any(0 <= pos > rec for pos in positions):
        issues.append("reconcile() 必须排在四个模块 AndWait 之后，否则读到的是残缺 pending")
    return issues


def check_budget_pipeline() -> list:
    for path in (BUDGET, APP):
        if not path.is_file():
            return [f"找不到预算链路文件：{path}"]
    return audit_budget_pipeline(
        strip_comments(BUDGET.read_text(encoding="utf-8", errors="ignore")),
        strip_comments(APP.read_text(encoding="utf-8", errors="ignore")),
    )


def self_test() -> int:
    """纯内存反例自检，不写临时文件：验证每条规则都能判红、合法写法不误报。"""
    bad = """
    center.getPendingNotificationRequests { requests in
        center.removePendingNotificationRequests(withIdentifiers: stale)
    }
    center.add(req)
    try? await UNUserNotificationCenter.current().add(req)
    """
    expected = {"callback_clear": 1, "unchecked_add": 1, "swallowed_add": 1}
    got = analyze(bad)
    if got != expected:
        print(f"❌ [自检] 反例未按预期判红：期望 {expected}，实际 {got}")
        return 1

    good = """
    let pending = await center.pendingNotificationRequests()
    do { try await center.add(request) } catch { print(error) }
    center.add(request) { error in
        print(error)
    }
    UNUserNotificationCenter.current().add(request) { [weak self] error in
        print(error)
    }
    engine.add(Self.staticSettingsDocuments())
    """
    if analyze(good):
        print(f"❌ [自检] 合法写法被误报：{analyze(good)}")
        return 1

    # 注释里描述反例不能自证其罪
    documented = """
    // 旧实现：center.getPendingNotificationRequests { ... }
    // 且 center.add(req) 没有回调
    /* try? await center.add(req) */
    """
    if analyze(documented):
        print(f"❌ [自检] 注释内容未剥离：{analyze(documented)}")
        return 1

    # 预算链路：对真实文件做变异，验证每条结构规则都能判红、且真实链路不误报。
    real_budget = strip_comments(BUDGET.read_text(encoding="utf-8", errors="ignore"))
    real_app = strip_comments(APP.read_text(encoding="utf-8", errors="ignore"))
    if audit_budget_pipeline(real_budget, real_app):
        print(f"❌ [自检] 真实预算链路被误报：{audit_budget_pipeline(real_budget, real_app)}")
        return 1
    mutations = [
        (real_budget.replace("static func reconcile(", "static func reconcileOld("),
         real_app, "缺 reconcile"),
        (real_budget + "\ncase external = 5\n", real_app, ".external 复活"),
        (real_budget.replace("activeSuppressions(", "noSuppressions("),
         real_app, "缺抑制名单"),
        (real_budget.replace('("psych-reminder-"', '("psych-x-"'),
         real_app, "漏登记前缀"),
        (real_budget, real_app.replace(REQUIRED_AWAITS[0], "let _ = 0", 1),
         "巡检未 await"),
        (real_budget, RECONCILE_CALL + "\n" + real_app, "reconcile 排在排期之前"),
    ]
    for budget_text, app_text, label in mutations:
        if not audit_budget_pipeline(budget_text, app_text):
            print(f"❌ [自检] 预算链路变异「{label}」未判红")
            return 1

    print("✅ [自检] 3 类违规均能判红；async/completion/非通知 add 不误报；注释正确剥离")
    print("✅ [自检] 预算链路 6 类变异（含 .external 复活 / 裁决时序倒置）均能判红")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="通知排期闸门")
    parser.add_argument("--print-baseline", action="store_true", help="输出当前实测基线，可直接粘贴回脚本")
    parser.add_argument("--self-test", action="store_true", help="纯内存反例自检，验证闸门负向有效性")
    args = parser.parse_args()

    if args.self_test:
        return self_test()

    measured = scan_tree()

    if args.print_baseline:
        print("BASELINE = {")
        for rel, counts in sorted(measured.items()):
            print(f'    "{rel}": {counts!r},')
        print("}")
        return 0

    issues = []
    for rel, counts in sorted(measured.items()):
        allowed = BASELINE.get(rel, {})
        for rule, found in counts.items():
            cap = allowed.get(rule, 0)
            if found > cap:
                issues.append(
                    f"{rel}：{RULE_NAMES[rule]} {found} 处（基线 {cap}）—— {RULE_HINTS[rule]}"
                )
    issues.extend(check_rebuilt_modules())
    issues.extend(check_budget_pipeline())

    if issues:
        for issue in issues:
            print("❌ [通知排期闸门] " + issue)
        return 1

    reducible = [
        f"{rel}.{rule}: {cap} → {measured.get(rel, {}).get(rule, 0)}"
        for rel, rules in BASELINE.items()
        for rule, cap in rules.items()
        if cap > measured.get(rel, {}).get(rule, 0)
    ]
    print(
        "✅ [通知排期闸门] 全局违规未超基线（存量已清零）；四个批量模块差量对账、"
        "预算准入、分类注册与巡检单点裁决均到位"
        f"（当前 {len(measured)} 个文件存在存量违规）"
    )
    if reducible:
        print("ℹ️ 可下调基线：" + "、".join(sorted(reducible)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
