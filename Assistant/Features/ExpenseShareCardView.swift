import AssistantCore
import SwiftUI
import UIKit

/// 方案二：温润收支手账日签卡片 (Warm Editorial Expense Journal Card)
///
/// 专为小红书、即刻、朋友圈设计的温暖燕麦纸感收支手账卡片，
/// 包含消费账目明细、安心花状态、AA人均分摊，
/// 并按规范展示 App 图标与 JohnnyBoyStudio 品牌标识。
public struct ExpenseShareCardView: View {
    public let record: ExpenseRecord
    public let todayTotalSpent: Double?
    public let safeToSpendRemaining: Double?

    public init(
        record: ExpenseRecord,
        todayTotalSpent: Double? = nil,
        safeToSpendRemaining: Double? = nil
    ) {
        self.record = record
        self.todayTotalSpent = todayTotalSpent
        self.safeToSpendRemaining = safeToSpendRemaining
    }

    private var splitCount: Int { max(record.splitCount, 1) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 1. 顶部 Header
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("DAILY LEDGER · 生活收支手账")
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.6, green: 0.55, blue: 0.5))
                        .tracking(1.0)

                    Text(record.date.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "zh_CN"))).uppercased())
                        .font(.system(size: 22, weight: .black, design: .serif))
                        .foregroundStyle(Color(red: 0.18, green: 0.16, blue: 0.14))

                    Text(record.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(red: 0.5, green: 0.46, blue: 0.42))
                }

                Spacer()

                // 金额大字
                VStack(alignment: .trailing, spacing: 1) {
                    Text(record.isIncome ? "入账金额" : "消费支出")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(red: 0.5, green: 0.46, blue: 0.42))
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(record.isIncome ? "+¥" : "¥")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(record.isIncome ? Color.green : Color(red: 0.18, green: 0.16, blue: 0.14))
                        Text(String(format: "%.2f", record.amount))
                            .font(.system(size: 24, weight: .black, design: .rounded))
                            .foregroundStyle(record.isIncome ? Color.green : Color(red: 0.18, green: 0.16, blue: 0.14))
                    }
                }
            }

            Rectangle()
                .fill(Color(red: 0.85, green: 0.82, blue: 0.78))
                .frame(height: 0.8)

            // 2. 核心账单信息卡
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: record.category.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(red: 0.18, green: 0.16, blue: 0.14))
                        .frame(width: 36, height: 36)
                        .background(Color(red: 0.90, green: 0.87, blue: 0.82))
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.title)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color(red: 0.18, green: 0.16, blue: 0.14))

                        HStack(spacing: 6) {
                            Text(record.category.rawValue)
                                .font(.system(size: 11))
                                .foregroundStyle(Color(red: 0.5, green: 0.46, blue: 0.42))

                            if let foreignBadge = record.formattedForeignBadge {
                                Text("· \(foreignBadge)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color(red: 0.5, green: 0.46, blue: 0.42))
                            }
                        }
                    }

                    Spacer()
                }

                // 若有 AA 分摊
                if !record.isIncome && splitCount > 1 {
                    HStack {
                        Label("AA 分摊：\(splitCount) 人", systemImage: "person.2.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(red: 0.45, green: 0.4, blue: 0.35))
                        Spacer()
                        Text("每人 ¥\(String(format: "%.2f", record.amount / Double(splitCount)))")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(red: 0.18, green: 0.16, blue: 0.14))
                    }
                    .padding(8)
                    .background(Color(red: 0.92, green: 0.89, blue: 0.84))
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous))
                }
            }
            .padding(12)
            .background(Color.white.opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous)
                    .strokeBorder(Color(red: 0.88, green: 0.85, blue: 0.80), lineWidth: 0.8)
            )

            // 3. 今日安心花状态条（若存在）
            if let safeRemaining = safeToSpendRemaining {
                VStack(spacing: 4) {
                    HStack {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(safeRemaining >= 0 ? Color.green : Color.orange)
                                .frame(width: 6, height: 6)
                            Text("今日安心花 · Safe-to-Spend")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(Color(red: 0.3, green: 0.28, blue: 0.25))
                        }
                        Spacer()
                        Text(safeRemaining >= 0 ? "预算健康" : "轻微超支")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(safeRemaining >= 0 ? Color.green : Color.orange)
                    }

                    HStack {
                        Text("今日可用结余")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(red: 0.55, green: 0.5, blue: 0.45))
                        Spacer()
                        Text("¥\(String(format: "%.2f", safeRemaining))")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(red: 0.18, green: 0.16, blue: 0.14))
                    }
                }
                .padding(10)
                .background(Color.white.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
            }

            // 4. 底部品牌栏 (App 图标 + JohnnyBoyStudio)
            VStack(spacing: 8) {
                Rectangle()
                    .fill(Color(red: 0.85, green: 0.82, blue: 0.78))
                    .frame(height: 0.8)

                HStack(alignment: .center, spacing: 10) {
                    Image("AssistantAppIcon")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.chip, style: .continuous))
                        .shadow(color: Color.black.opacity(0.12), radius: 3, y: 1)

                    VStack(alignment: .leading, spacing: 1.5) {
                        Text("小助 Assistant")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color(red: 0.18, green: 0.16, blue: 0.14))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)

                        Text("记所想，助所行")
                            .font(.system(size: 9))
                            .foregroundStyle(Color(red: 0.5, green: 0.46, blue: 0.42))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 1) {
                        Text("JohnnyBoyStudio")
                            .font(.system(size: 10.5, weight: .black, design: .rounded))
                            .foregroundStyle(Color(red: 0.25, green: 0.22, blue: 0.20))
                            .lineLimit(1)

                        Text("Crafted with Purpose")
                            .font(.system(size: 8))
                            .foregroundStyle(Color(red: 0.6, green: 0.55, blue: 0.5))
                            .lineLimit(1)
                    }
                    .fixedSize(horizontal: true, vertical: true)
                }
            }
        }
        .padding(18)
        // 窄屏时允许卡片收缩，分享卡片仍保留 350pt 的最大宽度。
        .frame(maxWidth: 350)
        .background(Color(red: 0.97, green: 0.96, blue: 0.94))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.hero, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.hero, style: .continuous)
                .strokeBorder(Color(red: 0.88, green: 0.85, blue: 0.80), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 14, y: 6)
    }
}

/// 升级后的账单分享弹层（支持手账卡片生成、相册保存与系统分享）
public struct ExpenseCardShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    public let record: ExpenseRecord

    @State private var toastMessage: String?
    @State private var includeReceipt = false
    @State private var showSystemShareSheet = false
    @State private var shareItems: [Any] = []

    public init(record: ExpenseRecord) {
        self.record = record
    }

    private var cardView: ExpenseShareCardView {
        ExpenseShareCardView(record: record)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    cardView
                        .padding(.top, 10)

                    VStack(spacing: 12) {
                        Button {
                            saveToPhotos()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "square.and.arrow.down.fill")
                                Text("保存手账日签至相册 (社交分享)")
                            }
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color(red: 0.25, green: 0.22, blue: 0.20))
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous))
                        }

                        Button {
                            shareViaSystem()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "photo.on.rectangle.angled")
                                Text("直接发送到社交平台")
                            }
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.banner, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("分享手账卡片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .overlay(alignment: .bottom) {
                if let msg = toastMessage {
                    Text(msg)
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.85), in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: toastMessage)
        }
        .sheet(isPresented: $showSystemShareSheet, onDismiss: { shareItems = [] }) {
            ShareActivityView(activityItems: shareItems)
        }
    }

    @MainActor
    private func renderImage() -> UIImage? {
        ShareCardActions.render(cardView)
    }

    private func saveToPhotos() {
        guard let image = renderImage() else {
            showToast(ShareCardActions.renderFailureMessage)
            return
        }
        Task { @MainActor in
            showToast(await ShareCardActions.saveToPhotos(image, successMessage: "已保存温润手账卡片至相册 📸"))
        }
    }

    private func shareViaSystem() {
        guard let image = renderImage() else {
            showToast(ShareCardActions.renderFailureMessage)
            return
        }

        var items: [Any] = [image]
        if includeReceipt, let data = record.receiptImageData, let receiptImg = UIImage(data: data) {
            items.append(receiptImg)
        }
        shareItems = items
        showSystemShareSheet = true
    }

    private func showToast(_ msg: String) {
        toastMessage = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if toastMessage == msg { toastMessage = nil }
        }
    }
}
