import Foundation
import SwiftData
import UserNotifications

/// 生活痛点自动化扫描器（订阅防被扣款、证件临期预警、健康补水）
@MainActor
struct DailyPainPointAuditor {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    init() {
        self.context = Persistence.shared.mainContext
    }

    /// 统一执行每日痛点巡检
    public func auditAll() {
        auditSubscriptions()
        auditItemExpiries()
        auditMedicineExpiries()
        auditAnniversaries()
        auditPasswordRotations()
        auditIDDocuments()
        auditVehicleCare()
        auditPetCare()
        auditChildVaccines()
        // 巡检期间新增的待办只在主线程做一次同步落盘，避免每条命中一次 fsync
        if insertFlag.didInsert {
            insertFlag.didInsert = false
            try? context.save()
        }
        AnniversaryReminderManager.shared.checkAndSendDailyNotifications(context: context)
        TravelTicketReminderManager.shared.checkAndSendDailyNotifications(context: context)
    }

    /// struct 不可变方法里的写入标记：用引用盒子免去全链路 mutating 改造
    private final class InsertFlagBox {
        var didInsert = false
    }

    private let insertFlag = InsertFlagBox()

    /// 1. 自动续费与订阅被动扣费防范
    private func auditSubscriptions() {
        let descriptor = FetchDescriptor<SubscriptionItem>()
        guard let subs = try? context.fetch(descriptor) else { return }

        let now = Date.now
        let cal = Calendar.current

        for sub in subs {
            let daysUntilBilling = cal.dateComponents([.day], from: now, to: sub.nextBillingDate).day ?? 0
            if daysUntilBilling <= sub.remindDaysBefore && daysUntilBilling >= 0 {
                let title = "💳 订阅扣费预警：\(sub.name)"
                let detail = "预计将在 \(daysUntilBilling) 天后自动扣款（\(sub.priceString)），若不再需要请及时前往取消。"
                upsertTodo(type: .subscription, title: title, detail: detail, dueAt: sub.nextBillingDate)

                postThrottledNotification(
                    id: "sub-\(sub.id.uuidString)",
                    title: "自动续费提醒",
                    body: "「\(sub.name)」即将于 \(daysUntilBilling) 天后扣费（\(sub.priceString)）"
                )
            }
        }
    }

    /// 2. 证件与保质期临期预警
    private func auditItemExpiries() {
        let descriptor = FetchDescriptor<ItemExpiryItem>(
            predicate: #Predicate { !$0.isResolved }
        )
        guard let items = try? context.fetch(descriptor) else { return }

        let now = Date.now
        let cal = Calendar.current

        for item in items {
            let daysLeft = cal.dateComponents([.day], from: now, to: item.expireDate).day ?? 0
            if daysLeft <= item.remindDaysBefore {
                let statusDesc = daysLeft < 0 ? "已过期 \(abs(daysLeft)) 天！" : "即将在 \(daysLeft) 天后过期"
                let title = "⚠️ 临期预警：\(item.title)"
                let detail = "[\(item.category)] \(statusDesc)，请尽快处理或换新。"
                upsertTodo(type: .itemExpiry, title: title, detail: detail, dueAt: item.expireDate)

                postThrottledNotification(
                    id: "exp-\(item.id.uuidString)",
                    title: "临期提醒",
                    body: "「\(item.title)」\(statusDesc)"
                )
            }
        }
    }

    /// 2.5 家庭常备药临期/过期预警（同种药多批次，逐批按实际到期日提醒）
    private func auditMedicineExpiries() {
        let descriptor = FetchDescriptor<MedicineItem>(
            predicate: #Predicate { !$0.isDisposed }
        )
        guard let meds = try? context.fetch(descriptor) else { return }

        let cal = Calendar.current
        let now = cal.startOfDay(for: Date.now)

        for med in meds {
            // effectiveExpiryDate 为派生属性（取包装有效期与开封后到期较早者），无法下推谓词，循环内计算
            guard let expiry = med.effectiveExpiryDate else { continue }
            let daysLeft = cal.dateComponents([.day], from: now, to: cal.startOfDay(for: expiry)).day ?? 0
            guard daysLeft <= 30 else { continue }

            let statusDesc = daysLeft < 0 ? "已过期 \(abs(daysLeft)) 天！" : (daysLeft == 0 ? "今天到期" : "即将在 \(daysLeft) 天后过期")
            let batchDesc = med.isOpened ? "已开封批次" : "未开封批次"
            let expiryStr = expiry.formatted(date: .numeric, time: .omitted)
            let title = "💊 药品临期预警：\(med.name)（\(batchDesc) · 到期 \(expiryStr)）"
            let detail = "[\(med.category.rawValue)] \(statusDesc)，存放于\(med.roomArea)·\(med.storageLocation)，请及时补货或妥善处理，切勿误服过期药。"
            upsertTodo(type: .itemExpiry, title: title, detail: detail, dueAt: expiry)

            postThrottledNotification(
                id: "medicine-\(med.id.uuidString)",
                title: "药品临期提醒",
                body: "「\(med.name)」\(batchDesc)\(statusDesc)"
            )
        }
    }

    /// 3. 纪念日、生日与重要日子提醒
    private func auditAnniversaries() {
        let descriptor = FetchDescriptor<AnniversaryItem>()
        guard let items = try? context.fetch(descriptor) else { return }

        for item in items {
            let daysLeft = item.daysUntilNext
            // 命中预警阈值（如提前 7 天、3 天、当天）
            if item.remindDaysBefore.contains(daysLeft) {
                let count = item.nextYearsCount
                let daysDesc = daysLeft == 0 ? "就在今天！🎉" : "还有 \(daysLeft) 天"
                let title = "🎁 纪念日提醒：\(item.title)（第 \(count) 周年）"
                let detail = "[\(item.category)] 距离 \(item.title) \(daysDesc)。提前备好礼物或惊喜吧！"

                upsertTodo(type: .anniversary, title: title, detail: detail, dueAt: item.nextAnniversaryDate)

                postThrottledNotification(
                    id: "anni-\(item.id.uuidString)-\(daysLeft)",
                    title: "纪念日提醒",
                    body: "「\(item.title)」\(daysDesc)（第 \(count) 周年）"
                )
            }
        }
    }

    /// 4. 长期未更换密码与安全轮换预警
    private func auditPasswordRotations() {
        let descriptor = FetchDescriptor<PasswordVaultItem>()
        guard let items = try? context.fetch(descriptor) else { return }

        for item in items {
            if item.isRotationDue {
                let title = "🔑 密码更新提醒：\(item.title)"
                let detail = "[\(item.category)] 账号 \(item.account) 的密码已连续使用 \(item.usedDays) 天，建议及时轮换更新以保障安全。"
                upsertTodo(type: .passwordSecurity, title: title, detail: detail, dueAt: item.nextRotationDueDate ?? .now)

                postThrottledNotification(
                    id: "pwd-rotate-\(item.id.uuidString)",
                    title: "密码更新预警",
                    body: "「\(item.title)」密码已使用超 \(item.rotateCycleDays) 天，建议更换。"
                )
            }
        }
    }

    /// 5. 证件到期预警（身份证、护照、驾照等）
    private func auditIDDocuments() {
        let descriptor = FetchDescriptor<IDDocumentItem>()
        guard let items = try? context.fetch(descriptor) else { return }

        for item in items {
            guard !item.isPermanent, let daysLeft = item.daysUntilExpiry, let expiry = item.expiryDate else { continue }
            if daysLeft <= 30 {
                let statusDesc = daysLeft < 0 ? "已过期 \(abs(daysLeft)) 天" : "即将在 \(daysLeft) 天后过期"
                let title = "🪪 证件临期预警：\(item.title)"
                let detail = "[\(item.type.rawValue)] \(statusDesc)，若需使用请提前前往换领或续签。"
                upsertTodo(type: .itemExpiry, title: title, detail: detail, dueAt: expiry)

                postThrottledNotification(
                    id: "id-doc-\(item.id.uuidString)",
                    title: "证件临期预警",
                    body: "「\(item.title)」\(statusDesc)，请记得及时换证。"
                )
            }
        }
    }

    /// 6. 有车一族车辆巡检（加油/加电提醒、定期保养、车险与年检合规）
    private func auditVehicleCare() {
        let descriptor = FetchDescriptor<VehicleProfile>(
            predicate: #Predicate { $0.isReminderEnabled }
        )
        guard let vehicles = try? context.fetch(descriptor) else { return }

        for vehicle in vehicles {
            // A. 加油 / 加电周期性提醒
            if vehicle.daysUntilNextEnergyRefill <= 1 {
                let verb = vehicle.powerType.energyVerb
                let title = "🚗 爱车\(verb)提醒：\(vehicle.name)"
                let statusText = vehicle.daysUntilNextEnergyRefill <= 0 ? "已达计划\(verb)周期" : "建议明天内补能"
                let detail = "[\(vehicle.plateNumber)] \(statusText)，建议趁晚间低谷电价或周末出行前完成\(verb)。"
                upsertTodo(type: .vehicleCare, title: title, detail: detail, dueAt: .now)

                postThrottledNotification(
                    id: "vehicle-energy-\(vehicle.id.uuidString)",
                    title: "爱车\(verb)提醒",
                    body: "「\(vehicle.name)」\(statusText)，记得及时\(verb)哦。"
                )
            }

            // B. 定期保养预警（15天内或已超期）
            if vehicle.needsMaintenanceSoon {
                let days = vehicle.daysUntilNextMaintenance
                let statusText = days < 0 ? "保养已超期 \(abs(days)) 天" : "还剩 \(days) 天到期"
                let title = "🔧 车辆常规保养预警：\(vehicle.name)"
                let detail = "[\(vehicle.plateNumber)] 保养周期\(statusText)，建议提前预约 4S 店/修理厂更换机油或检测三电系统。"
                upsertTodo(type: .vehicleCare, title: title, detail: detail, dueAt: vehicle.nextMaintenanceDate)

                postThrottledNotification(
                    id: "vehicle-maint-\(vehicle.id.uuidString)",
                    title: "爱车保养提醒",
                    body: "「\(vehicle.name)」常规保养\(statusText)，请提前预约。"
                )
            }

            // C. 车险到期预警（30天内）
            if let daysLeft = vehicle.daysUntilInsuranceExpiry, let expiry = vehicle.insuranceExpiryDate, daysLeft <= 30 {
                let statusText = daysLeft < 0 ? "车险已脱保 \(abs(daysLeft)) 天！" : "即将在 \(daysLeft) 天后到期"
                let title = "🛡️ 车险续保预警：\(vehicle.name)"
                let detail = "[\(vehicle.plateNumber)] \(statusText)，请提前对比商业险与交强险报价并完成续保，杜绝脱险裸奔。"
                upsertTodo(type: .vehicleCare, title: title, detail: detail, dueAt: expiry)

                postThrottledNotification(
                    id: "vehicle-insur-\(vehicle.id.uuidString)",
                    title: "车险续保提醒",
                    body: "「\(vehicle.name)」车险\(statusText)，切勿脱保上路。"
                )
            }

            // D. 车辆年检预警（60天内）
            if let daysLeft = vehicle.daysUntilAnnualInspection, let inspectionDate = vehicle.annualInspectionDate, daysLeft <= 60 {
                let statusText = daysLeft < 0 ? "年检已逾期 \(abs(daysLeft)) 天！" : "还剩 \(daysLeft) 天"
                let title = "📋 车辆年检预警：\(vehicle.name)"
                let detail = "[\(vehicle.plateNumber)] 检验有效期\(statusText)，免检车辆可在「交管12123」申领检验标志，上线车辆请提前预约检测站。"
                upsertTodo(type: .vehicleCare, title: title, detail: detail, dueAt: inspectionDate)

                postThrottledNotification(
                    id: "vehicle-inspect-\(vehicle.id.uuidString)",
                    title: "车辆年检预警",
                    body: "「\(vehicle.name)」年检\(statusText)，请及时办理免检标或上线检测。"
                )
            }
        }
    }

    /// 7. 毛孩子宠物养护（体内外驱虫与年度疫苗到期提醒）
    private func auditPetCare() {
        let descriptor = FetchDescriptor<PetProfile>(
            predicate: #Predicate { $0.isReminderEnabled }
        )
        guard let pets = try? context.fetch(descriptor) else { return }

        for pet in pets {
            // 体外驱虫提醒
            if let days = pet.daysUntilNextExternalDeworm, days <= 1 {
                let status = days <= 0 ? "已达驱虫周期（30天）" : "明天到期"
                postThrottledNotification(
                    id: "pet-ext-deworm-\(pet.id.uuidString)",
                    title: "🐾 毛孩子体外驱虫提醒",
                    body: "「\(pet.name)」体外驱虫\(status)，记得及时滴药预防跳蚤蜱虫哦。"
                )
            }

            // 体内驱虫提醒
            if let days = pet.daysUntilNextInternalDeworm, days <= 2 {
                let status = days <= 0 ? "已满 3 个月周期" : "将在 \(days) 天后到期"
                postThrottledNotification(
                    id: "pet-int-deworm-\(pet.id.uuidString)",
                    title: "💊 毛孩子体内驱虫提醒",
                    body: "「\(pet.name)」体内驱虫\(status)，建议安排药片驱虫。"
                )
            }

            // 年度疫苗预警（提前 14 天）
            if let days = pet.daysUntilNextVaccine, days <= 14 {
                let status = days <= 0 ? "疫苗已到期" : "即将在 \(days) 天后到期"
                postThrottledNotification(
                    id: "pet-vaccine-\(pet.id.uuidString)",
                    title: "💉 宠物联苗/狂犬接种预警",
                    body: "「\(pet.name)」年度疫苗\(status)，请提前预约宠物医院接种。"
                )
            }
        }
    }

    /// 8. 亲子育儿适龄疫苗接种提醒
    private func auditChildVaccines() {
        let descriptor = FetchDescriptor<ChildProfile>()
        guard let children = try? context.fetch(descriptor) else { return }

        for child in children {
            let pending = child.pendingVaccines
            if let firstPending = pending.first {
                postThrottledNotification(
                    id: "child-vaccine-\(child.id.uuidString)-\(firstPending.id)",
                    title: "👶 宝贝疫苗适龄接种提醒",
                    body: "「\(child.name)」已达 \(child.currentMonthAge) 月龄适龄期，建议预约接种「\(firstPending.vaccineName)」。"
                )
            }
        }
    }

    private func postThrottledNotification(id: String, title: String, body: String) {
        let dateKey = "audit_notif_date_\(id)"
        let cal = Calendar.current
        if let lastDate = UserDefaults.standard.object(forKey: dateKey) as? Date,
           cal.isDateInToday(lastDate) {
            return
        }
        UserDefaults.standard.set(Date.now, forKey: dateKey)
        NotificationService.post(title: title, body: body, id: id)
    }

    private func upsertTodo(type: TodoType, title: String, detail: String, dueAt: Date) {
        let typeRaw = type.rawValue
        let active = TodoStatus.active.rawValue
        let existing = (try? context.fetch(FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.title == title && $0.typeRaw == typeRaw && $0.statusRaw == active }
        ))) ?? []

        if existing.isEmpty {
            let todo = TodoItem(type: type, status: .active, title: title, detail: detail, dueAt: dueAt)
            context.insert(todo)
            insertFlag.didInsert = true
        }
    }
}
