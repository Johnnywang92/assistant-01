import AssistantCore
import Photos
import SwiftData
import SwiftUI
import UIKit

/// 社交网络分享海报卡片主题
enum ShareCardTheme: String, CaseIterable, Identifiable {
    case cleanWhite = "极简白"
    case midnight = "暗夜星空"
    case obsidian = "黑曜石成就"
    case paper = "羊皮书卷"

    var id: String { rawValue }

    var backgroundColor: Color {
        switch self {
        case .cleanWhite:
            return Color.white
        case .midnight:
            return Color(red: 0.08, green: 0.09, blue: 0.12)
        case .obsidian:
            return Color(red: 0.05, green: 0.06, blue: 0.08)
        case .paper:
            return Color(red: 0.96, green: 0.94, blue: 0.90)
        }
    }

    var textColor: Color {
        switch self {
        case .cleanWhite, .paper:
            return Color(red: 0.12, green: 0.13, blue: 0.15)
        case .midnight, .obsidian:
            return Color.white
        }
    }

    var secondaryTextColor: Color {
        switch self {
        case .cleanWhite, .paper:
            return Color.secondary
        case .midnight:
            return Color(white: 0.65)
        case .obsidian:
            return Color(red: 0.55, green: 0.60, blue: 0.66)
        }
    }

    var dividerColor: Color {
        switch self {
        case .cleanWhite:
            return Color(.systemGray5)
        case .midnight:
            return Color.white.opacity(0.12)
        case .obsidian:
            return Color(red: 0.18, green: 0.85, blue: 0.48).opacity(0.25)
        case .paper:
            return Color(red: 0.85, green: 0.82, blue: 0.77)
        }
    }

    var accentColor: Color {
        switch self {
        case .obsidian:
            return Color(red: 0.18, green: 0.85, blue: 0.48)
        default:
            return Color.accentColor
        }
    }
}

/// 专为导出高清分享图设计的 SwiftUI 卡片视图（支持 3x 离屏光栅化）
struct TodoShareCardView: View {
    let title: String
    let items: [TodoItem]
    let showWatermark: Bool
    let theme: ShareCardTheme
    var miniQRCode: UIImage? = nil

    // 双语 Slogan 定义
    static let sloganZh = "记所想，助所行"
    static let sloganEn = "Capture thoughts, empower actions."

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 1. 卡片头部：日期与总览
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Date.now.formatted(.dateTime.year().month().day().weekday(.wide)))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.secondaryTextColor)

                    Text(L10n.tr(title))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.textColor)
                }

                Spacer()

                // 完成进度胶囊
                let doneCount = items.filter { $0.status == .done }.count
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(doneCount)/\(items.count)")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.accentColor)
                    Text("完成进度")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.secondaryTextColor)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(theme.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            Rectangle()
                .fill(theme.dividerColor)
                .frame(height: 1)

            // 2. 清单列表条目
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checklist")
                        .font(.largeTitle)
                        .foregroundStyle(theme.secondaryTextColor.opacity(0.5))
                    Text("请在下方列表中勾选要分享的事项")
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryTextColor)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                let displayItems = Array(items.prefix(15))
                VStack(alignment: .leading, spacing: 13) {
                    ForEach(displayItems) { item in
                        HStack(spacing: 12) {
                            Image(systemName: item.status == .done ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(item.status == .done ? (theme == .obsidian ? theme.accentColor : Color.green) : Color.secondary.opacity(0.6))

                            VStack(alignment: .leading, spacing: 3) {
                                Text(L10n.tr(item.title))
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(item.status == .done ? theme.secondaryTextColor : theme.textColor)
                                    .strikethrough(item.status == .done)

                                if let code = item.pickupCode {
                                    HStack(spacing: 4) {
                                        Text("取件码：\(code)")
                                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                                        if let station = item.location ?? item.station {
                                            Text("(\(station))")
                                                .font(.system(size: 11))
                                        }
                                    }
                                    .foregroundStyle(Color.orange)
                                }
                            }

                            Spacer()
                        }
                    }

                    if items.count > 15 {
                        Text("… 更多 \(items.count - 15) 项事项")
                            .font(.caption)
                            .foregroundStyle(theme.secondaryTextColor)
                            .padding(.leading, 28)
                    }
                }
                .padding(.vertical, 2)
            }

            // 3. 底部 App Logo 与 Slogan 水印栏（可自由显隐）
            if showWatermark {
                Rectangle()
                    .fill(theme.dividerColor)
                    .frame(height: 1)
                    .padding(.top, 4)

                HStack(spacing: 12) {
                    Image("AssistantAppIcon")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 38, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .shadow(color: Color.black.opacity(0.08), radius: 3, y: 1)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("小助")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(theme.textColor)

                            Text("· 个人智能生活助理")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(theme.secondaryTextColor)
                        }

                        // 双语 Slogan：记所想，助所行 / Capture thoughts, empower actions.
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Self.sloganZh)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(theme.accentColor)

                            Text(Self.sloganEn)
                                .font(.system(size: 9.5, weight: .regular))
                                .foregroundStyle(theme.secondaryTextColor)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 3) {
                        if let miniQRCode {
                            Image(uiImage: miniQRCode)
                                .interpolation(.none)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 38, height: 38)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
                                )
                        }

                        Text("JohnnyBoyStudio")
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            .foregroundStyle(theme == .obsidian ? Color(red: 0.18, green: 0.85, blue: 0.48) : theme.secondaryTextColor)
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 350)
        .background(theme.backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(theme.dividerColor.opacity(0.6), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 14, y: 5)
    }
}

/// 分享展示形式
enum ShareFormatMode: String, CaseIterable, Identifiable {
    case qrCode = "面对面二维码"
    case poster = "海报长图卡片"

    var id: String { rawValue }
}

/// 专为面对面扫码设计的二维码分享卡片
struct TodoQRCodeCardView: View {
    let title: String
    let items: [TodoItem]
    let qrImage: UIImage?

    var body: some View {
        VStack(spacing: 14) {
            // 顶部 App 标志与标语
            HStack(spacing: 10) {
                Image("AssistantAppIcon")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .shadow(color: Color.black.opacity(0.08), radius: 3, y: 1)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("小助 · 面对面扫码导入")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.primary)
                    }

                    Text("记所想，助所行 · Capture thoughts, empower actions.")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color.secondary)
                }

                Spacer()
            }

            Rectangle()
                .fill(Color(.systemGray5))
                .frame(height: 1)

            // 清单标题与条目统计
            VStack(spacing: 4) {
                Text(L10n.tr(title))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.primary)

                Text("已打包 \(items.count) 项待办事宜，扫码一键同步至手机")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
            }

            // 高清二维码
            if let qrImage {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 210, height: 210)
                    .padding(12)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.black.opacity(0.08), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.06), radius: 8, y: 3)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("请在下方勾选待办生成二维码")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
                .frame(width: 210, height: 210)
            }

            // 引导提示胶囊
            HStack(spacing: 6) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.caption.bold())
                    .foregroundStyle(Color.accentColor)
                Text("其他用户打开小助扫一扫，或使用系统相机直接扫描")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.08))
            .clipShape(Capsule())
        }
        .padding(20)
        .frame(width: 340)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color(.systemGray5), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 14, y: 5)
    }
}

/// 待办分享管理面板（支持选择分类、自主勾选条目、生成社交图片、防闪退相册权限校验）
struct TodoShareSheet: View {
    @Environment(\.dismiss) private var dismiss

    let allTodos: [TodoItem]
    @State private var selectedCategory: TodoFilterCategory
    @State private var selectedItemIds: Set<UUID>

    @State private var shareFormat: ShareFormatMode = .qrCode
    @State private var showWatermark: Bool = true
    @State private var selectedTheme: ShareCardTheme = .cleanWhite
    @State private var renderedImage: UIImage?
    @State private var toastMessage: String?
    @State private var showSystemShareSheet: Bool = false
    @State private var isItemSelectionExpanded: Bool = true

    init(
        allTodos: [TodoItem],
        initialCategory: TodoFilterCategory = .all,
        initialSelectedIds: Set<UUID>? = nil
    ) {
        self.allTodos = allTodos
        self._selectedCategory = State(initialValue: initialCategory)

        // 计算当前分类下的候选项
        let candidates = Self.filterItems(allTodos: allTodos, category: initialCategory)
        let defaultSelection: Set<UUID>
        if let initialSelectedIds {
            defaultSelection = initialSelectedIds
        } else {
            // 默认全选当前分类下的条目
            defaultSelection = Set(candidates.map { $0.id })
        }
        self._selectedItemIds = State(initialValue: defaultSelection)
    }

    // MARK: - 候选数据源过滤

    private static func filterItems(allTodos: [TodoItem], category: TodoFilterCategory) -> [TodoItem] {
        switch category {
        case .all:
            return allTodos
        case .general:
            return allTodos.filter { [.general, .event].contains($0.type) }
        case .work:
            return allTodos.filter { $0.type == .work }
        case .recurring:
            return allTodos.filter { $0.isRecurring }
        case .parcel:
            return allTodos.filter { [.parcel, .returnParcel].contains($0.type) }
        case .life:
            return allTodos.filter { [.medication, .housework, .charging, .hydration].contains($0.type) }
        case .alert:
            return allTodos.filter { [.subscription, .bill, .itemExpiry, .anniversary, .passwordSecurity, .data, .vehicleCare].contains($0.type) }
        case .parenting:
            return allTodos.filter { [.childVaccine, .childGrowth, .childMilestone, .childHealth].contains($0.type) }
        case .pet:
            return allTodos.filter { $0.type == .pet }
        }
    }

    /// 当前分类下的所有候选项
    private var candidateItems: [TodoItem] {
        Self.filterItems(allTodos: allTodos, category: selectedCategory)
    }

    /// 勾选并在卡片上实际展示的事项列表
    private var itemsForCard: [TodoItem] {
        candidateItems.filter { selectedItemIds.contains($0.id) }
    }

    /// 动态卡片标题
    private var dynamicCardTitle: String {
        switch selectedCategory {
        case .all:
            return L10n.tr("我的生活清单")
        case .general:
            return L10n.tr("日常待办清单")
        case .work:
            return L10n.tr("工作待办清单")
        case .recurring:
            return L10n.tr("周期待办清单")
        case .parcel:
            return L10n.tr("快递与退货清单")
        case .life:
            return L10n.tr("生活作息备忘")
        case .alert:
            return L10n.tr("重要提醒与预警")
        case .parenting:
            return L10n.tr("亲子育儿清单")
        case .pet:
            return L10n.tr("宠物照护")
        }
    }

    /// 面对面扫码高清二维码
    private var qrCodeImage: UIImage? {
        guard !itemsForCard.isEmpty else { return nil }
        let payloadURL = QRCodeService.encodePayload(title: dynamicCardTitle, todos: itemsForCard)
        return QRCodeService.generateQRCode(from: payloadURL, targetSize: 480)
    }

    /// 海报卡片右下角小二维码
    private var miniQRCodeImage: UIImage? {
        guard !itemsForCard.isEmpty else { return nil }
        let payloadURL = QRCodeService.encodePayload(title: dynamicCardTitle, todos: itemsForCard)
        return QRCodeService.generateQRCode(from: payloadURL, targetSize: 140)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // 0. 分享形式切换：面对面二维码 vs 海报长图卡片
                    Picker("分享形式", selection: $shareFormat) {
                        ForEach(ShareFormatMode.allCases) { mode in
                            Text(L10n.tr(mode.rawValue)).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.top, 4)

                    // 1. 分类快速切换胶囊栏
                    categorySegmentBar

                    // 2. 实时所见即所得卡片预览
                    if shareFormat == .qrCode {
                        TodoQRCodeCardView(
                            title: dynamicCardTitle,
                            items: itemsForCard,
                            qrImage: qrCodeImage
                        )
                        .padding(.horizontal)
                    } else {
                        TodoShareCardView(
                            title: dynamicCardTitle,
                            items: itemsForCard,
                            showWatermark: showWatermark,
                            theme: selectedTheme,
                            miniQRCode: miniQRCodeImage
                        )
                        .padding(.horizontal)
                    }

                    // 3. 事项勾选列表板块（可自主选择要分享的事项）
                    itemSelectionSection

                    // 4. 视觉与参数配置板块
                    if shareFormat == .poster {
                        VStack(spacing: 14) {
                            // 水印 Logo 开关
                            Toggle(isOn: $showWatermark) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "sparkles")
                                            .foregroundStyle(.tint)
                                        Text("显示 App 图标与 Slogan")
                                            .font(.subheadline.bold())
                                    }
                                    Text("开启展示「记所想，助所行」双语标语与扫码导入角标")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tint(.accentColor)

                            Divider()

                            // 卡片质感配色切换
                            HStack {
                                Text("卡片配色")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Picker("卡片配色", selection: $selectedTheme) {
                                    ForEach(ShareCardTheme.allCases) { t in
                                        Text(L10n.tr(t.rawValue)).tag(t)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .frame(maxWidth: 210)
                            }
                        }
                        .padding(16)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
                        .padding(.horizontal)
                    } else {
                        // 二维码使用说明卡片
                        HStack(spacing: 12) {
                            Image(systemName: "info.circle.fill")
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("扫码即时传输")
                                    .font(.subheadline.bold())
                                Text("双方无需添加好友，离线状态下也可直接对准屏幕扫描导入。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
                        .padding(.horizontal)
                    }

                    // 5. 核心分享按钮组
                    VStack(spacing: 12) {
                        if shareFormat == .qrCode {
                            // 二维码模式：保存二维码到相册 / 复制导入口令 / 直接分享图片
                            Button {
                                generateAndSaveToPhotos()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "square.and.arrow.down.fill")
                                    Text("保存二维码卡片到相册")
                                }
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(itemsForCard.isEmpty ? Color.gray : Color.accentColor)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .disabled(itemsForCard.isEmpty)

                            HStack(spacing: 10) {
                                Button {
                                    copyImportLink()
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "doc.on.doc")
                                        Text("复制导入口令链接")
                                    }
                                    .font(.subheadline.bold())
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color(.secondarySystemGroupedBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .disabled(itemsForCard.isEmpty)

                                Button {
                                    shareImageViaSystemSheet()
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "photo.on.rectangle.angled")
                                        Text("直接分享卡片")
                                    }
                                    .font(.subheadline.bold())
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color(.secondarySystemGroupedBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .disabled(itemsForCard.isEmpty)
                            }

                            ShareLink(
                                item: generateFriendShareText(),
                                subject: Text("好友分享给您的生活待办"),
                                message: Text("包含结构化清单，支持直接查看与导入小助 App")
                            ) {
                                HStack(spacing: 6) {
                                    Image(systemName: "person.2.fill")
                                    Text("分享文本给朋友 (含一键导入链接)")
                                }
                                .font(.subheadline.bold())
                                .foregroundStyle(Color.accentColor)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.accentColor.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .disabled(itemsForCard.isEmpty)

                        } else {
                            // 海报长图模式
                            Button {
                                generateAndSaveToPhotos()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "square.and.arrow.down.fill")
                                    Text("保存卡片至相册 (社交分享)")
                                }
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(itemsForCard.isEmpty ? Color.gray : Color.accentColor)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .disabled(itemsForCard.isEmpty)

                            Button {
                                shareImageViaSystemSheet()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "photo.on.rectangle.angled")
                                    Text("直接分享图片")
                                }
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color(.secondarySystemGroupedBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(itemsForCard.isEmpty)

                            ShareLink(
                                item: generateFriendShareText(),
                                subject: Text("好友分享给您的生活待办"),
                                message: Text("包含结构化清单，支持直接查看与导入小助 App")
                            ) {
                                HStack(spacing: 6) {
                                    Image(systemName: "person.2.fill")
                                    Text("分享文本给朋友 (含一键导入链接)")
                                }
                                .font(.subheadline.bold())
                                .foregroundStyle(Color.accentColor)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.accentColor.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .disabled(itemsForCard.isEmpty)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("分享待办与信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        shareImageViaSystemSheet()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(itemsForCard.isEmpty)
                }
            }
            .sheet(isPresented: $showSystemShareSheet) {
                if let renderedImage {
                    ShareActivityView(activityItems: [renderedImage])
                }
            }
            .overlay(alignment: .bottom) {
                if let toastMessage {
                    Text(L10n.tr(toastMessage))
                        .font(.footnote.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.black.opacity(0.85)))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 24)
                }
            }
        }
    }

    // MARK: - 1. 分类选择栏

    private var categorySegmentBar: some View {
        HStack(spacing: 6) {
            ForEach(TodoFilterCategory.allCases) { cat in
                let isSelected = selectedCategory == cat
                let count = Self.filterItems(allTodos: allTodos, category: cat).count

                Button {
                    AppMotion.animate(.spring(response: 0.3, dampingFraction: 0.8)) {
                        selectedCategory = cat
                        // 切换分类后自动全选该分类下的事项
                        let newCandidates = Self.filterItems(allTodos: allTodos, category: cat)
                        selectedItemIds = Set(newCandidates.map { $0.id })
                    }
                    Haptic.selection()
                } label: {
                    HStack(spacing: 4) {
                        Text(L10n.tr(cat.rawValue))
                            .font(.subheadline)
                            .fontWeight(isSelected ? .bold : .medium)

                        if count > 0 {
                            Text("\(count)")
                                .font(.caption2.bold())
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(isSelected ? Color.white.opacity(0.25) : Color.secondary.opacity(0.15)))
                        }
                    }
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isSelected ? Color.accentColor : Color(.secondarySystemBackground))
                    )
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
    }

    // MARK: - 2. 事项勾选选择区（支持多选、反选、自主挑选）

    private var itemSelectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("选择要分享的事项")
                    .font(.subheadline.bold())

                Text("(\(itemsForCard.count)/\(candidateItems.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if !candidateItems.isEmpty {
                    Button(selectedItemIds.count == candidateItems.count ? "取消全选" : "全选本类") {
                        AppMotion.animate(.spring(response: 0.25)) {
                            if selectedItemIds.count == candidateItems.count {
                                selectedItemIds.removeAll()
                            } else {
                                selectedItemIds = Set(candidateItems.map { $0.id })
                            }
                        }
                        Haptic.selection()
                    }
                    .font(.caption.bold())
                }
            }

            if candidateItems.isEmpty {
                HStack {
                    Spacer()
                    Text("当前「\(L10n.tr(selectedCategory.rawValue))」分类下暂无事项")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                    Spacer()
                }
            } else {
                VStack(spacing: 6) {
                    ForEach(candidateItems) { item in
                        let isSelected = selectedItemIds.contains(item.id)
                        Button {
                            AppMotion.animate(.spring(response: 0.2)) {
                                if isSelected {
                                    selectedItemIds.remove(item.id)
                                } else {
                                    selectedItemIds.insert(item.id)
                                }
                            }
                            Haptic.light()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                    .font(.title3)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L10n.tr(item.title))
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    if let code = item.pickupCode {
                                        HStack(spacing: 4) {
                                            Text("取件码: \(code)")
                                                .font(.caption.bold())
                                                .foregroundStyle(.orange)
                                            if let station = item.location ?? item.station {
                                                Text("(\(station))")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }

                                Spacer()

                                if item.status == .done {
                                    Text("已完成")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                                }
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
        .padding(.horizontal)
    }

    // MARK: - 3x 高清离屏光栅化 (ImageRenderer)

    @MainActor
    private func renderCardImage() -> UIImage? {
        if shareFormat == .qrCode {
            let card = TodoQRCodeCardView(
                title: dynamicCardTitle,
                items: itemsForCard,
                qrImage: qrCodeImage
            )
            let renderer = ImageRenderer(content: card)
            renderer.scale = 3.0
            renderer.isOpaque = false
            return renderer.uiImage
        } else {
            let card = TodoShareCardView(
                title: dynamicCardTitle,
                items: itemsForCard,
                showWatermark: showWatermark,
                theme: selectedTheme,
                miniQRCode: miniQRCodeImage
            )
            let renderer = ImageRenderer(content: card)
            renderer.scale = 3.0 // 3x 超高清清晰度
            renderer.isOpaque = false
            return renderer.uiImage
        }
    }

    private func copyImportLink() {
        guard !itemsForCard.isEmpty else { return }
        let payloadURL = QRCodeService.encodePayload(title: dynamicCardTitle, todos: itemsForCard)
        UIPasteboard.general.string = payloadURL
        Haptic.success()
        showToast("已复制一键导入口令链接 📋")
    }

    private func generateAndSaveToPhotos() {
        guard !itemsForCard.isEmpty else {
            showToast("请至少勾选 1 项待办再保存")
            return
        }
        guard let image = renderCardImage() else {
            showToast("生成卡片失败，请重试")
            return
        }

        // 使用 PHPhotoLibrary 规范请求写入权限，杜绝隐私权限导致的系统级 Crash
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            DispatchQueue.main.async {
                switch status {
                case .authorized, .limited:
                    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                    Haptic.success()
                    showToast(shareFormat == .qrCode ? "已保存高清二维码至相册 ✨" : "已保存超清海报至系统相册 ✨")
                case .denied, .restricted:
                    Haptic.warning()
                    showToast("保存失败：请在系统「设置」中允许小助访问相册")
                case .notDetermined:
                    showToast("请授权相册访问以保存卡片")
                @unknown default:
                    showToast("保存相册遇到未知状态")
                }
            }
        }
    }

    private func shareImageViaSystemSheet() {
        guard !itemsForCard.isEmpty else {
            showToast("请至少勾选 1 项待办再分享")
            return
        }
        guard let image = renderCardImage() else { return }
        self.renderedImage = image
        self.showSystemShareSheet = true
    }

    private func showToast(_ msg: String) {
        AppMotion.animate(.spring(duration: 0.25)) {
            toastMessage = msg
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            AppMotion.animate(.easeInOut(duration: 0.25)) {
                toastMessage = nil
            }
        }
    }

    // MARK: - 场景 1：朋友 1 对 1 文本生成

    private func generateFriendShareText() -> String {
        let items = itemsForCard
        guard !items.isEmpty else { return "【小助清单】暂无选中的事项" }
        var text = "【小助清单】\(dynamicCardTitle)\n"
        for (i, item) in items.enumerated() {
            let status = item.status == .done ? "✅" : "⏳"
            let code = item.pickupCode != nil ? " (取件码: \(item.pickupCode!))" : ""
            text += "\(i + 1). \(status) \(item.title)\(code)\n"
        }
        let importURL = QRCodeService.encodePayload(title: dynamicCardTitle, todos: items)
        text += "\n📲 复制本条内容或轻点链接导入小助 App：\n\(importURL)\n\n—— 记所想，助所行 (Capture thoughts, empower actions.)"
        return text
    }
}

/// 系统 UIActivityViewController 桥接封装
struct ShareActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    init(activityItems: [Any]) {
        self.activityItems = activityItems
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
