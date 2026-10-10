import SwiftData
import SwiftUI

/// 生活档案与数字资产大厅 (Tab 3: 生活档案)
struct LifeVaultView: View {
    @Environment(\.modelContext) private var context
    @Query private var storedItems: [StoredItem]
    @Query private var documents: [IDDocumentItem]
    @Query private var passwords: [PasswordVaultItem]
    @Query private var anniversaries: [AnniversaryItem]
    @Query private var habits: [PeriodicHabit]
    @Query private var medications: [MedicationPlan]
    @Query private var subscriptions: [SubscriptionItem]
    @Query private var expiries: [ItemExpiryItem]
    @Query private var places: [LearnedPlace]
    @Query private var departureItems: [DepartureCheckItem]
    @Query private var voiceMemos: [VoiceMemo]
    @Query private var vehicles: [VehicleProfile]
    @ObservedObject private var bgManager = AppBackgroundManager.shared
    @Environment(\.colorScheme) private var colorScheme

    // 随身防丢未清点核心件
    private var uncheckedDepartureCount: Int {
        departureItems.filter { $0.isEssential && !$0.isChecked }.count
    }

    // 爱车需要关注补能或保养/保险/年检的数量
    private var needCareVehicleCount: Int {
        var count = 0
        for v in vehicles {
            if v.needsAttention {
                count += 1
            }
        }
        return count
    }

    // 最近即将到来的纪念日
    private var nearestAnniversary: (item: AnniversaryItem, days: Int)? {
        let list = anniversaries.compactMap { item -> (AnniversaryItem, Int)? in
            let days = item.daysUntilNext
            return (item, days)
        }.sorted { $0.1 < $1.1 }
        return list.first
    }

    // 临期证件数量
    private var expiringDocCount: Int {
        documents.filter { $0.isExpiringSoon || $0.isExpired }.count
    }

    // 活跃服药计划
    private var activeMedCount: Int {
        medications.filter { $0.isEnabled }.count
    }

    var body: some View {
        NavigationStack {
            List {
                // 顶部快速看板统计
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        NavigationLink {
                            IDDocumentVaultView()
                        } label: {
                            statPill(title: "证件", count: "\(documents.count)", icon: "person.text.rectangle.fill", color: .blue, badgeCount: expiringDocCount)
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            PasswordVaultView()
                        } label: {
                            statPill(title: "密码", count: "\(passwords.count)", icon: "key.fill", color: .teal)
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            ItemStorageVaultView()
                        } label: {
                            statPill(title: "收纳", count: "\(storedItems.count)", icon: "archivebox.fill", color: .indigo)
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            VehicleManagementView()
                        } label: {
                            statPill(title: "爱车", count: "\(vehicles.count)", icon: "car.fill", color: .indigo, badgeCount: needCareVehicleCount)
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            DepartureChecklistView()
                        } label: {
                            statPill(title: "防丢", count: "\(departureItems.count)", icon: "bag.fill", color: .teal, badgeCount: uncheckedDepartureCount)
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            AnniversaryManagementView()
                        } label: {
                            statPill(title: "纪念日", count: "\(anniversaries.count)", icon: "gift.fill", color: .pink)
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            HabitAndMedicationView()
                        } label: {
                            statPill(title: "习惯", count: "\(habits.count + activeMedCount)", icon: "heart.fill", color: .purple)
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            VoiceMemoListView()
                        } label: {
                            statPill(title: "录音", count: "\(voiceMemos.count)", icon: "mic.circle.fill", color: .red)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

                // MARK: - 1. 私密数字保险箱
                Section("私密数字保险箱") {
                    NavigationLink {
                        IDDocumentVaultView()
                    } label: {
                        vaultRow(
                            icon: "person.text.rectangle.fill",
                            color: .blue,
                            title: "重要证件与照片保险箱",
                            subtitle: "身份证、护照、驾照、社保卡等正反面照片安全归档",
                            status: expiringDocCount > 0 ? "⚠️ \(expiringDocCount) 张即将到期" : "已归档 \(documents.count) 张证件",
                            isAlert: expiringDocCount > 0
                        )
                    }

                    NavigationLink {
                        PasswordVaultView()
                    } label: {
                        vaultRow(
                            icon: "key.fill",
                            color: .teal,
                            title: "离线安全密码库",
                            subtitle: "本地独立硬件加密，强随机生成与密码轮换预警",
                            status: "已妥善加密 \(passwords.count) 组账号凭据",
                            isAlert: false
                        )
                    }

                    NavigationLink {
                        VoiceMemoListView()
                    } label: {
                        vaultRow(
                            icon: "mic.circle.fill",
                            color: .red,
                            title: "语音备忘录",
                            subtitle: "离线录音、倍速回放，转写文字并一键提取待办",
                            status: "已保存 \(voiceMemos.count) 条录音",
                            isAlert: false
                        )
                    }
                }

                // MARK: - 2. 情感记忆与守护
                Section("情感与生活守护") {
                    NavigationLink {
                        AnniversaryManagementView()
                    } label: {
                        vaultRow(
                            icon: "gift.fill",
                            color: .pink,
                            title: "纪念日与重要日子",
                            subtitle: "恋爱纪念日、亲友生日、天数倒数与农历智能推算",
                            status: nearestAnniversarySummary,
                            isAlert: false
                        )
                    }

                    NavigationLink {
                        PainPointManagementView()
                    } label: {
                        vaultRow(
                            icon: "shield.lefthalf.filled",
                            color: .indigo,
                            title: "防自动续费与物品临期",
                            subtitle: "自动扣款提前提醒拦截、开封药品与食品保质期监控",
                            status: "\(subscriptions.count) 项自动续费 | \(expiries.count) 项物品临期",
                            isAlert: false
                        )
                    }
                }

                // MARK: - 3. 物品收纳与空间感知
                Section("物品收纳与空间记忆") {
                    NavigationLink {
                        ItemStorageVaultView()
                    } label: {
                        vaultRow(
                            icon: "archivebox.fill",
                            color: .indigo,
                            title: "物品收纳备忘",
                            subtitle: "羽绒服、备用钥匙、工具盒，照片找物一秒定位",
                            status: "已收录 \(storedItems.count) 件收纳物品",
                            isAlert: false
                        )
                    }

                    NavigationLink {
                        LearnedPlacesView()
                    } label: {
                        vaultRow(
                            icon: "brain.head.profile",
                            color: .orange,
                            title: "常驻地点学习 (家/公司)",
                            subtitle: "基于夜间停留与 WiFi 的空间感知地点模型",
                            status: "已掌握 \(places.count) 处常驻空间",
                            isAlert: false
                        )
                    }
                }

                // MARK: - 4. 健康作息与习惯
                Section("健康作息与生活习惯") {
                    NavigationLink {
                        HabitAndMedicationView()
                    } label: {
                        vaultRow(
                            icon: "heart.text.square.fill",
                            color: .purple,
                            title: "周期家务与健康服药",
                            subtitle: "滤芯更换、打扫卫生、定时服药打卡及智能家居联动",
                            status: "\(habits.count) 项周期家务 | \(activeMedCount) 项服药提醒",
                            isAlert: false
                        )
                    }
                }

                // MARK: - 4. 随身防丢与车务守护
                Section("随身防丢与车务守护") {
                    NavigationLink {
                        VehicleManagementView()
                    } label: {
                        vaultRow(
                            icon: "car.fill",
                            color: .indigo,
                            title: "爱车守护与车务管理",
                            subtitle: "加油/加电周期提醒、常规保养、车险续保与年检预警",
                            status: vehicleStatusSummary,
                            isAlert: needCareVehicleCount > 0
                        )
                    }

                    NavigationLink {
                        DepartureChecklistView()
                    } label: {
                        vaultRow(
                            icon: "bag.fill",
                            color: .teal,
                            title: "出门防遗忘清单",
                            subtitle: "工作通勤、出差旅行、运动健身防漏带，指差四字确认",
                            status: uncheckedDepartureCount > 0 ? "⚠️ \(uncheckedDepartureCount) 件核心装备未确认" : "已收录 \(departureItems.count) 项随身装备",
                            isAlert: uncheckedDepartureCount > 0
                        )
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(bgManager.isCustomBackgroundActive ? .hidden : .automatic)
            .themedAppBackground()
            .themedRow()
            .navigationTitle("生活档案")
        }
    }

    // MARK: - 辅助子视图

    private var vehicleStatusSummary: String {
        if vehicles.isEmpty {
            return "未添加车辆，点击开启爱车守护"
        } else if needCareVehicleCount > 0 {
            return "⚠️ \(needCareVehicleCount) 辆车需关注补能或保养"
        } else {
            return "已守护 \(vehicles.count) 辆爱车，车况良好"
        }
    }

    private var nearestAnniversarySummary: String {
        if let next = nearestAnniversary {
            if next.days == 0 {
                return "今天正是 \(next.item.title)！"
            } else {
                return "最近：\(next.item.title) 还有 \(next.days) 天"
            }
        }
        return "共记录 \(anniversaries.count) 个纪念日"
    }

    @ViewBuilder
    private func statPill(title: String, count: String, icon: String, color: Color, badgeCount: Int = 0) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                    .frame(width: 28, height: 28)

                if badgeCount > 0 {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .offset(x: 4, y: -2)
                }
            }

            Text(count)
                .font(.headline)
                .foregroundStyle(.primary)

            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(badgeCount > 0 ? Color.red.opacity(0.35) : Color.clear, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func vaultRow(
        icon: String,
        color: Color,
        title: String,
        subtitle: String,
        status: String,
        isAlert: Bool
    ) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color.gradient)
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.body.bold())
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(status)
                    .font(.caption2.bold())
                    .foregroundStyle(isAlert ? .red : color)
                    .padding(.top, 1)
            }
            .padding(.vertical, 4)
        }
    }
}
