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
                Section("私密资料") {
                    NavigationLink {
                        IDDocumentVaultView()
                    } label: {
                        vaultRow(
                            icon: "person.text.rectangle.fill",
                            color: .blue,
                            title: "重要证件",
                            status: expiringDocCount > 0 ? "\(expiringDocCount) 张即将到期" : "\(documents.count) 张证件",
                            isAlert: expiringDocCount > 0
                        )
                    }

                    NavigationLink {
                        PasswordVaultView()
                    } label: {
                        vaultRow(
                            icon: "key.fill",
                            color: .teal,
                            title: "密码库",
                            status: "\(passwords.count) 组账号",
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
                            status: "\(voiceMemos.count) 条录音",
                            isAlert: false
                        )
                    }
                }

                // MARK: - 2. 情感记忆与守护
                Section("生活提醒") {
                    NavigationLink {
                        AnniversaryManagementView()
                    } label: {
                        vaultRow(
                            icon: "gift.fill",
                            color: .pink,
                            title: "纪念日",
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
                            title: "续费与物品临期",
                            status: "\(subscriptions.count) 项续费 · \(expiries.count) 项临期",
                            isAlert: false
                        )
                    }
                }

                // MARK: - 3. 物品收纳与空间感知
                Section("物品与地点") {
                    NavigationLink {
                        ItemStorageVaultView()
                    } label: {
                        vaultRow(
                            icon: "archivebox.fill",
                            color: .indigo,
                            title: "物品收纳",
                            status: "\(storedItems.count) 件物品",
                            isAlert: false
                        )
                    }

                    NavigationLink {
                        LearnedPlacesView()
                    } label: {
                        vaultRow(
                            icon: "brain.head.profile",
                            color: .orange,
                            title: "常驻地点",
                            status: "\(places.count) 处地点",
                            isAlert: false
                        )
                    }
                }

                // MARK: - 4. 健康作息与习惯
                Section("健康与习惯") {
                    NavigationLink {
                        HabitAndMedicationView()
                    } label: {
                        vaultRow(
                            icon: "heart.text.square.fill",
                            color: .purple,
                            title: "周期家务与服药",
                            status: "\(habits.count) 项家务 · \(activeMedCount) 项服药",
                            isAlert: false
                        )
                    }
                }

                // MARK: - 4. 随身防丢与车务守护
                Section("出行") {
                    NavigationLink {
                        VehicleManagementView()
                    } label: {
                        vaultRow(
                            icon: "car.fill",
                            color: .indigo,
                            title: "爱车管理",
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
                            title: "出门清单",
                            status: uncheckedDepartureCount > 0 ? "\(uncheckedDepartureCount) 件未确认" : "\(departureItems.count) 件随身物品",
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
            return "尚未添加车辆"
        } else if needCareVehicleCount > 0 {
            return "\(needCareVehicleCount) 辆车需关注"
        } else {
            return "\(vehicles.count) 辆车"
        }
    }

    private var nearestAnniversarySummary: String {
        if let next = nearestAnniversary {
            if next.days == 0 {
                return "今天：\(next.item.title)"
            } else {
                return "\(next.item.title) · 还有 \(next.days) 天"
            }
        }
        return "\(anniversaries.count) 个纪念日"
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

                Text(status)
                    .font(.caption)
                    .foregroundStyle(isAlert ? .red : .secondary)
            }
            .padding(.vertical, 4)
        }
    }
}
