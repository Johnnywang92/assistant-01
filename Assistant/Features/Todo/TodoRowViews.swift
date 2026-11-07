import AssistantCore
import PhotosUI
import SwiftData
import SwiftUI
import CoreLocation
import WeatherKit

struct TodoRow: View {
    @Environment(\.modelContext) private var context
    let item: TodoItem
    var isHighlighted: Bool = false
    var onMoveToTop: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil
    var onShowQRCode: (() -> Void)? = nil
    var onShare: (() -> Void)? = nil
    @ObservedObject private var seniorManager = SeniorModeManager.shared
    @State private var isCopied: Bool = false
    @State private var isAnimatingCompletion: Bool = false
    @State private var ringScale: CGFloat = 0.5
    @State private var ringOpacity: Double = 0.0

    private var isEffectivelyDone: Bool {
        item.status == .done || isAnimatingCompletion
    }

    private var isSenior: Bool { seniorManager.isSeniorModeEnabled }

    private var metaColor: Color {
        seniorManager.isHighContrastEnabled ? Color.primary.opacity(0.85) : Color.secondary
    }

    private var typeColor: Color {
        switch item.type {
        case .parcel: return .orange
        case .returnParcel: return .indigo
        case .general, .event: return .blue
        case .work: return .brown
        case .medication: return .green
        case .housework: return .purple
        case .charging: return .yellow
        case .subscription, .bill: return .indigo
        case .itemExpiry: return .red
        case .anniversary: return .pink
        case .passwordSecurity: return .teal
        case .vehicleCare: return .indigo
        case .exercise: return .green
        case .childVaccine, .childGrowth, .childMilestone, .childHealth: return .pink
        case .pet: return .orange
        case .other: return .secondary
        default: return .secondary
        }
    }

    // MARK: - 两行契约

    /// 每一行固定两层：主行（标题/取件码 + 至多一个主操作）、元数据行。
    /// 地点、详情、时间、重复、来源全部中点内联，超长由 lineLimit(1) 截断，
    /// 不再各自独占一个子行 —— 这是首页卡片「松散」的根因。
    private struct MetadataPiece {
        let text: String
        var isDanger: Bool = false
    }

    private var navigationTarget: String? {
        guard item.type != .parcel, item.type != .returnParcel,
              let loc = item.displayLocationText, !loc.isEmpty else { return nil }
        return loc
    }

    private var metadataPieces: [MetadataPiece] {
        var pieces: [MetadataPiece] = []

        let placeText: String? = {
            if let loc = item.location, let st = item.station, !loc.contains(st) {
                return "\(st) · \(loc)"
            }
            return item.location ?? item.station
        }()

        let leading: String
        switch item.type {
        case .parcel:
            // 驿站 / 快递 / 柜位 / 事项名压成同一段，不再单独占一层
            leading = [item.courier, placeText, item.displayConciseTitle]
                .compactMap { $0 }
                .joined(separator: " · ")
        case .returnParcel:
            leading = [
                item.pickupCode.map { "寄件码 \($0)" },
                item.station,
                item.courier,
                placeText
            ]
            .compactMap { $0 }
            .joined(separator: " · ")
        default:
            leading = [item.displayLocationText, item.displayConciseDetail]
                .compactMap { $0 }
                .joined(separator: " · ")
        }
        if !leading.isEmpty {
            pieces.append(MetadataPiece(text: leading))
        }

        // 退货倒数预警从主行胶囊降级为元数据里的一段红色文本
        if item.type == .returnParcel, let due = item.dueAt, !isEffectivelyDone {
            let days = Calendar.current.dateComponents(
                [.day],
                from: Calendar.current.startOfDay(for: .now),
                to: Calendar.current.startOfDay(for: due)
            ).day ?? 0
            let text = days < 0 ? "已逾期"
                : (days == 0 ? "今天截止!" : (days == 1 ? "仅剩1天" : "退货剩\(days)天"))
            pieces.append(MetadataPiece(text: text, isDanger: days <= 1))
        }

        if let due = item.dueAt {
            // 存量数据 scheduleRaw == nil 时不做 JSON 解码，列表滚动零额外开销。
            let schedule: TodoSchedule? = item.scheduleRaw == nil ? nil : item.schedule
            let cal = Calendar.current
            let timeText: String
            if let start = schedule?.effectiveStartAt, cal.isDate(start, inSameDayAs: due), !(schedule?.isAllDay ?? false) {
                timeText = "\(start.formatted(date: .numeric, time: .shortened))–\(due.formatted(date: .omitted, time: .shortened))"
            } else if let start = schedule?.effectiveStartAt, !(schedule?.isAllDay ?? false) {
                timeText = "\(start.formatted(date: .numeric, time: .shortened)) – \(due.formatted(date: .numeric, time: .shortened))"
            } else if schedule?.isAllDay == true {
                timeText = "\(due.formatted(date: .numeric, time: .omitted)) \(L10n.tr("全天"))"
            } else {
                timeText = due.formatted(date: .numeric, time: .shortened)
            }
            pieces.append(MetadataPiece(text: timeText, isDanger: due < .now && !isEffectivelyDone))
        } else {
            pieces.append(MetadataPiece(text: item.createdAt.formatted(.relative(presentation: .named))))
        }

        if item.isRecurring {
            pieces.append(MetadataPiece(text: "↻ \(item.recurrenceSummaryText)"))
        }
        for tag in item.tags.prefix(2) {
            pieces.append(MetadataPiece(text: "#\(tag)"))
        }
        return pieces
    }

    /// 用 AttributedString 保留局部配色（逾期红 / 常规次要色），
    /// 整段仍是一个 Text，可被 lineLimit(1) 统一截断。
    private var metadataText: AttributedString {
        var result = AttributedString()
        for (index, piece) in metadataPieces.enumerated() {
            if index > 0 {
                var separator = AttributedString(" · ")
                separator.foregroundColor = metaColor.opacity(0.6)
                result += separator
            }
            var part = AttributedString(piece.text)
            part.foregroundColor = piece.isDanger ? Color.red : metaColor
            result += part
        }
        return result
    }

    private var codeFont: Font {
        isSenior ? Font.title3.monospaced().bold() : Font.system(size: 17, weight: .bold, design: .monospaced)
    }

    private var titleFont: Font {
        if isSenior { return .title3 }
        return .body.weight(isEffectivelyDone ? .regular : (seniorManager.isHighContrastEnabled ? .bold : .semibold))
    }

    // MARK: - 主体

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            completionButton

            VStack(alignment: .leading, spacing: 4) {
                primaryLine
                Text(metadataText)
                    .font(isSenior ? .footnote : .caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                onEdit?()
                Haptic.light()
            }
        }
        .background(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .fill(isHighlighted ? Color.orange.opacity(0.20) : .clear)
                .overlay {
                    if isHighlighted {
                        RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                            .stroke(Color.orange.opacity(0.75), lineWidth: 2)
                    }
                }
        )
        .responsiveAnimation(.easeInOut(duration: 0.25), value: isHighlighted)
        .id(item.id)
        .opacity(isEffectivelyDone ? 0.6 : 1.0)
        .responsiveAnimation(.easeInOut(duration: 0.25), value: isEffectivelyDone)
        .responsiveAnimation(.easeInOut(duration: 0.2), value: item.status)
        .padding(.vertical, 6)
        .frame(minHeight: 56)
        .contextMenu {
            // 手势层只保留「分享」：编辑走点按行，置顶走左侧滑，其余能力
            // 统一收进编辑页的「快捷动作」区，避免同一能力散落在三处入口。
            Button("分享此待办卡片", systemImage: "square.and.arrow.up") {
                onShare?()
                Haptic.light()
            }
        } preview: {
            sharePreview
        }
        // 单按钮且非破坏性，放开整滑：手一划到底即可置顶，不必瞄准 72pt 按钮。
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if let onMoveToTop {
                Button {
                    onMoveToTop()
                } label: {
                    Label("置顶", systemImage: "arrow.up.to.line")
                }
                .tint(.orange)
            }
        }
        // 删除不可整滑直达：默认 allowsFullSwipe 为 true，一划到底会直接落库且无撤销。
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Haptic.warning()
                item.cleanupExternalIntegrations()
                context.delete(item)
                context.saveReportingFailure { SaveFailureCenter.shared.report($0, action: "删除待办") }
            } label: { Label("删除", systemImage: "trash") }
        }
        .themedRow()
    }

    private var completionButton: some View {
        Button {
            if item.status == .active {
                // 1. 播放成功震动与波纹动效
                Haptic.success()
                isAnimatingCompletion = true
                ringScale = 0.6
                ringOpacity = 1.0
                AppMotion.animate(.easeOut(duration: 0.65)) {
                    ringScale = 2.0
                    ringOpacity = 0.0
                }
                // 2. 延迟 0.70 秒（保留清晰的完成反馈体验，随后平滑移入已完成列表）
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.70) {
                    AppMotion.animate(.spring(response: 0.38, dampingFraction: 0.78)) {
                        item.markAsCompleted(in: context)
                        isAnimatingCompletion = false
                        ringScale = 0.5
                        ringOpacity = 0.0
                    }
                    // 完成待办是唯一事实源：落库失败时 rollback 会把状态退回未完成，
                    // 必须让用户知道（否则重启后「已完成」又变回待办）。
                    guard context.saveReportingFailure({ SaveFailureCenter.shared.report($0, action: "完成待办") }) else {
                        Haptic.error()
                        return
                    }
                    // 同步桌面/锁屏组件快照（含技能练习的「今日已打卡」状态）
                    WidgetSnapshotSyncController.shared.refreshSnapshot(context: context)
                }
            } else {
                // 反选/恢复为未完成
                Haptic.medium()
                AppMotion.animate(.spring(response: 0.3, dampingFraction: 0.75)) {
                    item.status = .active
                    TodoNotificationManager.shared.scheduleNotification(for: item)
                    isAnimatingCompletion = false
                }
                LifeEventTodoLink.syncTask(for: item, in: context)
                context.saveReportingFailure { SaveFailureCenter.shared.report($0, action: "恢复待办") }
            }
        } label: {
            ZStack {
                // 绿色波纹动效光环
                Circle()
                    .stroke(AppColor.success, lineWidth: 2)
                    .scaleEffect(ringScale)
                    .opacity(ringOpacity)
                    .frame(width: isSenior ? 34 : 24, height: isSenior ? 34 : 24)

                Image(systemName: isEffectivelyDone ? "checkmark.circle.fill" : "circle")
                    .font(isSenior ? .title : .title2)
                    .foregroundStyle(isEffectivelyDone ? AppColor.success : (seniorManager.isHighContrastEnabled ? Color.primary.opacity(0.65) : Color.secondary))
                    .scaleEffect(isAnimatingCompletion ? 1.25 : 1.0)
                    .responsiveAnimation(.spring(response: 0.28, dampingFraction: 0.5), value: isAnimatingCompletion)
            }
            .frame(width: isSenior ? 44 : 28, height: isSenior ? 44 : 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // VoiceOver：完成/取消完成待办的核心交互必须有可播报的状态与操作
        .accessibilityLabel(item.title)
        .accessibilityValue(isEffectivelyDone ? "已完成" : "未完成")
        .accessibilityHint(isEffectivelyDone ? "双击标记回未完成" : "双击完成该待办")
        .padding(.top, 2)
    }

    /// 主行：类型徽标 + 标题（或取件码）+ 至多一个主操作，右侧锚点位置恒定。
    private var primaryLine: some View {
        HStack(alignment: .center, spacing: 6) {
            if item.type == .parcel, let code = item.pickupCode, !code.isEmpty {
                Text(code)
                    .font(codeFont)
                    .foregroundStyle(isEffectivelyDone ? Color.secondary : Color.primary)
                    .strikethrough(isEffectivelyDone)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                copyCodeButton(code: code, accessibilityTitle: "复制取件码")
            } else {
                typeBadge
                Text(item.displayConciseTitle)
                    .font(titleFont)
                    .strikethrough(isEffectivelyDone)
                    .foregroundStyle(isEffectivelyDone ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)
            trailingAction
        }
        .frame(height: isSenior ? 30 : 24)
    }

    private var typeBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                .fill(typeColor.opacity(isEffectivelyDone ? 0.08 : 0.16))
                .frame(width: isSenior ? 28 : 22, height: isSenior ? 28 : 22)
            Image(systemName: item.type == .returnParcel ? "arrow.uturn.backward.circle.fill" : item.type.icon)
                .font(.caption2.bold())
                .foregroundStyle(isEffectivelyDone ? Color.secondary : (item.type == .returnParcel ? Color.indigo : typeColor))
        }
        .accessibilityHidden(true)
    }

    /// 右侧只留一个主操作（导航 / 复制寄件码 / 出示凭证，按类型与可用性择一）。
    /// 长辈模式的语音播报是无障碍刚需，作为唯一例外追加，其余能力都在编辑页快捷动作区。
    @ViewBuilder
    private var trailingAction: some View {
        HStack(spacing: 4) {
            if item.type == .returnParcel, let code = item.pickupCode, !code.isEmpty {
                copyIconButton(code: code)
            } else if let loc = navigationTarget {
                Button {
                    MapNavigationService.openDirections(to: loc)
                } label: {
                    Label("导航", systemImage: "arrow.triangle.turn.up.right.diamond")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("导航到\(loc)")
            } else if item.hasQRCodeOrTicket {
                Button {
                    onShowQRCode?()
                    Haptic.medium()
                } label: {
                    Image(systemName: item.hasQRCode ? "qrcode" : "photo")
                        .font(.subheadline.bold())
                        .foregroundStyle(.blue)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("快速调出预约二维码")
            }

            if seniorManager.isVoiceBroadcastEnabled {
                voiceButton
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func copyCodeButton(code: String, accessibilityTitle: String) -> some View {
        Button {
            copy(code)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                Text(isCopied ? "已复制" : "复制")
            }
            .font(.caption2.bold())
            .foregroundStyle(isCopied ? AppColor.success : AppColor.warning)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(isCopied
                    ? AppColor.softFill(AppColor.success, opacity: 0.15)
                    : AppColor.softFill(AppColor.warning, opacity: 0.12))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityHint("将取件码复制到剪贴板，便于在驿站时报出")
    }

    private func copyIconButton(code: String) -> some View {
        Button {
            copy(code)
        } label: {
            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                .font(.caption2)
                .foregroundStyle(isCopied ? AppColor.success : Color.secondary)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("复制寄件码")
        .accessibilityHint("将寄件码复制到剪贴板")
    }

    private func copy(_ code: String) {
        UIPasteboard.general.string = code
        Haptic.light()
        AppMotion.animate(.spring(duration: 0.2)) { isCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            AppMotion.animate { isCopied = false }
        }
    }

    private var voiceButton: some View {
        Button {
            let speechText: String = {
                if item.type == .parcel, let code = item.pickupCode {
                    let station = item.location ?? item.station ?? ""
                    return "快递取件码：\(code)，\(item.displayConciseTitle)。\(station)"
                } else if item.type == .returnParcel {
                    let codeStr = item.pickupCode.map { "，寄件码：\($0)" } ?? ""
                    return "退货待办：\(item.displayConciseTitle)\(codeStr)。\(item.displayConciseDetail ?? "")"
                } else {
                    return "\(item.displayConciseTitle)。\(item.displayConciseDetail ?? "")"
                }
            }()

            if seniorManager.isSpeaking && seniorManager.currentSpeakingId == item.id.uuidString {
                seniorManager.stopSpeaking()
            } else {
                Task { await seniorManager.speakSenior(text: speechText, id: item.id.uuidString) }
                Haptic.light()
            }
        } label: {
            let isCurrentSpeaking = seniorManager.isSpeaking && seniorManager.currentSpeakingId == item.id.uuidString
            Image(systemName: isCurrentSpeaking ? "speaker.wave.3.fill" : "speaker.wave.2")
                .font(isSenior ? .title3.bold() : .caption)
                .foregroundStyle(isCurrentSpeaking ? Color.orange : (isSenior ? Color.orange : Color.secondary.opacity(0.7)))
                .frame(width: isSenior ? 38 : 26, height: isSenior ? 38 : 26)
                .background(
                    Circle().fill(isCurrentSpeaking ? Color.orange.opacity(0.2) : (isSenior ? Color.orange.opacity(0.12) : Color.clear))
                )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel("朗读这条待办")
    }

    /// 长按预览只展示卡片内容，不放可点操作：菜单里唯一的动作就是分享。
    private var sharePreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            if item.type == .parcel || item.type == .returnParcel,
               let code = item.pickupCode, !code.isEmpty {
                Text(code)
                    .font(.title3.monospaced().bold())
                Text(item.displayConciseTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text(item.displayConciseTitle)
                    .font(.headline)
                    .lineLimit(2)
            }

            if let place = item.location ?? item.station, !place.isEmpty {
                Label(place, systemImage: "mappin.and.ellipse")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let due = item.dueAt {
                Text(due, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 240, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
    }
}

struct ReviewRow: View {
    @Environment(\.modelContext) private var context
    @Bindable var item: TodoItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("标题", text: $item.title, axis: .vertical)
                .font(.body)
            if let src = item.sourceText, src != item.title {
                Text(src).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            HStack {
                Button("加入待办") {
                    item.status = .active
                    context.saveReportingFailure { SaveFailureCenter.shared.report($0, action: "加入待办") }
                }
                .buttonStyle(.borderedProminent)
                Button("忽略", role: .destructive) {
                    context.delete(item)
                    context.saveReportingFailure { SaveFailureCenter.shared.report($0, action: "忽略待办") }
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
        .themedRow()
    }
}
