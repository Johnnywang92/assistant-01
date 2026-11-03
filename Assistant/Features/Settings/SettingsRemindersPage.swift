import SwiftData
import SwiftUI

/// 设置子页：提醒与报告（生活习惯、睡前提醒、日报开关、月预算）。
/// 自根 SettingsView 拆分而来，所有键名与行为保持不变；
/// 「生活报告」功能大卡片已移除（首页与语音均有入口），只保留日报提醒开关。
struct SettingsRemindersPage: View {
    @AppStorage("weather_alerts_enabled") private var weatherAlertsEnabled: Bool = true
    @AppStorage("weather_morning_push_time") private var weatherMorningPushTime: String = "07:30"
    @AppStorage("todo_notification_show_sensitive_details") private var showSensitiveTodoNotifications: Bool = true
    @AppStorage("user_lifestyle_profile") private var lifestyleProfile: UserLifestyleProfile = .officeWorker
    @AppStorage("user_off_work_minutes") private var offWorkMinutes: Int = 18 * 60
    @AppStorage("context_adaptive_sorting_enabled") private var isAdaptiveSortingEnabled: Bool = true
    @AppStorage("expense_monthly_budget") private var monthlyBudget: Double = 0
    @ObservedObject private var reportManager = PeriodicReportManager.shared
    @ObservedObject private var sleepScheduler = SleepReminderScheduler.shared
    @ObservedObject private var screenTracker = ScreenTimeTracker.shared
    @Environment(\.modelContext) private var context
    @State private var showingBudgetSheet: Bool = false
    /// 刚切换到的身份；非空即弹出该身份的建议清单（上班族建议集为空，不弹）
    @State private var pendingPresetProfile: UserLifestyleProfile?

    private var offWorkTimeBinding: Binding<Date> {
        Binding(
            get: {
                let calendar = Calendar.current
                return calendar.date(bySettingHour: offWorkMinutes / 60,
                                     minute: offWorkMinutes % 60,
                                     second: 0,
                                     of: .now) ?? .now
            },
            set: { newValue in
                let calendar = Calendar.current
                let hour = calendar.component(.hour, from: newValue)
                let minute = calendar.component(.minute, from: newValue)
                offWorkMinutes = hour * 60 + minute
            }
        )
    }

    /// 早间天气变化提醒推送时间（"HH:mm"）↔ DatePicker
    private var weatherMorningPushTimeBinding: Binding<Date> {
        Binding(
            get: {
                let parts = weatherMorningPushTime.split(separator: ":").compactMap { Int($0) }
                let hour = parts.count == 2 ? parts[0] : 7
                let minute = parts.count == 2 ? parts[1] : 30
                return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now) ?? .now
            },
            set: { newDate in
                let calendar = Calendar.current
                let hour = calendar.component(.hour, from: newDate)
                let minute = calendar.component(.minute, from: newDate)
                weatherMorningPushTime = String(format: "%02d:%02d", hour, minute)
                Task {
                    await WeatherAlertService.shared.checkAlertsIfNeeded()
                }
            }
        )
    }

    /// 期望就寝时间（"HH:mm"）↔ DatePicker。00:30 表示次日凌晨。
    private var desiredBedtimeBinding: Binding<Date> {
        Binding(
            get: {
                let parts = (sleepScheduler.desiredBedtimeHHmm ?? "23:00")
                    .split(separator: ":").compactMap { Int($0) }
                let hour = parts.count == 2 ? parts[0] : 23
                let minute = parts.count == 2 ? parts[1] : 0
                return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now) ?? .now
            },
            set: { date in
                let calendar = Calendar.current
                sleepScheduler.desiredBedtimeHHmm = String(
                    format: "%02d:%02d",
                    calendar.component(.hour, from: date),
                    calendar.component(.minute, from: date)
                )
                scheduleSleepResync()
            }
        )
    }

    /// 设置改动后重算今晚建议：DatePicker 滚轮会连续触发 set，防抖 0.4s 再同步
    @State private var sleepResyncTask: Task<Void, Never>? = nil

    private func scheduleSleepResync() {
        sleepResyncTask?.cancel()
        sleepResyncTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await sleepScheduler.syncSleepReminders()
        }
    }

    private func migrateLegacyOffWorkTimeIfNeeded() {
        guard UserDefaults.standard.object(forKey: "user_off_work_minutes") == nil,
              let legacyHour = UserDefaults.standard.object(forKey: "user_off_work_hour") as? Int else { return }
        offWorkMinutes = min(max(legacyHour * 60, 0), 23 * 60 + 59)
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        SettingsIconBadge(icon: "person.crop.circle.badge.clock", color: .indigo)
                        Text("作息习惯与身份")
                    }

                    Picker("作息习惯与身份", selection: Binding(
                        get: { lifestyleProfile },
                        set: { newProfile in
                            Haptic.selection()
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                lifestyleProfile = newProfile
                            }
                            // 身份本身立即生效（情境推断靠它），配套的节奏建议要人确认才落笔
                            if !LifestyleProfilePreset.fields(for: newProfile).isEmpty {
                                pendingPresetProfile = newProfile
                            }
                        }
                    )) {
                        ForEach(UserLifestyleProfile.allCases) { profile in
                            Text(profile.shortTitle).tag(profile)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(.vertical, 2)

                if lifestyleProfile == .officeWorker {
                    HStack(spacing: 12) {
                        SettingsIconBadge(icon: "clock.fill", color: .blue)
                        DatePicker("常规下班时间", selection: offWorkTimeBinding, displayedComponents: .hourAndMinute)
                    }
                }

                HStack(spacing: 12) {
                    SettingsIconBadge(icon: "arrow.up.arrow.down.circle.fill", color: .teal)
                    Toggle("情境动态排序", isOn: $isAdaptiveSortingEnabled)
                }

                HStack(spacing: 12) {
                    SettingsIconBadge(icon: "cloud.sun.bolt.fill", color: .blue)
                    Toggle("天气突变与降温预警", isOn: $weatherAlertsEnabled)
                        .onChange(of: weatherAlertsEnabled) { _, enabled in
                            if enabled {
                                Task {
                                    await NotificationService.requestAuthorization()
                                    await WeatherAlertService.shared.checkAlertsIfNeeded()
                                }
                            } else {
                                WeatherAlertService.shared.cancelAllAlertNotifications()
                            }
                        }
                }

                if weatherAlertsEnabled {
                    HStack(spacing: 12) {
                        SettingsIconBadge(icon: "bell.badge.fill", color: .orange)
                        DatePicker("早间推送时间", selection: weatherMorningPushTimeBinding, displayedComponents: .hourAndMinute)
                    }
                }

                HStack(spacing: 12) {
                    SettingsIconBadge(icon: "lock.shield.fill", color: .purple)
                    Toggle("在锁屏通知中显示待办详情", isOn: $showSensitiveTodoNotifications)
                        .onChange(of: showSensitiveTodoNotifications) { _, _ in
                            TodoNotificationManager.shared.syncAllTodoNotifications(context: context)
                        }
                }
            } header: {
                Text("生活习惯")
            }

            // MARK: - 睡前提醒
            Section {
                HStack(spacing: 12) {
                    SettingsIconBadge(icon: "moon.stars.fill", color: .indigo)
                    Toggle("睡前提醒", isOn: Binding(
                        get: { sleepScheduler.isEnabled },
                        set: { newValue in
                            sleepScheduler.isEnabled = newValue
                            if newValue {
                                Task { await sleepScheduler.requestAuthorization() }
                            }
                            scheduleSleepResync()
                        }
                    ))
                    .tint(.indigo)
                }

                if sleepScheduler.isEnabled {
                    HStack(spacing: 12) {
                        SettingsIconBadge(icon: "bed.double.fill", color: .purple)
                        DatePicker("期望就寝时间", selection: desiredBedtimeBinding, displayedComponents: .hourAndMinute)
                    }

                    HStack(spacing: 12) {
                        SettingsIconBadge(icon: "hourglass", color: .teal)
                        Picker("提前缓冲", selection: Binding(
                            get: { sleepScheduler.windDownMinutes },
                            set: { newValue in
                                sleepScheduler.windDownMinutes = newValue
                                scheduleSleepResync()
                            }
                        )) {
                            Text("提前 15 分钟").tag(15)
                            Text("提前 30 分钟").tag(30)
                            Text("提前 45 分钟").tag(45)
                        }
                    }

                    HStack(spacing: 12) {
                        SettingsIconBadge(icon: "target", color: .green)
                        Picker("睡眠目标", selection: Binding(
                            get: { sleepScheduler.sleepGoalMinutes },
                            set: { newValue in
                                sleepScheduler.sleepGoalMinutes = newValue
                                scheduleSleepResync()
                            }
                        )) {
                            Text("6 小时").tag(360)
                            Text("6.5 小时").tag(390)
                            Text("7 小时").tag(420)
                            Text("7.5 小时").tag(450)
                            Text("8 小时").tag(480)
                        }
                    }

                    if sleepScheduler.notificationDenied {
                        Button("打开系统设置开启通知") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .foregroundStyle(AppColor.danger)
                    }
                }
            } header: {
                Text("睡前提醒")
            } footer: {
                Text("根据日常作息、运动与生理指标动态建议今晚就寝时刻。")
            }

            // MARK: - 手机屏幕使用时间感知
            Section {
                HStack(spacing: 12) {
                    SettingsIconBadge(icon: "hourglass.bottomhalf.filled", color: .cyan)
                    Stepper(value: Binding(
                        get: { screenTracker.todayScreenTimeMinutes },
                        set: { newValue in
                            screenTracker.recordScreenTime(minutes: newValue)
                            scheduleSleepResync()
                        }
                    ), in: 0...960, step: 30) {
                        HStack {
                            Text("今日屏幕使用时长")
                            Spacer()
                            Text("\(screenTracker.todayScreenTimeMinutes / 60) 小时 \(screenTracker.todayScreenTimeMinutes % 60) 分钟")
                                .foregroundStyle(AppColor.secondaryText)
                        }
                    }
                }
            } header: {
                Text("屏幕使用时间")
            } footer: {
                Text("用于动态评估睡前蓝光负荷，支持快捷指令自动化上报。")
            }

            // MARK: - 定期复盘报告
            Section {
                HStack(spacing: 12) {
                    SettingsIconBadge(icon: "chart.bar.doc.horizontal.fill", color: .green)
                    Toggle("每日日报提醒", isOn: $reportManager.isDailyReportEnabled)
                        .tint(.green)
                }
            } header: {
                Text("定期报告")
            }

            // MARK: - 月预算（今日安心花）
            Section {
                Button {
                    showingBudgetSheet = true
                    Haptic.light()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIconBadge(icon: "yensign.circle.fill", color: .orange)
                        Text("月预算")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(monthlyBudget > 0
                             ? "¥\(String(format: "%.0f", monthlyBudget))"
                             : "未设置")
                            .font(.subheadline)
                            .foregroundStyle(monthlyBudget > 0 ? .secondary : Color.orange)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showingBudgetSheet) {
                    BudgetEditSheet()
                }
            } header: {
                Text("消费预算")
            } footer: {
                Text("用于智能记账页计算每日安心花额度。")
            }
        }
        .themedScrollContentBackground()
        .themedAppBackground()
        .themedRow()
        .navigationTitle(L10n.tr("提醒与报告"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            migrateLegacyOffWorkTimeIfNeeded()
        }
        .sheet(item: $pendingPresetProfile) { profile in
            LifestylePresetDiffSheet(profile: profile)
        }
    }
}
