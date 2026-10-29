#!/usr/bin/env python3
"""偏好键覆盖闸门：App 代码里每一个 UserDefaults 键，必须要么进备份白名单，
要么落在本文件的豁免清单里并写明理由。

为什么要有这道闸：`AssistantSettingsKeys` 的注释自己写了「漏登记的键只是不进备份，
不会报错」——它靠人肉记忆，而人确实漏过：季报/年报的开关与推送时间四个键没登记，
同族的日报/周报/月报全都在；睡前提醒的一整组设置、手动排序的类别顺序也一样没登记。
还原后备份里这些设置静默回到默认，用户只会觉得「刚换机就全乱了」。

用法：
    python3 scripts/check_settings_keys.py            # 校验，失败非零退出
    python3 scripts/check_settings_keys.py --audit    # 只打印现状，不作为闸门结论
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WHITELIST_FILE = ROOT / "Packages/AssistantCore/Sources/AssistantCore/SettingsSnapshot.swift"
SCAN_DIRS = ["Assistant", "WidgetShared", "Packages/AssistantCore/Sources"]
WHITELIST_ARRAYS = ("stringKeys", "boolKeys", "intKeys", "doubleKeys", "dataKeys")

# 不进备份的键，逐条写明理由。要新增豁免必须先能读出它为什么不属于用户偏好。
EXEMPT = {
    # --- 安全材料 / 需在新设备上重新建立 ---
    "app_lock_passcode_hash": "应用锁 PIN 哈希，绝不能进备份",
    "app_lock_enabled": "设备级安全开关，换机后应在本机重新设置",
    "app_lock_use_biometrics": "生物识别绑定本机 Secure Enclave，迁移无意义",
    "app_lock_fail_count": "本机锁定计数，迁移等于把锁死状态搬过去",
    "app_lock_lockout_until": "本机锁止截止时间，同上",
    "app_lock_timeout_seconds": "安全超时应在本机重设，不随备份走",
    "has_completed_permission_onboarding_v1": "权限引导状态，新设备必须重新走一遍授权",
    "migration_pin_salt_v1": "迁移 PIN 的派生材料",
    "migration_pin_verifier_v1": "迁移 PIN 的校验器",
    "migration_pin_iterations_v1": "迁移 PIN 的迭代次数",
    "migration_pin_hint_v1": "PIN 提示语跟着 PIN 走，单独迁移会误导",
    "llm_remote_context_consent": "隐私同意不能替用户迁移",
    "llm_developer_endpoint": "局域网地址，属本机网络环境而非偏好",
    "llm_remote_ollama_model": "与 endpoint 同族：指向本机局域网上的模型，换机需重选",
    "llm_selected_model_preset_v1": "同上，预设跟着本机可用的模型走",
    "webdav_sync_config_v1": "外部服务器地址与账号；密码在 Keychain，单独迁移只得到半个配置",
    "password_vault_purge_pending_v1": "明文清理的一次性待办标记",
    # --- 只读的历史键：值已被更细的键取代，登记回去反而会让旧迁移再跑一遍 ---
    "user_off_work_hour": "旧版只存小时的下班时间，仅两处一次性升级在读取；"
                          "登记进白名单等于把被 user_off_work_minutes 取代的值搬回新设备",
    # --- 运行态缓存：下次访问自行重建 ---
    "cached_user_current_city": "城市缓存，由定位重新得出",
    "weather_cached_temp": "天气缓存",
    "weather_cached_symbol": "天气缓存",
    "weather_cached_desc": "天气缓存",
    "weather_last_dismissed_date": "当日已忽略标记，跨天即失效",
    "weather_last_recorded_date": "温差基准快照日期",
    "weather_yesterday_max_temp": "温差基准数值",
    "weather_last_check_status": "排查用的状态串，不是用户偏好",
    "today_briefing_dismissed_date": "当日已忽略的简报日期",
    "overdue_triage_last_date": "逾期分诊的当日节流日期",
    "expense_exchange_rate_updated_at": "汇率同步时间戳",
    "sleepReminder.lastRemindedNightKey": "「本夜已提醒」节流标记",
    "clipboard_last_handled_change_count": "剪贴板设备状态",
    "clipboard_rejected_content_keys": "被拒绝内容的去重集",
    # --- 提醒去重/会话状态：新设备本就该重新生成一遍 ---
    "anniversary_dismissed_records": "纪念日已忽略记录（按年生效）",
    "anniversary_prep_added_records": "纪念日已生成待办的去重记录",
    "anniversary_last_notification_dates": "纪念日最近通知日期",
    "travel_ticket_added_records": "行程票已生成待办的去重记录",
    "travel_ticket_dismissed_records": "行程票已忽略记录",
    "expense_budget_alert_state_v1": "预算预警的触发状态位",
    "pickup_checkout_session_v1": "进行中的取件销号会话，跨设备无意义",
    "departure_checklist_seeded": "一次性播种标记",
    "todo_home_category_work_migrated_v1": "一次性迁移标记",
    "todo_home_category_other_migrated_v1": "一次性迁移标记",
    # --- 跨进程桥接缓存（App Group，不是用户偏好）---
    "widget_shared_snapshot_v1": "小组件共享快照",
    "widget_pending_commands_v1": "小组件待处理指令队列",
    # --- 行为学习历史：SettingsValue 没有字典类型，丢了只退回默认排序 ---
    "life_vault_card_usage_counts_v2": "卡片使用频次统计（字典存储）",
    "life_vault_card_last_used_timestamps_v2": "卡片最近使用时间（字典存储）",
    # --- UI 位置与系统自管键 ---
    "floating_voice_norm_x": "悬浮语音球位置",
    "floating_voice_norm_y": "悬浮语音球位置",
    "AppleLanguages": "Apple 自己管理语言的键",
}

# 含插值的键模板（如 "notif_sent_\(id)"）：逐键判定无从下手，只汇报不判红。
DYNAMIC_KEYS = []


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def swift_files():
    for d in SCAN_DIRS:
        base = ROOT / d
        if not base.is_dir():
            continue
        for p in sorted(base.rglob("*.swift")):
            if ".build" in p.parts or "DerivedData" in p.parts:
                continue
            yield p


def collect_used_keys():
    """返回 ({键: [位置, ...]}, {常量名: 键值}, 全部源码文本)。

    只认三种确定属于 UserDefaults 的形状：
      1. @AppStorage("KEY")
      2. 接收者是 UserDefaults / 由 UserDefaults 赋来的局部别名，调用 …(forKey: "KEY")
      3. 键名常量声明 `static let someKey = "KEY"`，且该常量名在同文件的 forKey 行里出现过
    第 3 条是为了堵「用常量声明的新偏好」——那正是能绕过闸门的写法；
    常量名必须真的被 forKey 用过，否则它是 Keychain 服务名之类的别物。
    这样能躲开 CoreImage 的 `filter.setValue(_:forKey:)` 与字典的
    `params.removeValue(forKey:)`——它们在文本里跟 UserDefaults 长得一模一样。
    """
    usage = {}
    consts = {}
    corpus = ""

    def note(key: str, where: str):
        usage.setdefault(key, []).append(where)

    for path in swift_files():
        text = read_text(path)
        corpus += text
        rel = str(path.relative_to(ROOT))
        line_of = lambda pos: text[:pos].count("\n") + 1

        for m in re.finditer(r'@AppStorage\(\s*"([^"]+)"', text):
            note(m.group(1), f"{rel}:{line_of(m.start())}")

        aliases = set(re.findall(r'(?:let|var)\s+(\w+)\s*=\s*UserDefaults(?:\.standard|\(suiteName)', text))
        # 长接收者放前面，否则 `UserDefaults.standard.string(forKey:)` 会被
        # 当成「UserDefaults . standard(」——少这一条会漏掉全仓最常见的写法。
        receivers = sorted(["UserDefaults.standard", "UserDefaults"] + list(aliases), key=len, reverse=True)
        call = re.compile(
            r'\b(?:' + "|".join(re.escape(r) for r in receivers) + r')'
            r'\s*\.\s*\w+\s*\((?P<args>[^)]*?)forKey:\s*"(?P<key>[^"]+)"',
            re.S,
        )
        for m in call.finditer(text):
            note(m.group("key"), f"{rel}:{line_of(m.start())}")

        forKey_lines = [ln for ln in text.splitlines() if "forKey" in ln]
        for m in re.finditer(r'(?:static\s+)?let\s+(\w+)\s*=\s*"([^"]+)"', text):
            name, key = m.group(1), m.group(2)
            consts.setdefault(name, key)
            if not any(re.search(rf'\b{re.escape(name)}\b', ln) for ln in forKey_lines):
                continue  # 常量名从没被 forKey 用过：多半是 Keychain 服务名之类的别物
            if "\\(" in key:
                DYNAMIC_KEYS.append((key, f"{rel}:{line_of(m.start())} ({name})"))
                continue
            note(key, f"{rel}:{line_of(m.start())} ({name})")

    return usage, consts, corpus


def load_whitelist(consts: dict):
    """解析 AssistantSettingsKeys：字面量 + 通过常量引用的键 + 声明的动态键族前缀。"""
    text = read_text(WHITELIST_FILE)
    body = text.split("public enum AssistantSettingsKeys", 1)
    if len(body) != 2:
        sys.exit("❌ 没能从 SettingsSnapshot.swift 里定位 AssistantSettingsKeys")
    body = body[1]

    keys = set(re.findall(r'static let \w+ = "([^"]+)"', body))
    unparsed = []
    for name in WHITELIST_ARRAYS:
        m = re.search(rf"static let {name}: \[String\] = \[(.*?)\n    \]", body, re.S)
        if not m:
            sys.exit(f"❌ 白名单数组 {name} 结构变了，闸门需要同步更新")
        block = m.group(1)
        keys.update(re.findall(r'"([^"]+)"', block))
        # 常量引用形如 ExpenseCurrency.preferredCurrencyKey
        for ref in re.findall(r'[A-Za-z_]\w*\.[a-z]\w*', re.sub(r'//.*', '', block)):
            last = ref.split(".")[-1]
            if last in consts:
                keys.add(consts[last])

    prefixes = re.findall(r'gate:dynamic_regex\s+(\S+)', text)
    return keys, prefixes, unparsed


def main() -> int:
    audit_only = "--audit" in sys.argv
    usage, consts, corpus = collect_used_keys()
    whitelist, patterns, _ = load_whitelist(consts)

    def is_whitelisted(key: str) -> bool:
        return key in whitelist or any(re.fullmatch(p, key) for p in patterns)

    used = set(usage)
    missing = sorted(k for k in used if not is_whitelisted(k) and k not in EXEMPT)
    contradictory = sorted(k for k in EXEMPT if is_whitelisted(k))
    stale_exempt = sorted(k for k in EXEMPT if k not in used and not any(re.fullmatch(p, k) for p in patterns))

    # 反方向也查：白名单里的键如果代码里从没出现（字面量、或以 `.常量名` 引用的常量），
    # 要么功能已删、要么键名写错——写错同样是「备份里静默少了这一项」。
    unused_whitelist = []
    for key in sorted(whitelist - used):
        if any(re.fullmatch(p, key) for p in patterns):
            continue
        names = [n for n, v in consts.items() if v == key]
        if any(re.search(rf'\.{re.escape(n)}\b', corpus) for n in names):
            continue
        unused_whitelist.append(key)

    print(f"白名单 {len(whitelist)} 键（+动态键族 {len(patterns)} 个）"
          f" / 代码里的 UserDefaults 键 {len(used)} 个 / 豁免 {len(EXEMPT)} 个")

    if missing:
        print(f"\n❌ 既不在白名单、也不在豁免清单的键（{len(missing)}）：")
        for key in missing:
            print(f"  {key}")
            for where in usage[key][:3]:
                print(f"      {where}")
        print("\n   处理二选一：")
        print("   1) 是用户偏好 → 登记进 AssistantSettingsKeys 对应类型的数组；")
        print("   2) 是缓存/安全/设备状态 → 加进 scripts/check_settings_keys.py 的 EXEMPT 并写明理由。")

    if contradictory:
        print(f"\n❌ 同时出现在白名单和豁免清单里（{len(contradictory)}）：{contradictory}")

    if unused_whitelist:
        print(f"\n❌ 白名单里的键在代码中已无引用（{len(unused_whitelist)}）——"
              f"键名写错或功能已删，两种都是静默不生效：")
        for key in unused_whitelist:
            print(f"  {key}")

    if stale_exempt:
        print(f"\n⚠️  豁免清单里的键在代码里已找不到（{len(stale_exempt)}），请删掉过期条目：{stale_exempt}")

    if DYNAMIC_KEYS:
        print(f"\nℹ️  含插值的键模板（{len(DYNAMIC_KEYS)}，闸门不判定，逐条确认它们不该进备份）：")
        for key, where in DYNAMIC_KEYS:
            print(f"  {key}  ← {where}")

    if audit_only:
        print("\n（--audit：只汇报现状，不作为闸门结论）")
        return 0
    return 1 if (missing or contradictory or unused_whitelist) else 0


if __name__ == "__main__":
    sys.exit(main())
