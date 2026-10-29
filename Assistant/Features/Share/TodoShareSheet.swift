/// 待办分享管理面板（支持选择分类、自主勾选条目、生成社交图片、防闪退相册权限校验）
///
/// 从 Assistant/Features/TodoShareSheet.swift 拆出（原文件 1009 行）：
/// - 主题 → ShareCardTheme.swift
/// - 海报卡片 → TodoShareCardView.swift
/// - 二维码卡片与展示形式 → TodoQRCodeCardView.swift
/// - 系统分享桥接 → ShareActivityView.swift
/// - 分类/标题/分享文案规则 → AssistantCore.TodoShareContent（可单测）
import AssistantCore
import SwiftData
import SwiftUI
import UIKit

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

    /// 候选过滤：规则在 `AssistantCore.TodoShareContent`（可单测），
    /// 这里只负责把 SwiftData 模型映射成 Core 的纯值快照。
    private static func filterItems(allTodos: [TodoItem], category: TodoFilterCategory) -> [TodoItem] {
        let shareCategory = category.shareCategory
        switch shareCategory {
        case .all:
            return allTodos
        case .general:
            let now = Date.now
            let cal = Calendar.current
            return allTodos.filter {
                TodoShareContent.isTodayItem(
                    dueAt: $0.dueAt,
                    reminderOverrideAt: $0.reminderOverrideAt,
                    createdAt: $0.createdAt,
                    now: now,
                    calendar: cal
                )
            }
        case .recurring:
            return allTodos.filter { $0.isRecurring }
        default:
            let groups = TodoShareContent.groups(for: shareCategory)
            return allTodos.filter { item in
                guard let group = shareGroup(for: item.type) else { return false }
                return groups.contains(group)
            }
        }
    }

    /// 模型映射：`TodoType` → 分享类型分组。
    /// 「哪些类型算哪一组」的规则在 Core，这里只做一对一映射，
    /// 避免同一份分类清单写两遍然后各自漂移。
    private static func shareGroup(for type: TodoType) -> TodoShareTypeGroup? {
        switch type {
        case .work: return .work
        case .parcel: return .parcel
        case .returnParcel: return .returnParcel
        case .medication, .housework, .charging, .hydration: return .life
        case .subscription, .bill, .itemExpiry, .anniversary, .passwordSecurity, .data, .vehicleCare: return .alert
        case .childVaccine, .childGrowth, .childMilestone, .childHealth: return .parenting
        case .pet: return .pet
        case .other: return .other
        default: return nil
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

    /// 动态卡片标题：文案规则在 Core，这里做本地化
    private var dynamicCardTitle: String {
        L10n.tr(TodoShareContent.title(for: selectedCategory.shareCategory))
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
            .sheet(isPresented: $showSystemShareSheet, onDismiss: { renderedImage = nil }) {
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

    // MARK: - 3x 高清离屏光栅化（ShareCardActions）

    @MainActor
    private func renderCardImage() -> UIImage? {
        if shareFormat == .qrCode {
            return ShareCardActions.render(
                TodoQRCodeCardView(
                    title: dynamicCardTitle,
                    items: itemsForCard,
                    qrImage: qrCodeImage
                )
            )
        }
        return ShareCardActions.render(
            TodoShareCardView(
                title: dynamicCardTitle,
                items: itemsForCard,
                showWatermark: showWatermark,
                theme: selectedTheme,
                miniQRCode: miniQRCodeImage
            )
        )
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
            showToast(ShareCardActions.renderFailureMessage)
            return
        }
        Task { @MainActor in
            showToast(await ShareCardActions.saveToPhotos(
                image,
                successMessage: shareFormat == .qrCode ? "已保存高清二维码至相册 ✨" : "已保存超清海报至系统相册 ✨"
            ))
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

    /// 好友分享文案：拼装规则在 `AssistantCore.TodoShareTextBuilder`（可单测），
    /// 这里只负责取模型快照与导入链接。
    private func generateFriendShareText() -> String {
        let items = itemsForCard
        guard !items.isEmpty else { return "【小助清单】暂无选中的事项" }
        let importURL = QRCodeService.encodePayload(title: dynamicCardTitle, todos: items)
        return TodoShareTextBuilder.friendShareText(
            title: dynamicCardTitle,
            items: items.map {
                TodoShareItem(
                    id: $0.id,
                    title: $0.title,
                    pickupCode: $0.pickupCode,
                    isDone: $0.status == .done,
                    isRecurring: $0.isRecurring,
                    dueAt: $0.dueAt,
                    reminderOverrideAt: $0.reminderOverrideAt,
                    createdAt: $0.createdAt
                )
            },
            importURL: importURL
        )
    }
}

/// 筛选分类 → 分享分类的一一映射。
/// 两套枚举的 case 名完全对齐，但 rawValue 不同（界面文案 vs 稳定标识），
/// 所以显式映射一次，避免用 rawValue 互转那种「改文案就崩」的隐式耦合。
extension TodoFilterCategory {
    var shareCategory: TodoShareCategory {
        switch self {
        case .all: return .all
        case .general: return .general
        case .work: return .work
        case .recurring: return .recurring
        case .parcel: return .parcel
        case .life: return .life
        case .alert: return .alert
        case .parenting: return .parenting
        case .pet: return .pet
        case .other: return .other
        }
    }
}
