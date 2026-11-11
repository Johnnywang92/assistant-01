import AssistantCore
import Foundation
import SwiftData
import WidgetKit

/// 主应用侧快照同步与扩展指令对账：
/// 1. 启动 / 回前台 / 后台 / 通知交互后 → 从 SwiftData 刷新 App Group 快照，桌面与锁屏组件据此渲染；
/// 2. 扩展（小组件勾选 / 手表卡片按钮）产生的指令队列在此按序落库，保证三端最终一致。
@MainActor
final class WidgetSnapshotSyncController: WidgetBridgeAppHook {
    static let shared = WidgetSnapshotSyncController()

    /// 最近已落库确认的手表指令 ID 环形缓冲（最多保留 100 条，随快照发给手表以消掉手表待确认列表）
    private var recentAckedCommandIDs: [UUID] = []
    private static let maxAckedIDs = 100

    private init() {}

    func recordAckedCommandID(_ id: UUID) {
        guard !recentAckedCommandIDs.contains(id) else { return }
        recentAckedCommandIDs.append(id)
        if recentAckedCommandIDs.count > Self.maxAckedIDs {
            recentAckedCommandIDs.removeFirst(recentAckedCommandIDs.count - Self.maxAckedIDs)
        }
    }

    func isCommandAcked(_ id: UUID) -> Bool {
        recentAckedCommandIDs.contains(id)
    }

    // MARK: - 快照构建

    func refreshSnapshot(context: ModelContext) {
        // 刷新共享快照前先将扩展侧（小组件/手表）积压的指令落库，防止用旧库状态覆盖乐观快照
        _ = drainAndApplyPendingCommands(context: context)
        let snapshot = buildSnapshot(context: context)
        WidgetSnapshotStore.save(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
        PhoneWatchBridge.shared.pushSnapshot(snapshot)
    }

    private func buildSnapshot(context: ModelContext) -> WidgetSnapshot {
        // 谓词化只拉活跃待办，避免每次刷新都把全部已完成历史物化到主线程
        let activeRaw = TodoStatus.active.rawValue
        let activeItems = (try? context.fetch(FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.statusRaw == activeRaw }
        ))) ?? []
        var sorted = activeItems
        TodoPriority.sort(&sorted)

        let topEntries = sorted.prefix(6).map(Self.entry(for:))

        let parcelEntries = sorted
            .filter { $0.type == .parcel || $0.type == .returnParcel }
            .filter { !($0.pickupCode ?? "").isEmpty }
            .map(Self.entry(for:))

        let todayExpense = Self.todayExpenseTotal(context: context) ?? 0
        let todayPractice = Self.todayPracticeEntry(context: context)
        let todayWaterML = Self.todayWaterEffectiveTotal(context: context)
        let waterGoalML = AppSettings.dailyWaterGoalML
        let todayMood = Self.todayMoodSummary(context: context)
        let departureSnapshot = Self.buildDepartureSnapshot(context: context)
        let travelSnapshot = Self.buildTravelSnapshot(activeItems: sorted)

        // 药品与习惯各只查一次，逐条与汇总共用同一份数据（避免同一张表查两遍）。
        let enabledPlans = (try? context.fetch(FetchDescriptor<MedicationPlan>(
            predicate: #Predicate { $0.isEnabled }
        ))) ?? []
        let enabledHabits = (try? context.fetch(FetchDescriptor<PeriodicHabit>(
            predicate: #Predicate { $0.isEnabled },
            sortBy: [SortDescriptor(\.nextDueAt)]
        ))) ?? []
        // 服药完成证据（今日已完成的服药待办）：逐条与汇总共用同一份数据。
        // 它是「今天到底服了几顿」的**唯一精确来源**——`MedicationPlan.lastTakenAt`
        // 只有一个时间戳，只能证明「至少服过一次」。
        // 查两遍同一张表是白白的开销（首页快照是主线程构建的）。
        let doseEvidence = MedicationDoseEvidence.todayEntries(context: context)
        let medications = Self.buildMedicationEntries(activeItems: sorted, plans: enabledPlans, evidence: doseEvidence)
        let habits = Self.buildHabitEntries(habits: enabledHabits)
        let medicationSummary = Self.buildMedicationSummary(plans: enabledPlans, evidence: doseEvidence)
        let habitSummary = Self.buildHabitSummary(habits: enabledHabits)
        let healthSnapshot = Self.buildHealthSnapshot(todayWaterML: todayWaterML, context: context)
        let homeOverview = Self.buildHomeOverview(context: context, activeItems: sorted)
        let anniversaries = Self.buildAnniversaryEntries(context: context)

        return WidgetSnapshot(
            topTodos: Array(topEntries),
            parcels: parcelEntries,
            todayExpense: todayExpense,
            todayPractice: todayPractice,
            todayWaterML: todayWaterML,
            waterGoalML: waterGoalML,
            todayMood: todayMood,
            departureSnapshot: departureSnapshot,
            travelSnapshot: travelSnapshot,
            medications: medications,
            habits: habits,
            healthSnapshot: healthSnapshot,
            homeOverview: homeOverview,
            anniversaries: anniversaries,
            medicationSummary: medicationSummary,
            habitSummary: habitSummary,
            ackedCommandIDs: recentAckedCommandIDs,
            generatedAt: .now
        )
    }

    // MARK: - 首页概览（与 App 首页同源）

    /// 构建小组件用的首页概览。
    ///
    /// **必须与 App 首页用同一份 Core 计算**：这里调用 `HomeSnapshotBuilder`，
    /// 而不是自己数一遍完成数/空闲时间。否则会出现「桌面显示 2/4、App 显示 3/4」。
    private static func buildHomeOverview(
        context: ModelContext,
        activeItems: [TodoItem]
    ) -> WidgetHomeOverview? {
        let calendar = Calendar.current
        let now = Date.now
        let startOfToday = calendar.startOfDay(for: now)
        guard let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) else {
            return nil
        }

        // 今日口径：今天到期（含逾期）或今天创建的活跃待办 + 今天完成的。
        // 与 App 首页 `homeFacts` 保持一致。
        var facts: [HomeTodoFact] = []
        for item in activeItems {
            let effective = item.reminderOverrideAt ?? item.dueAt
            if let effective {
                guard effective < startOfTomorrow else { continue }
            } else {
                guard item.createdAt >= startOfToday else { continue }
            }
            facts.append(HomeTodoFact(
                id: item.id,
                isDone: false,
                dueAt: effective,
                createdAt: item.createdAt,
                isOverdue: (effective ?? .distantFuture) < now
            ))
        }

        let doneRaw = TodoStatus.done.rawValue
        let completedToday = (try? context.fetch(FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.statusRaw == doneRaw }
        ))) ?? []
        for item in completedToday {
            guard let completedAt = item.completedAt, completedAt >= startOfToday else { continue }
            facts.append(HomeTodoFact(
                id: item.id,
                isDone: true,
                dueAt: item.reminderOverrideAt ?? item.dueAt,
                createdAt: item.createdAt
            ))
        }

        let schedule = Self.homeScheduleFact(context: context, activeItems: activeItems, now: now)
        let snapshot = HomeSnapshotBuilder.make(
            todos: facts,
            schedule: schedule,
            now: now,
            calendar: calendar
        )

        // 节奏比例：空闲段与已安排段各占多少
        var freeRatio = 0.0
        var busyRatio = 0.0
        for slice in snapshot.segments {
            switch slice.segment {
            case .free: freeRatio += slice.weight
            case .busy, .reminder: busyRatio += slice.weight
            }
        }

        // 主任务标题：Core 判定 ID，标题由 App 查表（扩展拿不到 SwiftData）
        let priorityTitle: String? = {
            guard let id = snapshot.priorityTaskID,
                  let item = activeItems.first(where: { $0.id == id }) else { return nil }
            return item.title
        }()

        return WidgetHomeOverview(
            done: snapshot.done,
            total: snapshot.total,
            freeMinutes: snapshot.freeMinutes,
            isAllDayFree: snapshot.isAllDayFree,
            priorityTaskTitle: priorityTitle,
            freeRatio: freeRatio,
            busyRatio: busyRatio
        )
    }

    /// 当日窗口与占用。与 App 首页 `homeSchedule` 保持同源：
    /// 起床 → 下班窗口（终点不含）+ 系统日历非全天日程 + 定时待办作为提醒点。
    private static func homeScheduleFact(
        context: ModelContext,
        activeItems: [TodoItem],
        now: Date
    ) -> HomeScheduleFact {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)

        // 与 App 首页共用同一组 @AppStorage 键
        let wakeMinutes = UserDefaults.standard.integer(forKey: "day_timeline_wake_minutes")
        let offMinutes = UserDefaults.standard.integer(forKey: "day_timeline_off_minutes")
        let wake = calendar.date(
            byAdding: .minute,
            value: wakeMinutes > 0 ? wakeMinutes : 7 * 60 + 30,
            to: startOfToday
        ) ?? startOfToday
        let off = calendar.date(
            byAdding: .minute,
            value: max(offMinutes > 0 ? offMinutes : 19 * 60, (wakeMinutes > 0 ? wakeMinutes : 7 * 60 + 30) + 60),
            to: startOfToday
        ) ?? wake
        guard off > wake else { return .unscheduled }

        let dayEnd = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? off
        let busy = CalendarAgendaService.shared.events
            .filter { !$0.isAllDay && $0.startDate < dayEnd && $0.endDate > startOfToday }
            .map { HomeBusyInterval(start: $0.startDate, end: $0.endDate) }
        let reminders = activeItems
            .compactMap { $0.reminderOverrideAt ?? $0.dueAt }
            .filter { $0 >= wake && $0 < off }

        return HomeScheduleFact(
            windowStart: wake,
            windowEnd: off,
            busy: busy,
            reminders: reminders
        )
    }

    // MARK: - 纪念日倒计时

    /// 构建纪念日倒计时快照（按距离升序，最多 5 条）。
    /// 农历换算由 Core 的 `AnniversaryCountdown` 统一处理。
    private static func buildAnniversaryEntries(context: ModelContext) -> [WidgetAnniversaryEntry] {
        let items = (try? context.fetch(FetchDescriptor<AnniversaryItem>())) ?? []
        guard !items.isEmpty else { return [] }

        let calendar = Calendar.current
        let now = Date.now
        return items
            .map { item in
                AnniversaryCountdown.entry(
                    id: item.id,
                    title: item.title,
                    targetDate: item.targetDate,
                    isLunar: item.isLunar,
                    now: now,
                    calendar: calendar
                )
            }
            .sorted { lhs, rhs in
                if lhs.daysUntil != rhs.daysUntil { return lhs.daysUntil < rhs.daysUntil }
                return lhs.title < rhs.title
            }
            .prefix(5)
            .map { $0 }
    }

    private static func buildDepartureSnapshot(context: ModelContext) -> WatchDepartureSnapshot? {
        let allItems = (try? context.fetch(FetchDescriptor<DepartureCheckItem>(
            sortBy: [SortDescriptor(\.createdAt)]
        ))) ?? []
        guard !allItems.isEmpty else { return nil }

        let activeScene = SituationalContextEngine.shared.effectiveDepartureScene()
        let filtered: [DepartureCheckItem]
        let sceneName: String
        if let scene = activeScene {
            let sceneItems = allItems.filter { $0.scene == scene }
            if !sceneItems.isEmpty {
                filtered = sceneItems
                sceneName = scene.displayName
            } else {
                filtered = allItems
                sceneName = "全部物品"
            }
        } else {
            filtered = allItems
            sceneName = "日常出行"
        }

        let sorted = filtered.sorted { a, b in
            if a.isChecked != b.isChecked { return !a.isChecked && b.isChecked }
            if a.isEssential != b.isEssential { return a.isEssential && !b.isEssential }
            return a.createdAt < b.createdAt
        }

        // 汇总计数基于**全部**条目，不是截断后的 12 条：
        // 否则「20 件里确认了 12 件」会被显示成「全部带齐」。
        let checkedCount = filtered.filter(\.isChecked).count
        let totalCount = filtered.count

        let watchItems = sorted.prefix(12).map {
            WatchDepartureItem(
                id: $0.id,
                title: $0.title,
                isChecked: $0.isChecked,
                isEssential: $0.isEssential,
                locationNote: $0.storageLocationNote
            )
        }
        return WatchDepartureSnapshot(
            sceneName: sceneName,
            items: Array(watchItems),
            checkedCount: checkedCount,
            totalCount: totalCount
        )
    }

    /// 构建行程护航快照。
    ///
    /// 口径全部走 Core 的 `TravelCountdownBuilder`：
    /// - 窗口 3 天（旧实现是 36 小时硬窗口 → 3 天后的行程直接从手表消失）；
    /// - 选**最近发车**的那一趟，不按待办优先级取第一条；
    /// - **没有可靠发车时刻就不产出倒计时**，不再编造 `now + 1 小时`
    ///   （那会让手表上出现一条根本不存在的「1 小时后发车」）。
    private static func buildTravelSnapshot(activeItems: [TodoItem]) -> WatchTravelSnapshot? {
        let now = Date.now
        let candidates = activeItems.map { item -> TravelDepartureCandidate in
            let info = TravelDepartureDetector.ticketInfo(
                title: item.title,
                detail: item.detail,
                sourceText: item.sourceText
            )
            let isTravel = info.hasSignal
                || TravelDepartureDetector.looksLikeTravel(
                    title: item.title,
                    detail: item.detail,
                    sourceText: item.sourceText
                )
            return TravelDepartureCandidate(
                id: item.id,
                title: item.displayConciseTitle,
                departureAt: item.dueAt,
                ticketSummary: info.summary,
                gate: info.gate,
                place: item.displayLocationText,
                isTravel: isTravel
            )
        }

        guard let countdown = TravelCountdownBuilder.build(candidates: candidates, now: now) else {
            return nil
        }
        return WatchTravelSnapshot(
            id: countdown.candidate.id,
            title: countdown.candidate.title,
            departureDate: countdown.departureAt,
            ticketSummary: countdown.candidate.ticketSummary,
            gate: countdown.candidate.gate,
            place: countdown.candidate.place
        )
    }

    private static func buildMedicationEntries(
        activeItems: [TodoItem],
        plans: [MedicationPlan],
        evidence: [MedicationDoseEvidence.Entry]
    ) -> [WatchMedicationEntry] {
        guard !plans.isEmpty else { return [] }
        let cal = Calendar.current
        let now = Date.now
        let medTodos = activeItems.filter { $0.type == .medication }
        // 今日已完成的服药待办（用于识别「漏服」的那一顿 + 精确算出已服几顿）
        let completedMedTitles = Set(evidence.map {
            MedicationTodoMaterializer.todoTitle(medName: $0.medName, timePoint: $0.timePoint)
        })

        // **待服排前面**再截断：快照里的条目是 `prefix(6)`，
        // 若按数据库原始顺序截断，可能截到的全是已服完的，
        // 而真正待服的第 7 条根本进不来 → 组件显示「已服完」→ 漏服。
        let sortedPlans = MedicationHabitDoseResolver.sortMedicationsPendingFirst(
            plans,
            isPending: { plan in
                !MedicationHabitDoseResolver.isMedicationTakenToday(
                    lastTakenAt: plan.lastTakenAt, now: now, calendar: cal)
            },
            nameOf: { $0.medName }
        )

        return sortedPlans.prefix(6).map { plan in
            // **精确匹配**（标题全等），不用 `contains(medName)`：
            // 药名可能互为子串（「维生素D」⊂「维生素D3」），
            // 用 contains 会让「维生素D」认领「维生素D3」的待办 → 另一种药被漏服。
            let slotTitles = MedicationTodoMaterializer.slotTitles(
                medName: plan.medName,
                dailyTimePoints: plan.dailyTimePoints,
                on: now,
                calendar: cal
            )
            let matchedTodo = medTodos.first { slotTitles.contains($0.title) }
            // 进度与下一时点由 Core 算（证据口径：精确到时点，不谎报也不多报）
            let progress = MedicationHabitDoseResolver.doseProgress(
                lastTakenAt: plan.lastTakenAt,
                dailyTimePoints: plan.dailyTimePoints,
                now: now,
                calendar: cal,
                completedSlotTimes: MedicationDoseEvidence.completedSlotTimes(
                    medName: plan.medName, entries: evidence)
            )
            // 「今天不用再吃了」= **今天每一顿都有完成记录**。
            //
            // 不能只看「今天有没有服药记录」+「没有待办」：一天 3 次的药只吃了
            // 08:00 那顿时，两个条件也会同时成立 → 谎报已服完 → 后面两顿漏服。
            let isTaken = progress.isFullySatisfied
            let nextSlotText = MedicationHabitDoseResolver.nextScheduledSlotText(
                dailyTimePoints: plan.dailyTimePoints, now: now, calendar: cal)
            // 漏服的那一顿（已过时点但未完成）——必须显式提示，否则用户会默默漏服
            let missedSlotText = MedicationHabitDoseResolver.missedSlotText(
                medName: plan.medName,
                dailyTimePoints: plan.dailyTimePoints,
                completedTitles: completedMedTitles,
                now: now,
                calendar: cal
            )
            return WatchMedicationEntry(
                id: plan.id,
                medName: plan.medName,
                dosage: plan.dosage,
                mealRelationText: plan.mealRelation.displayName,
                timePointsText: plan.dailyTimePoints.joined(separator: " / "),
                isTakenToday: isTaken,
                activeTodoID: matchedTodo?.id,
                scheduledCount: progress.scheduledCount,
                takenCount: progress.takenLowerBound,
                nextDueText: nextSlotText,
                missedSlotText: missedSlotText
            )
        }
    }

    /// 今日服药汇总。
    ///
    /// **必须在这里算，不能让小组件自己聚合**：快照里的 `medications` 是
    /// `prefix(6)` 截断的，扩展若拿这 6 条求和，会把「10 个药里服了 6 个」
    /// 显示成「全部服完」——这类谎报会直接导致漏服。
    ///
    /// 与 `buildMedicationEntries` 共用同一份完成证据（同一个函数里查两遍
    /// 同一张表是白白的开销，首页快照是主线程构建的）。
    private static func buildMedicationSummary(
        plans: [MedicationPlan],
        evidence: [MedicationDoseEvidence.Entry]
    ) -> WidgetMedicationSummary? {
        guard !plans.isEmpty else { return nil }
        let cal = Calendar.current
        let now = Date.now

        var scheduledDoseCount = 0
        var takenDoseLowerBound = 0
        var pendingPlanCount = 0
        var pendingDoseCount = 0
        var allSatisfied = true

        for plan in plans {
            let progress = MedicationHabitDoseResolver.doseProgress(
                lastTakenAt: plan.lastTakenAt,
                dailyTimePoints: plan.dailyTimePoints,
                now: now,
                calendar: cal,
                completedSlotTimes: MedicationDoseEvidence.completedSlotTimes(
                    medName: plan.medName, entries: evidence)
            )
            scheduledDoseCount += progress.scheduledCount
            takenDoseLowerBound += progress.takenLowerBound
            // 逐计划累加待服数：已服完的计划贡献 0（不是差值算出的 2），
            // 否则聚合后会虚报 → 用户重复服药。
            pendingDoseCount += progress.pendingCount
            if progress.pendingCount > 0 {
                pendingPlanCount += 1
                allSatisfied = false
            }
        }

        return WidgetMedicationSummary(
            scheduledDoseCount: scheduledDoseCount,
            takenDoseLowerBound: takenDoseLowerBound,
            pendingPlanCount: pendingPlanCount,
            totalPlanCount: plans.count,
            isAllSatisfied: allSatisfied,
            pendingDoseCount: pendingDoseCount
        )
    }

    private static func buildHabitEntries(habits: [PeriodicHabit]) -> [WatchHabitEntry] {
        guard !habits.isEmpty else { return [] }
        let cal = Calendar.current
        let now = Date.now

        // **待打卡排前面**再截断（与药品同理：截断在前会把待打卡的挤掉）。
        let sortedHabits = MedicationHabitDoseResolver.sortHabitsDueFirst(
            habits,
            isDue: { habit in
                MedicationHabitDoseResolver.isHabitDueToday(
                    nextDueAt: habit.nextDueAt, lastCompletedAt: habit.lastCompletedAt,
                    now: now, calendar: cal)
            },
            dueAt: { $0.nextDueAt },
            titleOf: { $0.title }
        )

        return sortedHabits.prefix(6).map { habit in
            // 口径统一到 Core：今日是否该打卡（含逾期），与 App 列表同源。
            let isDue = MedicationHabitDoseResolver.isHabitDueToday(
                nextDueAt: habit.nextDueAt,
                lastCompletedAt: habit.lastCompletedAt,
                now: now,
                calendar: cal
            )
            return WatchHabitEntry(
                id: habit.id,
                title: habit.title,
                recurrenceText: habit.recurrence.displayName,
                isDueToday: isDue,
                nextDueText: MedicationHabitDoseResolver.slotTimeText(habit.nextDueAt, calendar: cal)
            )
        }
    }

    /// 今日打卡汇总（同样在主 App 侧算，避免截断失真）。
    ///
    /// 与 `buildHabitEntries` 共用同一次 fetch。
    private static func buildHabitSummary(habits: [PeriodicHabit]) -> WidgetHabitSummary? {
        guard !habits.isEmpty else { return nil }
        let cal = Calendar.current
        let now = Date.now

        let dueCount = habits.filter { habit in
            MedicationHabitDoseResolver.isHabitDueToday(
                nextDueAt: habit.nextDueAt,
                lastCompletedAt: habit.lastCompletedAt,
                now: now,
                calendar: cal
            )
        }.count

        return WidgetHabitSummary(dueCount: dueCount, totalCount: habits.count)
    }

    private static func buildHealthSnapshot(todayWaterML: Double, context: ModelContext) -> WatchHealthSnapshot? {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: .now)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

        let foodDescriptor = FetchDescriptor<FoodIntakeRecord>(
            predicate: #Predicate { $0.date >= dayStart && $0.date < dayEnd }
        )
        let foodRecords = (try? context.fetch(foodDescriptor)) ?? []
        let todayFoodCalories: Double? = foodRecords.isEmpty ? nil : foodRecords.reduce(0.0) { $0 + $1.consumedCalories }

        var rawSnap = HealthKitService.shared.snapshot
        if rawSnap == nil {
            var snapDesc = FetchDescriptor<HealthDaySnapshotRecord>(
                predicate: #Predicate { $0.day == dayStart }
            )
            snapDesc.fetchLimit = 1
            if let rec = (try? context.fetch(snapDesc))?.first {
                let restored = rec.toSnapshot()
                if restored.readState == .hasData {
                    rawSnap = restored
                }
            }
        }

        let effectiveSnap = rawSnap?.overridingDietaryWater(todayWaterML > 0 ? todayWaterML : nil)
        let hasHealthData = effectiveSnap?.readState == .hasData

        guard hasHealthData || todayFoodCalories != nil else { return nil }

        // 两个指数必须共用同一份身体档案事实，否则桌面/手表与 App 会给出不同分数。
        let bodyProfile = BodyProfileContextProvider.shared.context()
        let vitality = VitalityEvaluator.evaluate(
            snapshot: effectiveSnap,
            foodIntakeCalories: todayFoodCalories,
            profile: bodyProfile
        )
        let pleasure = HealthKitService.shared.pleasureEvaluation
            ?? PleasureIndexEvaluator.evaluate(
                snapshot: effectiveSnap,
                baseline: HealthKitService.shared.userBaseline,
                profile: bodyProfile
            )

        let stepsVal = (effectiveSnap?.value(for: .stepCount)?.value).map { Int($0.rounded()) }
        let rhrVal = effectiveSnap?.value(for: .restingHeartRate)?.value

        return WatchHealthSnapshot(
            vitalityScore: vitality.score,
            vitalityBadge: vitality.level.badge,
            pleasureScore: hasHealthData ? pleasure.pleasureScore : nil,
            pleasureBadge: hasHealthData ? pleasure.state.badge : nil,
            stressBadge: hasHealthData ? pleasure.stressLevel.badge : nil,
            headlineAdvice: hasHealthData ? pleasure.advice : vitality.suggestion,
            sleepHours: effectiveSnap?.sleepHours,
            hrvMS: effectiveSnap?.heartRateVariability,
            restingHR: rhrVal,
            steps: stepsVal
        )
    }

    private static func todayWaterEffectiveTotal(context: ModelContext) -> Double {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: .now)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let descriptor = FetchDescriptor<WaterIntakeRecord>(
            predicate: #Predicate { $0.date >= dayStart && $0.date < dayEnd }
        )
        guard let records = try? context.fetch(descriptor) else { return 0 }
        return records.reduce(0) { $0 + $1.effectiveHydrationML }
    }

    private static func todayMoodSummary(context: ModelContext) -> MoodCheckInSummary? {
        let startOfDay = Calendar.current.startOfDay(for: .now)
        var descriptor = FetchDescriptor<MoodCheckInRecord>(
            predicate: #Predicate { $0.day == startOfDay }
        )
        descriptor.fetchLimit = 1
        guard let record = (try? context.fetch(descriptor))?.first else { return nil }
        return MoodCheckInSummary(mood: record.moodScore, energy: record.energyScore, stress: record.stressScore)
    }

    /// 今日练习快照：只取最近活跃（最近打卡优先，否则最近开始）的进行中路径。
    /// 锁屏/桌面组件据此显示连续天数与今日是否打卡，点击深链到学习路径页。
    /// 按 pathID 谓词定向取数，不再为一条路径全表物化 stages/todos/logs。
    private static func todayPracticeEntry(context: ModelContext) -> WidgetPracticeEntry? {
        let activeRaw = SkillPathStatus.active.rawValue
        let paths = ((try? context.fetch(FetchDescriptor<SkillPath>(
            predicate: #Predicate { $0.statusRaw == activeRaw }
        ))) ?? [])
        guard let path = paths.sorted(by: {
            ($0.lastPracticedAt ?? $0.startedAt) > ($1.lastPracticedAt ?? $1.startedAt)
        }).first else { return nil }

        let pid = path.id
        let logs = (try? context.fetch(FetchDescriptor<SkillPracticeLog>(
            predicate: #Predicate { $0.pathID == pid }
        ))) ?? []
        let stages = (try? context.fetch(FetchDescriptor<SkillStage>(
            predicate: #Predicate { $0.pathID == pid }
        ))) ?? []
        let currentStage = stages.first { $0.index == path.currentStageIndex }

        return WidgetPracticeEntry(
            pathID: path.id,
            title: path.title,
            stageName: currentStage?.name ?? "进行中",
            streakDays: SkillPathManager.streakDays(from: logs.map { $0.practicedAt }, now: .now),
            minutesThisWeek: SkillPathManager.minutesThisWeek(from: logs, now: .now),
            weeklyTargetMinutes: path.weeklyMinutes,
            isPracticedToday: logs.contains { Calendar.current.isDateInToday($0.practicedAt) }
        )
    }

    private static func entry(for item: TodoItem) -> WidgetTodoEntry {
        WidgetTodoEntry(
            id: item.id,
            title: item.displayConciseTitle,
            typeRaw: item.typeRaw,
            pickupCode: item.pickupCode,
            stationName: {
                let st = item.station?.trimmingCharacters(in: .whitespacesAndNewlines)
                let loc = item.location?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (st?.isEmpty == false ? st : loc)
            }(),
            dueAt: item.dueAt,
            isRecurring: item.isRecurring
        )
    }

    /// 今日支出合计（非收入、非待结算）。查询抛错返回 nil：调用方据此省略或提示，
    /// 不能把「读失败」当成「今天没花钱」报给用户。
    private static func todayExpenseTotal(context: ModelContext) -> Double? {
        // 只取今日窗口内的账单，避免全量历史支出记录物化到主线程
        let calendar = Calendar.current
        let now = Date.now
        let dayStart = calendar.startOfDay(for: now)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let descriptor = FetchDescriptor<ExpenseRecord>(
            predicate: #Predicate { $0.date >= dayStart && $0.date < dayEnd }
        )
        guard let records = try? context.fetch(descriptor) else { return nil }
        // 与 App 头部「今日支出」同一口径，见 ExpenseRecord.countsAsTodayExpense
        return records
            .filter { $0.countsAsTodayExpense(now: now, calendar: calendar) }
            .reduce(0) { $0 + $1.amount }
    }

    // MARK: - 指令对账（扩展 → 主应用）

    /// 单条指令的处理结果。只有 `.applied` / `.consumed` 才允许从队列摘除，
    /// `.retry` 必须留在队首——否则「报已成功、实际没落库」会再次发生。
    private enum CommandOutcome {
        /// 已产生变更，`context.save()` 成功后才能摘除
        case applied
        /// 重试也不会成功（条目已不存在、输入无法解析），直接摘除
        case consumed
        /// 暂时失败（查询异常等），保留在队首等下次对账
        case retry
    }

    private struct CommandBatchResult {
        var consumed = 0
        var hitRetry = false
    }

    @discardableResult
    private func drainAndApplyPendingCommands(context: ModelContext) -> Bool {
        var didProcess = false
        // 有界兜底循环：对账期间扩展可能继续入队，处理完再重读一轮
        for _ in 0..<3 {
            let commands = WidgetSnapshotStore.drainCommands()
            guard !commands.isEmpty else { break }
            let batch = processCommandBatch(commands, context: context)
            if batch.consumed > 0 { didProcess = true }
            // 队首指令暂时失败或整批都没推进：本轮到此为止，留待下次对账，不空转重试
            if batch.hitRetry || batch.consumed == 0 { break }
        }
        return didProcess
    }

    func processPendingCommands(context: ModelContext) {
        if drainAndApplyPendingCommands(context: context) {
            refreshSnapshot(context: context)
        }
    }

    /// 逐条执行队首指令，返回本次可以安全摘除的条数。
    /// 落库成功后才裁剪队列；`save` 失败则回滚并保留整批，下次对账重来。
    @discardableResult
    private func processCommandBatch(_ commands: [WidgetCommand], context: ModelContext) -> CommandBatchResult {
        var result = CommandBatchResult()
        var notifications: [TodoItem] = []
        for command in commands {
            switch apply(command, context: context, deferredNotifications: &notifications) {
            case .applied, .consumed:
                result.consumed += 1
            case .retry:
                result.hitRetry = true
                // 已处理成功的队首前缀照常落库并摘除；失败的那条及之后的指令全部保留
                if result.consumed > 0, !commit(result.consumed, context: context) {
                    result.consumed = 0
                    return result
                }
                scheduleDeferredNotifications(notifications)
                return result
            }
        }
        if result.consumed > 0, !commit(result.consumed, context: context) {
            result.consumed = 0
            return result
        }
        scheduleDeferredNotifications(notifications)
        return result
    }

    /// 落库成功后才排通知（审计 SVC-04：先排会留下指向不存在待办的提醒）。
    private func scheduleDeferredNotifications(_ items: [TodoItem]) {
        for item in items {
            TodoNotificationManager.shared.scheduleNotification(for: item)
        }
    }

    private func commit(_ count: Int, context: ModelContext) -> Bool {
        do {
            try context.save()
        } catch {
            context.rollback()
            print("⚠️ [WidgetSync] 指令落库失败，保留队列待下次对账: \(error.localizedDescription)")
            return false
        }
        WidgetSnapshotStore.removeFirst(count)
        return true
    }

    private func apply(
        _ command: WidgetCommand,
        context: ModelContext,
        deferredNotifications: inout [TodoItem]
    ) -> CommandOutcome {
        switch command {
        case .completeTodo(let id):
            return completeInDB(id: id, context: context)

        case .snoozeTodo(let id, let minutes):
            let result = snoozeInDB(id: id, minutes: minutes, tomorrow: false, context: context)
            if let item = result.item { deferredNotifications.append(item) }
            return result.outcome

        case .snoozeTomorrow(let id):
            let result = snoozeInDB(id: id, minutes: 0, tomorrow: true, context: context)
            if let item = result.item { deferredNotifications.append(item) }
            return result.outcome

        case .toggleDeparture(let id, let isChecked):
            return toggleDepartureInDB(id: id, isChecked: isChecked, context: context)

        case .completeAllDeparture(let ids):
            return completeAllDepartureInDB(ids: ids, context: context)

        case .quickAddExpense(let text):
            return quickAddExpenseInDB(text: text, context: context)

        case .quickAddTodo(let text):
            guard let item = quickAddTodoInDB(text: text, context: context) else { return .consumed }
            deferredNotifications.append(item)
            return .applied

        case .logMood(let mood, let energy, let stress):
            return logMoodInDB(mood: mood, energy: energy, stress: stress, context: context)

        case .addWater(let beverageRaw, let volumeML):
            return addWaterInDB(beverageRaw: beverageRaw, volumeML: volumeML, context: context)

        case .markMedicationTaken(let planID, let todoID):
            return markMedicationTakenInDB(planID: planID, todoID: todoID, context: context)

        case .completeHabit(let habitID):
            return completeHabitInDB(habitID: habitID, context: context)
        }
    }

    @discardableResult
    private func logMoodInDB(mood: Int, energy: Int, stress: Int, context: ModelContext) -> CommandOutcome {
        let clampedMood = min(max(mood, 1), 5)
        let clampedEnergy = min(max(energy, 1), 5)
        let clampedStress = min(max(stress, 1), 5)
        let startOfDay = Calendar.current.startOfDay(for: .now)
        var descriptor = FetchDescriptor<MoodCheckInRecord>(
            predicate: #Predicate { $0.day == startOfDay }
        )
        descriptor.fetchLimit = 1
        do {
            if let existing = try context.fetch(descriptor).first {
                existing.update(mood: clampedMood, energy: clampedEnergy, stress: clampedStress, note: existing.note)
            } else {
                let record = MoodCheckInRecord(
                    day: startOfDay,
                    moodScore: clampedMood,
                    energyScore: clampedEnergy,
                    stressScore: clampedStress,
                    note: nil
                )
                context.insert(record)
            }
            return .applied
        } catch {
            print("⚠️ [WidgetSync] 情绪微打卡查询失败，保留重试: \(error.localizedDescription)")
            return .retry
        }
    }

    @discardableResult
    private func addWaterInDB(beverageRaw: String, volumeML: Double, context: ModelContext) -> CommandOutcome {
        guard volumeML > 0, volumeML <= 5000 else { return .consumed }
        let bev = HydrationBeverageType(rawValue: beverageRaw) ?? .plainWater
        let record = WaterIntakeRecord(
            date: .now,
            beverageType: bev,
            volumeML: volumeML,
            note: "Apple Watch 快捷补水"
        )
        context.insert(record)
        let effectiveML = record.effectiveHydrationML
        let date = record.date
        Task {
            _ = await HealthKitService.shared.recordWaterIntake(amountML: effectiveML, date: date)
        }
        return .applied
    }

    /// 处理来自 Apple Watch 的带 ID 指令信封（幂等对账 + 落库 + 刷新快照并返回用户可见回执文案）
    func handleWatchCommandEnvelope(_ envelope: WatchCommandEnvelope, context: ModelContext) async -> String {
        if isCommandAcked(envelope.id) {
            return "已同步 ✓"
        }

        switch envelope.command {
        case .quickAddExpense(let text):
            if let reply = await handleQuickAddExpense(text: text) {
                recordAckedCommandID(envelope.id)
                refreshSnapshot(context: context)
                return reply
            }
            // 若未识别出金额，尝试识别是否是快速记待办或饮水
            if let drink = HydrationNaturalLanguageParser.parse(text) {
                var notifications: [TodoItem] = []
                let outcome = apply(.addWater(beverageRaw: drink.beverageType.rawValue, volumeML: drink.volumeML), context: context, deferredNotifications: &notifications)
                if outcome == .applied, saveHook(context, action: "手表语音补水") {
                    recordAckedCommandID(envelope.id)
                    refreshSnapshot(context: context)
                    return "已记录 \(drink.customName) \(Int(drink.volumeML))ml"
                }
            }
            if let todoReply = await handleQuickAddTodo(text: text) {
                recordAckedCommandID(envelope.id)
                refreshSnapshot(context: context)
                return todoReply
            }
            recordAckedCommandID(envelope.id)
            return "未能识别内容，请重试"

        case .quickAddTodo(let text):
            if let reply = await handleQuickAddTodo(text: text) {
                recordAckedCommandID(envelope.id)
                refreshSnapshot(context: context)
                return reply
            }
            recordAckedCommandID(envelope.id)
            return "待办内容为空"

        default:
            var notifications: [TodoItem] = []
            let outcome = apply(envelope.command, context: context, deferredNotifications: &notifications)
            switch outcome {
            case .retry:
                return "同步稍后重试"
            case .applied, .consumed:
                if saveHook(context, action: "手表指令同步") {
                    scheduleDeferredNotifications(notifications)
                    recordAckedCommandID(envelope.id)
                    refreshSnapshot(context: context)
                    switch envelope.command {
                    case .completeTodo:
                        return "已完成 ✓"
                    case .snoozeTodo(_, let mins):
                        return "已延后 \(mins) 分钟"
                    case .snoozeTomorrow:
                        return "已延后至明早 9:00"
                    case .logMood(let m, let e, let s):
                        return "已记录心情（情绪\(m) 精力\(e) 压力\(s)）"
                    case .addWater(_, let vol):
                        return "已补水 +\(Int(vol))ml 💧"
                    case .toggleDeparture(_, let checked):
                        return checked ? "已确认携带 ✓" : "已恢复未清点"
                    case .completeAllDeparture:
                        return "随身物品已全部带齐 ✓"
                    case .markMedicationTaken:
                        return "今日服药已打卡 💊"
                    case .completeHabit:
                        return "周期习惯已完成 ✓"
                    default:
                        return "已同步 ✓"
                    }
                }
                return "保存失败，稍后重试"
            }
        }
    }

    @discardableResult
    private func completeAllDepartureInDB(ids: [UUID], context: ModelContext) -> CommandOutcome {
        let allItems: [DepartureCheckItem]
        do {
            allItems = try context.fetch(FetchDescriptor<DepartureCheckItem>())
        } catch {
            print("⚠️ [WidgetSync] 批量出门清点查询失败，保留重试: \(error.localizedDescription)")
            return .retry
        }
        let targetSet = Set(ids)
        var changed = false
        for item in allItems where targetSet.isEmpty || targetSet.contains(item.id) {
            if !item.isChecked {
                item.isChecked = true
                changed = true
            }
        }
        Task { await LiveActivityService.endDepartureActivities() }
        return changed ? .applied : .consumed
    }

    @discardableResult
    private func markMedicationTakenInDB(planID: UUID, todoID: UUID?, context: ModelContext) -> CommandOutcome {
        let planDesc = FetchDescriptor<MedicationPlan>(predicate: #Predicate { $0.id == planID })
        do {
            guard let plan = try context.fetch(planDesc).first else { return .consumed }
            plan.markTaken(at: .now)
            let medName = plan.medName
            let medTypeRaw = TodoType.medication.rawValue
            let activeRaw = TodoStatus.active.rawValue
            if let todoID {
                let todoDesc = FetchDescriptor<TodoItem>(predicate: #Predicate { $0.id == todoID })
                if let todo = (try? context.fetch(todoDesc))?.first, todo.status == .active {
                    todo.markAsCompleted(in: context)
                }
            } else {
                let todoDesc = FetchDescriptor<TodoItem>(
                    predicate: #Predicate { $0.typeRaw == medTypeRaw && $0.statusRaw == activeRaw }
                )
                // **精确匹配**（标题全等），不用 `contains(medName)`：
                // 药名可能互为子串（「维生素D」⊂「维生素D3」），用 contains 会
                // 让「维生素D」的计划完成「维生素D3」的待办 → 另一种药被漏服。
                let slotTitles = Set(MedicationTodoMaterializer.slotTitles(
                    medName: medName,
                    dailyTimePoints: plan.dailyTimePoints,
                    on: .now,
                    calendar: .current
                ))
                let matchingTodos = ((try? context.fetch(todoDesc)) ?? [])
                    .filter { slotTitles.contains($0.title) }
                for todo in matchingTodos {
                    todo.markAsCompleted(in: context)
                }
            }
            return .applied
        } catch {
            print("⚠️ [WidgetSync] 服药打卡查询失败，保留重试: \(error.localizedDescription)")
            return .retry
        }
    }

    @discardableResult
    private func completeHabitInDB(habitID: UUID, context: ModelContext) -> CommandOutcome {
        let habitDesc = FetchDescriptor<PeriodicHabit>(predicate: #Predicate { $0.id == habitID })
        do {
            guard let habit = try context.fetch(habitDesc).first else { return .consumed }
            habit.completeOnce()
            let habitTitle = habit.title
            let exTypeRaw = TodoType.exercise.rawValue
            let activeRaw = TodoStatus.active.rawValue
            let todoDesc = FetchDescriptor<TodoItem>(
                predicate: #Predicate { $0.typeRaw == exTypeRaw && $0.statusRaw == activeRaw }
            )
            // **精确匹配**（标题全等），不用 `contains(habitTitle)`：
            // 习惯名可能互为子串（「跑步」⊂「夜跑」），用 contains 会让
            // 「跑步」的打卡完成「夜跑」的待办 → 另一个习惯被误标完成。
            // 标题格式与 `HabitAndMedicationScheduler` 生成的一致：「运动：<名称>」。
            // 两端都取 Core 的单一真源，避免字面量各写一份后漂移。
            let expectedTitle = CheckInTodoLink.habitTodoTitle(habitName: habitTitle)
            let matchingTodos = ((try? context.fetch(todoDesc)) ?? [])
                .filter { $0.title == expectedTitle }
            for todo in matchingTodos {
                todo.markAsCompleted(in: context)
            }
            return .applied
        } catch {
            print("⚠️ [WidgetSync] 周期习惯打卡查询失败，保留重试: \(error.localizedDescription)")
            return .retry
        }
    }

    @discardableResult
    private func completeInDB(id: UUID, context: ModelContext) -> CommandOutcome {
        let descriptor = FetchDescriptor<TodoItem>(predicate: #Predicate { $0.id == id })
        let items: [TodoItem]
        do {
            items = try context.fetch(descriptor)
        } catch {
            // 查询失败不能当成「待办不存在/已完成」：那会收起实时活动，而这条打勾指令随后也被摘除
            print("⚠️ [WidgetSync] 完成指令查询失败，保留队列重试: \(error.localizedDescription)")
            return .retry
        }
        guard let item = items.first, item.status == .active else {
            // 已在主应用完成过：仅确保实时活动收起（主进程长寿，允许异步收尾）
            Task { await PickupActivityHelper.endActivity(for: id) }
            return .consumed
        }
        item.markAsCompleted(in: context)
        Task { await PickupActivityHelper.markCompleted(todoID: id) }
        return .applied
    }

    /// 稍后提醒：只改内存字段并返回待排期的条目，通知由调用方在落库成功后统一排
    /// （审计 SVC-04：先排通知再 save，失败会留下指向未落库时间的提醒）。
    private func snoozeInDB(
        id: UUID,
        minutes: Int,
        tomorrow: Bool,
        context: ModelContext
    ) -> (outcome: CommandOutcome, item: TodoItem?) {
        let descriptor = FetchDescriptor<TodoItem>(predicate: #Predicate { $0.id == id })
        let item: TodoItem
        do {
            guard let found = try context.fetch(descriptor).first else { return (.consumed, nil) }
            item = found
        } catch {
            print("⚠️ [WidgetSync] 稍后提醒查询失败，保留队列重试: \(error.localizedDescription)")
            return (.retry, nil)
        }
        if tomorrow {
            var components = Calendar.current.dateComponents([.year, .month, .day], from: .now)
            components.day = (components.day ?? 0) + 1
            components.hour = 9
            components.minute = 0
            item.reminderOverrideAt = Calendar.current.date(from: components)
        } else {
            item.reminderOverrideAt = Date.now.addingTimeInterval(TimeInterval(max(1, minutes)) * 60)
        }
        return (.applied, item)
    }

    @discardableResult
    private func toggleDepartureInDB(id: UUID, isChecked: Bool, context: ModelContext) -> CommandOutcome {
        let descriptor = FetchDescriptor<DepartureCheckItem>(predicate: #Predicate { $0.id == id })
        let checkItem: DepartureCheckItem
        do {
            guard let found = try context.fetch(descriptor).first else { return .consumed }
            checkItem = found
        } catch {
            print("⚠️ [WidgetSync] 出门清点查询失败，保留队列重试: \(error.localizedDescription)")
            return .retry
        }
        checkItem.isChecked = isChecked
        Task { await DepartureActivityHelper.setChecked(itemID: id, isChecked: isChecked) }
        return .applied
    }

    @discardableResult
    private func quickAddExpenseInDB(text: String, context: ModelContext) -> CommandOutcome {
        let results = ExpenseNaturalLanguageParser.parseMulti(text)
        guard !results.isEmpty else { return .consumed }
        for result in results {
            let record = ExpenseRecord(
                amount: result.amount,
                isIncome: result.isIncome,
                category: result.category,
                title: result.title,
                rawText: text,
                date: result.date,
                currencyCode: result.isForeignCurrency ? result.currency.rawValue : nil,
                foreignAmount: result.foreignAmount,
                exchangeRateToCNY: result.exchangeRateToCNY
            )
            context.insert(record)
        }
        return .applied
    }

    /// 快速加待办：只建对象不排通知——通知必须在落库成功后由调用方排（审计 SVC-04）。
    private func quickAddTodoInDB(text: String, context: ModelContext) -> TodoItem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parsed = TodoNaturalLanguageParser.parse(trimmed)
        let minOrder = TodoItem.minimumSortOrder(in: context)
        let item = TodoItem(
            type: parsed.type,
            status: .active,
            title: parsed.title.isEmpty ? trimmed : parsed.title,
            dueAt: parsed.dueAt,
            sourceText: trimmed,
            sortOrder: minOrder - 1,
            recurrenceRuleRaw: parsed.recurrenceRule == .none ? nil : parsed.recurrenceRule.rawValue,
            recurrenceIntervalDays: parsed.customIntervalDays
        )
        context.insert(item)
        return item
    }

    // MARK: - WidgetBridgeAppHook（AppIntent 在主应用进程执行时走这里）

    /// App hook 的统一落库出口：失败回滚 + 日志；返回是否成功，成功后才刷新快照/排通知。
    /// - Parameter reportToBanner: 返回 Void 的 hook（完成/推迟/出门清点）没有别的回执渠道，
    ///   走全局失败横幅让用户看见；返回文案的 quick-add 已有失败回复，不重复弹。
    @discardableResult
    private func saveHook(_ context: ModelContext, action: String, reportToBanner: Bool = false) -> Bool {
        context.saveReportingFailure { error in
            print("⚠️ [WidgetSync] \(action)落库失败: \(error.localizedDescription)")
            if reportToBanner {
                SaveFailureCenter.shared.report(error, action: action)
            }
        }
    }

    func handleCompleteTodo(id: UUID) {
        let context = Persistence.shared.mainContext
        switch completeInDB(id: id, context: context) {
        case .retry:
            return // 查询失败：不落库，下次前台巡检重试
        case .applied, .consumed:
            if saveHook(context, action: "完成待办", reportToBanner: true) {
                refreshSnapshot(context: context)
            }
        }
    }

    func handleSnoozeTodo(id: UUID, minutes: Int) {
        let context = Persistence.shared.mainContext
        let result = snoozeInDB(id: id, minutes: minutes, tomorrow: false, context: context)
        if case .applied = result.outcome, let item = result.item,
           saveHook(context, action: "稍后提醒", reportToBanner: true) {
            TodoNotificationManager.shared.scheduleNotification(for: item)
        }
    }

    func handleSnoozeTomorrow(id: UUID) {
        let context = Persistence.shared.mainContext
        let result = snoozeInDB(id: id, minutes: 0, tomorrow: true, context: context)
        if case .applied = result.outcome, let item = result.item,
           saveHook(context, action: "稍后提醒（明早）", reportToBanner: true) {
            TodoNotificationManager.shared.scheduleNotification(for: item)
        }
    }

    func handleToggleDeparture(id: UUID, isChecked: Bool) {
        let context = Persistence.shared.mainContext
        switch toggleDepartureInDB(id: id, isChecked: isChecked, context: context) {
        case .retry:
            return
        case .applied, .consumed:
            _ = saveHook(context, action: "出门清点勾选", reportToBanner: true)
        }
    }

    func handleQuickAddExpense(text: String) async -> String? {
        let context = Persistence.shared.mainContext
        let results = ExpenseNaturalLanguageParser.parseMulti(text)
        guard !results.isEmpty else { return nil }
        var totalExpense = 0.0
        var titles: [String] = []
        for result in results {
            let record = ExpenseRecord(
                amount: result.amount,
                isIncome: result.isIncome,
                category: result.category,
                title: result.title,
                rawText: text,
                date: result.date,
                currencyCode: result.isForeignCurrency ? result.currency.rawValue : nil,
                foreignAmount: result.foreignAmount,
                exchangeRateToCNY: result.exchangeRateToCNY
            )
            context.insert(record)
            if !result.isIncome { totalExpense += result.amount }
            titles.append(result.title)
        }
        // 先落库再回执（审计 SVC-04）：失败如实返回失败文案，不刷新快照、不报「已记账」。
        guard saveHook(context, action: "快捷记账") else {
            return "记账失败，请稍后重试"
        }
        refreshSnapshot(context: context)

        if results.count == 1, let result = results.first {
            let amountText = String(format: result.amount.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.2f", result.amount)
            if result.isIncome {
                return "已入账收入 \(amountText) 元：\(result.title)"
            }
            return "已记账 \(amountText) 元（\(result.category.displayName)）" + Self.todayExpenseSuffix(context: context)
        }
        let totalText = String(format: totalExpense.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.2f", totalExpense)
        return "已记账 \(results.count) 笔合计 \(totalText) 元（\(titles.joined(separator: "、"))）" + Self.todayExpenseSuffix(context: context)
    }

    /// 「今日累计支出」后缀；读账本失败时整段省略，不回退成 0 元。
    private static func todayExpenseSuffix(context: ModelContext) -> String {
        guard let total = todayExpenseTotal(context: context) else { return "" }
        let text = String(format: total.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.2f", total)
        return "，今日累计支出 \(text) 元"
    }

    func handleQuickAddTodo(text: String) async -> String? {
        let context = Persistence.shared.mainContext
        guard let item = quickAddTodoInDB(text: text, context: context) else { return nil }
        // 先落库、再排通知 + 回执：失败时通知不排，也不报「已创建」。
        guard saveHook(context, action: "快捷加待办") else {
            return "待办保存失败，请稍后重试"
        }
        TodoNotificationManager.shared.scheduleNotification(for: item)
        refreshSnapshot(context: context)
        if let due = item.dueAt {
            let dueStr = due.formatted(date: .abbreviated, time: .shortened)
            return "已创建待办「\(item.title)」，将于 \(dueStr) 提醒你"
        }
        return "已创建待办：\(item.title)"
    }

    func handleQueryParcels() async -> String {
        let context = Persistence.shared.mainContext
        let activeRaw = TodoStatus.active.rawValue
        let parcelRaw = TodoType.parcel.rawValue
        let returnParcelRaw = TodoType.returnParcel.rawValue
        let descriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.statusRaw == activeRaw && ($0.typeRaw == parcelRaw || $0.typeRaw == returnParcelRaw) }
        )
        let items = ((try? context.fetch(descriptor)) ?? [])
            .filter { !($0.pickupCode ?? "").isEmpty }
        guard !items.isEmpty else { return "目前没有待取的快递" }

        refreshSnapshot(context: context)
        let started = LiveActivityService.startPickupActivity(for: items)
        let codes = items.prefix(5).map { item -> String in
            let place = [item.station, item.location].compactMap { $0 }.first { !$0.isEmpty }
            return place.map { "\($0) \(item.pickupCode!)" } ?? item.pickupCode!
        }
        var reply = "待取快递 \(items.count) 件：" + codes.joined(separator: "、")
        if items.count > 5 { reply += " 等" }
        reply += started ? "，已送上灵动岛与手表 🏝️" : "（实时活动不可用，可在锁屏查看小组件）"
        return reply
    }

    func handleQueryBudget() async -> String {
        let context = Persistence.shared.mainContext
        guard let dayTotal = Self.todayExpenseTotal(context: context) else {
            return "暂时读不到账本，算不出今天的安心花额度，稍后再问我一次吧。"
        }
        let dayText = String(format: dayTotal.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.2f", dayTotal)
        let monthlyBudget = BudgetSettings.monthlyBudget
        if monthlyBudget > 0 {
            // 只取本月 + 昨日 + 本周一至今，避免全表物化到主线程
            let window = ExpenseRecordWindow.budgetWindow()
            let windowStart = window.start
            let windowEnd = window.end
            let descriptor = FetchDescriptor<ExpenseRecord>(
                predicate: #Predicate { $0.date >= windowStart && $0.date < windowEnd }
            )
            let records: [ExpenseRecord]
            do {
                records = try context.fetch(descriptor)
            } catch {
                return "暂时读不到账本，算不出今天的安心花额度，稍后再问我一次吧。"
            }
            let fixedMonthlyTotal = RecurringExpenseManager.shared.monthlyEstimatedTotal
            let input = SafeToSpendCalculator.inputFromRecords(
                records: records,
                fixedMonthlyTotal: fixedMonthlyTotal,
                monthlyBudget: monthlyBudget
            )
            let result = SafeToSpendCalculator.compute(input: input)
            let safeText = String(format: "%.0f", result.safeToSpendToday)
            let remainMonthText = String(format: "%.0f", max(0, result.remainingThisMonth))
            if result.isTodayOverspent {
                let overText = String(format: "%.0f", result.todayOverspentAmount)
                return "今日已支出 \(dayText) 元（超支 \(overText) 元），本月剩余 ¥\(remainMonthText)。适度收一收，慢慢花。"
            } else {
                return "今日已支出 \(dayText) 元，今天还能安心花 ¥\(safeText)，本月剩余 ¥\(remainMonthText)。放宽心，慢慢花。"
            }
        }
        return "今日已累计支出 \(dayText) 元。放宽心，慢慢花。"
    }

    func handleQueryTodayTodos() async -> String {
        let context = Persistence.shared.mainContext
        let activeRaw = TodoStatus.active.rawValue
        let descriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.statusRaw == activeRaw }
        )
        var items = (try? context.fetch(descriptor)) ?? []
        TodoPriority.sort(&items)
        if items.isEmpty {
            return "今日待办已全部清空，好好休息吧！"
        }
        let topCount = min(3, items.count)
        let titles = items.prefix(topCount).map(\.displayConciseTitle).joined(separator: "、")
        var reply = "今日待办共有 \(items.count) 项。优先处理：\(titles)"
        if items.count > topCount {
            reply += " 等"
        }
        return reply
    }
}
